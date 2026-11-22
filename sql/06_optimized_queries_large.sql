-- =====================================================================
-- Zomato Food Delivery Database - Phase 5: optimized workload for the
-- large dataset (3,000,000 orders)
-- Team T0022 (Section B) - DE_Project_2026
--
-- A copy of sql/06_optimized_queries.sql (Phase 4) with two changes,
-- both found by running 06 on the large data:
--   R20  LATERAL per customer -> back to the original join + GROUP BY.
--        The LATERAL form wins on the seed data (7.3 vs 18.5 ms) but loses
--        on the large data (168 vs 102 ms): the original lets the planner
--        split the 80,000 Mumbai customers across parallel workers.
--   R23  keyset pagination: the "last seen" placed_at is re-read from the
--        large data, because page 4,000 ends at a different order there.
-- The other 28 queries are byte-for-byte the same as in 06.
--
-- Run 05_indexes.sql and 07_scale_fixes.sql first, then:
--   ./benchmarks/run_benchmark.sh <db> large 3 sql/06_optimized_queries_large.sql
-- Safe to run directly: everything is inside BEGIN ... ROLLBACK.
-- =====================================================================
SET search_path TO zomato;
BEGIN;

-- @R01
-- Home feed: open restaurants in Koramangala, best rated first
SELECT r.restaurant_id, r.name, r.cuisines, r.avg_cost_for_two, r.rating
FROM restaurants r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.locality_name = 'Koramangala'
  AND r.status = 'OPEN'
ORDER BY r.rating DESC NULLS LAST
LIMIT 20;

-- @R02
-- Dish search: available "paneer" dishes in Bengaluru
SELECT m.item_id, m.item_name, m.price, r.name AS restaurant
FROM menu_items m
JOIN restaurants r ON r.restaurant_id = m.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE l.city_id = 1
  AND m.is_available
  AND m.item_name ILIKE '%paneer%'
ORDER BY m.price
LIMIT 50;

-- @R03
-- Restaurant page: the menu of one restaurant, grouped by category
SELECT category, item_name, price, is_veg, is_bestseller
FROM menu_items
WHERE restaurant_id = 217 AND is_available
ORDER BY category, is_bestseller DESC, item_name;

-- @R04
-- "Your orders": a customer's last 10 orders with restaurant names
SELECT o.order_id, r.name AS restaurant, o.status, o.total_amount, o.placed_at
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
WHERE o.customer_id = 1042
ORDER BY o.placed_at DESC
LIMIT 10;

-- @R05
-- Kitchen-delay alert: orders stuck in PREPARING for over 40 minutes (checked at 23:59 on 30 Jun 2026)
SELECT order_id, restaurant_id, accepted_at
FROM orders
WHERE status = 'PREPARING'
  AND accepted_at < TIMESTAMPTZ '2026-06-30 23:59:00+05:30' - interval '40 minutes'
ORDER BY accepted_at;

-- @R06
-- Restaurant partner app: all orders received by restaurant 217 on 15 June 2026
-- REWRITE: DATE(placed_at) hides the column inside a function, so no
-- index on placed_at can be used. DATE() of a timestamptz takes the day
-- in the session TimeZone, and so do the two literals below, which makes
-- the range return exactly the same rows in any TimeZone.
-- Uses orders_restaurant_placed_idx (restaurant_id =, placed_at range).
SELECT order_id, status, item_total, placed_at
FROM orders
WHERE restaurant_id = 217
  AND placed_at >= '2026-06-15' AND placed_at < '2026-06-16'
ORDER BY placed_at;

-- @R07
-- Restaurant partner app: units sold per dish in May 2026
SELECT m.item_name, sum(oi.quantity) AS units, sum(oi.quantity * oi.unit_price) AS sales
FROM order_items oi
JOIN orders o     ON o.order_id = oi.order_id
JOIN menu_items m ON m.item_id  = oi.item_id
WHERE o.restaurant_id = 217
  AND o.status = 'DELIVERED'
  AND o.placed_at >= '2026-05-01' AND o.placed_at < '2026-06-01'
GROUP BY m.item_name
ORDER BY units DESC;

-- @R08
-- Bestseller badges: top 3 dishes of every Pune restaurant in the last 30 days
SELECT *
FROM (
    SELECT o.restaurant_id, oi.item_id, sum(oi.quantity) AS units,
           RANK() OVER (PARTITION BY o.restaurant_id ORDER BY sum(oi.quantity) DESC) AS rnk
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    JOIN restaurants r  ON r.restaurant_id = o.restaurant_id
    JOIN localities l   ON l.locality_id = r.locality_id
    WHERE l.city_id = 6
      AND o.status = 'DELIVERED'
      AND o.placed_at >= '2026-06-01'
    GROUP BY o.restaurant_id, oi.item_id
) t
WHERE rnk <= 3
ORDER BY restaurant_id, rnk;

