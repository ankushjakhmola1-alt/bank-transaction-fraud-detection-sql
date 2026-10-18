-- =====================================================================
--  BANK TRANSACTION FRAUD DETECTION  |  SQL Practice Project #2
--  Solutions to all 17 practice questions + project challenge
--  Engine: MySQL 8.0+ (also tested on MariaDB 10.11)
--  Load first:  2_bank_transaction_fraud_detection.sql
-- =====================================================================
--  Dataset: 20 customers | 30 accounts | 15 merchants | 8 cities | 722 transactions
--  Seeded patterns found while profiling the data:
--    * 7 "burst" events (accounts 1, 7, 8, 22, 23, 28, 29): 4-6 high-value
--      purchases, 2 minutes apart, spread across different cities
--    * 6 pairs of purchases exactly 30 minutes apart (accounts 4, 9, 13, 15, 17, 21)
--    * Very large one-off withdrawals/transfers (> 10,000)
--    * Two FROZEN accounts (3 and 8)
-- =====================================================================

USE bank_fraud_db;

-- ---------------------------------------------------------------------
-- STEP 0 - SETUP: reference table with REAL city coordinates
-- ---------------------------------------------------------------------
-- WHY: the latitude/longitude values in `locations` are not real
-- (e.g. Lahore = -37.89, -34.19 which is in the South Atlantic; Toronto
-- has latitude -75.84). Distance maths on them would be meaningless, so
-- impossible-travel questions use this corrected reference table instead.
DROP TABLE IF EXISTS city_reference;
CREATE TABLE city_reference (
    city      VARCHAR(100) PRIMARY KEY,
    latitude  DECIMAL(9,6) NOT NULL,
    longitude DECIMAL(9,6) NOT NULL
);
INSERT INTO city_reference (city, latitude, longitude) VALUES
('Lahore',     31.549700,  74.343600),
('Karachi',    24.860700,  67.001100),
('Islamabad',  33.684400,  73.047900),
('Dubai',      25.204800,  55.270800),
('London',     51.507400,  -0.127800),
('New York',   40.712800, -74.006000),
('Toronto',    43.653200, -79.383200),
('Singapore',   1.352100, 103.819800);


-- =====================================================================
--  BEGINNER
-- =====================================================================

-- B1. Total transaction count and value for each account
-- Skills: LEFT JOIN (keeps accounts with zero activity), GROUP BY, COALESCE
-- Note: "value" = sum of all amounts regardless of type (deposits included).
SELECT  a.account_id,
        a.account_type,
        a.status,
        COUNT(t.transaction_id)         AS txn_count,
        COALESCE(SUM(t.amount), 0)      AS total_value
FROM    accounts a
LEFT JOIN transactions t ON t.account_id = a.account_id
GROUP BY a.account_id, a.account_type, a.status
ORDER BY total_value DESC;


-- B2. Accounts with more than 20 transactions in one day
-- As written (threshold 20) this returns 0 rows: the busiest day in this
-- dataset has only 6 transactions. Query is correct for a bank-sized table.
SELECT  account_id,
        DATE(transaction_date) AS txn_day,
        COUNT(*)               AS txns_that_day
FROM    transactions
GROUP BY account_id, DATE(transaction_date)
HAVING  COUNT(*) > 20;

-- B2 (scaled to this dataset): more than 3 transactions in one day
SELECT  account_id,
        DATE(transaction_date) AS txn_day,
        COUNT(*)               AS txns_that_day,
        SUM(amount)            AS day_value
FROM    transactions
GROUP BY account_id, DATE(transaction_date)
HAVING  COUNT(*) > 3
ORDER BY txns_that_day DESC, day_value DESC;


-- B3. Largest transaction for each account
-- RANK() keeps ties (two equal maximums would both show).
SELECT  account_id, transaction_id, transaction_date, transaction_type, amount
FROM (
    SELECT  t.*,
            RANK() OVER (PARTITION BY account_id ORDER BY amount DESC) AS rnk
    FROM    transactions t
) ranked
WHERE rnk = 1
ORDER BY amount DESC;


-- B4. Customers whose average transaction value exceeds the overall average
SELECT  c.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        COUNT(t.transaction_id)                AS txn_count,
        ROUND(AVG(t.amount), 2)                AS customer_avg,
        ROUND((SELECT AVG(amount) FROM transactions), 2) AS overall_avg
