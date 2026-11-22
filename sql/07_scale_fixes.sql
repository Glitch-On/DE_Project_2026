-- =====================================================================
-- Zomato Food Delivery Database - Phase 5: fixes for problems that only
-- showed up on the large dataset (3,000,000 orders, 500,000 customers)
-- Team T0022 (Section B) - DE_Project_2026
--
-- Run after 01_schema.sql, 02_load_data.sql (large_data/) and
-- 05_indexes.sql:
--   psql -d <db> -X -v ON_ERROR_STOP=1 -f sql/07_scale_fixes.sql
-- Then benchmark the large-data workload:
--   ./benchmarks/run_benchmark.sh <db> large 3 sql/06_optimized_queries_large.sql
--
-- 05_indexes.sql is left as it was for Phase 4, so the CP3 numbers in
-- benchmarks/results/optimized/ can still be reproduced from it. This
-- file changes one index and one table setting on top of it. Safe to
-- re-run.
-- =====================================================================

SET search_path TO zomato;

-- ---------------------------------------------------------------------
-- W05 (nightly: end expired Gold plans): make the UPDATE a HOT update
-- ---------------------------------------------------------------------
-- What broke. On the seed data W05 updates 1,230 rows in about 16 ms.
-- On the large data it updates 24,720 rows, and run 1 took 1,394 ms,
-- 70% of the 2,000 ms batch budget (benchmarks/results/large_initial/W05.txt).
-- Its plan finds the rows in 1 ms; the other 1,393 ms are spent in the
-- "Update on customers" node: 393,874 buffer hits + 15,474 reads, about
-- 16 buffers per updated row.
--
-- Why. None of the updates were HOT (heap-only tuple). PostgreSQL can
-- only skip index maintenance when no indexed column changes, and a
-- column used in a partial index's WHERE clause counts. The Phase 4
-- index was
--     customers (gold_expires_on) WHERE is_gold_member
-- and W05 sets is_gold_member = FALSE, so every updated row got a new
-- entry in all four indexes of customers: the primary key, the email
-- and phone UNIQUE indexes and this one. email and phone are random
-- text keys, so each of the 24,720 rows lands on a different leaf page
-- of customers_email_key (39 MB) and customers_phone_key (15 MB). The
-- deeper and wider those indexes get, the more of those pages miss the
-- cache, so the cost per row grows with the table. That is why W05
-- grew 39.6x for 20x the data. The second blocker is fillfactor: COPY
-- fills every heap page to 100%, so even a HOT-eligible update has no
-- room for the new row version on its page.
--
-- Fix, part 1: same rows, no is_gold_member in the predicate. Every
-- Gold member has gold_expires_on set and every non-member has it NULL
-- (74,670 / 74,670 and 425,330 / 0 on the large data; 3,792 / 3,792
-- and 21,208 / 0 on the seed data), so
-- "WHERE gold_expires_on IS NOT NULL" indexes the same 74,670 rows as
-- "WHERE is_gold_member". The planner still uses it for R14 and W05,
-- because "gold_expires_on < '2026-07-01'" implies "IS NOT NULL"; the
-- is_gold_member test moves to a cheap heap Filter. W05 no longer
-- changes any indexed column. One difference: once W05 commits, an
-- ex-member keeps gold_expires_on, so they stay in this index (the old
-- one dropped them). The index grows by the number of lapsed members;
-- R14 and W05 skip them on the is_gold_member Filter.
DROP INDEX IF EXISTS customers_gold_expiry_idx;
CREATE INDEX customers_gold_expiry_idx
    ON customers (gold_expires_on)
    WHERE gold_expires_on IS NOT NULL;

-- Fix, part 2: leave 15% of each customers page free so the new row
-- version fits on the same page. fillfactor is a per-table storage
-- setting, not a server setting. It only applies to pages written
-- from now on, so VACUUM FULL rewrites the table once (it takes an
-- exclusive lock: run it in the maintenance window). Cost: the heap
-- grows from 59 MB to 61 MB on the large data.
--
-- Measured on the large data: W05 went from 811 / 196 / 239 ms (3 runs,
-- fresh copy of the database) to 53 / 56 / 54 ms, and
-- pg_stat_user_tables.n_tup_hot_upd shows all 24,720 updates as HOT.
-- R14, the other user of the index, is unchanged (about 24 ms).
ALTER TABLE customers SET (fillfactor = 85);
VACUUM FULL customers;

-- ---------------------------------------------------------------------
-- Statistics and visibility map (VACUUM FULL rebuilt the table and its
-- indexes, so the Index Only Scans need a fresh visibility map)
-- ---------------------------------------------------------------------
VACUUM ANALYZE customers;
