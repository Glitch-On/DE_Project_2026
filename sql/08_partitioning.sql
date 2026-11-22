-- =====================================================================
-- Zomato Food Delivery Database - Phase 5: partitioning orders
-- Team T0022 (Section B) - DE_Project_2026
--
-- Run on the large database after 01, 02 (large_data/), 05 and 07:
--   psql -d <db> -X -v ON_ERROR_STOP=1 -f sql/08_partitioning.sql \
--        > benchmarks/results/large/partitioning_explain.txt
--
-- What it does: builds a RANGE-partitioned copy of orders, one
-- partition per month of placed_at, in its own schema zomato_part, loads
-- the 3,000,000 orders into it, and prints EXPLAIN plans that show
-- partition pruning. zomato.orders is not touched, so the benchmark
-- numbers are not affected. Remove the copy with
--   DROP SCHEMA zomato_part CASCADE;
-- The cutover steps for production are at the end (commented out).
--
-- Why orders, and why RANGE on placed_at (full reasoning and numbers in
-- docs/05_scalability_report.md, section 6.1):
--   * orders is the table that grows: 357 MB heap + 661 MB of indexes on
--     the large data, 3,000,000 rows. At 100x the seed volume it is
--     15,000,000 rows (about 1.8 GB heap, 3 GB of indexes).
--   * 11 of the 30 queries filter orders on a placed_at range (R06,
--     R07, R08, R09, R10, R11, R13, R14, R21, R22, R23) and 4 more sort
--     on it (R04, R12, R19, W02). Most only want the last days or weeks.
--   * Old months are never updated again, so they can be archived by
--     detaching a partition instead of a 1-million-row DELETE.
--   * LIST does not fit (no small set of values), HASH spreads every
--     month over every partition and so prunes nothing for a date range.
--   * Monthly: about 167,000 orders a month on the large data (833,000
--     at 100x), small enough that one partition and its indexes fit in
--     memory, and few enough partitions (12 a year) for the planner.
-- =====================================================================

SET search_path TO zomato;
\timing off
\pset pager off

DROP SCHEMA IF EXISTS zomato_part CASCADE;
CREATE SCHEMA zomato_part;

-- ---------------------------------------------------------------------
-- 1. The primary-key rule for partitioned tables
-- ---------------------------------------------------------------------
-- A PRIMARY KEY or UNIQUE constraint on a partitioned table must contain
-- every partition-key column. Each partition enforces uniqueness only
-- inside itself; including placed_at guarantees two rows with the same
-- key can never sit in different partitions. So PRIMARY KEY (order_id)
-- is rejected. This block shows the error PostgreSQL gives.
CREATE TABLE zomato_part.pk_rule_demo (
    order_id  integer     NOT NULL,
    placed_at timestamptz NOT NULL
) PARTITION BY RANGE (placed_at);

DO $$
BEGIN
    ALTER TABLE zomato_part.pk_rule_demo ADD PRIMARY KEY (order_id);
EXCEPTION WHEN others THEN
    RAISE NOTICE 'PRIMARY KEY (order_id) rejected: %', SQLERRM;
END $$;

DROP TABLE zomato_part.pk_rule_demo;

