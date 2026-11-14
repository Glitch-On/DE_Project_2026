-- =====================================================================
-- Zomato Food Delivery Database - Phase 2: schema
-- Team T0022 (Section B) - DE_Project_2026
--
-- Runs top-to-bottom on an EMPTY database without errors:
--   psql -d <db> -X -v ON_ERROR_STOP=1 -f sql/01_schema.sql
--
-- Creates schema `zomato` and 11 tables. This phase creates ONLY
-- constraints (PK, FK, UNIQUE, NOT NULL, CHECK). No secondary indexes:
-- PostgreSQL automatically indexes PRIMARY KEY and UNIQUE columns, and
-- that is the whole baseline for Phase 3.
--
-- Conventions
--   * money            -> numeric(10,2)   (exact, no float rounding)
--   * timestamps       -> timestamptz     (CSV carries +05:30 offsets)
--   * yes/no flags     -> boolean         (CSV uses t/f)
--   * ratings          -> numeric(3,1) / numeric(2,1)
--   * short codes      -> varchar(n)      (coupon_code, pincode, phone)
--   * cuisines         -> text[]          (PostgreSQL array; `= ANY` works)
-- =====================================================================

DROP SCHEMA IF EXISTS zomato CASCADE;
CREATE SCHEMA zomato;
SET search_path TO zomato;

-- ---------------------------------------------------------------------
-- 1. cities
-- ---------------------------------------------------------------------
CREATE TABLE cities (
    city_id   integer      NOT NULL,
    city_name varchar(50)  NOT NULL,
    state     varchar(50)  NOT NULL,
    CONSTRAINT cities_pkey PRIMARY KEY (city_id),
    CONSTRAINT cities_city_name_key UNIQUE (city_name),
    CONSTRAINT cities_city_id_check  CHECK (city_id > 0),
    CONSTRAINT cities_city_name_check CHECK (char_length(city_name) >= 2),
    CONSTRAINT cities_state_check    CHECK (char_length(state) >= 2)
);

