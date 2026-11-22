-- Storage report used for docs/05_scalability_report.md, section 5.
-- psql -d <db> -X -A -F' | ' -f benchmarks/storage.sql

SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;
SELECT c.relname, c.reltuples::bigint AS rows,
       pg_size_pretty(pg_table_size(c.oid)) AS heap, pg_size_pretty(pg_indexes_size(c.oid)) AS indexes,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total, pg_table_size(c.oid) AS heap_b, pg_indexes_size(c.oid) AS idx_b
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='zomato' AND c.relkind IN ('r','m') ORDER BY pg_total_relation_size(c.oid) DESC;
SELECT pg_size_pretty(sum(pg_table_size(c.oid))) heap, pg_size_pretty(sum(pg_indexes_size(c.oid))) idx, sum(pg_table_size(c.oid)) hb, sum(pg_indexes_size(c.oid)) ib
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='zomato' AND c.relkind IN ('r','m');
