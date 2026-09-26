-- =============================================================================
-- Dog Log sync schema tests (WORK-136 PR-A)
--
-- Run with psql as the database owner/superuser AFTER the migration is applied:
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/dog_log_sync.sql
-- Everything runs inside one transaction that is ROLLED BACK at the end, so the
-- script leaves no rows behind. Synthetic users only; never real Dog Log data.
-- Any failed assertion raises and stops the script (ON_ERROR_STOP).
-- Concurrency (two sessions) and rollback are covered by tests/local/run_local.sh.
-- =============================================================================
\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned

begin;

create function pg_temp.ok(p_cond boolean, p_name text) returns text language plpgsql as $$
begin
  if p_cond is distinct from true then
    raise exception 'FAIL: %', p_name;
  end if;
  return 'ok   ' || p_name;
end $$;

\set A '''aaaaaaaa-0000-4000-8000-00000000000a'''
\set B '''bbbbbbbb-0000-4000-8000-00000000000b'''
\set D '''dddddddd-0000-4000-8000-00000000000d'''
\set E '''eeeeeeee-0000-4000-8000-00000000000e'''
\set asA 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"aaaaaaaa-0000-4000-8000-00000000000a","role":"authenticated"}'', true) \\g /dev/null'
\set asB 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"bbbbbbbb-0000-4000-8000-00000000000b","role":"authenticated"}'', true) \\g /dev/null'
\set asD 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"dddddddd-0000-4000-8000-00000000000d","role":"authenticated"}'', true) \\g /dev/null'
\set asE 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"eeeeeeee-0000-4000-8000-00000000000e","role":"authenticated"}'', true) \\g /dev/null'
\set F '''ffffffff-0000-4000-8000-00000000000f'''
\set G '''99999999-0000-4000-8000-000000000009'''
\set asF 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"ffffffff-0000-4000-8000-00000000000f","role":"authenticated"}'', true) \\g /dev/null'
\set asG 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"99999999-0000-4000-8000-000000000009","role":"authenticated"}'', true) \\g /dev/null'
\set asNoJwt 'set local role authenticated; select set_config(''request.jwt.claims'', '''', true) \\g /dev/null'
\set asAnon 'set local role anon; select set_config(''request.jwt.claims'', ''{"role":"anon"}'', true) \\g /dev/null'
\set asOwner 'reset role; select set_config(''request.jwt.claims'', '''', true) \\g /dev/null'

insert into auth.users (id, email) values
  (:A, 'a@test.invalid'), (:B, 'b@test.invalid'), (:D, 'd@test.invalid'), (:E, 'e@test.invalid'),
  (:F, 'f@test.invalid'), (:G, 'g@test.invalid');

-- ---------------------------------------------------------------- 1. install
select pg_temp.ok((select count(*) from pg_tables where schemaname = 'dog_log') = 4, '01 four dog_log tables exist');
select pg_temp.ok((select bool_and(relrowsecurity) from pg_class where relnamespace = 'dog_log'::regnamespace and relkind = 'r'), '01 RLS enabled on every table');
select pg_temp.ok(to_regprocedure('dog_log.seed_state(uuid,jsonb,text,integer)') is not null
              and to_regprocedure('dog_log.sync(jsonb,text,integer)') is not null, '01 client RPCs exist');
select pg_temp.ok((select prosecdef from pg_proc where oid = 'dog_log.sync(jsonb,text,integer)'::regprocedure)
              and (select prosecdef from pg_proc where oid = 'dog_log.seed_state(uuid,jsonb,text,integer)'::regprocedure), '01 client RPCs are SECURITY DEFINER');
select pg_temp.ok(not exists (select 1 from pg_proc where pronamespace = 'dog_log'::regnamespace
                                 and not coalesce(proconfig @> array['search_path=pg_catalog, pg_temp'], false)), '01 every dog_log function pins search_path=pg_catalog, pg_temp');
select pg_temp.ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'dog_log' and tablename = 'state')
              and (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'dog_log') = 1, '01 only dog_log.state added to supabase_realtime');

-- ------------------------------------------------- 2-3. grants, anon denied
select pg_temp.ok(not has_schema_privilege('anon', 'dog_log', 'usage'), '02 anon has no schema usage');
select pg_temp.ok(bool_and(not has_table_privilege(r, 'dog_log.' || t, p)), '02 no client write privilege on any table')
  from unnest(array['anon', 'authenticated']) r, unnest(array['state', 'meal_events', 'mutations', 'state_snapshots']) t,
       unnest(array['insert', 'update', 'delete', 'truncate', 'references', 'trigger']) p;
select pg_temp.ok(bool_and(not has_table_privilege('anon', 'dog_log.' || t, 'select')), '02 anon cannot select any table')
  from unnest(array['state', 'meal_events', 'mutations', 'state_snapshots']) t;
select pg_temp.ok(bool_and(has_table_privilege('authenticated', 'dog_log.' || t, 'select')), '02 authenticated has select (RLS-limited)')
  from unnest(array['state', 'meal_events', 'mutations', 'state_snapshots']) t;
select pg_temp.ok(not has_sequence_privilege('authenticated', 'dog_log.state_snapshots_id_seq', 'usage')
              and not has_sequence_privilege('anon', 'dog_log.state_snapshots_id_seq', 'usage'), '02 no sequence privilege for clients');
select pg_temp.ok(bool_and(has_function_privilege('authenticated', p.oid, 'execute') = (p.proname in ('seed_state', 'sync'))
                       and not has_function_privilege('anon', p.oid, 'execute')
                       and not has_function_privilege('service_role', p.oid, 'execute')),
                  '02 only seed_state/sync executable, and only by authenticated')
  from pg_proc p where p.pronamespace = 'dog_log'::regnamespace;

:asAnon
do $$ begin
  perform 1 from dog_log.state;
  raise exception 'FAIL: anon read dog_log.state';
exception when insufficient_privilege then raise notice 'ok   03 anon select denied';
end $$;
do $$ begin
  perform dog_log.sync('[]'::jsonb, 'x', 1);
  raise exception 'FAIL: anon executed sync';
exception when insufficient_privilege then raise notice 'ok   03 anon sync denied';
end $$;
do $$ begin
  perform dog_log.seed_state(gen_random_uuid(), '{}'::jsonb, 'x', 1);
  raise exception 'FAIL: anon executed seed_state';
exception when insufficient_privilege then raise notice 'ok   03 anon seed_state denied';
end $$;

:asNoJwt
do $$ begin
  perform dog_log.sync('[]'::jsonb, 'x', 1);
  raise exception 'FAIL: sync without a JWT subject succeeded';
exception when insufficient_privilege then raise notice 'ok   03 sync without JWT subject refused (not_authenticated)';
end $$;

-- ------------------------------------------------------- 4. first seed (A)
:asA
select dog_log.sync('[]'::jsonb, 'dev-a', 1) as r_noseed \gset
select dog_log.seed_state('11111111-1111-4111-8111-111111111111'::uuid,
  jsonb_build_object(
    'stock', jsonb_build_object('fridge', 3, 'freezer', 2, 'minceKg', 1.2000000000000002, 'neckBags', 4,
                                'necksOnly', '2', 'minceOnly', null, 'lykaPackets', 'junk', 'scratchPackets', 1),
    'settings', jsonb_build_object('totalContainers', 40, 'containersPerDay', 2, 'mincePurchaseIncrementKg', 0.5),
    'tracking', jsonb_build_object('mealCursor', (extract(epoch from now() - interval '30 hours') * 1000)::bigint,
                                   'mealLog', jsonb_build_object(to_char((now() - interval '3 days') at time zone 'Australia/Melbourne', 'YYYY-MM-DD'),
                                                                 jsonb_build_object('breakfast', 'fed', 'dinner', 'no-stock'))),
    'batches', jsonb_build_array(jsonb_build_object('at', '2026-09-20T01:00:00.000Z', 'containers', 10, 'minceUsedKg', 5, 'neckPacketsUsed', 3)),
    'history', jsonb_build_array(jsonb_build_object('at', '2026-09-20T01:00:00.000Z', 'action', 'Prep batch'), 'not-an-object'),
    'calendar', jsonb_build_object('endpoint', 'https://script.google.com/macros/s/abc/exec', 'token', 'SECRET-TOKEN', 'paired', true, 'lastSync', 'x')),
  'dev-a', 1) as r_seed \gset
:asOwner
select pg_temp.ok((:'r_noseed'::jsonb ->> 'status') = 'no-cloud-state', '04 sync before seed reports no-cloud-state');
select pg_temp.ok((:'r_seed'::jsonb ->> 'status') = 'seeded', '04 first seed succeeds into empty cloud');
select pg_temp.ok((:'r_seed'::jsonb #>> '{state,revision}')::int = 1, '04 seeded revision is 1');
select pg_temp.ok(position('SECRET-TOKEN' in (select doc::text from dog_log.state where owner_id = :A)) = 0
              and (select doc -> 'calendar' from dog_log.state where owner_id = :A) = '{"endpoint": "https://script.google.com/macros/s/abc/exec"}'::jsonb,
                  '04 calendar token/paired/lastSync stripped; endpoint kept');
select pg_temp.ok((select doc -> 'stock' from dog_log.state where owner_id = :A)
                  = '{"fridge": 3, "freezer": 2, "minceKg": 1.200, "neckPackets": 4, "necksOnly": 2, "minceOnly": 0, "lykaPackets": 0, "scratchPackets": 1}'::jsonb,
                  '04 seed normalises (converts, never rejects) legacy/bad values');
select pg_temp.ok((select jsonb_array_length(doc -> 'history') from dog_log.state where owner_id = :A) = 1, '04 malformed history entries dropped');
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :A and origin = 'seed' and slot <> 'transfer') = 2
              and (select count(*) from dog_log.meal_events where owner_id = :A and origin = 'seed' and slot = 'transfer') = 1,
                  '04 recent device mealLog imported as seed events (its Dinner closes that day''s transfer)');
