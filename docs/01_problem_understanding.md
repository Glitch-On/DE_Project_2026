# Phase 1 — Problem Understanding

**Team T0022 (Section B)** · Zomato Food Delivery Database · DE_Project_2026

Zomato runs food delivery in 10 Indian cities, each split into 10 localities.
A customer browses restaurants in their locality, adds dishes to a cart,
applies a coupon, and pays (UPI, card, wallet or cash on delivery). The
restaurant accepts and prepares the order, a delivery partner picks it up,
and after delivery the customer may leave a review. Gold members get free
delivery.

The existing database was built quickly and has **no documented schema** —
only data exports survive. Ten product problems (P1–P10) were reported.
This document states, in our own words, what the business needs for each,
who is affected, and whether the workload is real-time or analytical.
That classification drives the performance targets we set in later phases.

---

## 1. The ten problems

### P1 — Home feed and restaurant pages load slowly at peak
**Stakeholders:** customers (app users), and indirectly the restaurants whose
 listings are seen.
**What the business needs:** when a customer opens the app at lunch or dinner,
the list of open restaurants in their locality must appear immediately, best
rated first. The same applies to the restaurant page (its menu, grouped by
category). At peak, thousands of customers hit this at once, so the query must
be cheap *and* scalable, not just fast on a quiet database.
**Related queries:** R01 (home feed), R03 (restaurant menu), R25 (cuisine filter).
**Classification: customer-facing / real-time.**

### P2 — Dish search is too slow for type-ahead
**Stakeholder:** customers (search box).
**What the business needs:** as a customer types "paneer" or "biryani", the app
must suggest matching available dishes within a few hundred milliseconds.
Type-ahead means the query runs on every keystroke, so it must not scan the
whole 50,000-row menu table each time.
**Related query:** R02.
**Classification: customer-facing / real-time** (interactive search; the target
band is "interactive search and ops", under 250 ms).

### P3 — Order history and bills take seconds to open
**Stakeholders:** customers.
**What the business needs:** "Your orders" (a customer's most recent orders with
restaurant names) and the bill page (one order with its items, restaurant and
successful payment) are opened repeatedly and must be instant. These are
point lookups by customer or by order id, so they should be index lookups, not
full scans of 150,000 orders.
**Related queries:** R04 (order history), R24 (bill page).
**Classification: customer-facing / real-time.**