-- ---------------------------------------------------------------------
-- 2. localities
-- ---------------------------------------------------------------------
CREATE TABLE localities (
    locality_id   integer     NOT NULL,
    city_id       integer     NOT NULL,
    locality_name varchar(50) NOT NULL,
    pincode       varchar(6)  NOT NULL,
    CONSTRAINT localities_pkey PRIMARY KEY (locality_id),
    CONSTRAINT localities_city_id_fkey FOREIGN KEY (city_id)
        REFERENCES cities (city_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT localities_pincode_key UNIQUE (pincode),
    CONSTRAINT localities_locality_name_city_key UNIQUE (locality_name, city_id),
    CONSTRAINT localities_locality_id_check CHECK (locality_id > 0),
    CONSTRAINT localities_city_id_check   CHECK (city_id > 0),
    CONSTRAINT localities_pincode_check   CHECK (pincode ~ '^[0-9]{6}$')
);

-- ---------------------------------------------------------------------
-- 3. customers
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id     integer      NOT NULL,
    full_name       varchar(80)  NOT NULL,
    email           varchar(120) NOT NULL,
    phone           varchar(10)  NOT NULL,
    city_id         integer      NOT NULL,
    signup_date     date         NOT NULL,
    is_gold_member  boolean      NOT NULL DEFAULT FALSE,
    gold_expires_on date,
    is_active       boolean      NOT NULL DEFAULT TRUE,
    CONSTRAINT customers_pkey PRIMARY KEY (customer_id),
    CONSTRAINT customers_email_key UNIQUE (email),
    CONSTRAINT customers_phone_key UNIQUE (phone),
    CONSTRAINT customers_city_id_fkey FOREIGN KEY (city_id)
        REFERENCES cities (city_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT customers_customer_id_check CHECK (customer_id > 0),
    CONSTRAINT customers_city_id_check   CHECK (city_id > 0),
    CONSTRAINT customers_email_check     CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
    CONSTRAINT customers_phone_check     CHECK (phone ~ '^[0-9]{10}$'),
    -- a Gold member must carry an expiry date.
    -- NOTE: the reverse rule ("a non-member must not carry one") is NOT
    -- enforced: the seed data contains 1,230 rows where is_gold_member is
    -- false but gold_expires_on still holds the date of a lapsed plan
    -- (e.g. customer 22: signup 2022-06-06, gold_expires_on 2026-03-14).
    -- This is a data-quality defect recorded in docs/02_schema_design.md;
    -- it is reported rather than rejected so that W05 (which re-arms
    -- is_gold_member = FALSE) can run.
    CONSTRAINT customers_gold_expiry_check CHECK (
        NOT is_gold_member OR gold_expires_on IS NOT NULL
    ),
    -- membership cannot expire before the customer signed up
    CONSTRAINT customers_gold_expiry_after_signup_check CHECK (
        gold_expires_on IS NULL OR gold_expires_on >= signup_date
    )
);

-- ---------------------------------------------------------------------
-- 4. restaurants
-- ---------------------------------------------------------------------
CREATE TABLE restaurants (
    restaurant_id    integer      NOT NULL,
    name             varchar(100) NOT NULL,
    locality_id      integer      NOT NULL,
    cuisines         text[]       NOT NULL,
    avg_cost_for_two numeric(8,2) NOT NULL,
    rating           numeric(3,1),
    rating_count     integer      NOT NULL DEFAULT 0,
    opens_at         time         NOT NULL,
    closes_at        time         NOT NULL,
    is_pure_veg      boolean      NOT NULL DEFAULT FALSE,
    status           varchar(20)  NOT NULL,
    onboarded_on     date         NOT NULL,
    CONSTRAINT restaurants_pkey PRIMARY KEY (restaurant_id),
    CONSTRAINT restaurants_name_key UNIQUE (name),
    CONSTRAINT restaurants_locality_id_fkey FOREIGN KEY (locality_id)
        REFERENCES localities (locality_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT restaurants_restaurant_id_check CHECK (restaurant_id > 0),
    CONSTRAINT restaurants_locality_id_check   CHECK (locality_id > 0),
    CONSTRAINT restaurants_cuisines_check      CHECK (cardinality(cuisines) BETWEEN 1 AND 3),
    CONSTRAINT restaurants_avg_cost_check      CHECK (avg_cost_for_two > 0),
    CONSTRAINT restaurants_rating_check        CHECK (rating IS NULL OR (rating >= 1.0 AND rating <= 5.0)),
    CONSTRAINT restaurants_rating_count_check  CHECK (rating_count >= 0),
    CONSTRAINT restaurants_hours_check         CHECK (closes_at > opens_at),
    CONSTRAINT restaurants_status_check        CHECK (status IN ('OPEN','TEMPORARILY_CLOSED','DELISTED'))
);

-- ---------------------------------------------------------------------
-- 5. menu_items
-- ---------------------------------------------------------------------
CREATE TABLE menu_items (
    item_id       integer      NOT NULL,
    restaurant_id integer      NOT NULL,
    item_name     varchar(80)  NOT NULL,
    category      varchar(30)  NOT NULL,
    price         numeric(8,2) NOT NULL,
    is_veg        boolean      NOT NULL DEFAULT TRUE,
    is_bestseller boolean      NOT NULL DEFAULT FALSE,
    is_available  boolean      NOT NULL DEFAULT TRUE,
    CONSTRAINT menu_items_pkey PRIMARY KEY (item_id),
    CONSTRAINT menu_items_restaurant_id_fkey FOREIGN KEY (restaurant_id)
        REFERENCES restaurants (restaurant_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT menu_items_restaurant_item_key UNIQUE (restaurant_id, item_name),
    CONSTRAINT menu_items_item_id_check       CHECK (item_id > 0),
    CONSTRAINT menu_items_restaurant_id_check CHECK (restaurant_id > 0),
    CONSTRAINT menu_items_price_check         CHECK (price > 0),
    CONSTRAINT menu_items_category_check      CHECK (
        category IN ('Main Course','Starters','Rice','Breads','Desserts','Beverages')
    )
);

-- ---------------------------------------------------------------------
-- 6. delivery_partners
-- ---------------------------------------------------------------------
CREATE TABLE delivery_partners (
    partner_id   integer      NOT NULL,
    full_name    varchar(80)  NOT NULL,
    phone        varchar(10)  NOT NULL,
    city_id      integer      NOT NULL,
    vehicle_type varchar(15)  NOT NULL,
    joined_on    date         NOT NULL,
    rating       numeric(3,1) NOT NULL,
    status       varchar(15)  NOT NULL,
    CONSTRAINT delivery_partners_pkey PRIMARY KEY (partner_id),
    CONSTRAINT delivery_partners_phone_key UNIQUE (phone),
    CONSTRAINT delivery_partners_city_id_fkey FOREIGN KEY (city_id)
        REFERENCES cities (city_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT delivery_partners_partner_id_check CHECK (partner_id > 0),
    CONSTRAINT delivery_partners_city_id_check   CHECK (city_id > 0),
    CONSTRAINT delivery_partners_phone_check     CHECK (phone ~ '^[0-9]{10}$'),
    CONSTRAINT delivery_partners_vehicle_check   CHECK (
        vehicle_type IN ('BIKE','SCOOTER','EV','BICYCLE')
    ),
    CONSTRAINT delivery_partners_rating_check    CHECK (rating >= 1.0 AND rating <= 5.0),
    CONSTRAINT delivery_partners_status_check    CHECK (status IN ('ACTIVE','INACTIVE','BLOCKED'))
);

-- ---------------------------------------------------------------------
-- 7. coupons
-- ---------------------------------------------------------------------
CREATE TABLE coupons (
    coupon_code     varchar(20)  NOT NULL,
    discount_pct    integer      NOT NULL,
    max_discount    numeric(8,2) NOT NULL,
    min_order_value numeric(8,2) NOT NULL,
    valid_from      date         NOT NULL,
    valid_to        date         NOT NULL,
    CONSTRAINT coupons_pkey PRIMARY KEY (coupon_code),
    CONSTRAINT coupons_discount_pct_check  CHECK (discount_pct > 0 AND discount_pct <= 100),
    CONSTRAINT coupons_max_discount_check  CHECK (max_discount > 0),
    CONSTRAINT coupons_min_order_check     CHECK (min_order_value > 0),
    CONSTRAINT coupons_validity_check      CHECK (valid_to >= valid_from)
);

-- ---------------------------------------------------------------------
-- 8. orders
-- ---------------------------------------------------------------------
CREATE TABLE orders (
    order_id     integer       NOT NULL,
    customer_id  integer       NOT NULL,
    restaurant_id integer      NOT NULL,
    partner_id   integer,
    coupon_code  varchar(20),
    placed_at    timestamptz   NOT NULL,
    accepted_at  timestamptz,
    picked_up_at timestamptz,
    delivered_at timestamptz,
    distance_km  numeric(4,1)  NOT NULL,
    item_total   numeric(10,2) NOT NULL,
    delivery_fee numeric(10,2) NOT NULL,
    discount     numeric(10,2) NOT NULL DEFAULT 0,
    total_amount numeric(10,2) NOT NULL,
    status       varchar(25)   NOT NULL,
    CONSTRAINT orders_pkey PRIMARY KEY (order_id),
    CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT orders_restaurant_id_fkey FOREIGN KEY (restaurant_id)
        REFERENCES restaurants (restaurant_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- partner is optional: an order may not have been assigned yet
    CONSTRAINT orders_partner_id_fkey FOREIGN KEY (partner_id)
        REFERENCES delivery_partners (partner_id) ON DELETE SET NULL ON UPDATE CASCADE,
    -- coupon is optional; an unknown code must never enter the database
    CONSTRAINT orders_coupon_code_fkey FOREIGN KEY (coupon_code)
        REFERENCES coupons (coupon_code) ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT orders_order_id_check      CHECK (order_id > 0),
    CONSTRAINT orders_customer_id_check   CHECK (customer_id > 0),
    CONSTRAINT orders_restaurant_id_check CHECK (restaurant_id > 0),
    CONSTRAINT orders_partner_id_check    CHECK (partner_id IS NULL OR partner_id > 0),
    CONSTRAINT orders_distance_check      CHECK (distance_km > 0 AND distance_km <= 50),
    CONSTRAINT orders_item_total_check    CHECK (item_total >= 0),
    CONSTRAINT orders_delivery_fee_check  CHECK (delivery_fee >= 0),
    CONSTRAINT orders_discount_check      CHECK (discount >= 0),
    CONSTRAINT orders_total_amount_check  CHECK (total_amount >= 0),
    CONSTRAINT orders_status_check        CHECK (
        status IN ('PLACED','ACCEPTED','PREPARING','OUT_FOR_DELIVERY','DELIVERED',
                   'CANCELLED_BY_CUSTOMER','CANCELLED_BY_RESTAURANT')
    ),
    -- money rule: total = item_total + delivery_fee - discount
    CONSTRAINT orders_total_amount_rule_check CHECK (
        total_amount = item_total + delivery_fee - discount
    ),
    -- lifecycle: placed -> accepted -> picked up -> delivered
    CONSTRAINT orders_time_order_check CHECK (
        (accepted_at  IS NULL OR accepted_at  >= placed_at)
        AND (picked_up_at IS NULL OR (accepted_at IS NOT NULL AND picked_up_at >= accepted_at))
        AND (delivered_at IS NULL OR (picked_up_at IS NOT NULL AND delivered_at >= picked_up_at))
    ),
    -- status-dependent NULL rules (see docs/02_schema_design.md)
    CONSTRAINT orders_placed_nulls_check CHECK (
        status <> 'PLACED' OR (partner_id IS NULL AND accepted_at IS NULL
                               AND picked_up_at IS NULL AND delivered_at IS NULL)
    ),
    CONSTRAINT orders_accepted_nulls_check CHECK (
        status <> 'ACCEPTED' OR (partner_id IS NULL AND accepted_at IS NOT NULL
                                 AND picked_up_at IS NULL AND delivered_at IS NULL)
    ),
    CONSTRAINT orders_preparing_nulls_check CHECK (
        status <> 'PREPARING' OR (partner_id IS NOT NULL AND accepted_at IS NOT NULL
                                  AND picked_up_at IS NULL AND delivered_at IS NULL)
    ),
    CONSTRAINT orders_out_for_delivery_nulls_check CHECK (
        status <> 'OUT_FOR_DELIVERY' OR (partner_id IS NOT NULL AND accepted_at IS NOT NULL
                                         AND picked_up_at IS NOT NULL AND delivered_at IS NULL)
    ),
    CONSTRAINT orders_delivered_nulls_check CHECK (
        status <> 'DELIVERED' OR (partner_id IS NOT NULL AND accepted_at IS NOT NULL
                                  AND picked_up_at IS NOT NULL AND delivered_at IS NOT NULL)
    ),
    -- a cancellation never has a pickup or a delivery time
    CONSTRAINT orders_cancelled_nulls_check CHECK (
        NOT status LIKE 'CANCELLED%' OR (picked_up_at IS NULL AND delivered_at IS NULL)
    ),
    -- a restaurant rejection happens before acceptance
    CONSTRAINT orders_cancelled_by_restaurant_nulls_check CHECK (
        status <> 'CANCELLED_BY_RESTAURANT' OR (partner_id IS NULL AND accepted_at IS NULL)
    )
);

-- ---------------------------------------------------------------------
-- 9. order_items
-- ---------------------------------------------------------------------
CREATE TABLE order_items (
    order_id   integer       NOT NULL,
    item_id    integer       NOT NULL,
    quantity   integer       NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    CONSTRAINT order_items_pkey PRIMARY KEY (order_id, item_id),
    CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id)
        REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT order_items_item_id_fkey FOREIGN KEY (item_id)
        REFERENCES menu_items (item_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT order_items_quantity_check   CHECK (quantity > 0),
    CONSTRAINT order_items_unit_price_check CHECK (unit_price >= 0)
);

-- ---------------------------------------------------------------------
-- 10. payments
-- ---------------------------------------------------------------------
CREATE TABLE payments (
    payment_id     integer       NOT NULL,
    order_id       integer       NOT NULL,
    amount         numeric(10,2) NOT NULL,
    method         varchar(10)   NOT NULL,
    payment_status varchar(10)   NOT NULL,
    attempted_at   timestamptz   NOT NULL,
    CONSTRAINT payments_pkey PRIMARY KEY (payment_id),
    CONSTRAINT payments_order_id_fkey FOREIGN KEY (order_id)
        REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT payments_payment_id_check CHECK (payment_id > 0),
    CONSTRAINT payments_order_id_check   CHECK (order_id > 0),
    CONSTRAINT payments_amount_check     CHECK (amount >= 0),
    CONSTRAINT payments_method_check     CHECK (method IN ('UPI','CARD','COD','WALLET')),
    CONSTRAINT payments_status_check     CHECK (payment_status IN ('SUCCESS','FAILED','REFUNDED'))
);

-- ---------------------------------------------------------------------
-- 11. reviews
-- ---------------------------------------------------------------------
CREATE TABLE reviews (
    review_id       integer      NOT NULL,
    order_id        integer      NOT NULL,
    customer_id     integer      NOT NULL,
    restaurant_id   integer      NOT NULL,
    food_rating     integer      NOT NULL,
    delivery_rating integer,
    review_text     text,
    created_at      timestamptz  NOT NULL,
    CONSTRAINT reviews_pkey PRIMARY KEY (review_id),
    CONSTRAINT reviews_order_id_key UNIQUE (order_id),
    CONSTRAINT reviews_order_id_fkey FOREIGN KEY (order_id)
        REFERENCES orders (order_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT reviews_customer_id_fkey FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT reviews_restaurant_id_fkey FOREIGN KEY (restaurant_id)
        REFERENCES restaurants (restaurant_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT reviews_review_id_check     CHECK (review_id > 0),
    CONSTRAINT reviews_order_id_check      CHECK (order_id > 0),
    CONSTRAINT reviews_customer_id_check   CHECK (customer_id > 0),
    CONSTRAINT reviews_restaurant_id_check CHECK (restaurant_id > 0),
    CONSTRAINT reviews_food_rating_check   CHECK (food_rating BETWEEN 1 AND 5),
    CONSTRAINT reviews_delivery_rating_check CHECK (delivery_rating IS NULL OR delivery_rating BETWEEN 1 AND 5)
);

-- ---------------------------------------------------------------------
-- Cross-table rules that a CHECK constraint cannot express
-- (PostgreSQL forbids subqueries in CHECK). These are enforced by
-- BEFORE INSERT/UPDATE triggers, which run with the same atomicity as
-- a constraint and reject the row with the same error class.
-- ---------------------------------------------------------------------

-- orders: a coupon can only be used above its minimum order value
CREATE OR REPLACE FUNCTION orders_check_coupon_min_order() RETURNS trigger AS $$
BEGIN
    IF NEW.coupon_code IS NOT NULL
       AND NEW.item_total < (SELECT min_order_value FROM coupons c
                             WHERE c.coupon_code = NEW.coupon_code) THEN
        RAISE EXCEPTION 'orders_coupon_min_order_check: item_total % is below the minimum order value for coupon %',
            NEW.item_total, NEW.coupon_code
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER orders_coupon_min_order_trigger
    BEFORE INSERT OR UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION orders_check_coupon_min_order();

-- payments: an attempt can never be for more than the order's total
CREATE OR REPLACE FUNCTION payments_check_amount() RETURNS trigger AS $$
BEGIN
    IF NEW.amount > (SELECT total_amount FROM orders o WHERE o.order_id = NEW.order_id) THEN
        RAISE EXCEPTION 'payments_amount_rule_check: amount % exceeds order total %',
            NEW.amount, (SELECT total_amount FROM orders o WHERE o.order_id = NEW.order_id)
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER payments_amount_trigger
    BEFORE INSERT OR UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_check_amount();

-- order_items: the dish on a line must belong to the restaurant that
-- received the order (a CHECK cannot read another table)
CREATE OR REPLACE FUNCTION order_items_check_restaurant() RETURNS trigger AS $$
DECLARE
    v_item_restaurant  integer;
    v_order_restaurant  integer;
BEGIN
    SELECT restaurant_id INTO v_item_restaurant FROM menu_items WHERE item_id = NEW.item_id;
    SELECT restaurant_id INTO v_order_restaurant FROM orders    WHERE order_id = NEW.order_id;
    IF v_item_restaurant IS DISTINCT FROM v_order_restaurant THEN
        RAISE EXCEPTION 'order_items_item_belongs_to_order_restaurant_check: item % belongs to restaurant %, not %',
            NEW.item_id, v_item_restaurant, v_order_restaurant
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER order_items_restaurant_trigger
    BEFORE INSERT OR UPDATE ON order_items
    FOR EACH ROW EXECUTE FUNCTION order_items_check_restaurant();

-- reviews: a review can only be written after the order was delivered,
-- by the customer who placed it, about the restaurant that received it.
CREATE OR REPLACE FUNCTION reviews_check_order() RETURNS trigger AS $$
DECLARE
    v_order orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = NEW.order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'reviews_order_id_fkey: order % not found', NEW.order_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_order.delivered_at IS NULL THEN
        RAISE EXCEPTION 'reviews_created_after_delivery_check: order % is not delivered yet', NEW.order_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.created_at < v_order.delivered_at THEN
        RAISE EXCEPTION 'reviews_created_after_delivery_check: review % precedes delivery %',
            NEW.created_at, v_order.delivered_at
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.customer_id <> v_order.customer_id THEN
        RAISE EXCEPTION 'reviews_customer_matches_order_check: customer % did not place order %',
            NEW.customer_id, NEW.order_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.restaurant_id <> v_order.restaurant_id THEN
        RAISE EXCEPTION 'reviews_restaurant_matches_order_check: restaurant % did not receive order %',
            NEW.restaurant_id, NEW.order_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER reviews_order_trigger
    BEFORE INSERT OR UPDATE ON reviews
    FOR EACH ROW EXECUTE FUNCTION reviews_check_order();

-- ---------------------------------------------------------------------
-- Indexes that exist after this script (PK/UNIQUE only - no tuning yet)
--   cities_pkey, cities_city_name_key
--   localities_pkey, localities_pincode_key, localities_locality_name_city_key
--   customers_pkey, customers_email_key, customers_phone_key
--   restaurants_pkey, restaurants_name_key
--   menu_items_pkey, menu_items_restaurant_item_key
--   delivery_partners_pkey, delivery_partners_phone_key
--   coupons_pkey
--   orders_pkey
--   order_items_pkey
--   payments_pkey
--   reviews_pkey, reviews_order_id_key
-- ---------------------------------------------------------------------
