# CP4: Scalability Report (large dataset)

## 1. Setup and method

| | Seed data | Large data (`large_data.zip`, release `large-data`) |
|---|---:|---:|
| orders | 150,000 | 3,000,000 |
| order_items | 375,000 | 7,500,000 |
| payments | 137,378 | 2,749,715 |
| reviews | 39,186 | 781,962 |
| customers | 25,000 | 500,000 |
| restaurants | 2,500 | 50,000 |
| menu_items | 50,000 | 1,000,000 |
| delivery_partners | 2,000 | 40,000 |

Both datasets cover the same 18 months (1 Jan 2025 to 30 Jun 2026), so the large data is the same business with 20× the orders per day, not a longer history.

Steps on the large database, in order:

```bash
psql -d postgres -c "CREATE DATABASE zomato_large"
psql -d zomato_large -X -v ON_ERROR_STOP=1 -f sql/01_schema.sql
sed 's#seed_data/#large_data/#g' sql/02_load_data.sql | psql -d zomato_large -X -v ON_ERROR_STOP=1   # 138 s
psql -d zomato_large -X -v ON_ERROR_STOP=1 -f sql/05_indexes.sql          # 8 s, ends with VACUUM ANALYZE
psql -d zomato_large -X -v ON_ERROR_STOP=1 -f sql/07_scale_fixes.sql      # Phase 5 fix, 2 s
./benchmarks/run_benchmark.sh zomato_large large 3 sql/06_optimized_queries_large.sql
```

The load script is unchanged apart from the folder name, and every row count matched the release notes. The original 30 queries were not run on the large data. The only exception is `benchmarks/equivalence_checks.py`, which runs each original once to compare its rows (section 4.4); with the Phase 4 indexes in place none of them took more than about a second.

Machine and settings: MacBook Pro M4, 16 GB RAM, PostgreSQL 18.6 (Postgres.app), default server settings (`shared_buffers = 128MB`, `work_mem = 4MB`, `max_parallel_workers_per_gather = 2`, `TimeZone = Asia/Kolkata`). Nothing was tuned.

Result folders:

| Folder | What it is |
|---|---|
| `benchmarks/results/large/` | **Final large-data results**: `06_optimized_queries_large.sql` after `07_scale_fixes.sql`. `summary.csv` + one raw plan file per query (3 runs each) |
| `benchmarks/results/large_initial/` | First pass: the Phase 4 files (`05` + `06`, R23 bound updated) on the large data, before any Phase 5 fix. The "before" plans of section 4 come from here |
| `benchmarks/results/seed_recheck/` | `06_optimized_queries.sql` on a fresh seed database, same laptop, same session, same script (`run_benchmark.sh`, average of 3) |
| `benchmarks/results/large/partitioning_explain.txt` | Output of `sql/08_partitioning.sql`: the pruning plans of section 6.1 |
| `benchmarks/results/large/equivalence_large.txt` | Same-result proof on the large data (section 4.4) |
| `benchmarks/results/large/storage_and_maintenance.txt` | Sizes and maintenance timings (sections 5 and 6.4) |

**Which seed number is the baseline for growth.** The CP3 numbers in `benchmarks/results/optimized/summary.csv` were taken with `robust_benchmark.py` (median of several runs) on a machine that was busy at the time (see `docs/04_optimization_report.md`). Dividing a `run_benchmark.sh` average by a median from another day mixes two methods. So the growth column divides the large result by `seed_recheck`, which used the same script and the same laptop in the same session. Both columns are shown.

## 2. Results table

Target groups from the brief: **RT** real-time < 5 ms, **IS** interactive search / ops < 250 ms, **RP** reports < 5,000 ms, **BJ** batch jobs < 2,000 ms. All values are the `avg_ms` column (average of 3 runs) of the named `summary.csv`. Growth = large final ÷ seed re-run.

| Query | Target | CP3 on seed (ms) | Seed re-run (ms) | Large, first pass (ms) | Large, final (ms) | Growth | Meets target? | What we changed for the large data |
|---|---|---:|---:|---:|---:|---:|:---:|---|
| R01 | RT < 5 | 0.314 | 0.186 | 1.453 | 0.887 | 4.8× | ✅ | none |
| R02 | IS < 250 | 6.641 | 5.460 | 82.735 | 79.694 | 14.6× | ✅ | none (trigram and price indexes tested, both slower, §4.5) |
| R03 | RT < 5 | 0.146 | 0.062 | 0.055 | 0.057 | 0.9× | ✅ | none |
| R04 | RT < 5 | 0.287 | 0.198 | 0.213 | 0.160 | 0.8× | ✅ | none |
| R05 | RT < 5 | 0.042 | 0.025 | 0.134 | 0.150 | 6.0× | ✅ | none |
| R06 | RT < 5 | 0.036 | 0.081 | 0.018 | 0.082 | 1.0× | ✅ | none |
| R07 | RP < 5,000 | 0.218 | 0.175 | 0.335 | 0.313 | 1.8× | ✅ | none |
| R08 | RP < 5,000 | 5.316 | 2.295 | 27.434 | 27.808 | 12.1× | ✅ | none |
| R09 | RP < 5,000 | 0.058 | 0.059 | 0.062 | 0.061 | 1.0× | ✅ | none (view refresh cost: §6.4) |
| R10 | IS < 250 | 1.587 | 0.709 | 7.427 | 7.714 | 10.9× | ✅ | none |
| R11 | RT < 5 | 0.037 | 0.180 | 0.032 | 0.033 | 0.2× | ✅ | none |
| R12 | RT < 5 | 0.053 | 0.025 | 0.025 | 0.025 | 1.0× | ✅ | none |
| R13 | IS < 250 | 0.764 | 0.291 | 5.190 | 5.116 | 17.6× | ✅ | none |
| R14 | IS < 250 | 2.906 | 1.320 | 24.470 | 74.010 | 56.1× | ✅ | index reshaped by `07` (for W05); run 1 cold, runs 2–3 = 25.6 / 25.5 ms, §3.4 |
| R15 | RP < 5,000 | 8.201 | 2.841 | 48.860 | 49.206 | 17.3× | ✅ | none |
| R16 | IS < 250 | 0.079 | 0.181 | 0.230 | 0.233 | 1.3× | ✅ | none |
| R17 | RP < 5,000 | 35.991 | 14.409 | 105.835 | 100.328 | 7.0× | ✅ | none (hash aggregate spills to disk, §4.3) |
| R18 | IS < 250 | 0.365 | 0.328 | 0.395 | 0.510 | 1.6× | ✅ | none |
| R19 | RP < 5,000 | 11.146 | 9.058 | 83.044 | 135.606 | 15.0× | ✅ | none (run 1 cold: 239 ms; runs 2–3: 87.5 / 80.0 ms) |
| R20 | RP < 5,000 | 22.177 | 9.833 | 171.560 | 111.952 | 11.4× | ✅ | **LATERAL rewrite undone**, original join is faster at scale (§4.2) |
| R21 | RP < 5,000 | 13.896 | 4.450 | 99.257 | 96.603 | 21.7× | ✅ | none (hash aggregate spills to disk, §4.3) |
| R22 | RP < 5,000 | 7.002 | 2.258 | 48.917 | 47.631 | 21.1× | ✅ | none |
| R23 | RP < 5,000 | 0.028 | 0.029 | 0.030 | 0.031 | 1.1× | ✅ | keyset bound re-read on the large data (§4.4) |
| R24 | RT < 5 | 0.072 | 0.285 | 0.364 | 0.439 | 1.5× | ✅ | none |
| R25 | IS < 250 | 1.034 | 0.315 | 5.120 | 5.177 | 16.4× | ✅ | none |
| W01 | RT < 5 | 3.684 | 1.697 | 1.865 | 1.832 | 1.1× | ✅ | none |
| W02 | RT < 5 | 3.221 | 1.074 | 1.024 | 1.161 | 1.1× | ✅ | none |
| W03 | RT < 5 | 0.392 | 0.298 | 0.211 | 0.201 | 0.7× | ✅ | none |
| W04 | BJ < 2,000 | 106.859 | 17.923 | 514.621 | 574.381 | 32.0× | ✅ | none (grows faster than the data, §3.3; risk at 100×) |
| W05 | BJ < 2,000 | 35.709 | 15.790 | 626.040 | 217.085 | 13.7× | ✅ | **made the UPDATE HOT** with `07_scale_fixes.sql` (§4.1) |
| **Total** | | **268.261** | **91.835** | **1,856.956** | **1,538.486** | 16.8× | **30 / 30** | |

