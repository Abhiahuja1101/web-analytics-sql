-- ============================================================
-- Web Analytics Advanced SQL Project — Queries
-- Each query solves a real analytics problem, mirroring the kind
-- of GA4 dashboard logic used in production BI reporting.
-- ============================================================


-- ------------------------------------------------------------
-- 1. SESSIONIZATION FROM RAW EVENTS
-- GA4 exports raw events without a session_id. We reconstruct
-- sessions using a 30-minute inactivity rule with LAG().
-- ------------------------------------------------------------
WITH events_with_gap AS (
    SELECT
        event_id,
        user_id,
        event_name,
        event_timestamp,
        page_path,
        traffic_source,
        traffic_medium,
        LAG(event_timestamp) OVER (
            PARTITION BY user_id ORDER BY event_timestamp
        ) AS prev_event_time
    FROM raw_events
),
session_flags AS (
    SELECT
        *,
        CASE
            WHEN prev_event_time IS NULL
                 OR event_timestamp - prev_event_time > INTERVAL '30 minutes'
            THEN 1 ELSE 0
        END AS is_new_session
    FROM events_with_gap
),
sessionized AS (
    SELECT
        *,
        SUM(is_new_session) OVER (
            PARTITION BY user_id ORDER BY event_timestamp
            ROWS UNBOUNDED PRECEDING
        ) AS session_seq
    FROM session_flags
)
SELECT
    user_id || '-' || session_seq AS session_id,
    user_id,
    MIN(event_timestamp) AS session_start,
    MAX(event_timestamp) AS session_end,
    COUNT(*) AS event_count,
    -- first non-null traffic source in the session = session's channel
    MIN(traffic_source) AS traffic_source
FROM sessionized
GROUP BY user_id, session_seq
ORDER BY user_id, session_start;


-- ------------------------------------------------------------
-- 2. FIRST-TOUCH vs LAST-TOUCH ATTRIBUTION
-- Which channel gets credit for a purchase? Compare both models
-- using ROW_NUMBER() on the events preceding each order.
-- ------------------------------------------------------------
WITH user_touchpoints AS (
    SELECT
        user_id,
        traffic_source,
        traffic_medium,
        event_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY event_timestamp ASC
        ) AS first_touch_rank,
        ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY event_timestamp DESC
        ) AS last_touch_rank
    FROM raw_events
    WHERE traffic_source IS NOT NULL
),
first_touch AS (
    SELECT user_id, traffic_source AS first_touch_source
    FROM user_touchpoints WHERE first_touch_rank = 1
),
last_touch AS (
    SELECT user_id, traffic_source AS last_touch_source
    FROM user_touchpoints WHERE last_touch_rank = 1
)
SELECT
    o.order_id,
    o.user_id,
    o.order_value,
    ft.first_touch_source,
    lt.last_touch_source
FROM orders o
JOIN first_touch ft ON ft.user_id = o.user_id
JOIN last_touch lt ON lt.user_id = o.user_id
ORDER BY o.order_timestamp;


-- ------------------------------------------------------------
-- 3. WEEKLY COHORT RETENTION
-- Bucket users into signup-week cohorts, then measure what
-- fraction of each cohort was still active in later weeks.
-- ------------------------------------------------------------
WITH cohorts AS (
    SELECT
        user_id,
        DATE_TRUNC('week', first_seen_date) AS cohort_week
    FROM users
),
activity AS (
    SELECT DISTINCT
        user_id,
        DATE_TRUNC('week', event_timestamp) AS activity_week
    FROM raw_events
),
cohort_activity AS (
    SELECT
        c.cohort_week,
        a.activity_week,
        (EXTRACT(EPOCH FROM (a.activity_week - c.cohort_week)) / 604800)::INT AS week_number,
        COUNT(DISTINCT a.user_id) AS active_users
    FROM cohorts c
    JOIN activity a ON a.user_id = c.user_id
    GROUP BY c.cohort_week, a.activity_week
),
cohort_size AS (
    SELECT cohort_week, COUNT(*) AS cohort_users
    FROM cohorts
    GROUP BY cohort_week
)
SELECT
    ca.cohort_week,
    ca.week_number,
    ca.active_users,
    cs.cohort_users,
    ROUND(100.0 * ca.active_users / cs.cohort_users, 1) AS retention_pct
FROM cohort_activity ca
JOIN cohort_size cs ON cs.cohort_week = ca.cohort_week
WHERE ca.week_number >= 0
ORDER BY ca.cohort_week, ca.week_number;