select pg_temp.ok((select count(*) from dog_log.state_snapshots where owner_id = :A and reason = 'seed') = 1, '04 seed snapshot recorded');

-- ------------------------------------------- 5. repeated / competing seeds
:asA
select dog_log.seed_state('11111111-1111-4111-8111-111111111111'::uuid, '{}'::jsonb, 'dev-a', 1) as r_retry \gset
select dog_log.seed_state('22222222-2222-4222-8222-222222222222'::uuid, '{"stock":{"fridge":0,"freezer":0}}'::jsonb, 'dev-empty', 1) as r_other \gset
:asOwner
select pg_temp.ok((:'r_retry'::jsonb ->> 'status') = 'already-seeded', '05 retry with the same seed_id returns already-seeded');
select pg_temp.ok((:'r_other'::jsonb ->> 'status') = 'cloud-exists', '05 another device''s seed returns cloud-exists');
select pg_temp.ok((select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :A) = 3
              and (select revision from dog_log.state where owner_id = :A) = 1, '05 empty/default seed did not overwrite cloud state');

-- ------------------------------------------------ 6. B seeds; RLS isolation
:asB
select dog_log.seed_state(gen_random_uuid(), '{"stock":{"fridge":7}}'::jsonb, 'dev-b', 1) \g /dev/null
select (select count(*) from dog_log.state) as b_rows, (select count(*) from dog_log.state where owner_id = :A) as b_sees_a,
       (select count(*) from dog_log.meal_events where owner_id = :A) + (select count(*) from dog_log.state_snapshots where owner_id = :A)
       + (select count(*) from dog_log.mutations where owner_id = :A) as b_sees_a_children \gset
:asA
select (select count(*) from dog_log.state) as a_rows, (select owner_id from dog_log.state) as a_owner \gset
:asOwner
select pg_temp.ok(:b_rows = 1 and :b_sees_a = 0 and :b_sees_a_children = 0, '06 B sees only its own rows in every table');
select pg_temp.ok(:a_rows = 1 and :'a_owner'::uuid = :A, '06 A sees only its own state row');

-- ----------------------------------------- 7. direct writes cannot bypass RPCs
:asA
do $$ begin
  update dog_log.state set revision = 999;
  raise exception 'FAIL: direct update allowed';
exception when insufficient_privilege then raise notice 'ok   07 direct UPDATE denied';
end $$;
do $$ begin
  insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, origin)
  values ('aaaaaaaa-0000-4000-8000-00000000000a', current_date, 'breakfast', 'no-stock', now(), 'server');
  raise exception 'FAIL: direct insert allowed';
exception when insufficient_privilege then raise notice 'ok   07 direct INSERT denied';
end $$;
do $$ begin
  delete from dog_log.mutations;
  raise exception 'FAIL: direct delete allowed';
exception when insufficient_privilege then raise notice 'ok   07 direct DELETE denied';
end $$;

-- ---------------------------------------- 8. ownership cannot be forged
do $$ begin
  perform dog_log._process_due_meals('bbbbbbbb-0000-4000-8000-00000000000b', now(), 'x');
  raise exception 'FAIL: client executed _process_due_meals';
exception when insufficient_privilege then raise notice 'ok   08 internal _process_due_meals not executable by clients';
end $$;
do $$ begin
  perform dog_log._apply_op('bbbbbbbb-0000-4000-8000-00000000000b', '{}'::jsonb, now(), 1);
  raise exception 'FAIL: client executed _apply_op';
exception when insufficient_privilege then raise notice 'ok   08 internal _apply_op not executable by clients';
end $$;
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'fridge', 'delta', 1,
  'owner_id', 'bbbbbbbb-0000-4000-8000-00000000000b', 'client_created_at', now(), 'label', 'Fridge +1')), 'dev-a', 1) as r_forge \gset
:asOwner
select pg_temp.ok((:'r_forge'::jsonb ->> 'revision')::int = 2, '14 first changing sync (meals + one op) bumps revision 1 -> 2 exactly once');
select pg_temp.ok((select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :B) = 7, '08 owner_id in a payload is ignored: B untouched');
do $$ begin
  perform set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-00000000000a"}', true);
  perform dog_log._process_due_meals('bbbbbbbb-0000-4000-8000-00000000000b', now(), 'x');
  raise exception 'FAIL: owner guard bypassed';
exception when insufficient_privilege then raise notice 'ok   08 internal owner guard rejects a JWT subject that is not p_owner';
end $$;
select set_config('request.jwt.claims', '', true) \g /dev/null

-- --------------------- 9/10. first sync processes due meals; no-op sync does not bump
select count(*) as expected_due from (
  select (d::date + t) at time zone 'Australia/Melbourne' as at
    from generate_series(((now() - interval '31 hours') at time zone 'Australia/Melbourne')::date,
                         (now() at time zone 'Australia/Melbourne')::date, interval '1 day') d,
         (values (time '09:00'), (time '18:00')) v(t)) s
 where at > now() - interval '30 hours' and at <= now() \gset
:asA
select dog_log.sync('[]'::jsonb, 'dev-a', 1) as r1 \gset
select dog_log.sync('[]'::jsonb, 'dev-a', 1) as r2 \gset
:asOwner
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :A and origin = 'server' and slot <> 'transfer') = :expected_due,
                  '09 every due Melbourne slot since the cursor processed exactly once');
select pg_temp.ok((:'r2'::jsonb ->> 'revision')::int = (:'r1'::jsonb ->> 'revision')::int, '10 no-op sync does not bump revision');

-- ---------------------------------------------- 11-12. deltas, clamps, idempotency
select revision as rev0, (doc #>> '{stock,fridge}')::int as fridge0, (doc #>> '{stock,freezer}')::int as freezer0
  from dog_log.state where owner_id = :A \gset
:asA
select dog_log.sync(jsonb_build_array(
  jsonb_build_object('mutation_id', '33333333-3333-4333-8333-333333333333', 'type', 'adjust', 'key', 'fridge', 'delta', 2, 'client_created_at', now(), 'label', 'Fridge +2'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'freezer', 'delta', -1, 'client_created_at', now(), 'label', 'Freezer -1'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'neckPackets', 'delta', -50, 'client_created_at', now(), 'label', 'Necks -50'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'fridge', 'delta', 0.5, 'client_created_at', now()),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'prep_batch', 'destination', 'fridge', 'containers', 'twelve', 'batch', '{}'::jsonb, 'client_created_at', now()),
  jsonb_build_object('mutation_id', 'not-a-uuid', 'type', 'adjust')), 'dev-a', 1) as r_delta \gset
select dog_log.sync(jsonb_build_array(
  jsonb_build_object('mutation_id', '33333333-3333-4333-8333-333333333333', 'type', 'adjust', 'key', 'fridge', 'delta', 2, 'client_created_at', now(), 'label', 'Fridge +2')),
  'dev-a', 1) as r_dup \gset
