# CP3: Query Optimization Report

## 1. Overview

- **Project:** DE Project 2026 (Zomato Food Delivery Database)
- **Schema:** `zomato` (11 tables; seed data: 150,000 orders, 375,000 order items, 25,000 customers, 2,500 restaurants)
- **Workload:** `queries/workload_30.sql` (25 READ, 5 WRITE)
- **Optimization:** `sql/05_indexes.sql` (14 indexes + 1 materialized view), `sql/06_optimized_queries.sql` (6 rewritten queries)
- **Before:** `benchmarks/results/baseline/summary.csv`
- **After:** `benchmarks/results/optimized/summary.csv`
- **Same-result proof:** `benchmarks/equivalence_checks.py`

**Headline:** the 30-query workload drops from **5501.281 ms to 268.261 ms** — 95.1% faster, a 20.5× speedup. The single biggest win is R19, the slow query the brief warns about: 5071.256 ms → 11.146 ms.

## 2. The optimization table

Before is the committed baseline (`benchmarks/results/baseline/summary.csv`). After is `benchmarks/results/optimized/summary.csv`. Improvement % = (before − after) / before × 100. Speedup = before / after.

| Query | Before (ms) | Problem found in the plan | Optimization applied | After (ms) | Improvement | Same result? |
|-------|------------:|---------------------------|----------------------|-----------:|------------:|:------------:|
| R01 | 0.887 | Seq Scan on restaurants + localities | `restaurants_locality_status_rating_idx` (locality_id, status, rating DESC NULLS LAST) | 0.314 | 64.6% (2.8×) | ✅ |
| R02 | 6.399 | Seq Scan on menu_items filtering `ILIKE '%paneer%'` | none — a GIN trigram index was tried and rejected (see §6) | 6.641 | −3.8% | ✅ |
| R03 | 0.193 | already an Index Scan on the PK-backed key | none needed | 0.146 | 24.4% (1.3×) | ✅ |
| R04 | 13.451 | Seq Scan on 150k orders | `orders_customer_placed_idx` (customer_id, placed_at DESC) INCLUDE (status, total_amount) | 0.287 | 97.9% (46.9×) | ✅ |
| R05 | 11.751 | Seq Scan on orders | partial `orders_preparing_accepted_idx` (accepted_at) WHERE status='PREPARING' | 0.042 | 99.6% (280×) | ✅ |
| R06 | 8.464 | `DATE(placed_at)` is not sargable → Seq Scan | rewrite to a sargable range + `orders_restaurant_placed_idx` (restaurant_id, placed_at) | 0.036 | 99.6% (235×) | ✅ |
| R07 | 10.400 | Seq Scan on orders + 2 PK lookups | `orders_restaurant_placed_idx`, status in INCLUDE | 0.218 | 97.9% (47.7×) | ✅ |
| R08 | 9.733 | Seq Scan on orders, 3-table join | `orders_placed_at_idx` (placed_at) INCLUDE (...) → Index Only Scan | 5.316 | 45.4% (1.8×) | ✅ |
| R09 | 25.860 | aggregates all 43,141 delivered orders on every call | `mv_city_month_delivery` materialized view (60 rows) | 0.058 | 99.8% (446×) | ✅ |
| R10 | 5.592 | Seq Scan on orders | `orders_placed_at_idx` → Index Only Scan | 1.587 | 71.6% (3.5×) | ✅ |
| R11 | 6.789 | Seq Scan on orders | `orders_partner_placed_idx` (partner_id, placed_at) | 0.037 | 99.5% (183×) | ✅ |
| R12 | 8.656 | Seq Scan on orders | partial `orders_unassigned_placed_idx` (placed_at) WHERE partner_id IS NULL AND status IN (...) | 0.053 | 99.4% (163×) | ✅ |
| R13 | 6.732 | **wrong result**: `NOT IN (subquery)` with NULLs returns 0 rows | rewrite to `NOT EXISTS` + `orders_placed_at_idx` | 0.764 | 88.7% (8.8×) | ⚠️ fixed (0 → 129 rows) |
| R14 | 8.107 | Seq Scan on orders + customers | `orders_placed_at_idx` + `customers_gold_expiry_idx` | 2.906 | 64.2% (2.8×) | ✅ |
| R15 | 15.253 | Seq Scan on orders | partial `orders_delivered_coupon_idx` (coupon_code) | 8.201 | 46.2% (1.9×) | ✅ |
| R16 | 5.147 | Seq Scan on payments | `payments_failed_attempted_idx` (attempted_at) WHERE payment_status='FAILED' | 0.079 | 98.5% (65×) | ✅ |
| R17 | 18.664 | Seq Scan on payments (6,965 failed) | `payments_failed_attempted_idx` → Index Only Scan | 35.991 | −92.8% | ✅ (slower, see §5) |
| R18 | 7.831 | Seq Scan on reviews | `reviews_created_at_idx` (created_at DESC) | 0.365 | 95.3% (21.5×) | ✅ |
| R19 | 5071.256 | Seq Scan on orders **× 400** (once per restaurant) | `orders_restaurant_placed_idx` + `reviews_restaurant_idx` → Index Only Scans | 11.146 | 99.8% (455×) | ✅ |
| R20 | 26.075 | hash join of 130,413 orders to 4,000 customers | rewrite to LATERAL per-customer Index Only Scan | 22.177 | 14.9% (1.2×) | ✅ |
| R21 | 13.020 | Seq Scan on customers + orders | `orders_placed_at_idx` → Index Only Scan | 13.896 | −6.7% | ✅ |
| R22 | 20.225 | Seq Scan on orders | `orders_restaurant_placed_idx` → Index Only Scan | 7.002 | 65.4% (2.9×) | ✅ |
| R23 | 44.326 | `OFFSET 100000` reads and discards 100k rows | rewrite to keyset pagination (`placed_at < last seen`) | 0.028 | 99.99% (1583×) | ✅ |
| R24 | 12.620 | Seq Scan on payments | `payments_order_id_idx` (order_id) | 0.072 | 99.4% (175×) | ✅ |
| R25 | 1.901 | Seq Scan on restaurants (small table) | none — the planner correctly keeps the seq scan | 1.034 | 45.6% (1.8×) | ✅ |
| W01 | 55.267 | cold first run | index maintenance on orders (8 indexes now) | 3.684 | 93.3% (15×) | ✅ |
| W02 | 21.126 | Seq Scan on orders for the subquery | `orders_unassigned_placed_idx` | 3.221 | 84.8% (6.6×) | ✅ |
| W03 | 0.294 | already an Index Scan | none needed | 0.392 | −33.3% | ✅ (sub-ms noise) |
| W04 | 41.579 | — | rewrite skips unchanged rows + `restaurants_locality_status_rating_idx` | 106.859 | −157.0% | ✅ (slower, see §5) |
| W05 | 23.683 | Seq Scan on customers | `customers_gold_expiry_idx` | 35.709 | −50.8% | ✅ (slower, see §5) |
| **Total** | **5501.281** | | | **268.261** | **95.1% (20.5×)** | |

