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

| Query | Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) |
|---|---|---:|---:|---:|---:|
| R01 | READ | 0.656 | 1.025 | 0.980 | 0.887 |
| R02 | READ | 7.469 | 5.721 | 6.008 | 6.399 |
| R03 | READ | 0.134 | 0.168 | 0.278 | 0.193 |
| R04 | READ | 19.950 | 11.917 | 8.486 | 13.451 |
| R05 | READ | 12.465 | 11.145 | 11.642 | 11.751 |
| R06 | READ | 8.685 | 7.970 | 8.736 | 8.464 |
| R07 | READ | 11.193 | 9.994 | 10.013 | 10.400 |
| R08 | READ | 10.170 | 9.589 | 9.440 | 9.733 |
| R09 | READ | 26.261 | 25.657 | 25.663 | 25.860 |
| R10 | READ | 5.689 | 5.568 | 5.520 | 5.592 |
| R11 | READ | 6.587 | 6.907 | 6.874 | 6.789 |
| R12 | READ | 8.659 | 8.872 | 8.436 | 8.656 |
| R13 | READ | 6.723 | 6.868 | 6.605 | 6.732 |
| R14 | READ | 7.943 | 8.376 | 8.001 | 8.107 |
| R15 | READ | 15.136 | 15.345 | 15.278 | 15.253 |
| R16 | READ | 5.203 | 5.223 | 5.016 | 5.147 |
| R17 | READ | 18.483 | 18.649 | 18.860 | 18.664 |
| R18 | READ | 8.037 | 7.455 | 8.001 | 7.831 |
| R19 | READ | 4803.416 | 5070.104 | 5340.247 | 5071.256 |
| R20 | READ | 27.240 | 25.990 | 24.994 | 26.075 |
| R21 | READ | 12.972 | 13.339 | 12.750 | 13.020 |
| R22 | READ | 19.906 | 20.399 | 20.371 | 20.225 |
| R23 | READ | 42.092 | 41.255 | 49.631 | 44.326 |
| R24 | READ | 14.864 | 10.943 | 12.054 | 12.620 |
| R25 | READ | 3.960 | 1.139 | 0.603 | 1.901 |
| W01 | WRITE | 157.544 | 4.969 | 3.287 | 55.267 |
| W02 | WRITE | 32.591 | 15.177 | 15.611 | 21.126 |
| W03 | WRITE | 0.206 | 0.357 | 0.320 | 0.294 |
| W04 | WRITE | 41.894 | 44.781 | 38.063 | 41.579 |
| W05 | WRITE | 19.807 | 17.496 | 33.747 | 23.683 |

## 3. Notes

- WRITE queries are executed inside transactions that are rolled back by the benchmark script, so benchmark writes do not persist changes.
- W01 has a high first-run value compared with Runs 2 and 3; its average includes all three measured runs as required.
- The individual run values are taken from the `Execution Time` lines in each corresponding raw plan file. The average values match the committed baseline summary to three decimal places.