:asOwner
select pg_temp.ok((select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :A) = :fridge0 + 2, '11 counter delta +2 applied once');
select pg_temp.ok((select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :A) = greatest(:freezer0 - 1, 0), '11 counter delta -1 applied');
select pg_temp.ok((:'r_delta'::jsonb -> 'results' -> 2 ->> 'status') = 'applied-clamped'
              and (select (doc #>> '{stock,neckPackets}')::int from dog_log.state where owner_id = :A) = 0, '11 over-deduction clamps at 0 and is reported');
select pg_temp.ok((:'r_delta'::jsonb -> 'results' -> 3 ->> 'status') = 'rejected', '11 fractional delta on a count is rejected');
select pg_temp.ok((:'r_delta'::jsonb -> 'results' -> 4 ->> 'status') = 'rejected', '11 malformed op is rejected without aborting the batch');
select pg_temp.ok((:'r_delta'::jsonb -> 'results' -> 5 ->> 'status') = 'rejected', '11 invalid mutation_id rejected');
select pg_temp.ok((:'r_delta'::jsonb ->> 'revision')::int = :rev0 + 1, '14 several ops in one sync bump revision once');
select pg_temp.ok((select doc #>> '{history,0,action}' from dog_log.state where owner_id = :A) = 'Necks -50', '11 labelled ops append history');
select pg_temp.ok((:'r_dup'::jsonb -> 'results' -> 0 ->> 'status') = 'duplicate'
              and (:'r_dup'::jsonb -> 'results' -> 0 ->> 'original_status') = 'applied'
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :A) = :fridge0 + 2
              and (:'r_dup'::jsonb ->> 'revision')::int = :rev0 + 1, '12 duplicate mutation_id is idempotent (no re-apply, no bump)');

-- ------------------------------- 13. conditional recount / stale expectations
select revision as rev1, (doc #>> '{stock,fridge}')::int as fridge1 from dog_log.state where owner_id = :A \gset
:asA
select dog_log.sync(jsonb_build_array(
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'set', 'key', 'fridge', 'value', 99, 'expected', :fridge1 + 5, 'client_created_at', now(), 'label', 'Fridge set to 99'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'settings', 'field', 'totalContainers', 'value', 50, 'expected', 41, 'client_created_at', now())),
  'dev-b-stale', 1) as r_stale \gset
:asOwner
select pg_temp.ok((:'r_stale'::jsonb -> 'results' -> 0 ->> 'status') = 'conflict'
              and (:'r_stale'::jsonb -> 'results' -> 0 -> 'detail' ->> 'current')::int = :fridge1
              and (:'r_stale'::jsonb -> 'results' -> 1 ->> 'status') = 'conflict', '13 stale recount and stale setting produce conflict');
select pg_temp.ok((select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :A) = :fridge1
              and (select revision from dog_log.state where owner_id = :A) = :rev1, '13 conflict writes nothing and does not bump revision');
select pg_temp.ok((select count(*) from dog_log.mutations where owner_id = :A and status = 'conflict' and op_type in ('set', 'settings')) = 2, '13 conflicts recorded in ledger');
:asA
select dog_log.sync(jsonb_build_array(
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'set', 'key', 'minceKg', 'value', 2.345, 'expected', 1.2000000000000002, 'client_created_at', now(), 'label', 'Pet mince set to 2.345 kg'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'settings', 'field', 'totalContainers', 'value', 50, 'expected', 40, 'client_created_at', now(), 'label', 'Food settings updated'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'calendar_endpoint', 'value', 'https://evil.example/x', 'expected', 'https://script.google.com/macros/s/abc/exec', 'client_created_at', now()),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'drop_everything', 'client_created_at', now()),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'fridge', 'delta', 1, 'client_created_at', now() - interval '31 days'),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'fridge', 'delta', 1, 'client_created_at', now() + interval '2 days')),
  'dev-a', 1) as r_misc \gset
:asOwner
select pg_temp.ok((:'r_misc'::jsonb -> 'results' -> 0 ->> 'status') = 'applied'
              and (select (doc #>> '{stock,minceKg}')::numeric from dog_log.state where owner_id = :A) = 2.345, '13 kg recount compares at 3 dp (float noise is not a conflict)');
select pg_temp.ok((:'r_misc'::jsonb -> 'results' -> 1 ->> 'status') = 'applied'
              and (select (doc #>> '{settings,totalContainers}')::numeric from dog_log.state where owner_id = :A) = 50, '13 conditional setting applied when expectation matches');
select pg_temp.ok((:'r_misc'::jsonb -> 'results' -> 2 ->> 'status') = 'rejected', '13 non-Apps-Script calendar endpoint rejected');
select pg_temp.ok((:'r_misc'::jsonb -> 'results' -> 3 ->> 'status') = 'rejected', '13 unknown operation type rejected');
select pg_temp.ok((:'r_misc'::jsonb -> 'results' -> 4 ->> 'status') = 'expired', '13 op older than 30 days expires');
select pg_temp.ok((:'r_misc'::jsonb -> 'results' -> 5 ->> 'status') = 'rejected', '13 op from the future rejected');

-- ------------------------------ 13b. prep batch with partial ingredient conflict
select (doc #>> '{stock,freezer}')::int as freezer2, jsonb_array_length(doc -> 'batches') as nb from dog_log.state where owner_id = :A \gset
:asA
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'prep_batch', 'destination', 'freezer', 'containers', 12,
  'batch', jsonb_build_object('at', '2026-09-24T01:00:00.000Z', 'containers', 12, 'minceUsedKg', 6, 'neckPacketsUsed', 4, 'minceLeftKg', 0.5, 'neckPacketsLeft', 1),
  'minceLeftKg', 0.5, 'expectedMinceKg', 2.345, 'neckPacketsLeft', 1, 'expectedNeckPackets', 9,
  'client_created_at', now(), 'label', 'Prep batch: 12 containers')), 'dev-a', 1) as r_prep \gset
:asOwner
select pg_temp.ok((:'r_prep'::jsonb -> 'results' -> 0 ->> 'status') = 'conflict'
              and (:'r_prep'::jsonb -> 'results' -> 0 -> 'detail' ->> 'partial')::boolean
              and (select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :A) = :freezer2 + 12
              and (select jsonb_array_length(doc -> 'batches') from dog_log.state where owner_id = :A) = :nb + 1
              and (select (doc #>> '{stock,minceKg}')::numeric from dog_log.state where owner_id = :A) = 0.5
              and (select (doc #>> '{stock,neckPackets}')::int from dog_log.state where owner_id = :A) = 0,
                  '13 prep batch: batch+containers applied, matching mince set, stale necks conflict');

-- ------------------------------------------------ 13c. clear_history(before)
:asA
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'clear_history', 'before', '2026-09-21T00:00:00Z', 'client_created_at', now())), 'dev-a', 1) \g /dev/null
:asOwner
select pg_temp.ok(not exists (select 1 from dog_log.state, jsonb_array_elements(doc -> 'history') h
                               where owner_id = :A and (h ->> 'at')::timestamptz <= '2026-09-21T00:00:00Z')
              and (select jsonb_array_length(doc -> 'history') from dog_log.state where owner_id = :A) > 0,
                  '13 clear_history removes only entries at/before the clear time');

-- ---------------------------- 15. R2 rebase: recount taken before later meals
-- Give A fed events after a recount time T, then send a recount stamped at T.
update dog_log.state set doc = jsonb_set(jsonb_set(doc, '{stock,fridge}', '20'), '{stock,freezer}', '0'),
                         meal_cursor = now() - interval '25 hours' where owner_id = :A;
delete from dog_log.meal_events where owner_id = :A and slot_at > now() - interval '25 hours';
select count(*) as fed_after from (
  select (d::date + t) at time zone 'Australia/Melbourne' as at
    from generate_series(((now() - interval '27 hours') at time zone 'Australia/Melbourne')::date,
                         (now() at time zone 'Australia/Melbourne')::date, interval '1 day') d,
         (values (time '09:00'), (time '18:00')) v(t)) s
 where at > now() - interval '25 hours' and at <= now() \gset
:asA
select dog_log.sync('[]'::jsonb, 'dev-other', 1) \g /dev/null
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'set', 'key', 'fridge', 'value', 15, 'expected', 20,
  'client_created_at', now() - interval '25 hours', 'label', 'Fridge set to 15')), 'dev-offline', 1) as r_rebase \gset
:asOwner
select pg_temp.ok((:'r_rebase'::jsonb -> 'results' -> 0 ->> 'status') = 'applied'
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :A) = 15 - :fed_after,
                  '15 recount is rebased: meals fed after the recount stay deducted (R2)');

-- --------------------------- 16. R1 interleave: offline add before the meal
:asD
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 0, 'freezer', 0),
  'tracking', jsonb_build_object('mealCursor', (extract(epoch from now() - interval '40 hours') * 1000)::bigint)), 'dev-d', 1) \g /dev/null
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'fridge', 'delta', 3,
  'client_created_at', now() - interval '30 hours', 'label', 'Fridge +3')), 'dev-d', 1) \g /dev/null
:asOwner
select count(*) as d_after from (
  select (d::date + t) at time zone 'Australia/Melbourne' as at
    from generate_series(((now() - interval '31 hours') at time zone 'Australia/Melbourne')::date,
                         (now() at time zone 'Australia/Melbourne')::date, interval '1 day') d,
         (values (time '09:00'), (time '18:00')) v(t)) s
 where at > now() - interval '30 hours' and at <= now() \gset
select pg_temp.ok(not exists (select 1 from dog_log.meal_events where owner_id = :D and outcome = 'fed' and slot_at <= now() - interval '30 hours')
              and not exists (select 1 from dog_log.meal_events where owner_id = :D and outcome = 'no-stock' and slot_at > now() - interval '30 hours')
              and (select count(*) from dog_log.meal_events where owner_id = :D and outcome = 'fed') = least(3, :d_after)
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :D) = 3 - least(3, :d_after),
                  '16 meals after an offline add are fed from it; earlier ones are no-stock (R1)');

-- ------------- 17-19. fixed-date meal engine: DST, order, exactly-once, catch-up
:asE
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 3, 'freezer', 2),
  'tracking', jsonb_build_object('mealCursor', (extract(epoch from timestamptz '2025-10-03 12:00 Australia/Melbourne') * 1000)::bigint)),
  'dev-e', 1) \g /dev/null
:asOwner
select pg_temp.ok(dog_log._process_due_meals(:E, timestamptz '2025-10-06 12:00 Australia/Melbourne', 'test'), '17 catch-up across DST start runs');
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :E and origin = 'server' and slot <> 'transfer') = 6
              and (select count(*) from dog_log.meal_events where owner_id = :E and origin = 'server' and slot = 'transfer') = 3, '17 six meal slots (Fri D .. Mon B) and three daily transfers processed');