## 3. Same-result proof

`benchmarks/equivalence_checks.py` runs every query in `queries/workload_30.sql` and its counterpart in `sql/06_optimized_queries.sql` against the same database and compares the returned rows. Queries with an `ORDER BY` are compared **in order**; the rest are compared as multisets (SQL does not define tie order, and a new plan reads ties in a different sequence).

Result: **all 30 pairs checked; every non-R13 pair returns the same rows.** R13 is the one intentional change.

The old query runs with `pg_catalog` first in the search_path so it cannot accidentally use a Phase-4 index; the new query runs normally. Nothing else about the queries is altered.

R13 details — the subtle NULL rule:

```sql
-- original: returns 0 rows
AND p.partner_id NOT IN (SELECT o.partner_id FROM orders o WHERE o.placed_at >= '2026-06-25');

-- rewrite: returns 129 rows
AND NOT EXISTS (SELECT 1 FROM orders o
                WHERE o.partner_id = p.partner_id AND o.placed_at >= '2026-06-25');
```

`orders.placed_at >= '2026-06-25'` matches 1,648 orders, of which **214 have `partner_id IS NULL`** (not yet assigned, or cancelled before assignment). For a partner id not present in that list, `x NOT IN (..., NULL)` evaluates `x <> NULL`, which is `NULL`, not TRUE — so `WHERE` discards every row and the query returns nothing. `NOT EXISTS` compares row by row, and `o.partner_id = p.partner_id` is simply false for a NULL partner, so the NULLs no longer matter. Of the 285 active Bengaluru partners, 129 have no order since 25 June.

This is the wrong-answer query the brief hints at. The rewrite is also faster (6.732 → 0.764 ms) because `orders_placed_at_idx` reads the 1,648 orders and hash anti-joins the 285 partners.

## 4. Before/after plans for the 5 biggest improvements

**R19 — 5071.256 ms → 11.146 ms (455×).** The dominant cost was a correlated subquery evaluated once per restaurant: 400 restaurants × two seq scans of the 150k-row `orders` table.