-- @R09
-- Ops dashboard: average delivery time (minutes) per city per month in 2026
-- REWRITE: reads the 60 rows of mv_city_month_delivery (sql/05_indexes.sql)
-- instead of aggregating 43,141 orders. avg(x) is sum(x) / count, so
-- round(sum_minutes / deliveries, 1) is the original value. month is the
-- date_trunc of placed_at, so "month in 2026" is "placed_at in 2026".
-- The view is refreshed nightly; this dashboard shows finished months.
--
-- Live version, if the view is not wanted (sargable year range instead of
-- EXTRACT(YEAR ...), Index Only Scan on orders_placed_at_idx):
--   SELECT l.city_id, date_trunc('month', o.placed_at) AS month,
--          round(avg(EXTRACT(EPOCH FROM (o.delivered_at - o.placed_at)) / 60), 1) AS avg_minutes
--   FROM orders o
--   JOIN restaurants r ON r.restaurant_id = o.restaurant_id
--   JOIN localities l  ON l.locality_id   = r.locality_id
--   WHERE o.status = 'DELIVERED'
--     AND o.placed_at >= '2026-01-01' AND o.placed_at < '2027-01-01'
--   GROUP BY 1, 2
--   ORDER BY 1, 2;
--
-- Same-result check (both counts must be 0):
--   WITH old AS (<original R09 without ORDER BY>), new AS (<this query>)
--   SELECT (SELECT count(*) FROM (TABLE old EXCEPT TABLE new) a),
--          (SELECT count(*) FROM (TABLE new EXCEPT TABLE old) b);
SELECT city_id, month, round(sum_minutes / deliveries, 1) AS avg_minutes
FROM mv_city_month_delivery
WHERE month >= '2026-01-01' AND month < '2027-01-01'
ORDER BY 1, 2;

-- @R10
-- Customer support: deliveries in June 2026 that took more than 60 minutes
SELECT order_id, customer_id, restaurant_id, placed_at, delivered_at
FROM orders
WHERE delivered_at - placed_at > interval '60 minutes'
  AND placed_at >= '2026-06-01' AND placed_at < '2026-07-01'
ORDER BY delivered_at - placed_at DESC
LIMIT 100;

-- @R11
-- Delivery partner app: this week's earnings (delivery fees) for partner 150
SELECT count(*) AS deliveries, sum(delivery_fee) AS fees_earned
FROM orders
WHERE partner_id = 150
  AND status = 'DELIVERED'
  AND placed_at >= '2026-06-22' AND placed_at < '2026-06-29';

-- @R12
-- Dispatch: orders still waiting for a delivery partner, oldest first
SELECT o.order_id, o.restaurant_id, o.status, o.placed_at
FROM orders o
WHERE o.partner_id IS NULL
  AND o.status IN ('PLACED', 'ACCEPTED')
ORDER BY o.placed_at
LIMIT 50;

-- @R13
-- Fleet team: active Bengaluru partners who have not been assigned any order since 25 June 2026
-- WRONG RESULT FIXED: the original returns 0 rows. Orders placed since
-- 25 June include 214 with partner_id NULL (not yet assigned, or
-- cancelled before assignment). "x NOT IN (..., NULL)" is never TRUE:
-- for a partner not in the list it is x <> NULL, which is NULL, so WHERE
-- drops every partner. That is problem P6, "the idle-partner list came
-- back empty". NOT EXISTS compares row by row, and o.partner_id = p.partner_id
-- is simply false for a NULL partner_id, so NULLs no longer matter.
-- This is the one query whose result is meant to change.
-- The plan reads the 1,648 orders since 25 June from orders_placed_at_idx
-- (partner_id is in its INCLUDE) and hash anti-joins the 285 partners.
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND NOT EXISTS (SELECT 1 FROM orders o
                  WHERE o.partner_id = p.partner_id
                    AND o.placed_at >= '2026-06-25');

-- @R14
-- Gold team: Gold members whose membership expires before July 2026 but who ordered in June 2026
SELECT c.customer_id, c.full_name, c.gold_expires_on
FROM customers c
WHERE c.is_gold_member
  AND c.gold_expires_on < '2026-07-01'
  AND EXISTS (SELECT 1 FROM orders o
              WHERE o.customer_id = c.customer_id
                AND o.placed_at >= '2026-06-01' AND o.placed_at < '2026-07-01');