-- ---------------------------------------------------------------------
-- 2. The partitioned orders table
-- ---------------------------------------------------------------------
-- LIKE ... INCLUDING CONSTRAINTS copies every column, NOT NULL, DEFAULT
-- and all 19 CHECK constraints of zomato.orders from 01_schema.sql. It
-- does not copy keys, so they are written out here.
--
-- Primary key: (order_id, placed_at), because of the rule above.
-- order_id is still unique in practice (it comes from one sequence),
-- but the database can no longer enforce "order_id alone is unique".
--
-- Foreign keys FROM orders (to customers, restaurants, partners,
-- coupons) work as before.
--
-- Foreign keys TO orders are the catch. order_items, payments and
-- reviews reference orders (order_id), and a foreign key needs a
-- unique constraint on exactly the referenced columns, which now has to
-- be (order_id, placed_at). There are two ways out:
--   a) add placed_at to the three child tables and reference
--      (order_id, placed_at). Correct and enforced; 8 bytes more per
--      child row (7.5 M order_items = about 60 MB on the large data).
--   b) drop those three foreign keys and check them in the application
--      or a nightly integrity query (sql/03_integrity_checks.sql).
-- We choose (a): the child rows are written in the same transaction as
-- the order, which already knows placed_at, and the bill page (R24) can
-- then prune to one partition. Section 4 below shows it for
-- order_items.
CREATE TABLE zomato_part.orders (
    LIKE zomato.orders INCLUDING DEFAULTS INCLUDING CONSTRAINTS,
    CONSTRAINT orders_pkey PRIMARY KEY (order_id, placed_at),
    CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id)
        REFERENCES zomato.customers (customer_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT orders_restaurant_id_fkey FOREIGN KEY (restaurant_id)
        REFERENCES zomato.restaurants (restaurant_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT orders_partner_id_fkey FOREIGN KEY (partner_id)
        REFERENCES zomato.delivery_partners (partner_id) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT orders_coupon_code_fkey FOREIGN KEY (coupon_code)
        REFERENCES zomato.coupons (coupon_code) ON DELETE SET NULL ON UPDATE CASCADE
) PARTITION BY RANGE (placed_at);

-- One partition per month, January 2025 to December 2026. The bounds
-- are written with the +05:30 offset so a month means an IST month,
-- the same months the reports use. FROM is inclusive, TO is exclusive,
-- so 23:59:59 on the last day is in the right month and midnight on the
-- 1st is in the next. The first one, written out:
--   CREATE TABLE zomato_part.orders_2025_01 PARTITION OF zomato_part.orders
--       FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-02-01 00:00:00+05:30');
-- A month is created ahead of time by the same statement (a monthly
-- job, or pg_partman); the six months after the data ends (2026-07 to
-- 2026-12) are created here so new orders never fall in the default
-- partition.
DO $$
DECLARE
    m date;
BEGIN
    FOR m IN SELECT generate_series(date '2025-01-01', date '2026-12-01', interval '1 month')::date LOOP
        EXECUTE format(
            'CREATE TABLE zomato_part.%I PARTITION OF zomato_part.orders
                 FOR VALUES FROM (%L) TO (%L)',
            'orders_' || to_char(m, 'YYYY_MM'),
            m::text || ' 00:00:00+05:30',
            (m + interval '1 month')::date::text || ' 00:00:00+05:30');
    END LOOP;
END $$;

-- No DEFAULT partition, on purpose. A first version of this script had
-- one, and the plans showed two costs: (1) it can hold any placed_at,
-- so every range query that is not pruned to it must still scan it, and
-- (2) it stops the planner from using an Ordered Append for
-- ORDER BY placed_at: R23 became a Merge Append that opened all 25
-- partitions (0.129 ms instead of reading only June). Without it, an
-- order for a month with no partition fails with "no partition of
-- relation found for row", which the monthly job prevents by creating
-- partitions ahead of time (see the end of this file).

-- Load first: every row is routed to its month by placed_at.
INSERT INTO zomato_part.orders SELECT * FROM zomato.orders;

-- Indexes: the same Phase 4 indexes from 05_indexes.sql. Created on the
-- parent, PostgreSQL creates one per partition and keeps them attached.
-- Each partition's index is about 1/18 of the old one, so an index that
-- serves the current month stays hot in memory. Non-unique indexes have
-- no partition-key rule; only UNIQUE / PRIMARY KEY do.
-- They are built after the INSERT: built first, they grew row by row
-- with page splits and came out at 796 MB instead of about 661 MB.
CREATE INDEX orders_customer_placed_idx   ON zomato_part.orders (customer_id, placed_at DESC) INCLUDE (status, total_amount);
CREATE INDEX orders_restaurant_placed_idx ON zomato_part.orders (restaurant_id, placed_at) INCLUDE (status);
CREATE INDEX orders_partner_placed_idx    ON zomato_part.orders (partner_id, placed_at);
CREATE INDEX orders_placed_at_idx         ON zomato_part.orders (placed_at)
    INCLUDE (order_id, customer_id, restaurant_id, partner_id, status, delivered_at);
CREATE INDEX orders_preparing_accepted_idx ON zomato_part.orders (accepted_at) WHERE status = 'PREPARING';
CREATE INDEX orders_unassigned_placed_idx  ON zomato_part.orders (placed_at)
    WHERE partner_id IS NULL AND status IN ('PLACED', 'ACCEPTED');
CREATE INDEX orders_delivered_coupon_idx   ON zomato_part.orders (coupon_code)
    INCLUDE (order_id, discount, total_amount)
    WHERE status = 'DELIVERED' AND coupon_code IS NOT NULL;

VACUUM ANALYZE zomato_part.orders;

-- Rows per partition.
SELECT tableoid::regclass AS partition, count(*) AS orders
FROM zomato_part.orders
GROUP BY 1
ORDER BY 1;

-- Sizes: the partitioned copy next to the plain table.
SELECT 'zomato.orders (plain)' AS "table",
       pg_size_pretty(pg_table_size('zomato.orders'))   AS heap,
       pg_size_pretty(pg_indexes_size('zomato.orders')) AS indexes
UNION ALL
SELECT 'zomato_part.orders (24 partitions)',
       pg_size_pretty(sum(pg_table_size(c.oid))),
       pg_size_pretty(sum(pg_indexes_size(c.oid)))
FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'zomato_part.orders'::regclass;

-- ---------------------------------------------------------------------
-- 3. Partition pruning, shown with EXPLAIN
-- ---------------------------------------------------------------------
-- Read the plans for the partition names: only the partitions that can
-- hold matching rows appear. "Subplans Removed: n" means n partitions
-- were pruned at executor start-up (the bound was not a plain constant
-- at plan time).
SET search_path TO zomato_part, zomato;

\echo '=== P1: R06 on the partitioned table: one restaurant, one day -> 1 of 24 partitions'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, status, item_total, placed_at
FROM orders
WHERE restaurant_id = 217
  AND placed_at >= '2026-06-15' AND placed_at < '2026-06-16'
ORDER BY placed_at;

\echo '=== P2: R10: deliveries in June 2026 over 60 minutes -> 1 of 24 partitions'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, customer_id, restaurant_id, placed_at, delivered_at
FROM orders
WHERE delivered_at - placed_at > interval '60 minutes'
  AND placed_at >= '2026-06-01' AND placed_at < '2026-07-01'
ORDER BY delivered_at - placed_at DESC
LIMIT 100;

\echo '=== P3: R22: last 8 weeks, bound computed at run time -> pruned at executor start-up'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT EXTRACT(ISODOW FROM o.placed_at) AS weekday, EXTRACT(HOUR FROM o.placed_at) AS hour, count(*) AS orders
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
JOIN localities l  ON l.locality_id   = r.locality_id
WHERE l.city_id = 1
  AND o.placed_at >= TIMESTAMPTZ '2026-07-01 00:00:00+05:30' - interval '8 weeks'
GROUP BY 1, 2
ORDER BY 1, 2;

\echo '=== P4: R23 keyset page: ORDER BY the partition key -> Ordered Append, stops in the newest partition'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, customer_id, restaurant_id, status, total_amount, placed_at
FROM orders
WHERE placed_at < '2026-06-12 19:12:00+05:30'
ORDER BY placed_at DESC
LIMIT 25;

\echo '=== P5: the cost of partitioning: R24 looks an order up by order_id only -> all 24 partitions probed'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, placed_at, total_amount
FROM orders
WHERE order_id = 123457;

\echo '=== P6: the same lookup when the caller also passes placed_at (option a above) -> 1 partition'
-- The bill page opens from an order the app already has on screen, so
-- it knows placed_at as well as order_id (2025-01-23 11:15:20+05:30 for order 123457).
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT order_id, placed_at, total_amount
FROM orders
WHERE order_id = 123457
  AND placed_at = '2025-01-23 11:15:20+05:30';

\echo '=== P7: R04: a customer''s last 10 orders: no placed_at filter -> every partition, merged'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT o.order_id, o.status, o.total_amount, o.placed_at
FROM orders o
WHERE o.customer_id = 1042
ORDER BY o.placed_at DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- 4. A child table under option (a): order_items carries placed_at
-- ---------------------------------------------------------------------
-- Shown on an empty table: the foreign key to the partitioned orders is
-- accepted once it names both primary-key columns.
CREATE TABLE zomato_part.order_items (
    order_id   integer       NOT NULL,
    placed_at  timestamptz   NOT NULL,   -- new: copied from the order
    item_id    integer       NOT NULL,
    quantity   integer       NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    CONSTRAINT order_items_pkey PRIMARY KEY (order_id, item_id),
    CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id, placed_at)
        REFERENCES zomato_part.orders (order_id, placed_at) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT order_items_item_id_fkey FOREIGN KEY (item_id)
        REFERENCES zomato.menu_items (item_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT order_items_quantity_check   CHECK (quantity > 0),
    CONSTRAINT order_items_unit_price_check CHECK (unit_price >= 0)
);

SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'zomato_part.order_items'::regclass AND contype = 'f'
  AND conparentid = 0;   -- the constraints as declared, not the per-partition copies

-- ---------------------------------------------------------------------
-- 5. Archiving and cutover (production steps, not run here)
-- ---------------------------------------------------------------------
-- Archive a month older than 12 months: DETACH is a catalog change, not
-- a DELETE, so it creates no dead tuples and needs no VACUUM. With
-- CONCURRENTLY it does not block queries on the other partitions.
--   ALTER TABLE orders DETACH PARTITION orders_2025_01 CONCURRENTLY;
--   -- copy it out (pg_dump -t, or COPY to a file / cheaper storage), then
--   DROP TABLE orders_2025_01;
--
-- Cutover from the plain table, in a maintenance window:
--   BEGIN;
--   ALTER TABLE zomato.orders RENAME TO orders_old;
--   ALTER TABLE zomato_part.orders SET SCHEMA zomato;
--   -- re-point the three child foreign keys to (order_id, placed_at),
--   -- after adding and back-filling placed_at in each child table
--   COMMIT;
--
-- Autovacuum on the partition that takes the writes (per-table storage
-- settings, not server settings; reasons in the report, section 6.4):
--   ALTER TABLE orders_2026_07 SET (autovacuum_vacuum_scale_factor = 0.01,
--                                   autovacuum_vacuum_insert_scale_factor = 0.01,
--                                   autovacuum_analyze_scale_factor = 0.005);
--
-- Creating next month's partition (monthly job, a few days early):
--   CREATE TABLE orders_2027_01 PARTITION OF orders
--       FOR VALUES FROM ('2027-01-01 00:00:00+05:30') TO ('2027-02-01 00:00:00+05:30');