All 30 queries meet their targets on the large data, with the closest one at 32% of its budget (R02: 79.7 of 250 ms). Phase 5 work went into the two queries that got worse faster than the data grew (W05, R20). Section 6 then uses these numbers to check what still holds at 100×.

Per-run times and scan nodes for every query are in the appendix.

## 3. Growth analysis

With 3 runs per query, one cold first run can move the average a lot. That happened in R14, R19 and W05, where run 1 had to read the table from disk or the OS cache because it was not yet in the 128 MB of shared buffers. For grouping, this section uses the **median** of the 3 runs (`median_ms` in the same `summary.csv` files), which is the warm-cache time. Median growth = large median ÷ seed re-run median.

### 3.1 Stayed about the same (0.4× – 1.6×): 13 queries

| Query | Seed median | Large median | Growth | Why it did not grow |
|---|---:|---:|---:|---|
| R03 | 0.062 | 0.059 | 1.0× | one restaurant's ~20 dishes through `menu_items_restaurant_item_key` |
| R04 | 0.084 | 0.036 | 0.4× | `orders_customer_placed_idx`, reads 10 entries for one customer |
| R06 | 0.016 | 0.015 | 0.9× | one restaurant, one day: `(restaurant_id, placed_at)` range |
| R07 | 0.079 | 0.090 | 1.1× | one restaurant, one month: same index |
| R09 | 0.050 | 0.051 | 1.0× | reads the 180-row materialized view, which does not grow with orders |
| R11 | 0.030 | 0.031 | 1.0× | one partner, one week: `(partner_id, placed_at)` range |
| R12 | 0.021 | 0.022 | 1.0× | partial index, `LIMIT 50` |
| R18 | 0.250 | 0.370 | 1.5× | walks `reviews_created_at_idx` newest first and stops after 50 matches |
| R23 | 0.027 | 0.027 | 1.0× | keyset: one index descent + 25 rows |
| R24 | 0.058 | 0.053 | 0.9× | five primary-key / foreign-key lookups for one order |
| W01 | 1.294 | 1.357 | 1.0× | one INSERT, 8 index entries |
| W02 | 0.891 | 0.847 | 1.0× | partial index finds the oldest unassigned order, one UPDATE |
| W03 | 0.193 | 0.189 | 1.0× | one restaurant's desserts |

These are all lookups of a **fixed number of rows** through a B-tree. A B-tree's depth grows with log n: `orders_customer_placed_idx` is 149 MB on the large data and 3 levels deep, the same depth as on the seed data (`bt_metap` root level 2 on both), so 20× the rows adds no extra page reads for the descent. The work is set by the size of the answer (one customer, one restaurant-day, 25 rows), and the answer did not get bigger.

In between are R16 (3.3×), R05 (5.2×) and R01 (7.7×). Their tables grew 20×, but what they grew with is the **size of their answer**: R05's PREPARING orders went from 37 to 750 (the partial index scan returns 709 rows), R16's failed payments in the last 7 days went from 82 to 1,689, and Koramangala went from 38 to 780 restaurants for R01's bitmap scan to read before the top-20 sort.

### 3.2 Grew about 20× (8× – 23×): 12 queries

