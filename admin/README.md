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
- `admin/events.html` - Events create + list (org-scoped via RLS)
- `admin/users.html` - User management (create Auth users + assign roles from UI)
- `admin/operations.html` - CRUD for event operations (Decor, Food, Photography, …)
- `admin/event-assign.html` - assign managers/clients to events (managers require an operation)
- `admin/event-feed.html` - per-event live feed (all managers' posts in one list); managers post here
- `admin/js/auth.js` - shared auth helpers + role module access
- `admin/js/events.js` - events create/list helpers
- `admin/js/users.js` - user create/list/update/delete helpers
- `admin/js/operations.js` - operations CRUD helpers
- `admin/js/event-feed.js` - event member assignment + uploads/feed helpers
- `admin/config.example.js` - template config (copy to `config.js`)
- `supabase/functions/admin-create-user/` - Edge Function used by Users page to create Auth logins

## Create users from UI (one-time deploy)

Browser cannot safely hold the service-role key, so user creation goes through an Edge Function.

1. Install Supabase CLI: https://supabase.com/docs/guides/cli
2. From repo root:
```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy admin-create-user
```
3. Open User Management → enter email, password, name, role → **Create User**

## GitHub Pages note

`admin/config.js` is gitignored. For Pages deploy, force-add the anon config once:

```bash
git add -f admin/config.js
git commit -m "Add Supabase anon config for GitHub Pages"
git push
```

Never commit the **service_role** key. Anon key in the browser is expected for Supabase client apps.


- `config.js` should not be committed (contains project keys).
- Login verifies both Auth session and `public.users` profile mapping.
- Events page requires login. Create allowed for `platform_owner`, `superadmin`, `opsadmin`, `manager`.
- Users page: create email/password/role from UI (after Edge Function deploy).
- Event Feed page: click an event to see one combined feed from all managers; managers post on that screen.
- Assign Users page: SuperAdmin/OpsAdmin assign managers/clients to events (separate from feed).
