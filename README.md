# Web Analytics SQL  Advanced Query Portfolio

A GA4-style analytics data model with a set of advanced SQL queries solving real product-analytics problems: sessionization, attribution modeling, cohort retention, funnel conversion, and event deduplication.

This project mirrors the kind of query work done on production BI/analytics dashboards — reconstructing sessions from raw event streams, resolving attribution, and cleaning duplicate tracking data.

## Schema

Three tables, modeled loosely after a GA4 BigQuery export:

- **`users`** — one row per user, with signup date, country, device
- **`raw_events`** — raw, session-less event stream (`page_view`, `add_to_cart`, `begin_checkout`, `purchase`, etc.), each tagged with traffic source/medium/campaign
- **`orders`** — completed purchases, used for attribution

See [`schema.sql`](./schema.sql) for full DDL.

> Raw events intentionally ship **without** a `session_id` — real GA4 exports work the same way. Reconstructing sessions from timestamps is query #1 below.

## Queries

All queries live in [`queries.sql`](./queries.sql), written for PostgreSQL (minor syntax tweaks needed for MySQL/Sisense ElastiCube — noted inline where relevant).

| # | Query | Technique | Business question it answers |
|---|-------|-----------|-------------------------------|
| 1 | Sessionization | `LAG()`, running-sum window frame | Turn raw events into sessions using a 30-min inactivity rule |
| 2 | First-touch vs last-touch attribution | `ROW_NUMBER()` | Which marketing channel should get credit for a sale? |
| 3 | Weekly cohort retention | `DATE_TRUNC`, self-join | What % of each signup cohort is still active in later weeks? |
| 4 | Funnel conversion | Conditional aggregation (`CASE` + `SUM`) | Where are users dropping off: view → cart → checkout → purchase? |
| 5 | Rolling 7-day active users | Window frame (`ROWS BETWEEN`) | Smooth out daily traffic noise into a trend line |
| 6 | Engagement quartiles | `NTILE(4)` | Segment users into power-user vs at-risk buckets |
| 7 | Full navigation path per user | Recursive CTE | Reconstruct the exact page-by-page journey per user |
| 8 | Event deduplication | `ROW_NUMBER()` + partition tiebreaker | Remove duplicate-fired tracking events before reporting |

## Why this project

Most "SQL portfolio" repos stop at `JOIN` and `GROUP BY`. These queries instead tackle problems that actually come up when building analytics dashboards on top of messy, high-volume event data:

- Raw data rarely comes pre-sessionized — you have to build sessions yourself
- Attribution isn't a single "right answer" — first-touch and last-touch tell different stories
- Retention and funnel metrics need careful handling of NULLs and zero-division
- Tracking pixels double-fire in production, so dedup logic is a real, recurring need

## How to run

```bash
# PostgreSQL
createdb web_analytics
psql -d web_analytics -f schema.sql
# (add your own seed data, or generate synthetic data with a tool like Faker)
psql -d web_analytics -f queries.sql
```

## Tech

- PostgreSQL syntax (window functions, recursive CTEs, `DATE_TRUNC`)
- No ORM / no app layer — pure SQL, meant to be read

---

*Part of my analytics/BI portfolio — see my other repos for dashboard and ETL work.*