| Query | Seed median | Large median | Growth | The fixed share of the data it reads |
|---|---:|---:|---:|---|
| R02 | 4.945 | 72.019 | 14.6× | probes the menu of every Bengaluru restaurant: 400 → 8,000 index scans |
| R08 | 2.039 | 25.580 | 12.5× | every delivered Pune order since 1 June |
| R10 | 0.693 | 7.639 | 11.0× | every June order (Index Only Scan of the month), top 100 |
| R13 | 0.267 | 5.072 | 19.0× | every order since 25 June, anti-joined to every Bengaluru partner |
| R14 | 1.127 | 25.612 | 22.7× | every Gold member expiring before July: 3,792 → 74,670 candidates (24,720 probes) |
| R15 | 2.477 | 48.431 | 19.6× | every delivered order with a coupon |
| R17 | 12.444 | 99.880 | 8.0× | every failed payment joined to every order (now a parallel hash join) |
| R19 | 4.050 | 87.517 | 21.6× | 3 index probes per Bengaluru restaurant: 400 → 8,000 restaurants |
| R20 | 7.460 | 103.887 | 13.9× | every Mumbai customer's delivered orders: 4,000 → 80,000 customers |
| R21 | 4.459 | 94.603 | 21.2× | every May order: 8,500 → 170,000 rows aggregated |
| R22 | 2.244 | 45.120 | 20.1× | every Bengaluru order in the last 8 weeks |
| R25 | 0.311 | 5.211 | 16.8× | seq scan of `restaurants` (2,500 → 50,000) |

Each of these reads **a fixed share of a table**: "all of May", "all Bengaluru restaurants", "all failed payments". The indexes made each row cheap to reach, but 20× the data means 20× the rows in that share, so the time grows about 20×. The ones well under 20× (R08, R10, R17, R20) switched to a **parallel plan** on the large data (2 workers + leader), which the planner does not bother with for small inputs. That spreads the 20× more rows over 3 processes; per-row work grew as expected.

For this group the indexes can't change the slope, only the constant. What does change it: precomputing (R09 shows this with a materialized view), narrowing the share (partition pruning, §6.1), or splitting it across machines (§6.2).

### 3.3 Grew more than 20×: W04 and W05

| Query | Rows changed (seed → large) | Seed median | Large median, first pass | Growth | After Phase 5 |
|---|---|---:|---:|---:|---:|
| W05 | 1,230 → 24,720 (20×) | 10.717 | 258.550 | 24.1× (average: 39.6×) | 69.207 ms, **6.5×** |
| W04 | 2,390 → 47,980 (20×) | 16.613 | 511.634 | 30.8× | 581.896 ms, 35.0× (not fixed) |

Both are batch UPDATEs whose row count grew exactly 20×, so the extra growth is in the **cost per row**. W05 went from 8.7 µs to 10.5 µs per row on warm runs, and to 56 µs per row on the cold first run (1,394 ms). W04 went from 7.0 to 10.7 µs per row. In both, each updated row inserts new entries into every index on the table, because neither update was HOT (section 4.1 explains why). Those inserts land on random leaf pages of text indexes (`customers_email_key` is 39 MB on the large data, `restaurants_name_key` 3.6 MB). With 20× the leaf pages, fewer of them are already in cache, so each insert costs more. That is a cost that grows with table size for every row, which is how a 20× row count becomes 30×–40× time.

W05 was fixed (§4.1). W04 meets its target at 574 ms. It can't be made HOT without giving up the R01 index (rating is in its key), so we report it as a risk instead (§7).

### 3.4 Why R14's average looks worse after the fix

R14's final average (74.0 ms) is three times its first-pass average (24.5 ms), but the runs are 170.9 / 25.6 / 25.5 ms against 26.0 / 24.3 / 23.1 ms before. `07_scale_fixes.sql` ends with `VACUUM FULL customers`, which rewrites the table, so the benchmark's first touch of `customers` read 7,509 pages from outside shared buffers (`Buffers: shared hit=40 read=7509` on the customers scan). The warm runs are the same as before. The plan also changed shape: R14 now runs a Nested Loop Semi Join from the Gold customers into `orders_customer_placed_idx`, where before it started from `orders_placed_at_idx`. Both take about 25 ms warm.

## 4. What broke at scale, and how it was fixed

### 4.1 W05: the nightly Gold-expiry job lost HOT updates (fixed)

**Symptom.** First pass on the large data: 1,394.352 / 258.550 / 225.218 ms, average 626.040 ms. Run 1 used 70% of the 2,000 ms batch budget, for 20× the rows that took 16 ms on the seed data.

**Before** (`benchmarks/results/large_initial/W05.txt`, run 1):

```
Update on customers  (actual time=1394.296..1394.297 rows=0.00 loops=1)
  Buffers: shared hit=393874 read=15474 dirtied=15824 written=5033
  ->  Bitmap Heap Scan on customers  (actual time=1.234..14.871 rows=24720.00 loops=1)
        Recheck Cond: ((gold_expires_on < '2026-07-01'::date) AND is_gold_member)
        ->  Bitmap Index Scan on customers_gold_expiry_idx  (actual time=0.810..0.810 rows=24720.00 loops=1)
```

Finding the 24,720 rows takes 15 ms. The other 1,379 ms are spent writing them: about 16 buffer accesses per row.

**Cause.** PostgreSQL can do a HOT (heap-only tuple) update, which writes no index entries at all, only if (1) no indexed column changes and (2) the new row version fits on the same heap page. Both failed:

1. The Phase 4 index was `customers (gold_expires_on) WHERE is_gold_member`. A column used in a partial index's `WHERE` counts as indexed, and W05 sets `is_gold_member = FALSE`. So every updated row needed new entries in all four indexes of `customers`: the primary key, `customers_email_key`, `customers_phone_key` and this one.
2. `COPY` fills heap pages to 100%, so there was no room on the page for a new row version anyway.

On the seed data, 1,230 rows × 4 index inserts into small, cached indexes was cheap. On the large data, the email and phone indexes are 39 MB and 15 MB, and each insert goes to a random leaf page.

**Fix** (`sql/07_scale_fixes.sql`):

```sql
DROP INDEX IF EXISTS customers_gold_expiry_idx;
CREATE INDEX customers_gold_expiry_idx
    ON customers (gold_expires_on)
    WHERE gold_expires_on IS NOT NULL;      -- same 74,670 rows, no is_gold_member
ALTER TABLE customers SET (fillfactor = 85); -- leave room on each page
VACUUM FULL customers;                      -- apply the fillfactor once
```

Every Gold member has `gold_expires_on` set and every non-member has it NULL (74,670 / 74,670 and 425,330 / 0 on the large data; 3,792 / 3,792 and 21,208 / 0 on the seed data), so the new predicate indexes the same rows. R14 and W05 still use it, because `gold_expires_on < '2026-07-01'` implies `IS NOT NULL`; the `is_gold_member` test becomes a heap Filter. `fillfactor` is a per-table storage setting, not a server setting. The heap grows from 59 MB to 61 MB.

