# CP2: Baseline Query Timings

## 1. Overview

- **Project:** DE Project 2026
- **Database schema:** `zomato`
- **Workload:** `queries/workload_30.sql`
- **Total queries:** 30 (25 READ and 5 WRITE)
- **Runs per query:** 3
- **Measurement:** `EXPLAIN (ANALYZE, BUFFERS)`; execution time reported in milliseconds (ms)
- **Raw execution plans:** `benchmarks/results/baseline/`
- **Summary output:** `benchmarks/results/baseline/summary.csv`

## 2. Run timings

The table below records the three execution-time measurements from each query's raw baseline plan file. The average is the arithmetic mean of Run 1, Run 2, and Run 3, rounded to three decimal places. The averages were cross-checked against `benchmarks/results/baseline/summary.csv`.

| SQL Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01: Home feed: open restaurants in Koramangala, best rated first | READ | 0.656 | 1.025 | 0.980 | 0.887 |
| R02: Dish search: available "paneer" dishes in Bengaluru | READ | 7.469 | 5.721 | 6.008 | 6.399 |
| R03: Restaurant page: the menu of one restaurant, grouped by category | READ | 0.134 | 0.168 | 0.278 | 0.193 |
| R04: "Your orders": a customer's last 10 orders with restaurant names | READ | 19.950 | 11.917 | 8.486 | 13.451 |
| R05: Kitchen-delay alert: orders stuck in PREPARING for over 40 minutes (checked at 23:59 on 30 Jun 2026) | READ | 12.465 | 11.145 | 11.642 | 11.751 |
| R06: Restaurant partner app: all orders received by restaurant 217 on 15 June 2026 | READ | 8.685 | 7.970 | 8.736 | 8.464 |
| R07: Restaurant partner app: units sold per dish in May 2026 | READ | 11.193 | 9.994 | 10.013 | 10.400 |
| R08: Bestseller badges: top 3 dishes of every Pune restaurant in the last 30 days | READ | 10.170 | 9.589 | 9.440 | 9.733 |
| R09: Ops dashboard: average delivery time (minutes) per city per month in 2026 | READ | 26.261 | 25.657 | 25.663 | 25.860 |
| R10: Customer support: deliveries in June 2026 that took more than 60 minutes | READ | 5.689 | 5.568 | 5.520 | 5.592 |
| R11: Delivery partner app: this week's earnings (delivery fees) for partner 150 | READ | 6.587 | 6.907 | 6.874 | 6.789 |
| R12: Dispatch: orders still waiting for a delivery partner, oldest first | READ | 8.659 | 8.872 | 8.436 | 8.656 |
| R13: Fleet team: active Bengaluru partners who have not been assigned any order since 25 June 2026 | READ | 6.723 | 6.868 | 6.605 | 6.732 |
| R14: Gold team: Gold members whose membership expires before July 2026 but who ordered in June 2026 | READ | 7.943 | 8.376 | 8.001 | 8.107 |
| R15: Marketing: coupon effectiveness (orders, total discount, average bill) | READ | 15.136 | 15.345 | 15.278 | 15.253 |
| R16: Payments team: failed payment attempts per method in the last 7 days | READ | 5.203 | 5.223 | 5.016 | 5.147 |
| R17: Risk team: customers with 2 or more failed payment attempts (all time) | READ | 18.483 | 18.649 | 18.860 | 18.664 |
| R18: Review moderation: newest reviews that complain about cold food or late delivery | READ | 8.037 | 7.455 | 8.001 | 7.831 |
| R19: Restaurant health report for Bengaluru: last order time, delivered orders and average food rating | READ | 4803.416 | 5070.104 | 5340.247 | 5071.256 |
| R20: Growth: top 20 customers in Mumbai by total spend on delivered orders | READ | 27.240 | 25.990 | 24.994 | 26.075 |
| R21: Growth: share of customers in each city who ordered at least twice in May 2026 | READ | 12.972 | 13.339 | 12.750 | 13.020 |
| R22: Ops heatmap: Bengaluru orders by weekday and hour, last 8 weeks | READ | 19.906 | 20.399 | 20.371 | 20.225 |
| R23: Admin panel: "All orders", newest first, page 4,001 (25 rows per page) | READ | 42.092 | 41.255 | 49.631 | 44.326 |
| R24: Bill page: one order with its items, restaurant and successful payment | READ | 14.864 | 10.943 | 12.054 | 12.620 |
| R25: Cuisine filter: open Chinese restaurants in Pune | READ | 3.960 | 1.139 | 0.603 | 1.901 |
| W01: Customer app: place a new order (header row) | WRITE | 157.544 | 4.969 | 3.287 | 55.267 |
| W02: Dispatch: assign partner 150 to the oldest accepted order that has no partner | WRITE | 32.591 | 15.177 | 15.611 | 21.126 |
| W03: Restaurant partner app: desserts sold out, so hide them | WRITE | 0.206 | 0.357 | 0.320 | 0.294 |
| W04: Nightly job: recompute every restaurant's rating from its reviews | WRITE | 41.894 | 44.781 | 38.063 | 41.579 |
| W05: Nightly job: end Gold membership for customers whose plan has expired | WRITE | 19.807 | 17.496 | 33.747 | 23.683 |
| **Total (sum of all 30)** | | **5355.935** | **5432.398** | **5715.515** | **5501.281** |

