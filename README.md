# NEXUS Transfer OTP Edge Function

Deploy this function as `nexus-transfer-otp`.

Required Supabase Edge Function secrets:
- `RESEND_API_KEY`
- `OTP_FROM_EMAIL`

`OTP_FROM_EMAIL` should contain only the verified/test sender address, for example `onboarding@resend.dev` during testing.

The function sends the OTP to the authenticated user's email address. It uses the Step 5 database function `create_transfer_otp_challenge(uuid,text)` and never returns the OTP to the browser.