**After** (`benchmarks/results/large/W05.txt`): 521.825 / 69.207 / 60.223 ms, average 217.085 ms.

```
Update on customers  (actual time=521.770..521.771 rows=0.00 loops=1)
  Buffers: shared hit=81666 read=7509 dirtied=7486
  ->  Bitmap Heap Scan on customers  (actual time=1.390..14.035 rows=24720.00 loops=1)
        Recheck Cond: (gold_expires_on < '2026-07-01'::date)
        Filter: is_gold_member
```

Buffer accesses for the update fell from 409,348 to 89,175. After the benchmark, `pg_stat_user_tables` for customers shows `n_tup_upd = 74160, n_tup_hot_upd = 74160`: every update in all three runs was HOT. Warm runs went from 225–259 ms to 60–69 ms (3.7×). The cold run 1 is still 522 ms, because it had to read the freshly rewritten table (`read=7509`) and dirty every page it touched. That is the realistic nightly cost, and it is well under 2,000 ms.

### 4.2 R20: a Phase 4 rewrite that stopped paying off (fixed)

In Phase 4, R20 (top 20 Mumbai customers by spend) was rewritten from `JOIN ... GROUP BY` to a `LATERAL` aggregate per customer. Measured on this laptop today (5 runs each, `EXPLAIN ANALYZE`):

| | Seed (4,000 Mumbai customers) | Large (80,000 Mumbai customers) |
|---|---:|---:|
| original `JOIN ... GROUP BY` (with Phase 4 indexes) | 32.2 / 20.6 / 19.0 / 18.5 / 18.6 ms | 102.1 / 102.0 / 106.6 / 103.2 / 101.3 ms |
| Phase 4 `LATERAL` rewrite | 8.5 / 7.4 / 7.4 / 7.2 / 7.3 ms | 170.5 / 166.0 / 170.7 / 168.9 / 167.2 ms |

The LATERAL form is 2.5× faster on the seed data and 1.65× slower on the large data.

**Before** (`large_initial/R20.txt`, run 3, 170.921 ms): a serial plan. `Seq Scan on customers` (80,000 Mumbai rows), then for each one an `Aggregate` over `Index Only Scan using orders_customer_placed_idx` (`loops=80000`).

**After** (`large/R20.txt`, run 3, 103.887 ms): the same per-customer index probe, split across processes:

```
Finalize GroupAggregate  (actual time=2.630..96.762 rows=79547.00 loops=1)
  ->  Gather Merge  (actual time=2.622..77.701 rows=79547.00 loops=1)
        Workers Planned: 2   Workers Launched: 2
        ->  Partial GroupAggregate  (actual time=0.060..74.881 rows=26515.67 loops=3)
              ->  Nested Loop  (actual time=0.052..62.249 rows=139374.00 loops=3)
                    ->  Parallel Index Scan using customers_pkey on customers c  (rows=26666.67 loops=3)
                          Filter: (city_id = 2)
                    ->  Index Only Scan using orders_customer_placed_idx on orders o  (rows=5.23 loops=80000)
```

The planner can split a join with `GROUP BY` into partial aggregates per worker. The LATERAL form, a subquery evaluated per outer row, stayed serial. At 4,000 customers parallelism was not worth starting; at 80,000 it is. `sql/06_optimized_queries_large.sql` goes back to the original R20 text, and the average drops from 171.560 to 111.952 ms. The lesson for the report: a rewrite that wins on small data has to be measured again on large data.

### 4.3 Hash aggregates spill to disk (found, not changed)

On the seed data every hash fits in `work_mem` (4 MB). On the large data two do not:

- R17: `HashAggregate ... Group Key: o.customer_id  Batches: 5  Memory Usage: 8249kB  Disk Usage: 696kB` (123,687 customers with a failed payment).
- R21: `HashAggregate ... Batches: 5  Memory Usage: 8505kB  Disk Usage: 1584kB` in each of the 3 processes (the May orders grouped by customer, about 144,000 groups).

`Batches: 5` means the hash table was split and part of it written to temp files. Both queries still finish in about 100 ms, against a 5,000 ms target, so we left them alone. Raising `work_mem` server-wide is not allowed by the brief, and it is not needed at this size. At 100× this is the first thing to fix for the report queries: a summary table (as for R09) or a per-role `work_mem` for the reporting user, measured first.

### 4.4 R23: the keyset value is data, not code

Phase 4 replaced `OFFSET 100000` with `WHERE placed_at < <last seen>`. The last-seen value from the seed data (`2025-07-02 00:00:00+05:30`) would return the wrong page on the large data. Re-read the same way:

```sql
SELECT placed_at FROM orders ORDER BY placed_at DESC OFFSET 99999 LIMIT 1;
-- seed:  2025-07-02 00:00:00+05:30   (100,000 orders = the last 12 months)
-- large: 2026-06-12 19:12:00+05:30   (100,000 orders = the last 18 days)
```

`placed_at` is still unique (3,000,000 rows, 3,000,000 distinct values), so `<` neither skips nor repeats a row. In the app the value is never computed with OFFSET. It is the `placed_at` of the 25th row of the page already on screen. That is why R23 costs 0.031 ms at any table size, while the original would read and discard 100,000 rows. `06_optimized_queries_large.sql` contains the large-data bound.

**Same-result proof on the large data.** `python3 benchmarks/equivalence_checks.py zomato_large sql/06_optimized_queries_large.sql` (output in `benchmarks/results/large/equivalence_large.txt`) runs every original query and its large-data version against the large database:

- 27 pairs: `SAME`. This includes R20 (back to the original) and R14/W05 (new index).
- R13: `FIXED (old 0 -> new 2712 rows)`, the NULL bug from Phase 4. On the large data the original still returns 0 rows.
- R08 and R10: `same rows, different order`. Neither query was rewritten; their text is identical in both files. `benchmarks/tie_order_check.py` shows that both return the same multiset and the same **sequence of ORDER BY keys**, and that only rows tied on the key change places. Running the new query twice in a row moves just as many tied rows (R08: 1,952 old→new vs 1,876 new→new; R10: 29 vs 32). Parallel workers hand tied rows to the sort in a different order each time, and SQL leaves the order of ties undefined.