select pg_temp.ok((select slot_at from dog_log.meal_events where owner_id = :E and meal_date = '2025-10-04' and slot = 'breakfast') = timestamptz '2025-10-03 23:00:00+00'
              and (select slot_at from dog_log.meal_events where owner_id = :E and meal_date = '2025-10-05' and slot = 'breakfast') = timestamptz '2025-10-04 22:00:00+00',
                  '17 09:00 Melbourne is correct on both sides of DST start (AEST/AEDT)');
select pg_temp.ok(dog_log._slot_at('2026-04-05', 'breakfast', 'Australia/Melbourne') = timestamptz '2026-04-04 23:00:00+00'
              and dog_log._slot_at('2026-04-04', 'dinner', 'Australia/Melbourne') = timestamptz '2026-04-04 07:00:00+00',
                  '17 slot times correct across DST end');
select pg_temp.ok((select string_agg(slot || ':' || outcome || ':' || coalesce(source_container, '-'), ',' order by slot_at)
                     from dog_log.meal_events where owner_id = :E and origin = 'server' and slot <> 'transfer')
                  = 'dinner:fed:fridge,breakfast:fed:fridge,dinner:fed:fridge,breakfast:fed:fridge,dinner:fed:fridge,breakfast:no-stock:-',
                  '18 dinner transfer replenishes fridge for later meals; then no-stock');