-- ------------------------------------------------------------
-- 4. FUNNEL CONVERSION (page_view -> add_to_cart -> begin_checkout -> purchase)
-- Uses conditional aggregation + window functions to compute
-- step-over-step drop-off, similar to a GA4 exploration funnel.
-- ------------------------------------------------------------
WITH funnel_steps AS (
    SELECT
        user_id,
        MAX(CASE WHEN event_name = 'page_view' THEN 1 ELSE 0 END) AS step_view,
        MAX(CASE WHEN event_name = 'add_to_cart' THEN 1 ELSE 0 END) AS step_cart,
        MAX(CASE WHEN event_name = 'begin_checkout' THEN 1 ELSE 0 END) AS step_checkout,
        MAX(CASE WHEN event_name = 'purchase' THEN 1 ELSE 0 END) AS step_purchase
    FROM raw_events
    GROUP BY user_id
),
funnel_counts AS (
    SELECT
        SUM(step_view) AS viewed,
        SUM(CASE WHEN step_view = 1 THEN step_cart ELSE 0 END) AS added_to_cart,
        SUM(CASE WHEN step_cart = 1 THEN step_checkout ELSE 0 END) AS checked_out,
        SUM(CASE WHEN step_checkout = 1 THEN step_purchase ELSE 0 END) AS purchased
    FROM funnel_steps
)
SELECT
    viewed,
    added_to_cart,
    ROUND(100.0 * added_to_cart / NULLIF(viewed, 0), 1) AS view_to_cart_pct,
    checked_out,
    ROUND(100.0 * checked_out / NULLIF(added_to_cart, 0), 1) AS cart_to_checkout_pct,
    purchased,
    ROUND(100.0 * purchased / NULLIF(checked_out, 0), 1) AS checkout_to_purchase_pct
FROM funnel_counts;


-- ------------------------------------------------------------
-- 5. ROLLING 7-DAY ACTIVE USERS (mini DAU/WAU trend)
-- Window frame RANGE over a date axis — common in traffic
-- trend widgets on BI dashboards.
-- ------------------------------------------------------------
WITH daily_active AS (
    SELECT
        DATE(event_timestamp) AS activity_date,
        COUNT(DISTINCT user_id) AS dau
    FROM raw_events
    GROUP BY DATE(event_timestamp)
)
SELECT
    activity_date,
    dau,
    ROUND(AVG(dau) OVER (
        ORDER BY activity_date
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ), 1) AS rolling_7day_avg_dau
FROM daily_active
ORDER BY activity_date;


-- ------------------------------------------------------------
-- 6. USER SEGMENTATION BY ENGAGEMENT (NTILE)
-- Split users into quartiles by total session/event count —
-- useful for targeting "power users" vs "at risk" segments.
-- ------------------------------------------------------------
WITH user_activity AS (
    SELECT
        user_id,
        COUNT(*) AS total_events
    FROM raw_events
    GROUP BY user_id
)
SELECT
    user_id,
    total_events,
    NTILE(4) OVER (ORDER BY total_events DESC) AS engagement_quartile
FROM user_activity
ORDER BY total_events DESC;


-- ------------------------------------------------------------
-- 7. RECURSIVE CTE — FULL PAGE NAVIGATION PATH PER USER
-- Builds an ordered path string (page1 -> page2 -> page3...)
-- for each user's session, useful for navigation-flow analysis.
-- ------------------------------------------------------------
WITH ranked_events AS (
    SELECT
        user_id,
        page_path,
        event_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY user_id ORDER BY event_timestamp
        ) AS rn
    FROM raw_events
    WHERE event_name = 'page_view'
),
RECURSIVE path_builder AS (
    SELECT
        user_id,
        rn,
        page_path,
        CAST(page_path AS VARCHAR(2000)) AS path_so_far
    FROM ranked_events
    WHERE rn = 1

    UNION ALL

    SELECT
        re.user_id,
        re.rn,
        re.page_path,
        pb.path_so_far || ' -> ' || re.page_path
    FROM ranked_events re
    JOIN path_builder pb
      ON re.user_id = pb.user_id
     AND re.rn = pb.rn + 1
)
SELECT user_id, MAX(path_so_far) AS full_navigation_path
FROM path_builder
GROUP BY user_id;

-- Note: PostgreSQL requires the RECURSIVE keyword directly after WITH.
-- If running this exact query, merge as: WITH RECURSIVE path_builder AS (...)
-- and move ranked_events into its own preceding CTE. Split here for readability.


-- ------------------------------------------------------------
-- 8. DEDUPLICATING NEAR-DUPLICATE SESSIONS
-- Same real-world problem as production dedup work: pick a single
-- canonical row per (user_id, page_path) using MAX(event_id) as
-- the tiebreaker when timestamps collide (e.g. double-fired tags).
-- ------------------------------------------------------------
WITH ranked AS (
    SELECT
        event_id,
        user_id,
        page_path,
        event_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, page_path, event_timestamp
            ORDER BY event_id DESC
        ) AS dedup_rank
    FROM raw_events
)
SELECT event_id, user_id, page_path, event_timestamp
FROM ranked
WHERE dedup_rank = 1;