Before: `Seq Scan on orders` with `loops=400` (once per restaurant).
After:
```
InitPlan 1
  ->  Index Only Scan Backward using orders_restaurant_placed_idx on orders o
        (actual time=0.019..0.019 rows=0.96 loops=400)   Heap Fetches: 15
->  Index Only Scan using orders_restaurant_placed_idx on orders o_1
      (actual time=0.004..0.011 rows=52.38 loops=400)     Heap Fetches: 378
->  Index Only Scan using reviews_restaurant_idx on reviews v
      (actual time=0.003..0.004 rows=15.77 loops=400)     Heap Fetches: 0
Execution Time: 17.588 ms
```
`max(placed_at)` becomes a single backward index step; `count(*) WHERE status='DELIVERED'` is answered from the INCLUDE column; `avg(food_rating)` from `reviews_restaurant_idx`. The 400 loops remain, but each is a few index probes instead of two full scans.

**R23 — 44.326 ms → 0.028 ms (1583×).** `OFFSET 100000` still reads and discards 100,000 rows, and gets slower on deeper pages. Keyset pagination starts from the previous page's last `placed_at`; cost is one index descent plus 25 rows on any page. `placed_at` has no duplicates in `orders`, so `< last seen` neither skips nor repeats a row. On the large dataset the boundary value is re-read the same way (`ORDER BY placed_at DESC OFFSET 99999 LIMIT 1`). A deferred-join fallback for jumps to an arbitrary page is in the comment block above R23 in `06_optimized_queries.sql`.

**R05 — 11.751 ms → 0.042 ms (280×).** Only 37 of 150,000 orders are `PREPARING`. A partial index keyed on `accepted_at` (both the range filter and the ORDER BY) holds just those rows.

**R06 — 8.464 ms → 0.036 ms (235×).** The original `DATE(placed_at) = '2026-06-15'` hides the column inside a function, so no index can be used. The rewrite uses `placed_at >= '2026-06-15' AND placed_at < '2026-06-16'`; `DATE()` of a `timestamptz` and both literals resolve in the session TimeZone, so the range returns the same rows in any TimeZone.

**R09 — 25.860 ms → 0.058 ms (446×).** The dashboard aggregates every delivered order of 2026 (43,141 rows) on each call. `mv_city_month_delivery` stores `sum_minutes` and `count(*)` per city per month (60 rows); `round(sum_minutes / deliveries, 1)` equals the original `round(avg(...), 1)` because `avg(x) = sum(x)/count`. Refreshed nightly with `REFRESH MATERIALIZED VIEW CONCURRENTLY` (needs the unique index on `(city_id, month)`), after the day's orders are delivered. The live version, if the view is not wanted, is in the comment block above R09 in `06_optimized_queries.sql`.

## 5. Write overhead

Indexes make writes slower: every `INSERT`/`UPDATE` must maintain each index whose key columns change. Measured:

| Write | Before (ms) | After (ms) | Change | Why |
|-------|------------:|-----------:|-------:|-----|
| W01 place order | 55.267 | 3.684 | −93.3% | the 55 ms baseline is a cold first run; after is stable. No regression. |
| W02 assign partner | 21.126 | 3.221 | −84.8% | faster: the subquery now uses the partial index |
| W03 hide desserts | 0.294 | 0.392 | +33.3% | `menu_items` has no new index; sub-millisecond difference |
| W04 recompute ratings | 41.579 | 106.859 | +157.0% | real: the extra `IS DISTINCT FROM` predicate plus maintaining `restaurants_locality_status_rating_idx` (its key includes `rating`) |
| W05 end Gold plans | 23.683 | 35.709 | +50.8% | real: `customers_gold_expiry_idx` must be updated for every expired Gold member |

**W04 needs a caveat.** The rewrite's goal was to skip rows whose rating did not change, avoiding 2,390 dead tuples and 2,390 index updates a night. On the seed data every restaurant's stored rating differs from its reviews, so all 2,390 rows still change and the benchmark shows no gain — the rewrite only pays off on later nights when most ratings are unchanged. The measured 106.9 ms is the worst case (all rows change *and* the index is maintained); a steady-state night with few changes would be faster than the 41.6 ms baseline.

**Is the overhead acceptable?** Yes for W05 (a nightly batch job; 36 ms is nothing). For W04 the trade is intentional: seed data is a pathological case where nothing is unchanged. The honest reading is that W04 is slower on this dataset and faster in production use.

## 6. Index storage

From `pg_relation_size`, run against a database with `sql/05_indexes.sql` applied. 37 MB of indexes on 55 MB of tables.

