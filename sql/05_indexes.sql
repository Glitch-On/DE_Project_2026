-- =====================================================================
-- Zomato Food Delivery Database - Phase 4: indexes
-- Team T0022 (Section B) - DE_Project_2026
--
-- Run after 01_schema.sql and 02_load_data.sql:
--   psql -d <db> -X -v ON_ERROR_STOP=1 -f sql/05_indexes.sql
-- Then benchmark the rewritten workload:
--   ./benchmarks/run_benchmark.sh <db> optimized 5 sql/06_optimized_queries.sql
--
-- Safe to re-run: every object uses IF NOT EXISTS.
--
-- Every index below says which queries it serves and why it has this
-- type and column order. Rules used throughout:
--   * equality columns first, then the range / ORDER BY column, so one
--     index range scan returns the rows already filtered and sorted;
--   * INCLUDE (...) adds the other columns a query reads, so the plan
--     becomes an Index Only Scan and never visits the table;
--   * a WHERE clause (partial index) when a query only wants a rare
--     status, so the index stays a few kB however big orders gets.
--
-- Indexes tried and left out, with the reason:
--   * GIN trigram on menu_items.item_name for R02: 'paneer' matches 5,288
--     of 50,000 dishes (about 10%), so the bitmap scan plus join took
--     3.5 ms, slower than the current 2.3 ms plan through
--     menu_items_restaurant_item_key. The planner does not pick it either.
--   * customers (city_id) for R20/R21: Mumbai is 4,000 of 25,000
--     customers (16%); the planner keeps the 1 ms seq scan.
--   * a covering (order_id) INCLUDE (customer_id) for R17: the planner
--     still prefers one hash join over 6,965 index probes.
--   * anything for R03 / W03: menu_items_restaurant_item_key already
--     finds one restaurant's ~20 dishes in under 0.1 ms.
-- =====================================================================

SET search_path TO zomato;

-- ---------------------------------------------------------------------
-- restaurants
-- ---------------------------------------------------------------------

-- R01 (home feed: open restaurants in one locality, best rated first).
-- locality_id and status are the equality filters, then rating in the
-- exact order R01 sorts by (DESC NULLS LAST), so the matching rows come
-- out of the index already sorted. Leading with locality_id also gives
-- the foreign key restaurants.locality_id an index.
-- R25 filters on the same (locality_id, status = 'OPEN'), but on 2,500
-- restaurants the planner still seq-scans for it.
CREATE INDEX IF NOT EXISTS restaurants_locality_status_rating_idx
    ON restaurants (locality_id, status, rating DESC NULLS LAST);

-- ---------------------------------------------------------------------
-- orders (150,000 rows, the table almost every query reads)
-- ---------------------------------------------------------------------

-- R04 (a customer's last 10 orders), R20 (lifetime spend per Mumbai
-- customer, LATERAL form in 06).
-- customer_id is the equality, placed_at DESC matches R04's ORDER BY, so
-- LIMIT 10 reads 10 entries and no sort is needed. INCLUDE (status,
-- total_amount) is for R20: it sums each customer's DELIVERED orders
-- with an Index Only Scan. Also indexes the foreign key orders.customer_id.
CREATE INDEX IF NOT EXISTS orders_customer_placed_idx
    ON orders (customer_id, placed_at DESC)
    INCLUDE (status, total_amount);

-- R06 (one restaurant's orders on one day), R07 (one restaurant's May
-- sales), R19 (last order and delivered count per restaurant), R22
-- (Bengaluru heatmap, last 8 weeks).
-- restaurant_id equality, then placed_at for the date range (R06, R07,
-- R22) and for max(placed_at) in R19, which becomes a single backward
-- step. status is in INCLUDE because R07 and R19 filter on DELIVERED;
-- with it R19's two subqueries and R22 are Index Only Scans. R19 drops
-- from 4.5 s to 3.5 ms: each of its 250 restaurants now costs two index
-- probes instead of two seq scans of orders.
-- R06 only uses this index after the rewrite in 06 (DATE(placed_at) is
-- not sargable). Also indexes the foreign key orders.restaurant_id.
CREATE INDEX IF NOT EXISTS orders_restaurant_placed_idx
    ON orders (restaurant_id, placed_at)
    INCLUDE (status);