FROM    customers c
JOIN    accounts a     ON a.customer_id = c.customer_id
JOIN    transactions t ON t.account_id  = a.account_id
GROUP BY c.customer_id, c.first_name, c.last_name
HAVING  AVG(t.amount) > (SELECT AVG(amount) FROM transactions)
ORDER BY customer_avg DESC;


-- B5. Transactions above a high-value threshold
-- Threshold = 5,000 (roughly the top 3.5% of transactions here).
-- Change the number in the WHERE clause to experiment.
SELECT  t.transaction_id, t.account_id, t.transaction_date,
        t.transaction_type, t.amount, l.city
FROM    transactions t
LEFT JOIN locations l ON l.location_id = t.location_id
WHERE   t.amount >= 5000
ORDER BY t.amount DESC;


-- =====================================================================
--  INTERMEDIATE
-- =====================================================================

-- I1. Multiple transactions from the same account within 5 minutes
-- Strategy A - self join (returns every PAIR that is within 5 minutes)
SELECT  t1.account_id,
        t1.transaction_id AS txn_a,
        t2.transaction_id AS txn_b,
        t1.transaction_date AS time_a,
        t2.transaction_date AS time_b,
        TIMESTAMPDIFF(SECOND, t1.transaction_date, t2.transaction_date) AS seconds_apart,
        t1.amount AS amount_a,
        t2.amount AS amount_b
FROM    transactions t1
JOIN    transactions t2
        ON  t2.account_id = t1.account_id
        AND t2.transaction_date >  t1.transaction_date
        AND t2.transaction_date <= t1.transaction_date + INTERVAL 5 MINUTE
ORDER BY t1.account_id, t1.transaction_date;

-- I1. Strategy B - LAG() (consecutive transactions only; cheaper on big tables)
WITH ordered AS (
    SELECT  t.*,
            LAG(transaction_date) OVER w AS prev_date,
            LAG(transaction_id)   OVER w AS prev_id
    FROM    transactions t
    WINDOW  w AS (PARTITION BY account_id ORDER BY transaction_date, transaction_id)
)
SELECT  account_id, prev_id, transaction_id, prev_date, transaction_date,
        TIMESTAMPDIFF(SECOND, prev_date, transaction_date) AS seconds_apart
FROM    ordered
WHERE   prev_date IS NOT NULL
  AND   TIMESTAMPDIFF(SECOND, prev_date, transaction_date) <= 300
ORDER BY account_id, transaction_date;


-- I2. Transactions significantly larger than the customer's normal spending
-- "Normal" = the customer's average of their OTHER transactions
-- (leave-one-out, so a huge transaction cannot inflate its own baseline).
-- Flag: amount > 5x that average and at least 1,000 in size.
WITH cust_txn AS (
    SELECT  c.customer_id, t.transaction_id, t.account_id,
            t.transaction_date, t.transaction_type, t.amount,
            COUNT(*)      OVER (PARTITION BY c.customer_id) AS n,
            SUM(t.amount) OVER (PARTITION BY c.customer_id) AS total
    FROM    transactions t
    JOIN    accounts  a ON a.account_id  = t.account_id
    JOIN    customers c ON c.customer_id = a.customer_id
)
SELECT  customer_id, transaction_id, account_id, transaction_date,
        transaction_type, amount,
        ROUND((total - amount) / (n - 1), 2)            AS avg_of_other_txns,
        ROUND(amount / ((total - amount) / (n - 1)), 1) AS times_normal
FROM    cust_txn
WHERE   n > 1
  AND   amount >= 1000
  AND   amount >  5 * (total - amount) / (n - 1)
ORDER BY times_normal DESC;


-- I3. Customers whose transaction frequency suddenly spikes
-- A "spike day" = a customer's daily count is at least 3x their own average
-- daily count AND at least 3 transactions.
WITH daily AS (
    SELECT  a.customer_id,
            DATE(t.transaction_date) AS txn_day,
            COUNT(*)                 AS txns
    FROM    transactions t
    JOIN    accounts a ON a.account_id = t.account_id
    GROUP BY a.customer_id, DATE(t.transaction_date)
),
with_avg AS (
    SELECT  d.*, AVG(txns) OVER (PARTITION BY customer_id) AS avg_daily_txns
    FROM    daily d
)
SELECT  w.customer_id,
        CONCAT(c.first_name, ' ', c.last_name) AS customer_name,
        w.txn_day,
        w.txns,
        ROUND(w.avg_daily_txns, 2)             AS avg_daily_txns,
        ROUND(w.txns / w.avg_daily_txns, 1)    AS spike_multiple