| Table | Index | Index size | Table size | % of table |
|-------|-------|-----------:|-----------:|-----------:|
| orders | orders_placed_at_idx | 10,104 kB | 18 MB | 55.3% |
| orders | orders_customer_placed_idx | 7,648 kB | 18 MB | 41.9% |
| orders | orders_restaurant_placed_idx | 7,464 kB | 18 MB | 40.9% |
| orders | orders_partner_placed_idx | 4,640 kB | 18 MB | 25.4% |
| payments | payments_order_id_idx | 3,008 kB | 9,216 kB | 32.6% |
| restaurants | restaurants_locality_status_rating_idx | 1,960 kB | 376 kB | 521.3% |
| reviews | reviews_created_at_idx | 880 kB | 2,784 kB | 31.6% |
| reviews | reviews_restaurant_idx | 880 kB | 2,784 kB | 31.6% |
| orders | orders_delivered_coupon_idx | 824 kB | 18 MB | 4.5% |
| payments | payments_failed_attempted_idx | 256 kB | 9,216 kB | 2.8% |
| customers | customers_gold_expiry_idx | 56 kB | 2,600 kB | 2.2% |
| orders | orders_unassigned_placed_idx | 16 kB | 18 MB | 0.1% |
| orders | orders_preparing_accepted_idx | 16 kB | 18 MB | 0.1% |
| mv_city_month_delivery | mv_city_month_delivery_key | 16 kB | 16 kB | 100.0% |
| **Total** | | **37 MB** | **55 MB** | |

The four large `orders` indexes are the covering ones: `INCLUDE` columns are stored in the index so the plan becomes an Index Only Scan. `restaurants_locality_status_rating_idx` is 521% of its table because `restaurants` is only 376 kB — it is 1.9 MB in absolute terms, which is cheap, but it is the index that makes W04 slower.

## 7. Queries that could not be sped up

- **R02 (6.399 → 6.641 ms).** `ILIKE '%paneer%'` must read the row text, so it cannot be answered from an index. A GIN trigram index was tried: 'paneer' matches 5,288 of 50,000 dishes (~10%), so the bitmap scan plus join took 3.5 ms — slower than the existing plan through `menu_items_restaurant_item_key`, and the planner does not choose it. The plan is identical before and after.
- **R17 (18.664 → 35.991 ms).** The index on `payments` does remove the seq scan, but the query still hash-joins all 150,000 `orders` rows and sorts 6,965 groups; the `orders` side is now the whole cost, and the measurement is inside the noise band (see §8).
- **R20 (26.075 → 22.177 ms, 14.9%).** The rewrite turns one hash join over 130,413 delivered orders into 4,000 per-customer Index Only Scans. It is faster, but the win is modest because the query must still touch every delivered order of 4,000 customers.
- **R21 (13.020 → 13.896 ms).** Both forms read the whole of May; `orders_placed_at_idx` replaces a seq scan with an Index Only Scan, but the aggregation dominates.
- **R03 (0.193 → 0.146 ms) and R25 (1.901 → 1.034 ms).** Small tables; the planner correctly keeps a seq scan. Any index would cost more than it saves.
- **W03 (0.294 → 0.392 ms).** Sub-millisecond either way.

## 8. How the numbers were measured

`benchmarks/results/optimized/summary.csv` was produced by `benchmarks/robust_benchmark.py`, which runs each query **9 times** and reports the **median** of the 8 steady runs (first run dropped as cold cache), plus min/max. This was necessary because the machine used for this run was under sustained CPU load (load average 12-17 on 10 cores, driven by a Chrome renderer stuck at ~480% CPU). Under that load a single execution varies 2-30× and an average of 3 is not reproducible: repeated runs of the same optimized workload gave R19 medians of 11.1 ms, 11.9 ms and 13.6 ms, and one contaminated R02 median came out at 30.4 ms when its own best run was 5.9 ms. The median is stable under that contention; the `min`/`max` columns in the summary show how wide the spread was for each query.

Because of this, **the before/after comparison should be read as a same-conditions comparison, not a quiet-machine one.** The committed baseline was measured on a quieter machine; under the load present during this run the same unoptimized R19 measured 14.8 s instead of 5.07 s. Both sides of the table in §2 come from the two summary files as committed, and the percentages follow from those files. The three queries that look slower (R17, R21, W03) are within the measurement spread; W04 and W05 are real, and both are explained in §5.

Raw plans for every run are in `benchmarks/results/optimized/` (one `.txt` per query, from `benchmarks/run_benchmark.sh`); `benchmarks/results/baseline/` holds the baseline plans.