select pg_temp.ok((select (doc #>> '{stock,fridge}')::int + (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 0,
                  '18 exactly one Full Container per fed slot');
select pg_temp.ok((select doc #>> '{history,0,action}' from dog_log.state where owner_id = :E) = 'Breakfast Mon 6 Oct 2025: no Full Container available'
              and (select doc #>> '{history,1,action}' from dog_log.state where owner_id = :E) = '18:00 freezer-to-fridge transfer Sun 5 Oct 2025: no Full Containers available in Freezer'
              and (select doc #>> '{history,2,action}' from dog_log.state where owner_id = :E) = 'Dinner Sun 5 Oct 2025: 1 Full Container used (fridge)'
              and exists (select 1 from jsonb_array_elements((select doc -> 'history' from dog_log.state where owner_id = :E)) h
                           where h ->> 'action' = '18:00 freezer-to-fridge transfer Fri 3 Oct 2025: 2 Full Containers moved from Freezer to Fridge'),
                  '18 history records dinner then the automatic freezer-to-fridge transfer');
select pg_temp.ok(not dog_log._process_due_meals(:E, timestamptz '2025-10-06 12:00 Australia/Melbourne', 'retry'), '19 retrying the same window reports no change');
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :E and origin = 'server' and slot <> 'transfer') = 6, '19 retrying the same window adds no events');
do $$ begin
  insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, origin)
  values ('eeeeeeee-0000-4000-8000-00000000000e', '2025-10-05', 'dinner', 'no-stock', now(), 'server');
  raise exception 'FAIL: duplicate meal identity accepted';
exception when unique_violation then raise notice 'ok   19 database rejects a second event for the same owner/date/slot';
end $$;
select pg_temp.ok((select count(distinct slot) from dog_log.meal_events where owner_id = :E and meal_date = '2025-10-05') = 3,
                  '20 breakfast, dinner and the transfer of the same day are independent identities');
select pg_temp.ok(dog_log._process_due_meals(:E, timestamptz '2025-10-10 12:00 Australia/Melbourne', 'test'), '20 long catch-up runs');
select pg_temp.ok((select doc #>> '{history,0,action}' from dog_log.state where owner_id = :E) = 'Scheduled meals caught up: 8 meals, 0 Full Containers used'
              and (select doc #>> '{history,1,action}' from dog_log.state where owner_id = :E) = 'Automatic 18:00 freezer-to-fridge transfers caught up: 0 Full Containers moved across 4 days',
                  '20 long catch-up keeps the meal summary and records transfer catch-up');
-- WORK-147 fixed dinner edges: dinner is consumed first, then 0/1/2 containers move.
update dog_log.state
   set doc = jsonb_set(jsonb_set(doc, '{stock,fridge}', '0'::jsonb), '{stock,freezer}', '3'::jsonb),
       meal_cursor = timestamptz '2026-09-20 17:59 Australia/Melbourne'
 where owner_id = :E;
delete from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-20';
select pg_temp.ok(dog_log._process_due_meals(:E, timestamptz '2026-09-20 18:01 Australia/Melbourne', 'edge-2'), '20 2-container dinner transfer runs');
select pg_temp.ok((select source_container from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-20' and slot = 'dinner') = 'freezer'
              and (select freezer_to_fridge_count from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-20' and slot = 'transfer') = 2
              and (select freezer_to_fridge_count from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-20' and slot = 'dinner') is null
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :E) = 2
              and (select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 0,
                  '20 dinner consumes freezer first, then exactly 2 remaining containers move to fridge');
select pg_temp.ok(not dog_log._process_due_meals(:E, timestamptz '2026-09-20 18:01 Australia/Melbourne', 'edge-2-retry')
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :E) = 2,
                  '20 retry cannot double-run the 18:00 transfer');
-- A recount made immediately before Dinner must replay both the meal and the transfer.
select dog_log._apply_op(:E, jsonb_build_object('type','set','key','freezer','value',4,'expected',3),
  timestamptz '2026-09-20 17:59 Australia/Melbourne', (select revision from dog_log.state where owner_id = :E)) as r_freezer_recount \gset
select pg_temp.ok((:'r_freezer_recount'::jsonb ->> 'status') = 'applied'
              and (:'r_freezer_recount'::jsonb #>> '{detail,transferred_since}')::int = 2
              and (select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 1,
                  '20 freezer recount replays dinner use plus 2-container transfer');

update dog_log.state
   set doc = jsonb_set(jsonb_set(doc, '{stock,fridge}', '0'::jsonb), '{stock,freezer}', '2'::jsonb),
       meal_cursor = timestamptz '2026-09-21 17:59 Australia/Melbourne'
 where owner_id = :E;
delete from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-21';
select pg_temp.ok(dog_log._process_due_meals(:E, timestamptz '2026-09-21 18:01 Australia/Melbourne', 'edge-1'), '20 1-container dinner transfer runs');
select pg_temp.ok((select freezer_to_fridge_count from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-21' and slot = 'transfer') = 1
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :E) = 1
              and (select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 0,
                  '20 only 1 remaining freezer container moves when dinner leaves one');
-- Restoring a backup from just before Dinner replays dinner first, then its recorded transfer.
select dog_log._apply_op(:E, jsonb_build_object(
  'type','replace_state','reason','restore-backup',
  'expected_revision',(select revision from dog_log.state where owner_id = :E),
  'doc','{"stock":{"fridge":0,"freezer":2}}'::jsonb,
  'subtract_meals_since',true,'backup_created_at','2026-09-21 17:59 Australia/Melbourne'),
  now(), (select revision from dog_log.state where owner_id = :E)) as r_transfer_restore \gset
select pg_temp.ok((:'r_transfer_restore'::jsonb ->> 'status') = 'applied'
              and (:'r_transfer_restore'::jsonb #>> '{detail,meals_subtracted}')::int = 1
              and (:'r_transfer_restore'::jsonb #>> '{detail,containers_transferred}')::int = 1
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :E) = 1
              and (select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 0,
                  '20 backup restore replays the recorded freezer-to-fridge transfer');

update dog_log.state
   set doc = jsonb_set(jsonb_set(doc, '{stock,fridge}', '1'::jsonb), '{stock,freezer}', '0'::jsonb),
       meal_cursor = timestamptz '2026-09-22 17:59 Australia/Melbourne'
 where owner_id = :E;
delete from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-22';
select pg_temp.ok(dog_log._process_due_meals(:E, timestamptz '2026-09-22 18:01 Australia/Melbourne', 'edge-0'), '20 0-container dinner transfer runs');
select pg_temp.ok((select freezer_to_fridge_count from dog_log.meal_events where owner_id = :E and meal_date = '2026-09-22' and slot = 'transfer') = 0
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :E) = 0
              and (select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 0
              and (select doc #>> '{history,0,action}' from dog_log.state where owner_id = :E)
                  = '18:00 freezer-to-fridge transfer ' || dog_log._fmt_day(timestamptz '2026-09-22 18:00 Australia/Melbourne', 'Australia/Melbourne') || ': no Full Containers available in Freezer',
                  '20 zero freezer stock is safe and clearly recorded');

do $$ begin
  perform dog_log._process_due_meals('eeeeeeee-0000-4000-8000-00000000000e', now() + interval '1 minute', 'x');
  raise exception 'FAIL: future processing allowed';
exception when invalid_parameter_value then raise notice 'ok   20 processing a future time is refused';
end $$;

-- ------------------------------------- 21. snapshots / restore (replace_state)
select revision as rev_a from dog_log.state where owner_id = :A \gset
select count(*) as snaps_a from dog_log.state_snapshots where owner_id = :A \gset
:asA
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'replace_state', 'reason', 'restore-backup', 'expected_revision', :rev_a - 1,
  'doc', '{"stock":{"fridge":1}}'::jsonb, 'client_created_at', now())), 'dev-a', 1) as r_rs_stale \gset
:asOwner
select pg_temp.ok((:'r_rs_stale'::jsonb -> 'results' -> 0 ->> 'status') = 'conflict'
              and (select count(*) from dog_log.state_snapshots where owner_id = :A) = :snaps_a, '21 restore with a stale expected_revision conflicts; no snapshot taken');
select meal_cursor as cursor_a from dog_log.state where owner_id = :A \gset
select count(*) as fed_since_backup from dog_log.meal_events where owner_id = :A and outcome = 'fed' and slot_at > now() - interval '25 hours' \gset
:asA
select dog_log.sync(jsonb_build_array(jsonb_build_object(
  'mutation_id', gen_random_uuid(), 'type', 'replace_state', 'reason', 'restore-backup', 'expected_revision', :rev_a,
  'doc', '{"stock":{"fridge":30,"freezer":5},"tracking":{"mealCursor":0},"calendar":{"token":"LEAK"}}'::jsonb,
  'subtract_meals_since', true, 'backup_created_at', now() - interval '25 hours',
  'client_created_at', now(), 'label', 'Restored device backup')), 'dev-a', 1) as r_rs \gset
:asOwner
select pg_temp.ok((:'r_rs'::jsonb -> 'results' -> 0 ->> 'status') = 'applied'
              and (select count(*) from dog_log.state_snapshots where owner_id = :A and reason = 'pre-restore') = 1
              and (select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = :A) = 30 - :fed_since_backup
              and (select meal_cursor from dog_log.state where owner_id = :A) = :'cursor_a'::timestamptz
              and position('LEAK' in (select doc::text from dog_log.state where owner_id = :A)) = 0,
                  '21 restore snapshots first, keeps the server meal cursor, subtracts meals since the backup, strips tokens');
select pg_temp.ok((select doc -> 'stock' -> 'fridge' from dog_log.state_snapshots where owner_id = :A and reason = 'pre-restore') is not null,
                  '21 pre-restore snapshot holds the previous doc');
:asA
:asOwner
do $$ declare i int; begin
  for i in 1 .. 24 loop
    insert into dog_log.state_snapshots (owner_id, reason, revision, doc) values ('aaaaaaaa-0000-4000-8000-00000000000a', 'pre-replace', 1, '{}');
  end loop;
end $$;
:asA
select dog_log.sync('[]'::jsonb, 'dev-a', 1) \g /dev/null
:asOwner
select pg_temp.ok((select count(*) from dog_log.state_snapshots where owner_id = :A) = 20, '21 snapshot retention keeps the newest 20');

-- --------------------------------------------- 22. compatibility gate, limits
update dog_log.state set min_client_version = 2 where owner_id = :B;
:asB
do $$ begin
  perform dog_log.sync('[]'::jsonb, 'dev-b', 1);
  raise exception 'FAIL: outdated client accepted';
exception when invalid_parameter_value then
  if sqlerrm <> 'client_outdated' then raise; end if;
  raise notice 'ok   22 outdated client refused (client_outdated)';
end $$;
do $$ begin
  perform dog_log.sync((select jsonb_agg('{}'::jsonb) from generate_series(1, 51)), 'dev-b', 2);
  raise exception 'FAIL: oversized batch accepted';
exception when invalid_parameter_value then raise notice 'ok   22 more than 50 mutations per call refused';
end $$;
:asOwner

-- ------------------------------------------ 23. hardening (independent review)
select pg_temp.ok(dog_log._fmt_day(timestamptz '2025-09-24 12:00 Australia/Melbourne', 'Australia/Melbourne') = 'Wed 24 Sept 2025'
              and dog_log._fmt_day(timestamptz '2025-06-03 12:00 Australia/Melbourne', 'Australia/Melbourne') = 'Tue 3 June 2025'
              and dog_log._fmt_day(timestamptz '2025-07-03 12:00 Australia/Melbourne', 'Australia/Melbourne') = 'Thu 3 July 2025',
                  '23 day labels use en-AU Intl month names (June, July, Sept)');
:asF
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 1e300, 'freezer', '99999999999999999999'),
  'tracking', jsonb_build_object('mealCursor', 1), 'calendar', jsonb_build_object('endpoint', 'https://evil.example/exec?token=x'),
  'settings', jsonb_build_object('containersPerDay', repeat('x', 5000)), 'history', jsonb_build_array(jsonb_build_object('at', repeat('9', 5000), 'action', 'x'))),
  'dev-f', 1) as r_f \gset
:asOwner
select pg_temp.ok((select meal_cursor from dog_log.state where owner_id = :F) >= now() - interval '400 days', '23 ancient seed mealCursor is bounded to 400 days');
select pg_temp.ok((select (doc #>> '{stock,fridge}')::numeric from dog_log.state where owner_id = :F) <= 1000000
              and (select (doc #>> '{stock,freezer}')::numeric from dog_log.state where owner_id = :F) <= 1000000, '23 absurd stock values are bounded');
select pg_temp.ok((select doc #>> '{calendar,endpoint}' from dog_log.state where owner_id = :F) = '', '23 seed stores only an Apps Script /exec endpoint');
select pg_temp.ok((select length(doc::text) from dog_log.state where owner_id = :F) < 5000, '23 oversized legacy/at strings are bounded');
:asF
select dog_log.sync(jsonb_build_array(
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'fridge', 'delta', 9e300, 'client_created_at', now()),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'set', 'key', 'fridge', 'value', 1, 'expected', 'x', 'client_created_at', now()),
  jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'replace_state', 'doc', '{}'::jsonb, 'expected_revision', 1.5, 'client_created_at', now())),
  'dev-f', 1) as r_over \gset
select dog_log.sync('[]'::jsonb, 'dev-f', 1) as r_after \gset
:asOwner
select pg_temp.ok((:'r_over'::jsonb -> 'results' -> 0 ->> 'status') = 'rejected'
              and (:'r_over'::jsonb -> 'results' -> 1 ->> 'status') = 'rejected'
              and (:'r_over'::jsonb -> 'results' -> 2 ->> 'status') = 'rejected'
              and (:'r_after'::jsonb ->> 'status') = 'ok', '23 overflow/garbage ops are rejected and the account keeps syncing');
select pg_temp.ok(not (:'r_over'::jsonb::text like '%error%'), '23 no raw database error text returned to the client');
do $$ begin
  perform set_config('request.jwt.claims', '{"sub":"99999999-0000-4000-8000-000000000009"}', true);
  set local role authenticated;
  perform dog_log.seed_state(gen_random_uuid(), '{}'::jsonb, 'x', 0);
  raise exception 'FAIL: seed from an outdated client accepted';
exception when invalid_parameter_value then raise notice 'ok   23 seed_state enforces the client version gate';
end $$;
:asOwner
-- ops are applied in client_created_at order even when submitted out of order; results keep submitted order
:asG
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 0, 'freezer', 0),
  'tracking', jsonb_build_object('mealCursor', (extract(epoch from now() - interval '40 hours') * 1000)::bigint)), 'dev-g', 1) \g /dev/null
select dog_log.sync(jsonb_build_array(
  jsonb_build_object('mutation_id', '77777777-7777-4777-8777-777777777777', 'type', 'adjust', 'key', 'fridge', 'delta', 1, 'client_created_at', now() - interval '10 hours'),
  jsonb_build_object('mutation_id', '88888888-8888-4888-8888-888888888888', 'type', 'adjust', 'key', 'fridge', 'delta', 2, 'client_created_at', now() - interval '35 hours')),
  'dev-g', 1) as r_order \gset
:asOwner
select pg_temp.ok((:'r_order'::jsonb -> 'results' -> 0 ->> 'mutation_id') = '77777777-7777-4777-8777-777777777777',
                  '23 results are returned in submitted order');
select pg_temp.ok((select outcome from dog_log.meal_events where owner_id = :G and slot <> 'transfer' and slot_at > now() - interval '35 hours' order by slot_at limit 1) = 'fed',
                  '23 an earlier-made op submitted later is still applied before the meals after it');
-- a caller's temporary objects cannot shadow type names inside the RPCs (pg_temp is searched last)
:asA
create temp table timestamptz (x int);
create temp table uuid (x int);
create temp table jsonb (x int);
create temp table text (x int);
create temp table numeric (x int);
select dog_log.sync(jsonb_build_array(jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'adjust', 'key', 'lykaPackets', 'delta', 1,
  'client_created_at', now(), 'label', 'Lyka +1')), 'dev-a', 1) ->> 'status' as r_hijack \gset
drop table pg_temp.timestamptz, pg_temp.uuid, pg_temp.jsonb, pg_temp.text, pg_temp.numeric;
:asOwner
select pg_temp.ok(:'r_hijack' = 'ok', '23 temp tables named timestamptz/uuid/jsonb/text/numeric do not affect the RPCs');

-- ------------------------- 24. WORK-148 configurable meal times and daily transfer
\set H '''48484848-0000-4000-8000-000000000048'''
\set asH 'set local role authenticated; select set_config(''request.jwt.claims'', ''{"sub":"48484848-0000-4000-8000-000000000048","role":"authenticated"}'', true) \\g /dev/null'
insert into auth.users (id, email) values (:H, 'h@test.invalid');
-- reset H: stock, settings, cursor (Melbourne local text) and that day's events
create function pg_temp.reset_h(p_fridge int, p_freezer int, p_settings jsonb, p_cursor text) returns void language sql as $$
  update dog_log.state set doc = jsonb_set(jsonb_set(jsonb_set(doc, '{stock,fridge}', to_jsonb(p_fridge)), '{stock,freezer}', to_jsonb(p_freezer)),
                                           '{settings}', (doc -> 'settings') || p_settings),
                           meal_cursor = (p_cursor::timestamp at time zone 'Australia/Melbourne')
   where owner_id = '48484848-0000-4000-8000-000000000048';
  delete from dog_log.meal_events where owner_id = '48484848-0000-4000-8000-000000000048'
     and slot_at > (p_cursor::timestamp at time zone 'Australia/Melbourne');
$$;
-- (a function, not an inline subquery: it sees the effects of an h_run earlier in the same statement)
create function pg_temp.h_hist(p_i int) returns text language sql as $$
  select doc #>> array['history', p_i::text, 'action'] from dog_log.state where owner_id = '48484848-0000-4000-8000-000000000048'
$$;
create function pg_temp.h_stock() returns text language sql as $$
  select (doc #>> '{stock,fridge}') || '/' || (doc #>> '{stock,freezer}') from dog_log.state where owner_id = '48484848-0000-4000-8000-000000000048'
$$;
create function pg_temp.h_ev(p_day date, p_slot text) returns text language sql as $$
  select outcome || ':' || coalesce(source_container, '-') || ':' || coalesce(freezer_to_fridge_count::text, '-') || '@' ||
         to_char(slot_at at time zone 'Australia/Melbourne', 'HH24:MI')
    from dog_log.meal_events where owner_id = '48484848-0000-4000-8000-000000000048' and meal_date = p_day and slot = p_slot
$$;
create function pg_temp.h_op(p_op jsonb, p_at text) returns jsonb language sql as $$
  select dog_log._apply_op('48484848-0000-4000-8000-000000000048', p_op, p_at::timestamp at time zone 'Australia/Melbourne',
                           (select revision from dog_log.state where owner_id = '48484848-0000-4000-8000-000000000048'))
$$;
create function pg_temp.h_run(p_until text) returns boolean language sql as $$
  select dog_log._process_due_meals('48484848-0000-4000-8000-000000000048', p_until::timestamp at time zone 'Australia/Melbourne', 'w148')
$$;

-- legacy defaults and normalisation
select pg_temp.ok(dog_log._setting('{}', 'breakfastTime') = '"09:00"' and dog_log._setting('{}', 'dinnerTime') = '"18:00"'
              and dog_log._setting('{}', 'fridgeTransferTime') = '"18:00"' and dog_log._setting('{}', 'fridgeTransferCount') = '2'
              and dog_log._setting('{}', 'maxFreezerContainers') = '70' and dog_log._setting('{}', 'maxFridgeContainers') = 'null',
                  '24 a document without Food settings reads as 09:00 / 18:00 / 2 at 18:00 / freezer 70 / fridge unset');
select pg_temp.ok(dog_log._norm_doc('{"settings":{"totalContainers":40,"containersPerDay":2}}') -> 'settings'
                  = '{"totalContainers": 40, "mincePurchaseIncrementKg": 0.5, "maxFreezerContainers": 70, "maxFridgeContainers": null,
                      "fridgeTransferCount": 2, "fridgeTransferTime": "18:00", "breakfastTime": "09:00", "dinnerTime": "18:00"}'::jsonb,
                  '24 old saved/backup settings normalise to the legacy defaults');
select pg_temp.ok(dog_log._norm_doc('{"settings":{"breakfastTime":"25:00","dinnerTime":"7pm","fridgeTransferTime":1800,"fridgeTransferCount":2.5,"maxFreezerContainers":-1,"maxFridgeContainers":"x"}}') -> 'settings'
                  @> '{"breakfastTime":"09:00","dinnerTime":"18:00","fridgeTransferTime":"18:00","fridgeTransferCount":2,"maxFreezerContainers":70,"maxFridgeContainers":null}'::jsonb,
                  '24 invalid Food settings normalise to defaults (converted, never rejected)');
select pg_temp.ok(dog_log._norm_doc('{"settings":{"breakfastTime":"07:15","dinnerTime":"17:45","fridgeTransferTime":"21:00","fridgeTransferCount":4,"maxFreezerContainers":90,"maxFridgeContainers":12}}') -> 'settings'
                  @> '{"breakfastTime":"07:15","dinnerTime":"17:45","fridgeTransferTime":"21:00","fridgeTransferCount":4,"maxFreezerContainers":90,"maxFridgeContainers":12}'::jsonb,
                  '24 valid Food settings survive normalisation (seed / restore)');

:asH
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 0, 'freezer', 0),
  'tracking', jsonb_build_object('mealCursor', (extract(epoch from timestamptz '2026-09-10 08:00 Australia/Melbourne') * 1000)::bigint)),
  'dev-h', 1) \g /dev/null
:asOwner
select pg_temp.ok(dog_log._setting((select doc from dog_log.state where owner_id = :H), 'fridgeTransferCount') = '2', '24 seeded doc carries the default transfer settings');

-- legacy behaviour: defaults, Dinner and transfer both 18:00 => Dinner first, then 2 move
select pg_temp.reset_h(0, 5, '{}', '2026-09-10 08:00');
select pg_temp.ok(pg_temp.h_run('2026-09-10 20:00'), '24 default schedule runs');
select pg_temp.ok(pg_temp.h_ev('2026-09-10', 'breakfast') = 'fed:freezer:-@09:00'
              and pg_temp.h_ev('2026-09-10', 'dinner') = 'fed:freezer:-@18:00'
              and pg_temp.h_ev('2026-09-10', 'transfer') = 'transferred:-:2@18:00'
              and pg_temp.h_stock() = '2/1',
                  '24 existing users keep 09:00 / 18:00 meals and a 2-container 18:00 transfer after Dinner');
select pg_temp.ok(pg_temp.h_hist(0)
                    = '18:00 freezer-to-fridge transfer ' || dog_log._fmt_day(timestamptz '2026-09-10 18:00 Australia/Melbourne', 'Australia/Melbourne') || ': 2 Full Containers moved from Freezer to Fridge'
              and pg_temp.h_hist(1) like 'Dinner %: 1 Full Container used (freezer)',
                  '24 equal time: history shows Dinner, then the transfer');
select pg_temp.ok(not pg_temp.h_run('2026-09-10 20:00') and pg_temp.h_stock() = '2/1', '24 reprocessing the same window is a no-op');

-- settings operations
select pg_temp.h_op('{"type":"settings","field":"breakfastTime","value":"07:30","expected":"09:00"}', '2026-09-10 21:00') as s1 \gset
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"17:00","expected":"18:00"}', '2026-09-10 21:00') as s2 \gset
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"16:00","expected":"18:00"}', '2026-09-10 21:00') as s3 \gset
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferCount","value":3,"expected":2}', '2026-09-10 21:00') as s4 \gset
select pg_temp.h_op('{"type":"settings","field":"maxFridgeContainers","value":8,"expected":null}', '2026-09-10 21:00') as s5 \gset
select pg_temp.h_op('{"type":"settings","field":"maxFreezerContainers","value":80,"expected":70}', '2026-09-10 21:00') as s6 \gset
select pg_temp.ok((:'s1'::jsonb ->> 'status') = 'applied' and (:'s2'::jsonb ->> 'status') = 'applied' and (:'s3'::jsonb ->> 'status') = 'applied'
              and (:'s4'::jsonb ->> 'status') = 'applied' and (:'s5'::jsonb ->> 'status') = 'applied' and (:'s6'::jsonb ->> 'status') = 'applied'
              and (select doc -> 'settings' from dog_log.state where owner_id = :H)
                  @> '{"breakfastTime":"07:30","dinnerTime":"17:00","fridgeTransferTime":"16:00","fridgeTransferCount":3,"maxFridgeContainers":8,"maxFreezerContainers":80}'::jsonb,
                  '24 each Food setting applies as a conditional settings operation');
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"19:00","expected":"18:00"}', '2026-09-10 21:00') as s_stale \gset
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"24:00","expected":"17:00"}', '2026-09-10 21:00') as s_bad1 \gset
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferCount","value":"3","expected":3}', '2026-09-10 21:00') as s_bad2 \gset
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferCount","value":101,"expected":3}', '2026-09-10 21:00') as s_bad3 \gset
select pg_temp.h_op('{"type":"settings","field":"maxFreezerContainers","value":null,"expected":80}', '2026-09-10 21:00') as s_bad4 \gset
select pg_temp.h_op('{"type":"settings","field":"mealCursor","value":1,"expected":1}', '2026-09-10 21:00') as s_bad5 \gset
select pg_temp.ok((:'s_stale'::jsonb ->> 'status') = 'conflict' and (:'s_stale'::jsonb #>> '{detail,current}') = '17:00'
              and (:'s_bad1'::jsonb ->> 'status') = 'rejected' and (:'s_bad2'::jsonb ->> 'status') = 'rejected'
              and (:'s_bad3'::jsonb ->> 'status') = 'rejected' and (:'s_bad4'::jsonb ->> 'status') = 'rejected'
              and (:'s_bad5'::jsonb ->> 'status') = 'rejected'
              and dog_log._setting((select doc from dog_log.state where owner_id = :H), 'dinnerTime') = '"17:00"',
                  '24 stale settings conflict; invalid times, counts and fields are rejected without writing');

-- transfer BEFORE Dinner (16:00 then 17:00), quantity 3
select pg_temp.reset_h(0, 5, '{}', '2026-09-11 07:00');
select pg_temp.ok(pg_temp.h_run('2026-09-11 17:30'), '24 custom schedule runs');
select pg_temp.ok(pg_temp.h_ev('2026-09-11', 'breakfast') = 'fed:freezer:-@07:30'
              and pg_temp.h_ev('2026-09-11', 'transfer') = 'transferred:-:3@16:00'
              and pg_temp.h_ev('2026-09-11', 'dinner') = 'fed:fridge:-@17:00'
              and pg_temp.h_stock() = '2/1',
                  '24 configured Breakfast 07:30, transfer 16:00 (3) and Dinner 17:00 run in time order; Dinner uses the transferred fridge stock');

-- transfer AFTER Dinner, freezer edge cases N / 1 / 0, and quantity 0
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"20:00","expected":"16:00"}', '2026-09-11 21:00') \g /dev/null
select pg_temp.reset_h(0, 5, '{}', '2026-09-12 16:00');
select pg_temp.ok(pg_temp.h_run('2026-09-12 20:30') and pg_temp.h_ev('2026-09-12', 'dinner') = 'fed:freezer:-@17:00'
              and pg_temp.h_ev('2026-09-12', 'transfer') = 'transferred:-:3@20:00' and pg_temp.h_stock() = '3/1',
                  '24 transfer after Dinner moves N=3 of the 4 remaining freezer containers');