FROM    with_avg w
JOIN    customers c ON c.customer_id = w.customer_id
WHERE   w.txns >= 3
  AND   w.txns >= 3 * w.avg_daily_txns
ORDER BY spike_multiple DESC, w.txns DESC;


-- I4. Potentially duplicated transactions
-- Tier 1: exact duplicates (same account, merchant, type, amount) - none exist here.
SELECT  account_id, merchant_id, transaction_type, amount,
        COUNT(*) AS times_seen,
        GROUP_CONCAT(transaction_id ORDER BY transaction_id) AS transaction_ids
FROM    transactions
GROUP BY account_id, merchant_id, transaction_type, amount
HAVING  COUNT(*) > 1;

-- Tier 2: likely duplicates - same account + same merchant + same type
-- within 60 minutes (amount may differ, e.g. a retried/split charge).
SELECT  t1.account_id,
        t1.merchant_id,
        t1.transaction_type,
        t1.transaction_id AS first_txn,
        t2.transaction_id AS second_txn,
        t1.amount         AS first_amount,
        t2.amount         AS second_amount,
        TIMESTAMPDIFF(MINUTE, t1.transaction_date, t2.transaction_date) AS minutes_apart
FROM    transactions t1
JOIN    transactions t2
        ON  t2.account_id       = t1.account_id
        AND t2.merchant_id      = t1.merchant_id
        AND t2.transaction_type = t1.transaction_type
        AND t2.transaction_id   > t1.transaction_id
        AND ABS(TIMESTAMPDIFF(MINUTE, t1.transaction_date, t2.transaction_date)) <= 60
ORDER BY t1.account_id, t1.transaction_date;

-- Tier 3 (watch-list): same account, same type, 10-60 minutes apart on the same day,
-- merchants differ. These are the six "30-minute pairs" seeded in the data
-- (five of the six also show up in A1 as impossible-travel cases).
SELECT  t1.account_id,
        t1.transaction_id AS first_txn,
        t2.transaction_id AS second_txn,
        t1.merchant_id    AS first_merchant,
        t2.merchant_id    AS second_merchant,
        t1.amount, t2.amount AS amount_2,
        TIMESTAMPDIFF(MINUTE, t1.transaction_date, t2.transaction_date) AS minutes_apart
FROM    transactions t1
JOIN    transactions t2
        ON  t2.account_id       = t1.account_id
        AND t2.transaction_type = t1.transaction_type
        AND t2.transaction_id   > t1.transaction_id
        AND t2.merchant_id     <> t1.merchant_id
        AND TIMESTAMPDIFF(MINUTE, t1.transaction_date, t2.transaction_date) BETWEEN 10 AND 60
ORDER BY t1.account_id, t1.transaction_date;


-- I5. Previous transaction amount for every account using LAG()
SELECT  account_id,
        transaction_id,
        transaction_date,
        amount,
        LAG(amount) OVER (PARTITION BY account_id
                          ORDER BY transaction_date, transaction_id) AS previous_amount,
        amount - LAG(amount) OVER (PARTITION BY account_id
                          ORDER BY transaction_date, transaction_id) AS change_vs_previous
FROM    transactions
ORDER BY account_id, transaction_date, transaction_id;


-- I6. Time difference between consecutive transactions
SELECT  account_id,
        transaction_id,
        transaction_date,
        LAG(transaction_date) OVER w AS previous_date,
        TIMESTAMPDIFF(MINUTE, LAG(transaction_date) OVER w, transaction_date) AS minutes_since_previous,
        ROUND(TIMESTAMPDIFF(MINUTE, LAG(transaction_date) OVER w, transaction_date) / 1440, 2) AS days_since_previous
FROM    transactions
WINDOW  w AS (PARTITION BY account_id ORDER BY transaction_date, transaction_id)
ORDER BY account_id, transaction_date, transaction_id;