### 4.5 R02: checked, nothing better found

R02 grew 14.6× and is the query closest to its target (79.7 of 250 ms). The plan probes `menu_items_restaurant_item_key` once per Bengaluru restaurant (`loops=8000`) and filters `ILIKE '%paneer%'` on about 20 dishes each. Two alternatives were tested on a copy of the large database:

- GIN trigram index on `item_name`: 105,808 of 1,000,000 dishes match "paneer" (10.6%). The planner does not use it; the time stays 68–84 ms.
- `menu_items (price) WHERE is_available`, to walk dishes cheapest first and stop at 50: the planner uses it, and it gets **slower**, 232–245 ms. Cheap dishes are rarely paneer dishes in Bengaluru, so the walk goes much further than the estimate.

Neither was kept. R02 is listed as a 100× risk in section 7.

## 5. Storage

From `benchmarks/storage.sql` (`pg_table_size`, `pg_indexes_size`), schema `zomato`, raw output in `benchmarks/results/large/storage_and_maintenance.txt`. Seed: after `05`. Large: after `05` + `07`, before `08`.

| | Seed | Large | Growth |
|---|---:|---:|---:|
| **Database total** (`pg_database_size`) | **121 MB** | **2,237 MB** | 18.5× |
| All tables (heap, incl. TOAST) | 55 MB | 1,103 MB | 20.1× |
| All indexes | 58 MB | 1,126 MB | 19.4× |
| Index : heap | 1.04 | 1.02 | |

| Table | Rows (large) | Heap seed | Heap large | Indexes seed | Indexes large | Total large |
|---|---:|---:|---:|---:|---:|---:|
| orders | 3,000,000 | 18 MB | 357 MB | 33 MB | 661 MB | 1,018 MB |
| order_items | 7,500,000 | 19 MB | 374 MB | 8,232 kB | 160 MB | 534 MB |
| payments | 2,749,715 | 9,192 kB | 179 MB | 6,288 kB | 122 MB | 301 MB |
| menu_items | 1,000,000 | 3,488 kB | 67 MB | 2,952 kB | 57 MB | 125 MB |
| reviews | 781,962 | 2,824 kB | 55 MB | 3,504 kB | 67 MB | 122 MB |
| customers | 500,000 | 3,016 kB | 61 MB | 3,072 kB | 50 MB | 111 MB |
| restaurants | 50,000 | 416 kB | 7,616 kB | 672 kB | 5,376 kB | 13 MB |
| delivery_partners | 40,000 | 216 kB | 3,600 kB | 144 kB | 2,144 kB | 5,744 kB |
| mv_city_month_delivery | 180 | 56 kB | 56 kB | 16 kB | 16 kB | 72 kB |
| cities, localities, coupons | 140 | 120 kB | 120 kB | 96 kB | 96 kB | 216 kB |

Everything grew close to 20×, as expected for B-trees. The exceptions are the summary view (180 rows either way) and the partial indexes, which grow with the rare status they cover, not with the table: `orders_preparing_accepted_idx` is 40 kB and `orders_unassigned_placed_idx` 56 kB on 3,000,000 orders. **orders' indexes are 1.85× its heap** (661 vs 357 MB), because three of the Phase 4 indexes are covering (`INCLUDE`). That buys Index Only Scans, and it is also why every new order writes 8 index entries.

Projected at 100× the seed data (15,000,000 orders), linear from the large data: about 11 GB in total, of which `orders` is about 5 GB (1.8 GB heap + 3.3 GB indexes). That no longer fits in 16 GB of RAM together with the rest, which is the starting point for section 6.

## 6. Architecture for 100×

### 6.1 Partitioning: `orders` by RANGE on `placed_at`, one partition per month

DDL and demo: `sql/08_partitioning.sql`. It builds a partitioned copy of `orders` in schema `zomato_part` on the large database (so the benchmark tables are untouched), loads all 3,000,000 rows, and prints the plans below. Output: `benchmarks/results/large/partitioning_explain.txt`.

**Why this table and this key.**
- `orders` is the largest table that is written all day (1,018 MB of 2,237 MB), and its indexes are what every query reads.
- 11 of the 30 queries filter orders on a `placed_at` range (R06, R07, R08, R09, R10, R11, R13, R14, R21, R22, R23) and 4 more sort on it (R04, R12, R19, W02). Almost all want recent data: a day, a week, a month, the last 8 weeks.
- Old months are never updated again, so archiving becomes `DETACH PARTITION` instead of a million-row `DELETE`.
- **RANGE**, because `placed_at` is continuous and queries ask for ranges. LIST suits a small fixed set of values (city, status), and pruning by city does not match these queries. HASH spreads every month across every partition, so a date-range query cannot prune any of them.
- **Monthly**: about 167,000 orders a month on the large data (the copy shows 153,846–170,330 per partition), about 833,000 at 100×. One month's indexes stay small enough to stay in memory, and 12 new partitions a year is a small number for the planner.

**The DDL (abridged):**

```sql
CREATE TABLE zomato_part.orders (
    LIKE zomato.orders INCLUDING DEFAULTS INCLUDING CONSTRAINTS,   -- all columns, NOT NULLs, 19 CHECKs
    CONSTRAINT orders_pkey PRIMARY KEY (order_id, placed_at),
    CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES zomato.customers (customer_id) ...,
    ... restaurant, partner, coupon foreign keys as in 01_schema.sql ...
) PARTITION BY RANGE (placed_at);

CREATE TABLE zomato_part.orders_2025_01 PARTITION OF zomato_part.orders
    FOR VALUES FROM ('2025-01-01 00:00:00+05:30') TO ('2025-02-01 00:00:00+05:30');
-- ... one per month to 2026_12 (a DO loop in 08 creates all 24)
```

**The primary-key rule.** A PRIMARY KEY or UNIQUE constraint on a partitioned table must include every partition-key column, because each partition enforces uniqueness only inside itself. `08` tries `PRIMARY KEY (order_id)` and PostgreSQL rejects it:

```
NOTICE:  PRIMARY KEY (order_id) rejected: unique constraint on partitioned table must include all partitioning columns
```