### P4 — Partner app: today's orders and dish-wise sales
**Stakeholders:** restaurant partners (owners/kitchen staff).
**What the business needs:** a restaurant owner opening the partner app wants
today's orders immediately, and a per-dish sales breakdown for the month. This
is a single-restaurant query, so it must be selective — the owner of restaurant
217 should never wait while the database reads every restaurant's orders.
**Related queries:** R06 (today's orders), R07 (units sold per dish), R08
(bestseller badges), W03 (hide sold-out dishes).
**Classification: customer-facing / real-time** (partner-facing, but the same
"open the app and see it now" contract as a customer screen).

### P5 — Dispatch screens must refresh every few seconds
**Stakeholders:** dispatch / ops controllers.
**What the business needs:** the dispatch screen shows orders still waiting for
a delivery partner, oldest first, and orders stuck in the kitchen. It refreshes
every few seconds, so the query runs continuously and must stay cheap. An
assignment (W02) must also be atomic: two controllers must not grab the same
order.
**Related queries:** R05 (kitchen-delay alert), R12 (unassigned orders),
W01 (place order), W02 (assign partner).
**Classification: customer-facing / real-time.**

### P6 — The fleet's idle-partner list came back empty
**Stakeholders:** fleet team (rider operations).
**What the business needs:** the fleet team wants active partners in a city who
have not been assigned any order since a given date, so they can be nudged or
reallocated. The report returned *zero rows*, which is impossible — this is a
correctness bug, not a performance one. The cause is a `NOT IN` subquery whose
inner result contains NULLs (see §3).
**Related queries:** R11 (partner earnings), R13 (idle partners).
**Classification: reporting / analytics** (but the bug affects trust in every
report, so it is fixed before tuning).

### P7 — Payment failures and suspicious customers
**Stakeholders:** payments team and risk/fraud team.
**What the business needs:** near-real-time counts of failed payment attempts per
method over the last few days, and a list of customers with repeated failures.
Risk work is time-sensitive (a stolen card must be caught early), so the
7-day window query must be selective on the attempt timestamp.
**Related queries:** R16 (failed attempts per method), R17 (repeat failures).
**Classification: reporting / analytics**, but with a real-time flavour — the
data must be fresh, so it cannot be a nightly batch.

### P8 — Gold, coupon and growth reports time out
**Stakeholders:** Gold team (subscriptions), marketing (coupons), growth.
**What the business needs:** which Gold members are about to lapse but were
active recently (so they can be retained); how effective each coupon code is
(orders, total discount, average bill); and growth metrics such as top spenders
and repeat-customer share per city. These are heavy aggregations over the whole
order history, run by analysts, not by customers.
**Related queries:** R14 (Gold expiry), R15 (coupon effectiveness), R20 (top
customers), R21 (repeat share), W05 (expire Gold).
**Classification: reporting / analytics.**

### P9 — Support needs late deliveries and angry reviews fast
**Stakeholders:** customer support agents.
**What the business needs:** find deliveries that took over an hour in a month,
and the newest reviews complaining about cold food or late delivery. Support
agents work against a waiting customer on the phone, so these must return in
well under a second even though they search free-text review comments.
**Related queries:** R10 (late deliveries), R18 (review moderation).
**Classification: interactive search and ops** (support is internal, but the
latency requirement is interactive, not batch).

### P10 — Leadership dashboards are slow, and volume will grow 20×
**Stakeholders:** ops leadership and the admin team.
**What the business needs:** average delivery time per city per month, an order
heatmap by weekday and hour, a per-restaurant health report, and an admin
"all orders" browser that can page to the end of a 150,000-row table. These are
the heaviest queries in the workload, and they must still work when the data
grows twenty-fold.
**Related queries:** R09 (delivery time), R19 (restaurant health), R22
(heatmap), R23 (admin paging), W04 (recompute ratings).
**Classification: reporting / analytics** (the admin browser is interactive
but tolerates report-grade latency).

---

## 2. Classification summary

| # | Problem | Stakeholder | Classification | Queries |
|---|---------|-------------|----------------|---------|
| P1 | Home feed / restaurant pages slow | Customer | customer-facing / real-time | R01, R03, R25 |
| P2 | Dish search too slow | Customer | customer-facing / real-time (interactive search) | R02 |
| P3 | Order history and bills slow | Customer | customer-facing / real-time | R04, R24 |
| P4 | Partner app today's orders and sales | Restaurant partner | customer-facing / real-time | R06, R07, R08, W03 |
| P5 | Dispatch screens must refresh | Dispatch / ops | customer-facing / real-time | R05, R12, W01, W02 |
| P6 | Idle-partner list empty | Fleet | reporting / analytics (correctness bug) | R11, R13 |
| P7 | Payment failures and risk | Payments / risk | reporting / analytics (near-real-time) | R16, R17 |
| P8 | Gold, coupon, growth reports time out | Gold / marketing / growth | reporting / analytics | R14, R15, R20, R21, W05 |
| P9 | Late deliveries and angry reviews | Support | interactive search and ops | R10, R18 |
| P10 | Leadership dashboards slow, 20× growth | Ops / leadership / admin | reporting / analytics | R09, R19, R22, R23, W04 |

**Performance targets that follow from this** (used in Phase 5):

| Group | Queries | Target |
|-------|---------|--------|
| Real-time / customer-facing | R01, R03, R04, R05, R06, R11, R12, R24, W01, W02, W03 | under 5 ms |
| Interactive search and ops | R02, R10, R13, R16, R18, R25, R14 | under 250 ms |
| Reports and analytics | R07, R08, R09, R15, R17, R19, R20, R21, R22, R23 | under 5,000 ms |
| Batch jobs | W04, W05 | under 2,000 ms |

The split is not arbitrary: a customer waiting for a screen will abandon the
app after a second, so real-time queries get the tightest target. An analyst
running a monthly report will wait several seconds, so reports get a looser
one. P6 is the exception — it is a correctness bug, and correctness outranks
latency.

---

## 3. The correctness bug behind P6

R13 is written as:

```sql
SELECT p.partner_id, p.full_name, p.phone
FROM delivery_partners p
WHERE p.city_id = 1
  AND p.status = 'ACTIVE'
  AND p.partner_id NOT IN (SELECT o.partner_id FROM orders o
                           WHERE o.placed_at >= '2026-06-25');
```

The subquery returns one row per order placed on or after 25 June 2026. Of
those, **214 rows have `partner_id IS NULL`** (orders not yet assigned). In
SQL, `x NOT IN (…, NULL, …)` evaluates to `NULL`, not to TRUE, for every `x` —
so the whole `WHERE` clause is never TRUE and the query returns **0 rows**.

Verified against the seed data:

| Query | Rows returned |
|-------|--------------:|
| R13 as written (`NOT IN`) | **0** |
| R13 rewritten with `NOT EXISTS` | **129** |
| Active Bengaluru partners (the true population before the anti-join) | 285 |
| … of which have an order since 25 Jun 2026 | 156 |
| … of which are genuinely idle | **129** |

The fix is to use `NOT EXISTS`, which is NULL-safe because it tests for the
*existence* of a matching row rather than comparing values:

```sql
AND NOT EXISTS (SELECT 1 FROM orders o
                WHERE o.partner_id = p.partner_id
                  AND o.placed_at >= '2026-06-25')
```

This is worth restating because it is the kind of bug that makes a team stop
trusting its reports: the query is syntactically valid, it runs without error,
and it returns a confidently wrong answer.

---

## 4. Assumptions

1. **Scope is the 10 cities in `cities.csv`.** The brief says 10 cities × 10
   localities; the data confirms exactly 100 localities, 10 per city.
2. **The seed data is a faithful export of production.** We treat every row as
   real and every anomaly as a data-quality defect to be reported, not as a
   reason to reject rows. The schema must accept all rows.
3. **`orders.status` is the single source of truth for order state.** The
   timestamps (`accepted_at`, `picked_up_at`, `delivered_at`) are null exactly
   when the corresponding step has not happened; we verified this for all
   150,000 rows and encode it as CHECK constraints.
4. **Money is exact.** All amounts are `numeric(10,2)`, never `float`, because
   `total_amount = item_total + delivery_fee - discount` must hold to the paisa.
5. **Timestamps keep their offset.** The CSVs carry `+05:30`; we load them into
   `timestamptz` so that comparisons and `date_trunc` behave correctly across
   the India-only operating window.
6. **`restaurants.rating` / `rating_count` are denormalised caches.** They are
   recomputed nightly by W04 from `reviews`. We keep them (the home feed sorts
   by rating and cannot aggregate 39,186 reviews per request) but we do not
   treat them as authoritative.
7. **`reviews.customer_id` and `reviews.restaurant_id` are denormalised.** Both
   are derivable from the order. We keep them so support can search reviews by
   restaurant without a join, and we enforce that they agree with the order.
8. **A coupon is optional on an order, and an order may have several payment
   attempts.** 6,965 delivered orders have a FAILED attempt followed by a
   SUCCESS one; 1,304 delivered orders have only a REFUNDED payment. So
   "exactly one successful payment per delivered order" is *not* a rule — the
   real rule is "at least one payment attempt, and at most one SUCCESS".
9. **Delivery fees follow a simple tariff.** Verified over all 150,000 orders:
   Gold members pay 0; non-Gold pay 45 when `distance_km > 5.0`, else 25.
10. **Coupon discounts follow `min(pct × item_total / 100, max_discount)`.**
    Verified over all 20,208 coupon-bearing orders with zero violations.
11. **"Large dataset" means ~20× the seed rows** (≈3,000,000 orders), released by
    faculty for Phase 5. Our design targets that, not an arbitrary bigger number.
12. **All 30 queries must run unchanged against our schema.** If a query fails,
    the schema is wrong — we do not edit `queries/workload_30.sql`.
