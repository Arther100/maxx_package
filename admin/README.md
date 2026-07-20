# MAXX Admin (Login + Profile Bootstrap)

Static admin pages for Supabase Auth login and profile loading via `get_me()`.

## Setup

1. Run DB migration:
   - `db/migrations/004_get_me_rpc.sql`

2. Copy config:
```bash
cp admin/config.example.js admin/config.js
```

3. Fill `admin/config.js` with your Supabase values:
   - Project URL
   - Anon public key

4. Open pages locally:
   - `admin/login.html`
   - `admin/index.html`

## Test accounts

- `platform.owner@maxxevents.local`
- `superadmin@maxxevents.local`

Use the passwords you set in Supabase Auth.

## Files

- `admin/login.html` - sign in page
- `admin/index.html` - protected dashboard, loads profile via `get_me()`
- `admin/js/auth.js` - shared auth helpers
- `admin/config.example.js` - template config (copy to `config.js`)

## Notes

- `config.js` should not be committed (contains project keys).
- Login verifies both Auth session and `public.users` profile mapping.