So the key becomes `(order_id, placed_at)`. The consequence is in the child tables: `order_items`, `payments` and `reviews` reference `orders (order_id)`, and a foreign key needs a unique constraint on exactly those columns. We would add `placed_at` to the three child tables and reference `(order_id, placed_at)`. `08` creates `zomato_part.order_items` that way, and PostgreSQL accepts `FOREIGN KEY (order_id, placed_at) REFERENCES orders(order_id, placed_at)`. The cost is 8 bytes per child row (about 60 MB on 7.5 M order items). The other option is dropping the three foreign keys and checking them in `03_integrity_checks.sql`, which gives up enforcement.

**Partition pruning** (from `partitioning_explain.txt`; plain-table times are the large-data medians from section 3):

| Plan | Query | Partitions read | Partitioned (ms) | Plain table (ms) |
|---|---|---|---:|---:|
| P1 | R06: restaurant 217 on 15 June | only `orders_2026_06` | 0.009 | 0.015 |
| P2 | R10: June deliveries > 60 min | only `orders_2026_06` (Parallel Seq Scan of the month) | 9.690 | 7.639 |
| P3 | R22: last 8 weeks, bound computed at run time | `Subplans Removed: 16`; May + June read, 6 empty future months opened | 42.450 | 45.120 |
| P4 | R23: keyset page, `ORDER BY placed_at DESC LIMIT 25` | Ordered Append: June read, the other 17 months `(never executed)` | 0.029 | 0.027 |
| P5 | order lookup by `order_id` only | **all 24** (18 index probes + 6 empty) | 0.235 | 0.025 |
| P6 | same lookup with `placed_at` too | only `orders_2025_01` | 0.009 | 0.025 |
| P7 | R04: one customer, no date filter | all 24, Merge Append | 0.171 | 0.036 |

P1, as printed by `08`:

```
Index Scan using orders_2026_06_restaurant_id_placed_at_status_idx on orders_2026_06 orders (actual time=0.007..0.007 rows=0.00 loops=1)
  Index Cond: ((restaurant_id = 217) AND (placed_at >= '2026-06-15 00:00:00+05:30') AND (placed_at < '2026-06-16 00:00:00+05:30'))
Execution Time: 0.009 ms
```

What the numbers say:

- **At 3 M rows, partitioning does not make the indexed queries faster.** P1–P4 are within noise of the plain table, because the Phase 4 indexes already go straight to the right range. Pruning shows its value in queries that scan a period: P2 and P3 read one or two months of heap, about 1/18 of the table, and at 100× that share stays a month while the table becomes 90 months.
- **Queries without `placed_at` get slower**: P5 is 9× slower than the plain primary-key lookup (0.235 vs 0.025 ms) because it probes 24 primary-key indexes, and P7 merges 24 index scans. Both are still far under the 5 ms target, but the cost grows with the number of partitions. That is why the child tables carry `placed_at` (P6 prunes to one partition) and why old partitions should be detached, not kept forever.
- **No DEFAULT partition.** Our first version of `08` had one. It made R23 a Merge Append that opened all 25 partitions instead of an Ordered Append, because a default partition can hold any `placed_at`, so the planner can no longer prove the partitions are in key order. Without it, an order for a month with no partition fails loudly, and the monthly job creates partitions ahead of time (`08` creates six spare months, 2026-07 to 2026-12).
- **Indexes are built after the load.** Built before the `INSERT`, the partition indexes came out at 796 MB because of page splits; built after, 690 MB. The plain table's are 661 MB; the remaining 4% is `placed_at` added to the primary key.

**Maintenance this enables** (`08`, section 5): `ALTER TABLE orders DETACH PARTITION orders_2025_01 CONCURRENTLY;` archives a month with no dead tuples and no table-wide lock. VACUUM and ANALYZE run per partition, and only the current month gets updates.

### 6.2 Sharding: by city

An order touches one customer, one restaurant and one partner. On the large data, for **all 3,000,000 orders the customer's city, the restaurant's city and the partner's city are the same** (2,728,978 orders have a partner, and every one of those partners is in the restaurant's city), and **no customer has ordered from two cities**. Sharding by city therefore puts every order on the same shard as all three of its parties. Every join in the 30 queries stays on one shard.

The other two keys split orders from their parties:
- **By customer**: a restaurant's orders (R06, R07, R19, W03's menu, R03) and a partner's orders (R11, W02 dispatch) would be on every shard.
- **By restaurant**: a customer's history (R04, R14, R20) and a partner's deliveries would be on every shard.

**Balance.** Orders per city on the large data: Mumbai, Bengaluru and Delhi 16.0% each, Hyderabad and Chennai 12.0% each, Kolkata and Pune 8.0% each, Lucknow, Ahmedabad and Jaipur 4.0% each. One shard per city would make the largest 4× the smallest. Grouping cities gives 6 shards of 16–20%: {Mumbai}, {Bengaluru}, {Delhi}, {Hyderabad + Lucknow}, {Chennai + Ahmedabad}, {Kolkata + Pune + Jaipur}. At 100× the seed volume each shard holds 2.4–3 M orders, about the size of the whole large database we just measured. We already know that size meets every target on one laptop.

**Reference tables** (`cities`, `localities`, `coupons`) are small (216 kB) and rarely change: copy them to every shard.

**Routing.** Queries that carry a city (R01, R02, R08, R13, R19, R20, R22, R25 via `localities.city_id`) go straight to one shard. Queries keyed by an id need a small directory, `customer_id / restaurant_id / partner_id → shard`, held by the application or a router, or the shard number can be encoded in the id range. R24's `order_id` can be routed the same way.

**Queries that become cross-shard**, and how to handle them:

| Query | Why cross-shard | Handling |
|---|---|---|
| R09, R21 | one row per city | scatter-gather: each shard answers for its cities, the results are concatenated (no merge logic) |
| R15 | coupons are national | each shard returns per-coupon `count`, `sum(discount)`, `sum(total_amount)`; the router adds them and computes `avg = sum / count` (not an average of averages) |
| R16 | failed payments by method, all cities | per-shard counts, summed |
| R17 | customers with ≥ 2 failed payments | each customer is on one shard, so each shard's list is complete; concatenate and sort |
| R18, R23 | newest reviews / orders across the country | each shard returns its top 50 / 25, the router merges by `created_at` / `placed_at` and keeps the top 50 / 25. Keyset pagination makes this cheap; `OFFSET 100000` across 6 shards would mean 600,000 rows |
| W04, W05 | nightly, all rows | run on every shard in parallel; each shard does 1/6 of the work |