-- R11 (one partner's delivered orders this week).
-- partner_id equality, then the placed_at range. Also indexes the
-- foreign key orders.partner_id (ON DELETE SET NULL would otherwise
-- scan orders).
CREATE INDEX IF NOT EXISTS orders_partner_placed_idx
    ON orders (partner_id, placed_at);

-- R08 (Pune bestsellers since 1 June), R10 (slow deliveries in June),
-- R13 (partners with an order since 25 June), R14 (customers with an
-- order in June), R21 (May orders per customer), R23 (admin list newest
-- first), and the live form of R09.
-- All of them filter or sort on placed_at alone, so it is the only key
-- column. INCLUDE holds what they read from orders: order_id (R08, R10,
-- R23), customer_id (R10, R14, R21), restaurant_id (R08, R10),
-- partner_id (R13), status (R08, R09) and delivered_at (R09, R10). Each
-- becomes an Index Only Scan over one date range, which is why this is
-- the widest index here.
CREATE INDEX IF NOT EXISTS orders_placed_at_idx
    ON orders (placed_at)
    INCLUDE (order_id, customer_id, restaurant_id, partner_id, status, delivered_at);

-- R05 (orders stuck in PREPARING).
-- Partial: only 37 of 150,000 orders are PREPARING. Keyed on
-- accepted_at, which is both the range filter and the ORDER BY.
CREATE INDEX IF NOT EXISTS orders_preparing_accepted_idx
    ON orders (accepted_at)
    WHERE status = 'PREPARING';

-- R12 (orders waiting for a partner, oldest first), W02 (assign the
-- oldest ACCEPTED order with no partner).
-- Partial on the exact predicate of R12 (75 rows). W02's predicate
-- (partner_id IS NULL AND status = 'ACCEPTED') implies it, so the
-- planner uses the same index. Keyed on placed_at for the ORDER BY ...
-- LIMIT in both.
CREATE INDEX IF NOT EXISTS orders_unassigned_placed_idx
    ON orders (placed_at)
    WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED');

-- R15 (coupon effectiveness).
-- Partial on delivered orders that used a coupon, keyed on coupon_code
-- for the join from coupons. The join "o.coupon_code = c.coupon_code" can
-- never match a NULL code, so leaving those rows out changes nothing and
-- shrinks the index from 5.3 MB to 824 kB. INCLUDE (order_id, discount,
-- total_amount) covers count(o.order_id), sum(discount) and
-- avg(total_amount), so the ~17,600 coupon orders are read from the
-- index alone.
CREATE INDEX IF NOT EXISTS orders_delivered_coupon_idx
    ON orders (coupon_code)
    INCLUDE (order_id, discount, total_amount)
    WHERE status = 'DELIVERED' AND coupon_code IS NOT NULL;

-- ---------------------------------------------------------------------
-- payments
-- ---------------------------------------------------------------------

-- R24 (bill page: the successful payment of one order).
-- Without it R24 seq-scans 137,378 payments to find one order's rows.
-- Also indexes the foreign key payments.order_id (ON DELETE CASCADE).
CREATE INDEX IF NOT EXISTS payments_order_id_idx
    ON payments (order_id);

-- R16 (failed attempts per method, last 7 days), R17 (customers with 2+
-- failed attempts).
-- Partial on FAILED (6,965 of 137,378 rows). attempted_at is the key for
-- R16's range; INCLUDE (method, order_id) makes R16 an Index Only Scan
-- and gives R17 its order ids without touching the table.
CREATE INDEX IF NOT EXISTS payments_failed_attempted_idx
    ON payments (attempted_at)
    INCLUDE (method, order_id)
    WHERE payment_status = 'FAILED';

-- ---------------------------------------------------------------------
-- reviews
-- ---------------------------------------------------------------------

-- R19 (average food rating per restaurant).
-- restaurant_id equality; INCLUDE (food_rating) so avg() is answered
-- from the index. Also indexes the foreign key reviews.restaurant_id.
CREATE INDEX IF NOT EXISTS reviews_restaurant_idx
    ON reviews (restaurant_id)
    INCLUDE (food_rating);

-- R18 (newest reviews mentioning cold or late).
-- 2,924 of 39,186 reviews match, about 1 in 13, so walking the reviews
-- newest first finds 50 matches after about 780 entries and stops. A trigram
-- index would find all 2,924 and then sort them; this is cheaper.
CREATE INDEX IF NOT EXISTS reviews_created_at_idx
    ON reviews (created_at DESC);

-- ---------------------------------------------------------------------
-- customers
-- ---------------------------------------------------------------------

-- R14 (Gold members expiring before July), W05 (end expired Gold plans).
-- Partial on is_gold_member (3,792 of 25,000), keyed on gold_expires_on
-- for the "< 2026-07-01" range both queries use.
CREATE INDEX IF NOT EXISTS customers_gold_expiry_idx
    ON customers (gold_expires_on)
    WHERE is_gold_member;

-- ---------------------------------------------------------------------
-- Summary table for R09
-- ---------------------------------------------------------------------

-- R09 (average delivery minutes per city per month) has to read every
-- delivered order of 2026, 43,141 rows; with orders_placed_at_idx that
-- is an Index Only Scan, but the join, sort and date_trunc still cost
-- about 20 ms, no faster than the baseline. A dashboard of past months
-- does not need live data, so the per-row work is done once here.
--
-- It stores the sum and count rather than the average so that
-- round(sum_minutes / deliveries, 1) in 06 gives the same value as the
-- original round(avg(...), 1). The EXCEPT check under @R09 in
-- 06_optimized_queries.sql shows the two return the same 60 rows.
--
-- Refresh: nightly, after the day's orders are delivered:
--   REFRESH MATERIALIZED VIEW CONCURRENTLY mv_city_month_delivery;
-- CONCURRENTLY needs the unique index below and does not block readers.
-- date_trunc('month', timestamptz) depends on the session TimeZone, as
-- does the original query: refresh with the same TimeZone the dashboard
-- uses (Asia/Kolkata here).
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_city_month_delivery AS
SELECT l.city_id,
       date_trunc('month', o.placed_at)                              AS month,
       sum(EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60)  AS sum_minutes,
       count(*)                                                      AS deliveries
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE o.status = 'DELIVERED'
GROUP BY 1, 2;

CREATE UNIQUE INDEX IF NOT EXISTS mv_city_month_delivery_key
    ON mv_city_month_delivery (city_id, month);

-- ---------------------------------------------------------------------
-- Statistics and visibility map
-- ---------------------------------------------------------------------
-- ANALYZE gives the planner statistics for the new indexes. VACUUM sets
-- the visibility map, without which an Index Only Scan still visits the
-- table for every row ("Heap Fetches" in the plan).
VACUUM ANALYZE;

-- ---------------------------------------------------------------------
-- Index storage, for the report: each index next to its table
-- ---------------------------------------------------------------------
SELECT t.relname                                   AS table_name,
       i.relname                                   AS index_name,
       pg_size_pretty(pg_relation_size(i.oid))     AS index_size,
       pg_size_pretty(pg_relation_size(t.oid))     AS table_size,
       round(100.0 * pg_relation_size(i.oid) / nullif(pg_relation_size(t.oid), 0), 1) AS pct_of_table
FROM pg_index x
JOIN pg_class i     ON i.oid = x.indexrelid
JOIN pg_class t     ON t.oid = x.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'zomato'
  AND NOT x.indisprimary
  AND NOT x.indisunique
   OR i.relname = 'mv_city_month_delivery_key'
ORDER BY t.relname, i.relname;
