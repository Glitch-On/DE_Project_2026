-- =====================================================================
-- Zomato DBMS Project - Phase 2 integrity checks
-- Team T0022 (Section B) - DE_Project_2026
--
-- Run after sql/02_load_data.sql:
--   psql -d <db> -X -f sql/03_integrity_checks.sql
--
-- Every check must return 0 (or the stated expected value). A non-zero
-- result means either the schema is wrong or the seed data is defective.
-- =====================================================================

SET search_path TO zomato;

\echo '=== IC1: every order line dish belongs to the order''s restaurant ==='
SELECT count(*) AS violations
FROM order_items oi
JOIN menu_items  m ON m.item_id = oi.item_id
JOIN orders      o ON o.order_id = oi.order_id
WHERE m.restaurant_id <> o.restaurant_id;

\echo '=== IC2: every delivered order has exactly one SUCCESS payment ==='
SELECT
  count(*) FILTER (WHERE s.n = 1)                AS delivered_with_one_success,
  count(*) FILTER (WHERE s.n = 0)                AS delivered_with_zero_success,
  count(*) FILTER (WHERE s.n > 1)                AS delivered_with_many_success
FROM orders o
LEFT JOIN (SELECT order_id, count(*) AS n FROM payments
           WHERE payment_status = 'SUCCESS' GROUP BY order_id) s
       ON s.order_id = o.order_id
WHERE o.status = 'DELIVERED';

\echo '=== IC2b: delivered orders with no SUCCESS payment - payment status breakdown ==='
SELECT coalesce(p.payment_status, '(no payment row)') AS status, count(*)
FROM orders o
LEFT JOIN payments p ON p.order_id = o.order_id
WHERE o.status = 'DELIVERED'
  AND NOT EXISTS (SELECT 1 FROM payments p2
                  WHERE p2.order_id = o.order_id AND p2.payment_status = 'SUCCESS')
GROUP BY 1 ORDER BY 1;

\echo '=== IC2c: every delivered order has at least one payment attempt ==='
SELECT count(*) AS violations
FROM orders o
WHERE o.status = 'DELIVERED'
  AND NOT EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.order_id);

\echo '=== IC2d: every delivered order has at most one SUCCESS payment ==='
SELECT count(*) AS violations
FROM orders o
JOIN (SELECT order_id, count(*) AS n FROM payments
      WHERE payment_status = 'SUCCESS' GROUP BY order_id) s
  ON s.order_id = o.order_id
WHERE o.status = 'DELIVERED' AND s.n > 1;

\echo '=== IC3: a pure-veg restaurant has no non-veg dish ==='
SELECT count(*) AS violations
FROM restaurants r
JOIN menu_items  m ON m.restaurant_id = r.restaurant_id
WHERE r.is_pure_veg AND NOT m.is_veg;

\echo '=== IC4: every order''s item_total equals sum(quantity * unit_price) ==='
SELECT count(*) AS violations
FROM orders o
JOIN (SELECT order_id, sum(quantity * unit_price) AS s FROM order_items GROUP BY order_id) t
  ON t.order_id = o.order_id
WHERE t.s <> o.item_total;

\echo '=== IC5: every order''s total_amount = item_total + delivery_fee - discount ==='
SELECT count(*) AS violations
FROM orders
WHERE total_amount <> item_total + delivery_fee - discount;

\echo '=== IC6: every order''s unit_price matches the dish''s menu price ==='
SELECT count(*) AS violations
FROM order_items oi
JOIN menu_items  m ON m.item_id = oi.item_id
WHERE oi.unit_price <> m.price;

\echo '=== IC7: every review is for a delivered order, by that order''s customer and restaurant ==='
SELECT
  count(*) FILTER (WHERE o.status <> 'DELIVERED')                       AS not_delivered,
  count(*) FILTER (WHERE r.customer_id <> o.customer_id)                AS wrong_customer,
  count(*) FILTER (WHERE r.restaurant_id <> o.restaurant_id)            AS wrong_restaurant,
  count(*) FILTER (WHERE r.created_at < o.delivered_at)                 AS before_delivery