Nothing in the workload needs a join across shards. A customer moving city, or a partner reassigned to another city, means moving their rows to another shard. Rare, but it has to be a planned operation.

### 6.3 Read replicas and caching

A replica applies the primary's WAL with a delay: usually under a second, more under load. The rule we used: a query goes to the primary if a user or another job acts on its result right after a write.

**Primary (writes, and reads that must see the latest write):**
- W01–W05: writes.
- R12 dispatch queue and the subquery of W02: a partner must not be assigned to an order that a replica still shows as unassigned.
- R05 kitchen-delay alert and R06 restaurant's orders today: the restaurant acts on these live.
- R04 "your orders" and R24 bill page right after checkout: the customer has to see the order they just placed (read-your-writes). After a few seconds they can go to a replica.

**Read replica (reports and ops screens that tolerate seconds of lag):**
R07, R08, R10, R11, R13, R14, R15, R16, R17, R18, R19, R20, R21, R22, R23. On the large data these add up to 657 ms of the 1,538 ms total, and they include every query that reads a fixed share of `orders` (section 3.2). That is the part of the load that grows with the data, and moving it to replicas keeps it off the primary, which handles the writes.

**Cache (application cache or CDN, invalidated or expired):**
- R01 home feed, R25 cuisine filter: change only when a restaurant opens or closes or W04 updates ratings. Cache per locality / city for a minute.
- R03 restaurant menu: cache per restaurant, invalidated by W03-style menu updates.
- R02 dish search: cache per (city, search term) for a few minutes. "paneer" in Bengaluru is a popular search, and this is the query closest to its target.
- R08 bestseller badges: recomputed once a day; store the result.
- R09 is already a materialized view.

### 6.4 Maintenance

**Autovacuum for `orders`.** Each order is updated about 4 times on its way from PLACED to DELIVERED. None of these updates is HOT, because `status` is in the `INCLUDE` of three Phase 4 indexes and `partner_id` in two (the same issue as W05, and here the indexes are worth keeping). The large data has about 5,500 orders a day (3,000,000 over 546 days), so roughly 22,000 dead tuples a day; at 100× of seed, about 27,500 orders and 110,000 dead tuples a day. With the default `autovacuum_vacuum_scale_factor = 0.2`, autovacuum waits for 20% of the table: 600,000 dead tuples on 3 M rows (about 27 days), 3,000,000 on 15 M. Until then the visibility map goes stale and our Index Only Scans start visiting the heap again (`Heap Fetches`). Per-table settings, not server settings:

```sql
ALTER TABLE orders SET (autovacuum_vacuum_scale_factor        = 0.01,
                        autovacuum_vacuum_insert_scale_factor = 0.01,  -- keeps the visibility map fresh for new orders
                        autovacuum_analyze_scale_factor       = 0.005);
```

With monthly partitions these go on the current month's partition only (template in `08`). The closed months receive no writes, so after one final VACUUM they never need vacuuming again. Measured: a manual `VACUUM (ANALYZE) orders` takes 116 ms on the large data (68 ms on seed) when there is little to clean.

**Archiving.** Keep 12–13 months in `orders` for the reports (R09 needs the current year, R21 last month) and detach older months (`DETACH PARTITION ... CONCURRENTLY`, then dump and drop). On the large data that keeps `orders` at about 2 M rows instead of growing forever; it also bounds the cost of P5/P7-style lookups that touch every partition.

**Refreshing summary tables.** `REFRESH MATERIALIZED VIEW CONCURRENTLY mv_city_month_delivery` takes 1.00 s / 0.99 s on the large data (93 / 51 ms on seed), because it re-aggregates every delivered order. Nightly is fine at 20×. At 100× it would be about 5 s and growing with history. With partitions, the closed months' rows never change, so the view can become a plain summary table refreshed only for the current month: `DELETE` + `INSERT ... SELECT` for one month, which reads one partition.

**`fillfactor` for tables updated in place.** `customers` now has `fillfactor = 85` (W05). The same reasoning applies to `menu_items` (W03 updates `is_available`, which is not indexed) if menu updates become frequent.

## 7. Conclusion and remaining risks

**Ready for next year (20×): yes, with numbers.** All 30 optimized queries meet their targets on 3,000,000 orders on one laptop with default settings. The total workload is 1,538 ms (16.8× the 92 ms seed re-run on the same machine, for 20× the data). Fixed-size lookups stayed flat, the fixed-share queries grew about 20× and stay well inside their budgets, and the two queries that grew faster than the data (W05 through lost HOT updates, R20 through a rewrite that blocked parallelism) were found from their plans and fixed. Results are unchanged on the large data, except R13, whose original was wrong.

Remaining risks, roughly in order. The 100× column multiplies the large-data median by 5, which assumes the growth from section 3 continues:

| Risk | Large (median) | ~100× (×5) | Target | What to do |
|---|---:|---:|---:|---|
| R02 dish search: one probe per restaurant in the city | 72 ms | ~360 ms | 250 ms | **misses.** Cache per (city, term) (§6.3); a search index that filters city and text together (e.g. `city_id` copied to `menu_items` + `btree_gin` / trigram), tested first, since both indexes we tried were slower |
| W04 rating recompute: non-HOT update of every restaurant, grew 35× for 20× | 582 ms | ~2.9 s or more | 2,000 ms | **misses.** Only recompute restaurants with new reviews since the last run (`reviews_created_at_idx` exists); on a normal night that is a small fraction of restaurants |
| R17, R21 hash aggregates already spill (`Batches: 5`) | ~100 ms | ~500 ms+ | 5,000 ms | fine on time; move to a replica (§6.3), then a summary table if they keep growing |
| Cold first runs (R14 171 ms, R19 239 ms, W05 522 ms) | | | | the database (2.2 GB) is already 17× `shared_buffers`; at 100× the working set (current month) has to fit, which partitioning makes possible |
| Default autovacuum on `orders` | | | | Index Only Scans degrade silently as `Heap Fetches` grow; apply §6.4 |
| Partitioning: queries without `placed_at` scan every partition | 0.24 ms | grows with partition count | 5 ms | archive old months; carry `placed_at` in child tables |
| R23 keyset bound | | | | must come from the previous page in the app, never from `OFFSET` |