The total row sums each column. The total of the Average column (5501.281 ms) is 0.002 ms off the mean of the three run totals (5501.283 ms) because each per-query average is rounded first.

R19 takes about 5 seconds and accounts for about 92% of the whole workload's time. This is the slow query the brief warns about.

## 3. Scan type and why each query is slow or fast

The scan types come from the `scan_nodes` column of `summary.csv` (taken from the run 3 plan). Row counts and buffer numbers are from the run 3 plan in `benchmarks/results/baseline/<id>.txt`. At baseline the only indexes are the ones PostgreSQL creates for PRIMARY KEY and UNIQUE constraints. `orders` is 2,304 pages (150,000 rows), so a full scan of it costs about 5–10 ms, and that one cost shows up in most of the queries below.

| Query | Scan type | Why it is slow or fast |
|---|---|---|
| R01 | Seq Scan on restaurants, Seq Scan on localities | Fast: both tables are small (47 + 1 pages). It reads all 2,500 restaurants to keep the 34 open ones in Koramangala, which is cheap at this size. |
| R02 | Seq Scan on restaurants, Seq Scan on localities, Index Scan using menu_items_restaurant_item_key | Medium: there is no index for `ILIKE '%paneer%'`, so for each of the 400 Bengaluru restaurants it walks that restaurant's menu through the UNIQUE (restaurant_id, item_name) index and filters by text, which is 1,654 buffer hits. |
| R03 | Index Scan using menu_items_restaurant_item_key | Fast: `restaurant_id` is the leading column of the UNIQUE index, so only this restaurant's 20 items are read (3 pages). |
| R04 | Seq Scan on orders, Index Scan using restaurants_pkey | Slow for a customer-facing screen: there is no index on `orders.customer_id`, so it scans all 150,000 orders to find 9 rows (149,991 removed by filter). |
| R05 | Parallel Seq Scan on orders | No index on `status` or `accepted_at`, so all of `orders` is scanned to return 35 PREPARING rows. |
| R06 | Parallel Seq Scan on orders | No index on `restaurant_id`, and `DATE(placed_at)` wraps the column in a function, so even an index on `placed_at` could not be used. Full scan, 0 matching rows. |
| R07 | Parallel Seq Scan on orders, Index Scan using order_items_pkey, Index Scan using menu_items_pkey | The joins to order_items and menu_items are cheap PK lookups. The cost is the full scan of `orders` to find restaurant 217's delivered May orders. |
| R08 | Seq Scan on orders, restaurants and localities, Index Scan using order_items_pkey | Full scan of `orders` for the date and status filter (about 7,000 rows kept), then about 570 PK lookups into order_items. The window function and sort are small. |
| R09 | Parallel Seq Scan on orders, Seq Scan on restaurants and localities | `EXTRACT(YEAR FROM placed_at) = 2026` cannot use an index. About 43,000 delivered rows go through two hash joins and a sort before the aggregate. It is a reporting query, so this time is acceptable, but it gets worse as orders grow. |
| R10 | Parallel Seq Scan on orders | Full scan for the June date range. The `delivered_at - placed_at` expression is sorted with a top-N heapsort, which is cheap. |
| R11 | Parallel Seq Scan on orders | No index on `partner_id`, so it scans all orders to sum one partner's fees for the week. |
| R12 | Seq Scan on orders | No index on `status` or on `partner_id IS NULL`. Scans 150,000 rows to find 75 waiting orders. A partial index would fit this well later. |
| R13 | Seq Scan on delivery_partners, Seq Scan on orders (hashed SubPlan) | Fast enough (one hashed subplan over orders), but **wrong**: it returns 0 rows. `orders.partner_id` is NULL for 214 orders placed since 25 June, and `x NOT IN (... NULL ...)` is never true, so every partner is filtered out. To be fixed in Phase 4 with `NOT EXISTS`. |
| R14 | Seq Scan on orders, Seq Scan on customers | EXISTS turns into a hash semi-join. Both tables are scanned in full (no index on `customer_id` or `placed_at`). |
| R15 | Seq Scan on orders, Seq Scan on coupons | Reads about 130,000 delivered orders and hash joins them to 30 coupons. Most of the time goes on moving that many rows. |
| R16 | Seq Scan on payments | No index on `payment_status` or `attempted_at`. Scans all 137,378 payments to count 82 recent failures. |
| R17 | Seq Scan on orders, Seq Scan on payments | Full scan of both tables. All 150,000 orders are hashed to join about 7,000 failed payments, then grouped. |
| R18 | Seq Scan on reviews | `ILIKE '%cold%' OR ILIKE '%late%'` with leading wildcards cannot use a B-tree, so every review's text is checked (36,262 rows removed). |
| R19 | Seq Scan on restaurants, localities, orders (x2 subplans) and reviews (subplan) | **Slowest query (about 5 s).** It has three correlated subqueries per restaurant, and with no index on `orders.restaurant_id` or `reviews.restaurant_id`, each runs as a full table scan 400 times (once per Bengaluru restaurant): 1,200 scans and about 1.98 million buffer hits. |
| R20 | Seq Scan on orders, Seq Scan on customers | Joins about 130,000 delivered orders to 4,000 Mumbai customers with a hash join, then aggregates. A full scan plus a big join, so it runs at about 26 ms. |
| R21 | Seq Scan on orders, Seq Scan on customers | Full scan of orders for May, group by customer, then a hash join to all 25,000 customers. |
| R22 | Seq Scan on orders, restaurants and localities | Full scan of orders for the last 8 weeks (about 15,000 rows), joined to Bengaluru restaurants. Most of the time is the scan. |
| R23 | Seq Scan on orders | `OFFSET 100000` with no index on `placed_at` forces a sort of all 150,000 rows. The sort spills to disk (`external merge  Disk: 7568kB`), which makes this the second slowest read. |
| R24 | Index Scan using orders_pkey, restaurants_pkey, order_items_pkey, menu_items_pkey, Seq Scan on payments | Every join is a PK lookup except payments: there is no index on `payments.order_id`, so a single order's payment is found by scanning all 137,378 payments (about 10 of the 12 ms). |
| R25 | Seq Scan on restaurants, Seq Scan on localities | Fast because restaurants is small. `'Chinese' = ANY(cuisines)` is checked row by row. |
| W01 | (no scan) | A single-row INSERT. Run 1 took 157 ms because of cold caches and first-time FK and trigger setup. Runs 2–3 take about 3–5 ms, mostly for the 4 FK checks, the coupon trigger and updating the orders indexes. |
| W02 | Seq Scan on orders, Index Scan using orders_pkey | The subquery scans all of `orders` to find the oldest ACCEPTED order with no partner. The UPDATE itself is a single PK lookup. |
| W03 | Index Scan using menu_items_restaurant_item_key | Fast: the leading `restaurant_id` column of the UNIQUE index limits the update to one restaurant's 20 items. |
| W04 | Seq Scan on restaurants, Seq Scan on reviews | Aggregates all 39,186 reviews and updates 2,390 restaurant rows. Writing the new row versions and their index entries (30,510 buffer hits) costs more than reading. |
| W05 | Seq Scan on customers | Scans all 25,000 customers and updates 1,230 rows. As with W04, the cost is mostly in writing the new row versions and maintaining the UNIQUE indexes on email and phone. |

## 4. Notes

- WRITE queries run inside `BEGIN; ... ROLLBACK;` (done by `run_benchmark.sh`), so the benchmark does not change the data.
- The individual run values come from the `Execution Time` lines in each raw plan file. The averages match `summary.csv` to three decimal places.
- Main patterns for Phase 4: most reads do a full scan of `orders` because it has no secondary indexes (`customer_id`, `restaurant_id`, `partner_id`, `status`, `placed_at`). `payments.order_id` and `reviews.restaurant_id` are not indexed either. R06 and R09 use non-sargable date filters, R23 uses OFFSET pagination, and R19 uses correlated subqueries.