-- @R15
-- Marketing: coupon effectiveness (orders, total discount, average bill)
SELECT c.coupon_code, c.discount_pct, count(o.order_id) AS orders,
       coalesce(sum(o.discount), 0) AS total_discount, round(avg(o.total_amount), 2) AS avg_bill
FROM coupons c
LEFT JOIN orders o ON o.coupon_code = c.coupon_code AND o.status = 'DELIVERED'
GROUP BY c.coupon_code, c.discount_pct
ORDER BY orders DESC;

-- @R16
-- Payments team: failed payment attempts per method in the last 7 days
SELECT method, count(*) AS failed_attempts
FROM payments
WHERE payment_status = 'FAILED'
  AND attempted_at >= '2026-06-24'
GROUP BY method
ORDER BY failed_attempts DESC;

-- @R17
-- Risk team: customers with 2 or more failed payment attempts (all time)
SELECT o.customer_id, count(*) AS failed_attempts
FROM payments p
JOIN orders o ON o.order_id = p.order_id
WHERE p.payment_status = 'FAILED'
GROUP BY o.customer_id
HAVING count(*) >= 2
ORDER BY failed_attempts DESC, o.customer_id;

-- @R18
-- Review moderation: newest reviews that complain about cold food or late delivery
SELECT review_id, restaurant_id, food_rating, review_text, created_at
FROM reviews
WHERE review_text ILIKE '%cold%' OR review_text ILIKE '%late%'
ORDER BY created_at DESC
LIMIT 50;

-- @R19
-- Restaurant health report for Bengaluru: last order time, delivered orders and average food rating
SELECT r.restaurant_id, r.name,
       (SELECT max(o.placed_at) FROM orders o WHERE o.restaurant_id = r.restaurant_id) AS last_order_at,
       (SELECT count(*) FROM orders o WHERE o.restaurant_id = r.restaurant_id AND o.status = 'DELIVERED') AS delivered_orders,
       (SELECT round(avg(v.food_rating), 2) FROM reviews v WHERE v.restaurant_id = r.restaurant_id) AS avg_food_rating
FROM restaurants r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.city_id = 1
ORDER BY last_order_at DESC NULLS LAST;

-- @R20
-- Growth: top 20 customers in Mumbai by total spend on delivered orders
-- PHASE 5: back to the original query text. Phase 4 rewrote it as a
-- LATERAL aggregate per Mumbai customer, which was 2.5x faster on 4,000
-- customers. On the large data there are 80,000 Mumbai customers and the
-- LATERAL form runs serially: 168 ms (3 runs: 167-171 ms). The original
-- runs as a Parallel Index Scan on customers_pkey, filtered on city_id,
-- with an Index Only Scan on orders_customer_placed_idx per customer
-- spread over 3 processes, then a Partial / Finalize GroupAggregate:
-- 102 ms. Same index, same per-customer probe, so the original returns
-- the same rows (checked by benchmarks/equivalence_checks.py on the
-- large database).
SELECT c.customer_id, c.full_name, count(*) AS orders, sum(o.total_amount) AS lifetime_spend
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
WHERE c.city_id = 2 AND o.status = 'DELIVERED'
GROUP BY c.customer_id, c.full_name
ORDER BY lifetime_spend DESC
LIMIT 20;

-- @R21
-- Growth: share of customers in each city who ordered at least twice in May 2026
WITH may AS (
    SELECT customer_id, count(*) AS n
    FROM orders
    WHERE placed_at >= '2026-05-01' AND placed_at < '2026-06-01'
    GROUP BY customer_id
)
SELECT c.city_id,
       count(*) AS ordering_customers,
       count(*) FILTER (WHERE may.n >= 2) AS repeat_customers,
       round(100.0 * count(*) FILTER (WHERE may.n >= 2) / count(*), 1) AS repeat_pct
FROM may
JOIN customers c ON c.customer_id = may.customer_id
GROUP BY c.city_id
ORDER BY c.city_id;

-- @R22
-- Ops heatmap: Bengaluru orders by weekday and hour, last 8 weeks
SELECT EXTRACT(ISODOW FROM o.placed_at) AS weekday, EXTRACT(HOUR FROM o.placed_at) AS hour, count(*) AS orders
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE l.city_id = 1
  AND o.placed_at >= TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '8 weeks'
