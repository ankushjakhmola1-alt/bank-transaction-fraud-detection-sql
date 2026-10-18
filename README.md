# Bank Transaction Fraud Detection (SQL)

An analytical SQL project that hunts for suspicious behaviour in a synthetic banking dataset using
window functions, CTEs, self joins, and date/time logic. It answers all 17 practice questions
(5 Beginner, 7 Intermediate, 5 Advanced) and ends with a rules-based fraud-risk score.

> This is an analytical exercise, not a production fraud model.

## Dataset

| Table | Rows | Purpose |
|---|---|---|
| customers | 20 | Customer records |
| accounts | 30 | Checking / Savings / Credit (2 are Frozen) |
| merchants | 15 | Merchant name + category |
| locations | 8 | Cities in Pakistan, UAE, UK, USA, Canada, Singapore |
| transactions | 722 | Jan 2023 - Aug 2026: Purchase, Withdrawal, Transfer, Deposit |

## Files

| File | What it is |
|---|---|
| `2_bank_transaction_fraud_detection.sql` | Schema + sample data (load this first) |
| `bank_fraud_solutions.sql` | All solutions, commented, plus a reusable risk view |
| `extension_seed.sql` | Optional: 4 extra withdrawals so question A3 has data to find |

## How to run

```sql
SOURCE 2_bank_transaction_fraud_detection.sql;
SOURCE bank_fraud_solutions.sql;
SOURCE extension_seed.sql;   -- optional, then re-run query A3
```

Requires MySQL 8.0+ (window functions and CTEs). Also tested on MariaDB 10.11.

## Query index

| # | Question | Technique |
|---|---|---|
| B1 | Count and value per account | LEFT JOIN, GROUP BY |
| B2 | More than 20 transactions in a day | GROUP BY + HAVING |
| B3 | Largest transaction per account | RANK() |
| B4 | Customers above the overall average | HAVING with subquery |
| B5 | High-value transactions | Threshold filter |
| I1 | Same account within 5 minutes | Self join **and** LAG() |
| I2 | Larger than the customer's normal | Leave-one-out average |
| I3 | Frequency spikes | Daily counts vs own average |
| I4 | Potential duplicates | Three tiers: exact, same merchant, watch-list |
| I5 | Previous amount | LAG() |
| I6 | Time between transactions | LAG() + TIMESTAMPDIFF |
| I7 | More than 3 cities in a day | COUNT(DISTINCT) |
| A1 | Impossible travel | Haversine distance + required speed |
| A2 | High vs previous 10 transactions | Rolling window frame |
| A3 | High-value burst then rapid withdrawal | Burst detection + join |
| A4 | Fraud-risk classification | Multi-flag CASE WHEN scoring, saved as a view |
| A5 | Longest consecutive-day streak | Gaps-and-islands |

## Findings (original 722-row dataset)

* **7 burst events** (accounts 1, 7, 8, 22, 23, 28, 29): 4-6 purchases two minutes apart, spread across
  different cities. Two of them touch 5 different cities in a single day (accounts 8 and 23).
* **Impossible travel** flags 30 hops between consecutive transactions. All the bursts show up, plus five of the
  six "30-minute pair" purchases (accounts 9, 13, 15, 17, 21). The sixth (account 4, Lahore to Islamabad)
  is physically possible in 30 minutes, so it is correctly not flagged.
* **Risk scoring** ranks 23 transactions Critical (3.2%, about 66.5K in value) and 18 High
  (2.5%, about 106K). Every burst account lands at the top; account 8 is highest because it is also Frozen.
* Large one-off withdrawals and transfers (some above 10,000) are caught by the high-amount and
  rolling-average checks rather than by the burst rules.

## Data notes worth knowing

1. **The `locations` latitude/longitude are not real** (Lahore is at -37.89, -34.19; Toronto has latitude
   -75.84). `bank_fraud_solutions.sql` creates a `city_reference` table with real coordinates and uses it
   for all distance maths.
2. **B2 returns 0 rows at the stated threshold of 20**: the busiest day has 6 transactions. A scaled
   version (more than 3) is included.
3. **No exact duplicate transactions exist**, so I4 uses looser tiers.
4. **A3 returns nothing on the original data** because no withdrawals follow the bursts. `extension_seed.sql`
   adds three cash-outs (should be flagged) and one control withdrawal two days later (should not be).
5. **A5 maxes out at 2 days**, since accounts are only active on a few days each.
6. Thresholds (5,000 high-value, 1,500 for bursts, 900 km/h, 10x rolling average) are judgement calls,
   documented in the SQL comments, and easy to tune.

## Ideas to extend

Write 20 more questions that cannot be answered with a plain GROUP BY, add a merchant-category risk
dimension, or backtest the scoring weights against the seeded bursts.
