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
\set asNoJwt 'set local role authenticated; select set_config(''request.jwt.claims'', '''', true) \\g /dev/null'
\set asAnon 'set local role anon; select set_config(''request.jwt.claims'', ''{"role":"anon"}'', true) \\g /dev/null'
\set asOwner 'reset role; select set_config(''request.jwt.claims'', '''', true) \\g /dev/null'

insert into auth.users (id, email) values
  (:A, 'a@test.invalid'), (:B, 'b@test.invalid'), (:D, 'd@test.invalid'), (:E, 'e@test.invalid');

-- ---------------------------------------------------------------- 1. install
select pg_temp.ok((select count(*) from pg_tables where schemaname = 'dog_log') = 4, '01 four dog_log tables exist');
select pg_temp.ok((select bool_and(relrowsecurity) from pg_class where relnamespace = 'dog_log'::regnamespace and relkind = 'r'), '01 RLS enabled on every table');
select pg_temp.ok(to_regprocedure('dog_log.seed_state(uuid,jsonb,text,integer)') is not null
              and to_regprocedure('dog_log.sync(jsonb,text,integer)') is not null, '01 client RPCs exist');
select pg_temp.ok((select prosecdef from pg_proc where oid = 'dog_log.sync(jsonb,text,integer)'::regprocedure)
              and (select prosecdef from pg_proc where oid = 'dog_log.seed_state(uuid,jsonb,text,integer)'::regprocedure), '01 client RPCs are SECURITY DEFINER');
select pg_temp.ok(not exists (select 1 from pg_proc where pronamespace = 'dog_log'::regnamespace
                                 and not coalesce(proconfig @> array['search_path=""'], false)), '01 every dog_log function pins search_path=''''');
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
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :A and origin = 'seed') = 2, '04 recent device mealLog imported as seed events');
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
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :A and origin = 'server') = :expected_due,
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
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :E and origin = 'server') = 6, '17 six slots processed (Fri D .. Mon B)');
select pg_temp.ok((select slot_at from dog_log.meal_events where owner_id = :E and meal_date = '2025-10-04' and slot = 'breakfast') = timestamptz '2025-10-03 23:00:00+00'
              and (select slot_at from dog_log.meal_events where owner_id = :E and meal_date = '2025-10-05' and slot = 'breakfast') = timestamptz '2025-10-04 22:00:00+00',
                  '17 09:00 Melbourne is correct on both sides of DST start (AEST/AEDT)');
select pg_temp.ok(dog_log._slot_at('2026-04-05', 'breakfast', 'Australia/Melbourne') = timestamptz '2026-04-04 23:00:00+00'
              and dog_log._slot_at('2026-04-04', 'dinner', 'Australia/Melbourne') = timestamptz '2026-04-04 07:00:00+00',
                  '17 slot times correct across DST end');
select pg_temp.ok((select string_agg(slot || ':' || outcome || ':' || coalesce(source_container, '-'), ',' order by slot_at)
                     from dog_log.meal_events where owner_id = :E and origin = 'server')
                  = 'dinner:fed:fridge,breakfast:fed:fridge,dinner:fed:fridge,breakfast:fed:freezer,dinner:fed:freezer,breakfast:no-stock:-',
                  '18 fridge first, then freezer, then no-stock');
select pg_temp.ok((select (doc #>> '{stock,fridge}')::int + (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = :E) = 0,
                  '18 exactly one Full Container per fed slot');
select pg_temp.ok((select doc #>> '{history,0,action}' from dog_log.state where owner_id = :E) = 'Breakfast Mon 6 Oct 2025: no Full Container available'
              and (select doc #>> '{history,1,action}' from dog_log.state where owner_id = :E) = 'Dinner Sun 5 Oct 2025: 1 Full Container used (freezer)',
                  '18 history text matches WORK-135 wording (year shown for a past year)');
select pg_temp.ok(not dog_log._process_due_meals(:E, timestamptz '2025-10-06 12:00 Australia/Melbourne', 'retry'), '19 retrying the same window reports no change');
select pg_temp.ok((select count(*) from dog_log.meal_events where owner_id = :E and origin = 'server') = 6, '19 retrying the same window adds no events');
do $$ begin
  insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, origin)
  values ('eeeeeeee-0000-4000-8000-00000000000e', '2025-10-05', 'dinner', 'no-stock', now(), 'server');
  raise exception 'FAIL: duplicate meal identity accepted';
exception when unique_violation then raise notice 'ok   19 database rejects a second event for the same owner/date/slot';
end $$;
select pg_temp.ok((select count(distinct slot) from dog_log.meal_events where owner_id = :E and meal_date = '2025-10-05') = 2,
                  '20 breakfast and dinner of the same day are independent identities');
select pg_temp.ok(dog_log._process_due_meals(:E, timestamptz '2025-10-10 12:00 Australia/Melbourne', 'test'), '20 long catch-up runs');
select pg_temp.ok((select doc #>> '{history,0,action}' from dog_log.state where owner_id = :E) = 'Scheduled meals caught up: 8 meals, 0 Full Containers used',
                  '20 more than 6 slots collapse into one summary line');
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

select 'ALL DOG_LOG SQL TESTS PASSED';
rollback;
