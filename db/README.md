# MAXX SaaS-Ready Database Baseline

This project now includes an additive migration at:

- `db/migrations/001_saas_ready_foundation.sql`
- `db/migrations/002_supabase_auth_rls_alignment.sql`
- `db/migrations/003_align_auth_user_ids.sql`
- `db/migrations/004_get_me_rpc.sql`
- `db/migrations/005_leads_booking_pipeline.sql`
- `db/migrations/006_events_details_and_settings.sql`

It sets up:

- `organizations` table
- `organization_id` scoping on business tables (`users`, `events`)
- `platform_owner` + org-scoped roles
- row-level security (RLS) with `organization_id` enforcement for non-platform-owner policies
- required seed records
- Supabase Auth-aware RLS (`auth.uid()` driven helper functions)
- role + organization enforced policies for `organizations`, `users`, `events`

## Seed records created

- Organization: `MAXX Events`
- User: `platform.owner@maxxevents.local` with role `platform_owner` and `organization_id = null`
- User: `superadmin@maxxevents.local` with role `superadmin` scoped to MAXX org

## Migration run order

1. Run `001_saas_ready_foundation.sql`
2. In Supabase Auth, create users for:
   - `platform.owner@maxxevents.local`
   - `superadmin@maxxevents.local`
3. Run `002_supabase_auth_rls_alignment.sql`
4. Run `003_align_auth_user_ids.sql` (fixes `public.users.id` = `auth.users.id`)
5. Run `004_get_me_rpc.sql` (profile RPC used by admin frontend)
6. Run `005_leads_booking_pipeline.sql` (booking form → DB + leads dashboard)
7. Run `006_events_details_and_settings.sql` (venue/maps/manager/upload/allowed features)

Migration `002` rebuilds policies to use authenticated user context.
Migration `003` is required if verification shows `id_aligned = false`.
Run `003` in Supabase SQL Editor (it uses a `SECURITY DEFINER` function to bypass RLS safely).
Migration `004` adds `get_me()` for frontend profile bootstrap.
Migration `005` adds `leads` table, org-scoped RLS, and `create_public_lead()` for the public booking form.
Migration `006` extends `events` with location, venue, maps link, manager settings, upload window, and allowed features.

## Verification queries

```sql
select id, name, status, created_at
from public.organizations;

select email, role, organization_id
from public.users
where email in ('platform.owner@maxxevents.local', 'superadmin@maxxevents.local');

select schemaname, tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
  and tablename in ('organizations', 'users', 'events')
order by tablename, policyname;

select
  pu.email,
  pu.id as public_user_id,
  au.id as auth_user_id,
  (pu.id = au.id) as id_aligned,
  pu.role,
  pu.organization_id
from public.users pu
left join auth.users au on lower(au.email) = lower(pu.email)
where pu.email in ('platform.owner@maxxevents.local', 'superadmin@maxxevents.local');
```

Expected: both rows show `id_aligned = true`.

## Runtime requirement

With migration `002`, RLS uses Supabase auth context automatically via `auth.uid()`.
No manual `set_config(...)` is needed in normal app requests.
