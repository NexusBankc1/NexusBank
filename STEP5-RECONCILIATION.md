# NEXUS Step 5 — Transfer Security Reconciliation

This step removes the split between the older `submit_transfer` path and the newer transaction-PIN/OTP flow.

## Run first

Run:

`supabase/migrations/20260927_step5_transfer_reconciliation.sql`

in the Supabase SQL Editor.

## Then deploy the Edge Function

Deploy `supabase/functions/nexus-transfer-otp` as:

`nexus-transfer-otp`

Configure:

- `RESEND_API_KEY`
- `NEXUS_OTP_FROM`

## Security behavior

1. Customer enters recipient and amount.
2. PostgreSQL validates the account, balance, recipient and transaction PIN.
3. A transfer request is created; no money moves yet.
4. The Edge Function generates a six-digit OTP and sends it to the customer's authenticated email.
5. The OTP is stored only as a bcrypt hash.
6. After successful OTP verification, the server performs the debit and creates the transaction.
7. A pending account creates a pending transaction instead of debiting immediately.
8. Frozen/deactivated accounts are blocked server-side.
9. Admins can audit OTP challenge status, but never see the OTP itself.

The existing admin funding, crypto funding, crypto wallet configuration, customer-care settings, account-status controls, recycle bin, and transaction display-date features remain separate and are preserved.

## Frontend wiring

`pages/send-money.html` and `js/pages/send-money.js` in this package now use the Step 5 flow. The old direct `submit_transfer` call is no longer used by the Send Money page.
