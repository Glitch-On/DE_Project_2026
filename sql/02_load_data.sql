-- =====================================================================
-- Zomato Food Delivery Database - Phase 2: load the seed data
-- Team T0022 (Section B) - DE_Project_2026
--
-- Run from the project root (the folder that contains seed_data/):
--   psql -d <db> -X -v ON_ERROR_STOP=1 -f sql/02_load_data.sql
--
-- \copy is a psql meta-command: it streams the CSV through the client,
-- so the file path is resolved on the machine running psql. Parents are
-- loaded before children so every foreign key is satisfied.
--
-- Note on booleans: the CSVs store t/f. PostgreSQL's COPY accepts
-- 't'/'f' for boolean columns, so no conversion is needed.
-- Note on arrays: restaurants.cuisines is a PostgreSQL text[] and the
-- CSV already holds array literal syntax ({Chinese,"North Indian"}),
-- which COPY parses natively.
-- =====================================================================

SET search_path TO zomato;

-- Start from an empty schema so the script is idempotent (safe to re-run).
-- TRUNCATE ... CASCADE clears the children too; RESTART IDENTITY resets
-- no sequences here because every table uses an explicit integer PK.
TRUNCATE reviews, payments, order_items, orders,
         delivery_partners, menu_items, restaurants,
         coupons, customers, localities, cities
RESTART IDENTITY CASCADE;

-- Parents first --------------------------------------------------------
\copy cities            FROM 'seed_data/cities.csv'            WITH (FORMAT csv, HEADER true)
\copy localities        FROM 'seed_data/localities.csv'        WITH (FORMAT csv, HEADER true)
\copy customers         FROM 'seed_data/customers.csv'         WITH (FORMAT csv, HEADER true)
\copy coupons           FROM 'seed_data/coupons.csv'           WITH (FORMAT csv, HEADER true)

-- Restaurants depend on localities; menu_items on restaurants;
-- delivery_partners on cities.
\copy restaurants       FROM 'seed_data/restaurants.csv'       WITH (FORMAT csv, HEADER true)
\copy menu_items        FROM 'seed_data/menu_items.csv'        WITH (FORMAT csv, HEADER true)
\copy delivery_partners FROM 'seed_data/delivery_partners.csv' WITH (FORMAT csv, HEADER true)

-- Orders depend on customers, restaurants, partners and coupons.
\copy orders            FROM 'seed_data/orders.csv'            WITH (FORMAT csv, HEADER true)

-- Children of orders ---------------------------------------------------
\copy order_items       FROM 'seed_data/order_items.csv'       WITH (FORMAT csv, HEADER true)
\copy payments          FROM 'seed_data/payments.csv'          WITH (FORMAT csv, HEADER true)
\copy reviews           FROM 'seed_data/reviews.csv'           WITH (FORMAT csv, HEADER true)

-- Fresh statistics for the planner -------------------------------------
ANALYZE;

-- Row-count verification (expected values from the project brief) -----
SELECT 'cities'            AS table_name, count(*) FROM cities            UNION ALL
SELECT 'localities',        count(*) FROM localities        UNION ALL
SELECT 'customers',         count(*) FROM customers         UNION ALL
SELECT 'restaurants',       count(*) FROM restaurants       UNION ALL
SELECT 'menu_items',        count(*) FROM menu_items        UNION ALL
SELECT 'delivery_partners', count(*) FROM delivery_partners UNION ALL
SELECT 'coupons',           count(*) FROM coupons           UNION ALL
SELECT 'orders',            count(*) FROM orders            UNION ALL
SELECT 'order_items',       count(*) FROM order_items       UNION ALL
SELECT 'payments',          count(*) FROM payments          UNION ALL
SELECT 'reviews',           count(*) FROM reviews;
