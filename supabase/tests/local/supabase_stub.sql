-- =============================================================================
-- Minimal Supabase-compatible bootstrap for a DISPOSABLE local PostgreSQL only.
--
-- NEVER run this against Supabase DEV or PROD: those projects already provide the
-- real auth schema, roles and publication. The guard below refuses to run on any
-- database that looks like a Supabase project.
--
-- It provides only what the dog_log migration and tests depend on:
--   roles anon / authenticated / service_role, auth.users, auth.uid(),
--   the supabase_realtime publication, and deliberately HOSTILE global default
--   privileges (grants to anon/authenticated on every new table/function), so the
--   tests prove the migration's explicit revokes hold even when defaults are unsafe.
-- =============================================================================
do $$
begin
  if exists (select 1 from pg_namespace where nspname in ('supabase_migrations', 'storage', 'realtime', 'vault')) then
    raise exception 'refusing to run the local Supabase stub on a Supabase-managed database';
  end if;
end $$;

create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;

create schema auth;
grant usage on schema auth to anon, authenticated, service_role;

create table auth.users (
  id    uuid primary key,
  email text
);

-- Same contract as Supabase: the JWT subject from request.jwt.claims, or null.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(
    current_setting('request.jwt.claim.sub', true),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  ), '')::uuid
$$;
grant execute on function auth.uid() to anon, authenticated, service_role;

create publication supabase_realtime;

-- Hostile defaults (worse than Supabase's "automatically expose new tables").
alter default privileges grant all on tables to anon, authenticated, service_role;
alter default privileges grant all on sequences to anon, authenticated, service_role;
alter default privileges grant execute on functions to anon, authenticated, service_role;