select pg_temp.reset_h(2, 1, '{}', '2026-09-13 19:00');
select pg_temp.ok(pg_temp.h_run('2026-09-13 20:30') and pg_temp.h_ev('2026-09-13', 'transfer') = 'transferred:-:1@20:00' and pg_temp.h_stock() = '3/0',
                  '24 only 1 freezer container: 1 moves, total conserved');
select pg_temp.reset_h(2, 0, '{}', '2026-09-14 19:00');
select pg_temp.ok(pg_temp.h_run('2026-09-14 20:30') and pg_temp.h_ev('2026-09-14', 'transfer') = 'transferred:-:0@20:00' and pg_temp.h_stock() = '2/0'
              and pg_temp.h_hist(0) like '20:00 freezer-to-fridge transfer %: no Full Containers available in Freezer',
                  '24 empty freezer: nothing moves, counts stay non-negative, clearly recorded');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferCount","value":0,"expected":3}', '2026-09-14 21:00') \g /dev/null
select pg_temp.reset_h(0, 4, '{}', '2026-09-15 19:00');
select pg_temp.h_hist(0) as h_before_zero \gset
select pg_temp.ok(pg_temp.h_run('2026-09-15 20:30') and pg_temp.h_ev('2026-09-15', 'transfer') = 'transferred:-:0@20:00' and pg_temp.h_stock() = '0/4'
              and pg_temp.h_hist(0) = :'h_before_zero',
                  '24 daily transfer of 0 moves nothing and adds no history');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferCount","value":2,"expected":0}', '2026-09-15 21:00') \g /dev/null

