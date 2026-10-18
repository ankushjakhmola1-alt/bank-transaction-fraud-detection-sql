-- =====================================================================
--  OPTIONAL EXTENSION DATA  (not part of the original dataset)
--  Adds 4 withdrawals so question A3 ("repeated high-value transactions
--  followed by rapid withdrawals") has something to find.
--  Safe to re-run: deletes its own rows first (transaction_id 723-726).
-- =====================================================================
USE bank_fraud_db;

DELETE FROM transactions WHERE transaction_id BETWEEN 723 AND 726;

INSERT INTO transactions (transaction_id, account_id, merchant_id, location_id, transaction_date, amount, transaction_type) VALUES
-- Account 1: burst ends 2025-01-16 08:48:53 -> cash-out about 16 minutes later (SHOULD be flagged)
(723, 1,  NULL, 5, '2025-01-16 09:05:00', 9500.00, 'Withdrawal'),
-- Account 8: burst ends 2024-06-18 11:38:08 -> cash-out about 31 minutes later (SHOULD be flagged)
(724, 8,  NULL, 2, '2024-06-18 12:10:00', 7800.00, 'Withdrawal'),
-- Account 28: burst ends 2024-10-03 01:42:28 -> cash-out about 27 minutes later (SHOULD be flagged)
(725, 28, NULL, 5, '2024-10-03 02:10:00', 6000.00, 'Withdrawal'),
-- Account 7: burst ends 2023-10-13 07:37:22 -> withdrawal 2 days later (control: should NOT be flagged)
(726, 7,  NULL, 1, '2023-10-15 10:00:00', 4000.00, 'Withdrawal');