-- I7. Accounts with transactions in more than 3 cities in one day
SELECT  t.account_id,
        DATE(t.transaction_date)           AS txn_day,
        COUNT(DISTINCT l.city)             AS distinct_cities,
        GROUP_CONCAT(DISTINCT l.city ORDER BY l.city SEPARATOR ', ') AS cities,
        COUNT(*)                           AS txns
FROM    transactions t
JOIN    locations l ON l.location_id = t.location_id
GROUP BY t.account_id, DATE(t.transaction_date)
HAVING  COUNT(DISTINCT l.city) > 3
ORDER BY distinct_cities DESC, txns DESC;


-- =====================================================================
--  ADVANCED
-- =====================================================================

-- A1. Impossible travel: different cities within an impossible time window
-- Logic: compare each transaction with the account's previous one; compute
-- great-circle (haversine) distance between the two cities and the speed
-- needed. Flag if speed > 900 km/h (faster than a commercial jet).
-- Time gaps under 1 minute are treated as 1 minute to avoid divide-by-zero.
WITH seq AS (
    SELECT  t.account_id, t.transaction_id, t.transaction_date, t.amount,
            l.city,
            LAG(t.transaction_id)   OVER w AS prev_id,
            LAG(t.transaction_date) OVER w AS prev_date,
            LAG(l.city)             OVER w AS prev_city
    FROM    transactions t
    JOIN    locations l ON l.location_id = t.location_id
    WINDOW  w AS (PARTITION BY t.account_id ORDER BY t.transaction_date, t.transaction_id)
),
dist AS (
    SELECT  s.*,
            TIMESTAMPDIFF(SECOND, s.prev_date, s.transaction_date) AS secs_apart,
            2 * 6371 * ASIN(SQRT(
                POWER(SIN(RADIANS(c2.latitude  - c1.latitude)  / 2), 2) +
                COS(RADIANS(c1.latitude)) * COS(RADIANS(c2.latitude)) *
                POWER(SIN(RADIANS(c2.longitude - c1.longitude) / 2), 2)
            )) AS km
    FROM    seq s
    JOIN    city_reference c1 ON c1.city = s.prev_city
    JOIN    city_reference c2 ON c2.city = s.city
    WHERE   s.prev_city IS NOT NULL
      AND   s.prev_city <> s.city
)
SELECT  account_id,
        prev_id          AS from_txn,
        transaction_id   AS to_txn,
        prev_city        AS from_city,
        city             AS to_city,
        prev_date        AS from_time,
        transaction_date AS to_time,
        ROUND(km)        AS km_apart,
        ROUND(secs_apart / 60, 1) AS minutes_apart,
        ROUND(km / (GREATEST(secs_apart, 60) / 3600)) AS required_speed_kmh
FROM    dist
WHERE   km / (GREATEST(secs_apart, 60) / 3600) > 900
ORDER BY required_speed_kmh DESC;


-- A2. Transactions unusually high vs the same account's previous 10 transactions
-- Window frame: the 10 rows BEFORE the current one (current row excluded).
-- Needs at least 3 prior transactions; flags amount >= 10x the rolling average
-- (5x flagged 57 rows, ~8% of the table - too noisy for a review queue).
WITH rolling AS (
    SELECT  t.*,
            AVG(amount)   OVER w AS prev10_avg,
            COUNT(amount) OVER w AS prev_count
    FROM    transactions t
    WINDOW  w AS (PARTITION BY account_id
                  ORDER BY transaction_date, transaction_id
                  ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING)
)
SELECT  account_id, transaction_id, transaction_date, transaction_type, amount,
        prev_count,
        ROUND(prev10_avg, 2)          AS avg_of_prev_10,
        ROUND(amount / prev10_avg, 1) AS times_recent_average
FROM    rolling
WHERE   prev_count >= 3
  AND   amount >= 10 * prev10_avg
ORDER BY times_recent_average DESC;