At 100×, the first steps are monthly partitioning of `orders` with archiving (§6.1), sending the report queries to a replica (§6.3), and fixing R02 and W04. City sharding (§6.2) is the step after that. The data supports it: every order stays inside one city.

## Appendix: per-run times on the large data (final)

From the raw plan files in `benchmarks/results/large/` (`Execution Time` of each run). Average and median are the `summary.csv` columns.

| Query | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Median (ms) | Scan nodes (run 3) |
|---|---:|---:|---:|---:|---:|---|
| R01 | 1.169 | 0.694 | 0.798 | 0.887 | 0.798 | Seq Scan on localities / Bitmap Heap Scan on restaurants / Bitmap Index Scan on restaurants_locality_status_rating_idx |
| R02 | 96.667 | 72.019 | 70.395 | 79.694 | 72.019 | Seq Scan on restaurants / Seq Scan on localities / Index Scan using menu_items_restaurant_item_key on menu_items |
| R03 | 0.060 | 0.059 | 0.052 | 0.057 | 0.059 | Index Scan using menu_items_restaurant_item_key on menu_items |
| R04 | 0.409 | 0.035 | 0.036 | 0.160 | 0.036 | Index Scan using orders_customer_placed_idx on orders / Index Scan using restaurants_pkey on restaurants |
| R05 | 0.191 | 0.135 | 0.124 | 0.150 | 0.135 | Index Scan using orders_preparing_accepted_idx on orders |
| R06 | 0.217 | 0.015 | 0.015 | 0.082 | 0.015 | Index Scan using orders_restaurant_placed_idx on orders |
| R07 | 0.765 | 0.090 | 0.083 | 0.313 | 0.090 | Index Scan using orders_restaurant_placed_idx on orders / Index Scan using order_items_pkey on order_items / Index Scan using menu_items_pkey on menu_items |
| R08 | 33.403 | 25.580 | 24.442 | 27.808 | 25.580 | Index Only Scan using orders_placed_at_idx on orders / Seq Scan on restaurants / Seq Scan on localities / Index Scan using order_items_pkey on order_items |
| R09 | 0.084 | 0.051 | 0.049 | 0.061 | 0.051 | Seq Scan on mv_city_month_delivery |
| R10 | 7.479 | 8.025 | 7.639 | 7.714 | 7.639 | Index Only Scan using orders_placed_at_idx on orders |
| R11 | 0.039 | 0.031 | 0.029 | 0.033 | 0.031 | Index Scan using orders_partner_placed_idx on orders |
| R12 | 0.031 | 0.022 | 0.022 | 0.025 | 0.022 | Index Scan using orders_unassigned_placed_idx on orders |
| R13 | 5.244 | 5.033 | 5.072 | 5.116 | 5.072 | Index Only Scan using orders_placed_at_idx on orders / Seq Scan on delivery_partners |
| R14 | 170.910 | 25.612 | 25.507 | 74.010 | 25.612 | Bitmap Heap Scan on customers / Bitmap Index Scan on customers_gold_expiry_idx / Index Only Scan using orders_customer_placed_idx on orders |
| R15 | 50.945 | 48.431 | 48.243 | 49.206 | 48.431 | Index Scan using coupons_pkey on coupons / Index Only Scan using orders_delivered_coupon_idx on orders |
| R16 | 0.261 | 0.219 | 0.220 | 0.233 | 0.220 | Index Only Scan using payments_failed_attempted_idx on payments |
| R17 | 99.880 | 101.503 | 99.600 | 100.328 | 99.880 | Seq Scan on orders / Index Only Scan using payments_failed_attempted_idx on payments |
| R18 | 0.792 | 0.370 | 0.368 | 0.510 | 0.370 | Index Scan using reviews_created_at_idx on reviews |
| R19 | 239.268 | 87.517 | 80.034 | 135.606 | 87.517 | Seq Scan on restaurants / Seq Scan on localities / Index Only Scan using orders_restaurant_placed_idx on orders / Index Only Scan using reviews_restaurant_idx on reviews |
| R20 | 130.683 | 101.285 | 103.887 | 111.952 | 103.887 | Index Scan using customers_pkey on customers / Index Only Scan using orders_customer_placed_idx on orders |
| R21 | 100.993 | 94.603 | 94.214 | 96.603 | 94.603 | Seq Scan on customers / Index Only Scan using orders_placed_at_idx on orders |
| R22 | 53.586 | 45.120 | 44.187 | 47.631 | 45.120 | Seq Scan on restaurants / Seq Scan on localities / Index Only Scan using orders_restaurant_placed_idx on orders |
| R23 | 0.039 | 0.027 | 0.026 | 0.031 | 0.027 | Index Scan using orders_placed_at_idx on orders |
| R24 | 1.217 | 0.053 | 0.047 | 0.439 | 0.053 | Index Scan using orders_pkey on orders / Index Scan using restaurants_pkey on restaurants / Index Scan using payments_order_id_idx on payments / Index Scan using order_items_pkey on order_items / Index Scan using menu_items_pkey on menu_items |
| R25 | 5.272 | 5.048 | 5.211 | 5.177 | 5.211 | Seq Scan on restaurants / Seq Scan on localities |
| W01 | 2.851 | 1.357 | 1.288 | 1.832 | 1.357 | (no scan) |
| W02 | 1.793 | 0.842 | 0.847 | 1.161 | 0.847 | Index Scan using orders_unassigned_placed_idx on orders / Index Scan using orders_pkey on orders |
| W03 | 0.226 | 0.187 | 0.189 | 0.201 | 0.189 | Index Scan using menu_items_restaurant_item_key on menu_items |
| W04 | 597.382 | 581.896 | 543.864 | 574.381 | 581.896 | Seq Scan on restaurants / Seq Scan on reviews |
| W05 | 521.825 | 69.207 | 60.223 | 217.085 | 69.207 | Bitmap Heap Scan on customers / Bitmap Index Scan on customers_gold_expiry_idx |