FROM reviews r JOIN orders o ON o.order_id = r.order_id;

\echo '=== IC8: every payment amount equals its order''s total_amount ==='
SELECT count(*) AS violations
FROM payments p JOIN orders o ON o.order_id = p.order_id
WHERE p.amount <> o.total_amount;

\echo '=== IC9: order lifecycle timestamps are monotonic ==='
SELECT
  count(*) FILTER (WHERE accepted_at  < placed_at)                          AS accepted_before_placed,
  count(*) FILTER (WHERE picked_up_at < accepted_at)                        AS picked_before_accepted,
  count(*) FILTER (WHERE delivered_at < picked_up_at)                       AS delivered_before_picked,
  count(*) FILTER (WHERE delivered_at < placed_at)                          AS delivered_before_placed
FROM orders;

\echo '=== IC10: status-dependent NULL rules ==='
SELECT
  count(*) FILTER (WHERE status = 'PLACED' AND (partner_id IS NOT NULL OR accepted_at IS NOT NULL)) AS placed_bad,
  count(*) FILTER (WHERE status = 'ACCEPTED' AND (partner_id IS NOT NULL OR accepted_at IS NULL))  AS accepted_bad,
  count(*) FILTER (WHERE status = 'PREPARING' AND (partner_id IS NULL OR accepted_at IS NULL))    AS preparing_bad,
  count(*) FILTER (WHERE status = 'OUT_FOR_DELIVERY' AND (picked_up_at IS NULL OR delivered_at IS NOT NULL)) AS ofd_bad,
  count(*) FILTER (WHERE status = 'DELIVERED' AND (partner_id IS NULL OR accepted_at IS NULL OR picked_up_at IS NULL OR delivered_at IS NULL)) AS delivered_bad,
  count(*) FILTER (WHERE status LIKE 'CANCELLED%' AND (picked_up_at IS NOT NULL OR delivered_at IS NOT NULL)) AS cancelled_bad
FROM orders;

\echo '=== IC11: delivery fee rule (Gold = free; non-Gold = 45 if distance > 5.0 else 25) ==='
SELECT count(*) AS violations
FROM orders o JOIN customers c ON c.customer_id = o.customer_id
WHERE CASE WHEN c.is_gold_member THEN o.delivery_fee <> 0
           ELSE o.delivery_fee <> CASE WHEN o.distance_km > 5.0 THEN 45 ELSE 25 END
      END;

\echo '=== IC12: coupon discount rule (min(pct * item_total / 100, max_discount)) ==='
SELECT count(*) AS violations
FROM orders o JOIN coupons c ON c.coupon_code = o.coupon_code
WHERE o.discount <> least(o.item_total * c.discount_pct / 100, c.max_discount);

\echo '=== IC13: coupon used only above its minimum order value ==='
SELECT count(*) AS violations
FROM orders o JOIN coupons c ON c.coupon_code = o.coupon_code
WHERE o.item_total < c.min_order_value;

\echo '=== IC14: referential integrity (orphan rows) ==='
SELECT
  (SELECT count(*) FROM localities l  WHERE NOT EXISTS (SELECT 1 FROM cities c WHERE c.city_id = l.city_id))            AS loc_orphans,
  (SELECT count(*) FROM customers c   WHERE NOT EXISTS (SELECT 1 FROM cities c2 WHERE c2.city_id = c.city_id))          AS cust_orphans,
  (SELECT count(*) FROM restaurants r WHERE NOT EXISTS (SELECT 1 FROM localities l WHERE l.locality_id = r.locality_id)) AS rest_orphans,
  (SELECT count(*) FROM menu_items m  WHERE NOT EXISTS (SELECT 1 FROM restaurants r WHERE r.restaurant_id = m.restaurant_id)) AS menu_orphans,
  (SELECT count(*) FROM delivery_partners d WHERE NOT EXISTS (SELECT 1 FROM cities c WHERE c.city_id = d.city_id))      AS partner_orphans,
  (SELECT count(*) FROM orders o      WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id)) AS order_cust_orphans,
  (SELECT count(*) FROM orders o      WHERE NOT EXISTS (SELECT 1 FROM restaurants r WHERE r.restaurant_id = o.restaurant_id)) AS order_rest_orphans,
  (SELECT count(*) FROM orders o      WHERE o.partner_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM delivery_partners d WHERE d.partner_id = o.partner_id)) AS order_partner_orphans,
  (SELECT count(*) FROM orders o      WHERE o.coupon_code IS NOT NULL AND NOT EXISTS (SELECT 1 FROM coupons c WHERE c.coupon_code = o.coupon_code))    AS order_coupon_orphans,
  (SELECT count(*) FROM order_items oi WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id))        AS oi_order_orphans,
  (SELECT count(*) FROM order_items oi WHERE NOT EXISTS (SELECT 1 FROM menu_items m WHERE m.item_id = oi.item_id))      AS oi_item_orphans,
  (SELECT count(*) FROM payments p    WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = p.order_id))          AS pay_orphans,
  (SELECT count(*) FROM reviews r     WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = r.order_id))          AS rev_orphans;

