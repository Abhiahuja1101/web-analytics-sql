-- ============================================================
-- Web Analytics Advanced SQL Project — Schema
-- Mimics a simplified GA4-style event/session data model
-- Compatible with PostgreSQL (minor tweaks needed for MySQL)
-- ============================================================

CREATE TABLE users (
    user_id         VARCHAR(20) PRIMARY KEY,
    first_seen_date DATE NOT NULL,
    country         VARCHAR(50),
    device_category VARCHAR(20)   -- desktop / mobile / tablet
);

CREATE TABLE raw_events (
    event_id        BIGINT PRIMARY KEY,
    user_id         VARCHAR(20) REFERENCES users(user_id),
    event_name      VARCHAR(50) NOT NULL,   -- page_view, add_to_cart, begin_checkout, purchase, etc.
    event_timestamp TIMESTAMP NOT NULL,
    page_path       VARCHAR(255),
    page_title      VARCHAR(255),
    traffic_source  VARCHAR(50),            -- google, direct, facebook, newsletter, etc.
    traffic_medium  VARCHAR(50),            -- organic, cpc, referral, email, none
    campaign        VARCHAR(100)
);

-- Note: raw_events intentionally has NO session_id.
-- Sessionizing raw event streams (30-min inactivity rule) is one
-- of the advanced query exercises in queries.sql — this mirrors
-- real GA4 export data, which also ships session-less at the row level.

CREATE TABLE orders (
    order_id        VARCHAR(20) PRIMARY KEY,
    user_id         VARCHAR(20) REFERENCES users(user_id),
    order_timestamp TIMESTAMP NOT NULL,
    order_value     DECIMAL(10,2) NOT NULL
);

-- Indexes to support the query patterns in queries.sql
CREATE INDEX idx_events_user_time ON raw_events(user_id, event_timestamp);
CREATE INDEX idx_events_name ON raw_events(event_name);
CREATE INDEX idx_orders_user ON orders(user_id);