-- A3. Repeated high-value transactions followed by rapid withdrawals
-- Pattern: 3+ high-value purchases (>= 1,500) inside 60 minutes, then a
-- withdrawal within the next 60 minutes (classic "cash out after card abuse").
-- NOTE: the original data has NO withdrawals after bursts, so this returns
-- 0 rows until you load extension_seed.sql (4 extra rows, clearly labelled).
WITH high AS (
    SELECT * FROM transactions
    WHERE  transaction_type = 'Purchase' AND amount >= 1500
),
burst AS (
    SELECT  h.account_id,
            h.transaction_id   AS last_high_txn,
            h.transaction_date AS burst_end,
            COUNT(*)           AS high_value_txns,
            SUM(h2.amount)     AS burst_value
    FROM    high h
    JOIN    high h2
            ON  h2.account_id = h.account_id
            AND h2.transaction_date BETWEEN h.transaction_date - INTERVAL 60 MINUTE
                                        AND h.transaction_date
    GROUP BY h.account_id, h.transaction_id, h.transaction_date
    HAVING  COUNT(*) >= 3
)
SELECT  b.account_id,
        MAX(b.high_value_txns)  AS high_value_txns_in_burst,
        MAX(b.burst_value)      AS burst_value,
        w.transaction_id        AS withdrawal_txn,
        w.amount                AS withdrawal_amount,
        w.transaction_date      AS withdrawal_time,
        MIN(TIMESTAMPDIFF(MINUTE, b.burst_end, w.transaction_date)) AS minutes_after_burst
FROM    burst b
JOIN    transactions w
        ON  w.account_id       = b.account_id
        AND w.transaction_type = 'Withdrawal'
        AND w.transaction_date >  b.burst_end
        AND w.transaction_date <= b.burst_end + INTERVAL 60 MINUTE
GROUP BY b.account_id, w.transaction_id, w.amount, w.transaction_date
ORDER BY w.transaction_date;


-- A4. Fraud-risk classification using multiple CASE WHEN conditions
-- Each transaction gets points for each red flag; points -> risk level.
--   amount >= 5,000 ............ +3   |  amount >= 1,500 ............ +1
--   within 5 min of prior txn .. +2   |  4+ txns on same day ........ +2
--   3+ cities on same day ...... +2   |  impossible travel (>900 km/h) +3
--   night (00:00-05:59) & >=1,000  +1 |  account is Frozen .......... +2
--   Level: >=7 Critical | 4-6 High | 2-3 Medium | 0-1 Low
CREATE OR REPLACE VIEW vw_transaction_risk AS
WITH base AS (
    SELECT  t.transaction_id, t.account_id, t.transaction_date, t.transaction_type,
            t.amount, l.city, a.status AS account_status,
            LAG(t.transaction_date) OVER w AS prev_date,
            LAG(l.city)             OVER w AS prev_city,
            COUNT(*)                OVER (PARTITION BY t.account_id, DATE(t.transaction_date)) AS txns_that_day
    FROM    transactions t
    JOIN    accounts  a ON a.account_id  = t.account_id
    JOIN    locations l ON l.location_id = t.location_id
    WINDOW  w AS (PARTITION BY t.account_id ORDER BY t.transaction_date, t.transaction_id)
),
city_day AS (
    SELECT  t.account_id, DATE(t.transaction_date) AS d, COUNT(DISTINCT l.city) AS cities_that_day
    FROM    transactions t JOIN locations l ON l.location_id = t.location_id
    GROUP BY t.account_id, DATE(t.transaction_date)
),
scored AS (
    SELECT  b.*, cd.cities_that_day,
            TIMESTAMPDIFF(SECOND, b.prev_date, b.transaction_date) AS secs_since_prev,
            CASE WHEN b.prev_city IS NOT NULL AND b.prev_city <> b.city
                 THEN 2 * 6371 * ASIN(SQRT(
                        POWER(SIN(RADIANS(c2.latitude  - c1.latitude)  / 2), 2) +
                        COS(RADIANS(c1.latitude)) * COS(RADIANS(c2.latitude)) *
                        POWER(SIN(RADIANS(c2.longitude - c1.longitude) / 2), 2)))
            END AS km_from_prev
    FROM    base b
    JOIN    city_day cd ON cd.account_id = b.account_id AND cd.d = DATE(b.transaction_date)
    LEFT JOIN city_reference c1 ON c1.city = b.prev_city
    LEFT JOIN city_reference c2 ON c2.city = b.city
),
points AS (
    SELECT  s.*,
            CASE WHEN amount >= 5000 THEN 3 WHEN amount >= 1500 THEN 1 ELSE 0 END AS pts_amount,
            CASE WHEN secs_since_prev <= 300 THEN 2 ELSE 0 END                    AS pts_rapid,
            CASE WHEN txns_that_day >= 4 THEN 2 ELSE 0 END                        AS pts_busy_day,
            CASE WHEN cities_that_day >= 3 THEN 2 ELSE 0 END                      AS pts_multi_city,
            CASE WHEN km_from_prev IS NOT NULL
                  AND km_from_prev / (GREATEST(secs_since_prev, 60) / 3600) > 900 THEN 3 ELSE 0 END AS pts_travel,
            CASE WHEN HOUR(transaction_date) < 6 AND amount >= 1000 THEN 1 ELSE 0 END AS pts_night,
            CASE WHEN account_status = 'Frozen' THEN 2 ELSE 0 END                 AS pts_frozen
    FROM    scored s
)
SELECT  p.transaction_id, p.account_id, p.transaction_date, p.transaction_type,
        p.amount, p.city,
        (pts_amount + pts_rapid + pts_busy_day + pts_multi_city + pts_travel + pts_night + pts_frozen) AS risk_score,
        CASE
            WHEN (pts_amount + pts_rapid + pts_busy_day + pts_multi_city + pts_travel + pts_night + pts_frozen) >= 7 THEN 'Critical'
            WHEN (pts_amount + pts_rapid + pts_busy_day + pts_multi_city + pts_travel + pts_night + pts_frozen) >= 4 THEN 'High'
            WHEN (pts_amount + pts_rapid + pts_busy_day + pts_multi_city + pts_travel + pts_night + pts_frozen) >= 2 THEN 'Medium'
            ELSE 'Low'
        END AS risk_level,
        CONCAT_WS(', ',
            CASE WHEN pts_amount  > 0 THEN 'high amount'      END,
            CASE WHEN pts_rapid   > 0 THEN 'rapid-fire'       END,
            CASE WHEN pts_busy_day> 0 THEN 'busy day'         END,
            CASE WHEN pts_multi_city>0 THEN 'multi-city day'  END,
            CASE WHEN pts_travel  > 0 THEN 'impossible travel' END,
            CASE WHEN pts_night   > 0 THEN 'night + large'    END,
            CASE WHEN pts_frozen  > 0 THEN 'frozen account'   END
        ) AS red_flags