GROUP BY 1, 2
ORDER BY 1, 2;

-- @R23
-- Admin panel: "All orders", newest first, page 4,001 (25 rows per page)
-- REWRITE (Phase 4): keyset pagination instead of OFFSET 100000. The
-- admin panel already has page 4,000 on screen, so it sends that page's
-- last placed_at and asks for the next 25 older orders.
--
-- PHASE 5, the last-seen value on the large data. Page 4,000 ends at
-- row 100,000 newest first, read the same way as on the seed data:
--   SELECT placed_at FROM orders ORDER BY placed_at DESC OFFSET 99999 LIMIT 1;
--   -> 2026-06-12 19:12:00+05:30   (seed data: 2025-07-02 00:00:00+05:30)
-- With 20x the orders in the same 18 months, 100,000 rows now cover
-- only the last 18 days instead of the last 12 months. placed_at is
-- still unique (3,000,000 rows, 3,000,000 distinct values), so
-- "< last seen" neither skips nor repeats a row. In the app the value
-- is never computed like this: it is the placed_at of the 25th row of
-- the page already shown, so there is no OFFSET at any table size.
SELECT order_id, customer_id, restaurant_id, status, total_amount, placed_at
FROM orders
WHERE placed_at < '2026-06-12 19:12:00+05:30'
ORDER BY placed_at DESC
LIMIT 25;

-- @R24
-- Bill page: one order with its items, restaurant and successful payment
SELECT o.order_id, o.placed_at, r.name AS restaurant, m.item_name, oi.quantity, oi.unit_price,
       o.total_amount, p.method
FROM orders o
JOIN restaurants r  ON r.restaurant_id = o.restaurant_id
JOIN order_items oi ON oi.order_id = o.order_id
JOIN menu_items m   ON m.item_id = oi.item_id
LEFT JOIN payments p ON p.order_id = o.order_id AND p.payment_status = 'SUCCESS'
WHERE o.order_id = 123457;

-- @R25
-- Cuisine filter: open Chinese restaurants in Pune
SELECT r.restaurant_id, r.name, r.cuisines, r.rating
FROM restaurants r
JOIN localities l ON l.locality_id = r.locality_id
WHERE l.city_id = 6
  AND r.status = 'OPEN'
  AND 'Chinese' = ANY (r.cuisines)
ORDER BY r.rating DESC NULLS LAST;

-- @W01
-- Customer app: place a new order (header row)
INSERT INTO orders (order_id, customer_id, restaurant_id, placed_at, distance_km,
                    item_total, delivery_fee, discount, total_amount, status)
VALUES (90000001, 1042, 217, '2026-07-01 13:05:00+05:30', 3.2, 540.00, 25.00, 0.00, 565.00, 'PLACED');

-- @W02
-- Dispatch: assign partner 150 to the oldest accepted order that has no partner
UPDATE orders
SET partner_id = 150, status = 'PREPARING'
WHERE order_id = (SELECT order_id FROM orders
                  WHERE partner_id IS NULL AND status = 'ACCEPTED'
                  ORDER BY placed_at
                  LIMIT 1);

-- @W03
-- Restaurant partner app: desserts sold out, so hide them
UPDATE menu_items
SET is_available = FALSE
WHERE restaurant_id = 217 AND category = 'Desserts';

-- @W04
-- Nightly job: recompute every restaurant's rating from its reviews
-- REWRITE: the original writes a new version of every reviewed
-- restaurant every night, even when its rating did not change. That is
-- 2,390 dead tuples a night and 2,390 updates of
-- restaurants_locality_status_rating_idx, whose key includes rating.
-- The extra condition skips rows that would stay the same, so the table
-- ends up identical. On the seed data every restaurant's stored rating
-- differs from its reviews, so all 2,390 rows still change and the
-- benchmark will not show a gain; on later nights only restaurants with
-- new reviews are written.
UPDATE restaurants r
SET rating = s.avg_rating, rating_count = s.n
FROM (SELECT restaurant_id, round(avg(food_rating), 1) AS avg_rating, count(*) AS n
      FROM reviews GROUP BY restaurant_id) s
WHERE s.restaurant_id = r.restaurant_id
  AND (r.rating IS DISTINCT FROM s.avg_rating OR r.rating_count IS DISTINCT FROM s.n);

-- @W05
-- Nightly job: end Gold membership for customers whose plan has expired
UPDATE customers
SET is_gold_member = FALSE
WHERE is_gold_member
  AND gold_expires_on < '2026-07-01';

-- @END
ROLLBACK;