-- changing a time after the slot ran never re-deducts or re-transfers
select pg_temp.reset_h(3, 3, '{}', '2026-09-16 07:00');
select pg_temp.ok(pg_temp.h_run('2026-09-16 07:45') and pg_temp.h_stock() = '2/3', '24 breakfast ran at 07:30');
select pg_temp.h_op('{"type":"settings","field":"breakfastTime","value":"10:00","expected":"07:30"}', '2026-09-16 08:00') \g /dev/null
select pg_temp.h_run('2026-09-16 10:30') \g /dev/null
select pg_temp.ok(pg_temp.h_stock() = '2/3' and pg_temp.h_ev('2026-09-16', 'breakfast') = 'fed:fridge:-@07:30',
                  '24 moving Breakfast later after it ran does not feed twice');
select pg_temp.ok(pg_temp.h_run('2026-09-16 20:30') and pg_temp.h_stock() = '3/1', '24 same day: Dinner 17:00 then transfer 20:00');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"22:00","expected":"20:00"}', '2026-09-16 20:45') \g /dev/null
select pg_temp.h_run('2026-09-16 22:30') \g /dev/null
select pg_temp.ok(pg_temp.h_stock() = '3/1' and pg_temp.h_ev('2026-09-16', 'transfer') = 'transferred:-:2@20:00',
                  '24 moving the transfer later after it ran does not transfer twice');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"20:00","expected":"22:00"}', '2026-09-16 22:45') \g /dev/null

-- WORK-147 legacy: a dinner row that already carried the day's transfer blocks a second one
select pg_temp.reset_h(2, 4, '{}', '2026-09-17 18:00');
insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, source_container, freezer_to_fridge_count, slot_at, origin)
values (:H, '2026-09-17', 'dinner', 'fed', 'fridge', 2, timestamptz '2026-09-17 18:00 Australia/Melbourne', 'server')
on conflict (owner_id, meal_date, slot) do update set freezer_to_fridge_count = 2;
select pg_temp.h_run('2026-09-17 20:30') \g /dev/null
select pg_temp.ok(pg_temp.h_ev('2026-09-17', 'transfer') is null and pg_temp.h_stock() = '2/4',
                  '24 a WORK-147 Dinner transfer is never repeated when the transfer time moves later');

-- multi-day catch-up with custom times; totals conserved (only meals consume)
select pg_temp.reset_h(1, 20, '{}', '2026-09-18 06:00');
select pg_temp.ok(pg_temp.h_run('2026-09-21 06:00'), '24 three-day catch-up runs');
select pg_temp.ok((select count(*) filter (where slot <> 'transfer') from dog_log.meal_events where owner_id = :H and slot_at > timestamptz '2026-09-18 06:00 Australia/Melbourne') = 6
              and (select count(*) filter (where slot = 'transfer') from dog_log.meal_events where owner_id = :H and slot_at > timestamptz '2026-09-18 06:00 Australia/Melbourne') = 3
              and pg_temp.h_stock() = '2/13',
                  '24 catch-up (Breakfast 10:00, Dinner 17:00, transfer 20:00): 6 meals and 3 transfers, 21 - 6 = 15 Full Containers');
select pg_temp.ok(pg_temp.h_hist(0) = 'Scheduled meals caught up: 6 meals, 6 Full Containers used'
              or pg_temp.h_hist(0) like '20:00 freezer-to-fridge transfer %',
                  '24 catch-up history recorded');
select pg_temp.reset_h(1, 20, '{}', '2026-09-18 06:00');
delete from dog_log.meal_events where owner_id = :H and slot_at > timestamptz '2026-09-18 06:00 Australia/Melbourne';
select pg_temp.ok(pg_temp.h_run('2026-09-22 06:00')
              and pg_temp.h_hist(0) = 'Scheduled meals caught up: 8 meals, 8 Full Containers used'
              and pg_temp.h_hist(1) = 'Automatic 20:00 freezer-to-fridge transfers caught up: 8 Full Containers moved across 4 days',
                  '24 long catch-up summarises meals and configured-time transfers');

-- recount rebasing and restore replay include transfer rows; equal-time restore replays Dinner first
select dog_log._apply_op(:H, jsonb_build_object('type','set','key','fridge','value',3,'expected',0),
  timestamptz '2026-09-21 18:30 Australia/Melbourne', (select revision from dog_log.state where owner_id = :H)) as h_rc \gset
select pg_temp.ok((:'h_rc'::jsonb ->> 'status') = 'applied' and (:'h_rc'::jsonb #>> '{detail,transferred_since}')::int = 2
              and (:'h_rc'::jsonb #>> '{detail,fed_since}')::int = 0 and pg_temp.h_stock() = '5/11',
                  '24 fridge recount taken before a 20:00 transfer is rebased by that transfer');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"18:00","expected":"20:00"}', '2026-09-22 06:30') \g /dev/null
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"18:00","expected":"17:00"}', '2026-09-22 06:30') \g /dev/null
select pg_temp.reset_h(0, 3, '{}', '2026-09-22 17:00');
select pg_temp.h_run('2026-09-22 18:30') \g /dev/null
select dog_log._apply_op(:H, jsonb_build_object('type','replace_state','reason','restore-backup',
  'expected_revision', (select revision from dog_log.state where owner_id = :H),
  'doc', '{"stock":{"fridge":0,"freezer":3},"settings":{"dinnerTime":"18:00","fridgeTransferTime":"18:00"}}'::jsonb,
  'subtract_meals_since', true, 'backup_created_at', '2026-09-22 17:30 Australia/Melbourne'),
  now(), (select revision from dog_log.state where owner_id = :H)) as h_rs \gset