\echo '=== IC15: duplicate natural keys ==='
SELECT
  (SELECT count(*) FROM (SELECT email FROM customers GROUP BY email HAVING count(*) > 1) d)                AS dup_email,
  (SELECT count(*) FROM (SELECT phone FROM customers GROUP BY phone HAVING count(*) > 1) d)                AS dup_phone,
  (SELECT count(*) FROM (SELECT phone FROM delivery_partners GROUP BY phone HAVING count(*) > 1) d)        AS dup_partner_phone,
  (SELECT count(*) FROM (SELECT pincode FROM localities GROUP BY pincode HAVING count(*) > 1) d)            AS dup_pincode,
  (SELECT count(*) FROM (SELECT name FROM restaurants GROUP BY name HAVING count(*) > 1) d)                AS dup_restaurant_name,
  (SELECT count(*) FROM (SELECT order_id FROM reviews GROUP BY order_id HAVING count(*) > 1) d)             AS dup_review_per_order;

\echo '=== IC16: data-quality defects found in the seed data ==='
SELECT
  (SELECT count(*) FROM restaurants WHERE rating = 0 OR rating IS NULL)                                        AS restaurants_without_rating,
  (SELECT count(*) FROM restaurants WHERE rating IS NOT NULL AND rating_count = 0)                             AS rating_but_zero_count,
  (SELECT count(*) FROM customers WHERE is_gold_member AND gold_expires_on < '2026-07-01')                      AS gold_already_expired,
  (SELECT count(*) FROM customers WHERE is_gold_member AND NOT is_active)                                      AS gold_but_inactive,
  (SELECT count(*) FROM reviews WHERE delivery_rating IS NULL)                                                  AS reviews_without_delivery_rating,
  (SELECT count(*) FROM reviews WHERE review_text IS NULL)                                                     AS reviews_without_text,
  (SELECT count(*) FROM restaurants r WHERE NOT EXISTS (SELECT 1 FROM reviews v WHERE v.restaurant_id = r.restaurant_id)) AS restaurants_without_reviews,
  (SELECT count(*) FROM customers c WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id))      AS customers_without_orders;

\echo '=== IC17: row counts vs the project brief ==='
SELECT 'cities'            AS table_name, count(*) AS rows_loaded, 10     AS expected FROM cities            UNION ALL
SELECT 'localities',        count(*), 100    FROM localities        UNION ALL
SELECT 'customers',         count(*), 25000  FROM customers         UNION ALL
SELECT 'restaurants',       count(*), 2500   FROM restaurants       UNION ALL
SELECT 'menu_items',        count(*), 50000  FROM menu_items        UNION ALL
SELECT 'delivery_partners', count(*), 2000   FROM delivery_partners UNION ALL
SELECT 'coupons',           count(*), 30     FROM coupons           UNION ALL
SELECT 'orders',            count(*), 150000 FROM orders            UNION ALL
SELECT 'order_items',       count(*), 375000 FROM order_items       UNION ALL
SELECT 'payments',          count(*), 137378 FROM payments          UNION ALL
SELECT 'reviews',           count(*), 39186  FROM reviews;
