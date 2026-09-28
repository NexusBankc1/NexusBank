# NEXUS Supabase Setup

## 1. Create a Supabase project
Create a project at the official Supabase dashboard.

## 2. Run the database schema
Open **SQL Editor** and run the complete file:

`supabase/schema.sql`

This creates the tables, RLS policies, triggers and protected PostgreSQL functions used by the frontend.

## 3. Configure the frontend
Open:

`js/supabase.js`

Set:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY` (publishable/anon key)

Do **not** put the service-role key in the frontend.

## 4. Deploy the admin Edge Function
Deploy:

`supabase/functions/nexus-admin/index.ts`

Set these function secrets:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

The service-role key must remain server-side.

## 5. Create the first admin
The schema creates new Auth users as customers by default. Create your first account, then set its `profiles.role` to `admin` from the Supabase SQL editor while you are setting up the project.

Example:

```sql
update public.profiles
set role = 'admin'
where email = 'your-admin-email@example.com';
```

## 6. Realtime
The schema adds `notifications` to the Supabase Realtime publication when the project allows that change. If your project reports that the publication cannot be changed by the SQL editor, enable Realtime for `public.notifications` in the Supabase dashboard.

## 7. Static hosting
The frontend is static and can be opened in an Android editor such as TrebEdit and deployed to a static host. No Node.js, PHP, XAMPP or WAMP server is required for the frontend.

## 8. What still requires a provider
The UI contains a card page, crypto wallet fields and crypto transaction records. Actual card issuance/payment processing and actual blockchain broadcasting require a legitimate regulated card/custody/payment provider. The application does not pretend that a database write is a blockchain settlement.