select pg_temp.ok((:'h_rs'::jsonb ->> 'status') = 'applied' and pg_temp.h_stock() = '2/0',
                  '24 restore replays the equal-time Dinner before its transfer (fridge 2, freezer 0)');

-- the settings operation through the client RPC, and recent_meals exposes transfer rows
:asH
select dog_log.sync(jsonb_build_array(jsonb_build_object('mutation_id', gen_random_uuid(), 'type', 'settings', 'field', 'breakfastTime',
  'value', '08:15', 'expected', '09:00', 'client_created_at', now(), 'label', 'Food settings updated: Breakfast time 08:15')), 'dev-h', 1) as h_sync \gset
:asOwner
select pg_temp.ok((:'h_sync'::jsonb -> 'results' -> 0 ->> 'status') = 'applied'
              and (:'h_sync'::jsonb #>> '{doc,settings,breakfastTime}') = '08:15',
                  '24 Food settings sync through dog_log.sync');
select pg_temp.ok(exists (select 1 from jsonb_array_elements((select dog_log._state_json(:H)) -> 'recent_meals') m
                           where m ->> 'slot' = 'transfer' and m ? 'freezer_to_fridge_count'),
                  '24 recent_meals includes transfer events with their counts');

-- Breakfast must be before Dinner: enforced on write, and a stored pair that is not falls back to the defaults
select pg_temp.reset_h(3, 5, '{"breakfastTime":"08:15","dinnerTime":"18:00","fridgeTransferTime":"12:00","fridgeTransferCount":2}', '2026-09-23 07:00');
select pg_temp.h_op('{"type":"settings","field":"breakfastTime","value":"19:00","expected":"08:15"}', '2026-09-23 07:05') as bd1 \gset
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"08:15","expected":"18:00"}', '2026-09-23 07:05') as bd2 \gset
select pg_temp.ok((:'bd1'::jsonb ->> 'status') = 'rejected' and (:'bd2'::jsonb ->> 'status') = 'rejected'
              and (:'bd1'::jsonb #>> '{detail,reason}') = 'Breakfast must be before Dinner'
              and dog_log._setting((select doc from dog_log.state where owner_id = :H), 'breakfastTime') = '"08:15"'
              and dog_log._setting((select doc from dog_log.state where owner_id = :H), 'dinnerTime') = '"18:00"',
                  '24 Breakfast at or after Dinner is rejected without writing');
select pg_temp.ok(dog_log._setting('{"settings":{"breakfastTime":"19:00","dinnerTime":"08:00"}}', 'breakfastTime') = '"09:00"'
              and dog_log._setting('{"settings":{"breakfastTime":"19:00","dinnerTime":"08:00"}}', 'dinnerTime') = '"18:00"'
              and dog_log._norm_doc('{"settings":{"breakfastTime":"12:00","dinnerTime":"12:00"}}') -> 'settings'
                  @> '{"breakfastTime":"09:00","dinnerTime":"18:00"}'::jsonb,
                  '24 a stored Breakfast/Dinner pair out of order reads as 09:00 / 18:00 (as the client)');

-- A slot moved to before the cursor on a day that has not had it yet runs at once, exactly once
select pg_temp.ok(pg_temp.h_run('2026-09-23 13:00') and pg_temp.h_stock() = '4/3'
              and pg_temp.h_ev('2026-09-23', 'transfer') = 'transferred:-:2@12:00',
                  '24 Breakfast 08:15 then transfer 12:00 ran');
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"11:00","expected":"18:00"}', '2026-09-23 13:00') as late1 \gset
select pg_temp.ok((:'late1'::jsonb ->> 'status') = 'applied' and (:'late1'::jsonb #>> '{detail,ran_now}') = 'dinner'
              and pg_temp.h_ev('2026-09-23', 'dinner') = 'fed:fridge:-@11:00' and pg_temp.h_stock() = '3/3'
              and pg_temp.h_hist(0) like 'Dinner %: 1 Full Container used (fridge)',
                  '24 Dinner moved to 11:00 after the 12:00 transfer ran: that day''s Dinner is fed at once');
select pg_temp.ok(not pg_temp.h_run('2026-09-23 23:00') and pg_temp.h_stock() = '3/3', '24 nothing else is due that day');
select pg_temp.h_op('{"type":"settings","field":"dinnerTime","value":"19:00","expected":"11:00"}', '2026-09-23 23:10') as late2 \gset
select pg_temp.h_run('2026-09-23 23:30') \g /dev/null
select pg_temp.ok((:'late2'::jsonb #>> '{detail,ran_now}') is null and pg_temp.h_stock() = '3/3'
              and pg_temp.h_ev('2026-09-23', 'dinner') = 'fed:fridge:-@11:00',
                  '24 moving that Dinner later again never feeds twice');
select pg_temp.reset_h(2, 4, '{"dinnerTime":"18:00","fridgeTransferTime":"20:00"}', '2026-09-24 17:00');
select pg_temp.ok(pg_temp.h_run('2026-09-24 18:30') and pg_temp.h_stock() = '1/4', '24 Dinner 18:00 ran; transfer 20:00 pending');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"17:00","expected":"20:00"}', '2026-09-24 18:45') as late3 \gset
select pg_temp.ok((:'late3'::jsonb #>> '{detail,ran_now}') = 'transfer'
              and pg_temp.h_ev('2026-09-24', 'transfer') = 'transferred:-:2@17:00' and pg_temp.h_stock() = '3/2',
                  '24 transfer moved to 17:00 after Dinner ran: that day''s transfer runs at once');
select pg_temp.ok(not pg_temp.h_run('2026-09-24 21:00') and pg_temp.h_stock() = '3/2', '24 and never again that day');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"16:00","expected":"17:00"}', '2026-09-24 21:05') as late4 \gset
select pg_temp.ok((:'late4'::jsonb #>> '{detail,ran_now}') is null and pg_temp.h_stock() = '3/2',
                  '24 moving an already-run transfer earlier again does not repeat it');
select pg_temp.h_op('{"type":"settings","field":"fridgeTransferTime","value":"20:00","expected":"16:00"}', '2026-09-24 21:10') \g /dev/null

-- seeding imports the device's transfer log; a pre-WORK-148 device's Dinner closes that day's transfer
\set I '''49494949-0000-4000-8000-000000000049'''
\set J '''50505050-0000-4000-8000-000000000050'''
insert into auth.users (id, email) values (:I, 'i@test.invalid'), (:J, 'j@test.invalid');
select to_char((now() - interval '1 day') at time zone 'Australia/Melbourne', 'YYYY-MM-DD') as yday \gset
select to_char(now() at time zone 'Australia/Melbourne', 'YYYY-MM-DD') as tday \gset
:asOwner
select (extract(epoch from now() - interval '1 minute') * 1000)::bigint as seed_cursor \gset
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"49494949-0000-4000-8000-000000000049","role":"authenticated"}', true) \g /dev/null
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', '{"fridge":2}'::jsonb,
  'tracking', jsonb_build_object('mealCursor', :seed_cursor,
                                 'mealLog', jsonb_build_object(:'yday', '{"breakfast":"fed","dinner":"fed"}'::jsonb))), 'dev-i', 1) \g /dev/null
-- J: a WORK-148 device. Today's transfer ran, then its time moved to 23:59 (after the cursor):
-- it is still imported, capped at the cursor, so it can never run again today.
select set_config('request.jwt.claims', '{"sub":"50505050-0000-4000-8000-000000000050","role":"authenticated"}', true) \g /dev/null
select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', '{"fridge":2}'::jsonb,
  'settings', '{"fridgeTransferTime":"23:59"}'::jsonb,
  'tracking', jsonb_build_object('mealCursor', :seed_cursor,
                                 'mealLog', jsonb_build_object(:'yday', '{"breakfast":"fed","dinner":"fed"}'::jsonb),
                                 'transferLog', jsonb_build_object(:'yday', '{"outcome":"processed","moved":2}'::jsonb,
                                                                   :'tday', '{"outcome":"processed","moved":1}'::jsonb))), 'dev-j', 1) \g /dev/null
:asOwner
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :I and origin = 'seed' and slot = 'transfer') = 1
              and (select count(*) from dog_log.meal_events where owner_id = :I and origin = 'seed') = 3,
                  '24 seed from a pre-WORK-148 device: each imported Dinner closes that day''s transfer');
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :J and origin = 'seed' and slot = 'transfer') = 2
              and (select freezer_to_fridge_count from dog_log.meal_events where owner_id = :J and meal_date = :'yday'::date and slot = 'transfer') = 2
              and (select slot_at from dog_log.meal_events where owner_id = :J and meal_date = :'tday'::date and slot = 'transfer')
                  = to_timestamp(:seed_cursor / 1000.0),
                  '24 seed imports the WORK-148 transferLog (moved counts kept; slot_at capped at the device cursor)');
select pg_temp.ok(not (dog_log._run_event(:J, (select doc from dog_log.state where owner_id = :J), :'tday'::date, 'transfer',
                                           now(), 'Australia/Melbourne', 'dev-j', 2) ->> 'ran')::boolean
              and (select doc #>> '{stock,fridge}' from dog_log.state where owner_id = :J) = '2',
                  '24 an imported transfer never runs again that day');

select 'ALL DOG_LOG SQL TESTS PASSED';
rollback;