FROM    points p;

-- A4a. Distribution of risk levels
SELECT  risk_level,
        COUNT(*)                AS txns,
        ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM vw_transaction_risk), 1) AS pct_of_all,
        ROUND(SUM(amount), 2)   AS total_value
FROM    vw_transaction_risk
GROUP BY risk_level
ORDER BY FIELD(risk_level, 'Critical', 'High', 'Medium', 'Low');

-- A4b. The highest-risk transactions
SELECT  *
FROM    vw_transaction_risk
WHERE   risk_level IN ('Critical', 'High')
ORDER BY risk_score DESC, amount DESC
LIMIT 25;

-- A4c. Accounts ranked by number of Critical/High transactions
SELECT  account_id,
        SUM(risk_level = 'Critical') AS critical_txns,
        SUM(risk_level = 'High')     AS high_txns,
        ROUND(SUM(CASE WHEN risk_level IN ('Critical','High') THEN amount END), 2) AS flagged_value
FROM    vw_transaction_risk
GROUP BY account_id
HAVING  SUM(risk_level IN ('Critical','High')) > 0
ORDER BY critical_txns DESC, high_txns DESC;


-- A5. Longest sequence of consecutive transaction days for each account
-- Gaps-and-islands: date minus its row number is constant inside a streak.
WITH days AS (
    SELECT DISTINCT account_id, DATE(transaction_date) AS d
    FROM   transactions
),
numbered AS (
    SELECT  d.*, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY d) AS rn
    FROM    days d
),
streaks AS (
    SELECT  account_id,
            MIN(d)   AS streak_start,
            MAX(d)   AS streak_end,
            COUNT(*) AS streak_days
    FROM    numbered
    GROUP BY account_id, DATE_SUB(d, INTERVAL rn DAY)
),
best AS (
    SELECT  s.*,
            ROW_NUMBER() OVER (PARTITION BY account_id
                               ORDER BY streak_days DESC, streak_start) AS pick
    FROM    streaks s
)
SELECT  account_id, streak_days AS longest_streak_days, streak_start, streak_end
FROM    best
WHERE   pick = 1
ORDER BY longest_streak_days DESC, account_id;
