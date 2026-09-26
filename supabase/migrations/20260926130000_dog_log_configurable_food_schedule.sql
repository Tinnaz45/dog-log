-- =============================================================================
-- WORK-148: configurable Food Settings (meal times, freezer-to-fridge transfer,
-- storage capacities).
--
-- * doc.settings gains maxFreezerContainers (default 70), maxFridgeContainers
--   (default null = not set), fridgeTransferCount (default 2), fridgeTransferTime
--   (default '18:00'), breakfastTime (default '09:00') and dinnerTime (default
--   '18:00'). Documents without them (every existing cloud row and old backups)
--   read as the defaults, so owners who change nothing keep 09:00 / 18:00 meals
--   and a 2-container 18:00 transfer.
-- * The freezer-to-fridge transfer becomes its own scheduled event with a durable
--   server identity: a meal_events row with slot = 'transfer' under the existing
--   (owner_id, meal_date, slot) primary key. It is processed at its configured
--   time, independent of Dinner; at an equal time Dinner is processed first.
-- * Days whose Dinner already carried a WORK-147 transfer (dinner row with a
--   non-null freezer_to_fridge_count) never get a second transfer.
-- * Setting changes are applied between meal-processing steps in time order, so
--   they only shape future slots; the primary key keeps every slot of a day
--   exactly-once even when its time moves.
-- * Capacities are configuration only: stock is never clamped to them.
--
-- Applying is a separate, operator-approved act (ENVIRONMENT_LIFECYCLE 10).
-- Rollback: supabase/rollbacks/20260926130000_dog_log_configurable_food_schedule.rollback.sql
-- =============================================================================

-- ---------------------------------------------------------------- meal_events
-- Replace the single-column checks on slot / outcome / freezer_to_fridge_count
-- (auto-named by earlier migrations) with named WORK-148 checks.
do $$
declare c record;
begin
  for c in
    select con.conname
      from pg_catalog.pg_constraint con
     where con.conrelid = 'dog_log.meal_events'::regclass and con.contype = 'c'
       and cardinality(con.conkey) = 1
       and con.conkey[1] in (select attnum from pg_catalog.pg_attribute
                              where attrelid = 'dog_log.meal_events'::regclass
                                and attname in ('slot', 'outcome', 'freezer_to_fridge_count'))
  loop
    execute format('alter table dog_log.meal_events drop constraint %I', c.conname);
  end loop;
end; $$;

-- Re-runnable after the WORK-148 rollback, which keeps these named checks.
alter table dog_log.meal_events
  drop constraint if exists meal_events_slot_check,
  drop constraint if exists meal_events_outcome_check,
  drop constraint if exists meal_events_slot_outcome_check,
  drop constraint if exists meal_events_freezer_to_fridge_count_check;
alter table dog_log.meal_events
  add constraint meal_events_slot_check check (slot in ('breakfast', 'dinner', 'transfer')),
  add constraint meal_events_outcome_check check (outcome in ('fed', 'no-stock', 'before-tracking', 'transferred')),
  add constraint meal_events_slot_outcome_check check (
    case when slot = 'transfer' then outcome in ('transferred', 'before-tracking') and source_container is null
         else outcome <> 'transferred' end),
  add constraint meal_events_freezer_to_fridge_count_check check (freezer_to_fridge_count between 0 and 100);

comment on column dog_log.meal_events.freezer_to_fridge_count is
  'Full Containers moved Freezer to Fridge. WORK-147 dinner rows: moved inside Dinner (0..2). WORK-148 transfer rows: moved by the daily transfer. NULL = no transfer recorded on this row.';
comment on table dog_log.meal_events is
  'Exactly-once scheduled events: one row per owner + Australia/Melbourne date + slot (breakfast, dinner, transfer).';

-- -------------------------------------------------------------------- helpers
-- Effective (defaulted, validated) value of a WORK-148 Food setting, as jsonb.
create or replace function dog_log._setting(p_doc jsonb, p_field text)
returns jsonb language plpgsql immutable set search_path = pg_catalog, pg_temp as $$
declare
  v   jsonb := p_doc -> 'settings' -> p_field;
  n   numeric;
  lim numeric := case p_field when 'fridgeTransferCount' then 100 else 1000000 end;
  b   text;
  d   text;
begin
  if p_field in ('breakfastTime', 'dinnerTime') then
    -- Breakfast must come before Dinner; otherwise both read as the defaults (client: sched()).
    b := dog_log._setting(p_doc, 'breakfastTimeRaw') #>> '{}';
    d := dog_log._setting(p_doc, 'dinnerTimeRaw') #>> '{}';
    if b >= d then b := '09:00'; d := '18:00'; end if;
    return to_jsonb(case p_field when 'breakfastTime' then b else d end);
  end if;
  if p_field in ('breakfastTimeRaw', 'dinnerTimeRaw', 'fridgeTransferTime') then
    v := p_doc -> 'settings' -> replace(p_field, 'Raw', '');
    if jsonb_typeof(v) = 'string' and (v #>> '{}') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      return v;
    end if;
    return to_jsonb(case p_field when 'breakfastTimeRaw' then '09:00' else '18:00' end);
  end if;
  if p_field in ('fridgeTransferCount', 'maxFreezerContainers', 'maxFridgeContainers') then
    if jsonb_typeof(v) = 'number' then
      n := (v #>> '{}')::numeric;
      -- (plpgsql ends an IF condition at the first THEN, so no CASE inside it)
      if n = round(n) and n >= 0 and n <= lim then
        return to_jsonb(round(n));
      end if;
    end if;
    return case p_field when 'fridgeTransferCount' then '2'::jsonb
                        when 'maxFreezerContainers' then '70'::jsonb
                        else 'null'::jsonb end;
  end if;
  return null;
end; $$;

-- Configured local time of a scheduled slot.
create or replace function dog_log._sched_time(p_doc jsonb, p_slot text)
returns time language sql stable set search_path = pg_catalog, pg_temp as $$
  select (dog_log._setting(p_doc, case p_slot when 'breakfast' then 'breakfastTime'
                                              when 'dinner' then 'dinnerTime'
                                              else 'fridgeTransferTime' end) #>> '{}')::time
$$;

-- Convert (never reject) a client doc into the canonical server shape (R10).
-- WORK-148: also carries the Food settings, defaulting absent or invalid ones.
create or replace function dog_log._norm_doc(p jsonb)
returns jsonb language plpgsql stable set search_path = pg_catalog, pg_temp as $$
declare
  s        jsonb := case when jsonb_typeof(p -> 'stock') = 'object' then p -> 'stock' else '{}'::jsonb end;
  st       jsonb := case when jsonb_typeof(p -> 'settings') = 'object' then p -> 'settings' else '{}'::jsonb end;
  tr       jsonb := case when jsonb_typeof(p -> 'tracking') = 'object' then p -> 'tracking' else '{}'::jsonb end;
  cal      jsonb := case when jsonb_typeof(p -> 'calendar') = 'object' then p -> 'calendar' else '{}'::jsonb end;
  necks    jsonb := coalesce(nullif(s -> 'neckPackets', 'null'::jsonb), s -> 'neckBags');
  sd       jsonb := jsonb_build_object('settings', st);
  batches  jsonb;
  history  jsonb;
  inc      numeric;
  endpoint text;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'at',              case when jsonb_typeof(b -> 'at') = 'string' then left(b ->> 'at', 40) else null end,
           'containers',      dog_log._kg(dog_log._num(b -> 'containers')),
           'minceUsedKg',     dog_log._kg(dog_log._num(b -> 'minceUsedKg')),
           'neckPacketsUsed', dog_log._kg(dog_log._num(b -> 'neckPacketsUsed')),
           'minceLeftKg',     dog_log._kg(dog_log._num(b -> 'minceLeftKg')),
           'neckPacketsLeft', dog_log._kg(dog_log._num(b -> 'neckPacketsLeft'))
         ) order by ord), '[]'::jsonb)
    into batches
    from (select b, ord from jsonb_array_elements(case when jsonb_typeof(p -> 'batches') = 'array' then p -> 'batches' else '[]'::jsonb end)
                 with ordinality as t(b, ord)
           where jsonb_typeof(b) = 'object' order by ord limit 50) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'at',     case when jsonb_typeof(h -> 'at') = 'string' then left(h ->> 'at', 40) else null end,
           'action', left(h ->> 'action', 500)
         ) order by ord), '[]'::jsonb)
    into history
    from (select h, ord from jsonb_array_elements(case when jsonb_typeof(p -> 'history') = 'array' then p -> 'history' else '[]'::jsonb end)
                 with ordinality as t(h, ord)
           where jsonb_typeof(h) = 'object' and jsonb_typeof(h -> 'action') = 'string' order by ord limit 150) x;

  inc := dog_log._kg(dog_log._num(st -> 'mincePurchaseIncrementKg', 0.5));
  if inc = 0 then inc := 0.5; end if;          -- client: Number(x)||.5
  inc := least(greatest(0.1, inc), 1000);      -- client: Math.max(.1, ...); bounded
  endpoint := case when jsonb_typeof(cal -> 'endpoint') = 'string'
                     and (cal ->> 'endpoint') ~ '^https://script\.google\.com/macros/s/[^/\s]+/exec$'
                     and length(cal ->> 'endpoint') <= 500
                   then cal ->> 'endpoint' else '' end;

  return jsonb_build_object(
    'stock', jsonb_build_object(
      'fridge',         dog_log._count(dog_log._num(s -> 'fridge')),
      'freezer',        dog_log._count(dog_log._num(s -> 'freezer')),
      'minceKg',        dog_log._kg(dog_log._num(s -> 'minceKg')),
      'neckPackets',    dog_log._count(dog_log._num(necks)),
      'necksOnly',      dog_log._count(dog_log._num(s -> 'necksOnly')),
      'minceOnly',      dog_log._count(dog_log._num(s -> 'minceOnly')),
      'lykaPackets',    dog_log._count(dog_log._num(s -> 'lykaPackets')),
      'scratchPackets', dog_log._count(dog_log._num(s -> 'scratchPackets'))),
    'settings', jsonb_build_object(
      'totalContainers',          round(least(greatest(dog_log._num(st -> 'totalContainers', 40), 0), 1000000), 2),
      'mincePurchaseIncrementKg', inc,
      'maxFreezerContainers',     dog_log._setting(sd, 'maxFreezerContainers'),
      'maxFridgeContainers',      dog_log._setting(sd, 'maxFridgeContainers'),
      'fridgeTransferCount',      dog_log._setting(sd, 'fridgeTransferCount'),
      'fridgeTransferTime',       dog_log._setting(sd, 'fridgeTransferTime'),
      'breakfastTime',            dog_log._setting(sd, 'breakfastTime'),
      'dinnerTime',               dog_log._setting(sd, 'dinnerTime')),
    'batches',  batches,
    'history',  history,
    'calendar', jsonb_build_object('endpoint', endpoint),
    'legacy',   jsonb_build_object(
      'containersPerDay', case when jsonb_typeof(st -> 'containersPerDay') = 'number' then to_jsonb(dog_log._num(st -> 'containersPerDay')) else '2'::jsonb end,
      'lastAutoDate',     case when jsonb_typeof(tr -> 'lastAutoDate') = 'string' then to_jsonb(left(tr ->> 'lastAutoDate', 40)) else 'null'::jsonb end));
end; $$;

-- ------------------------------------------------------ scheduled-event engine
-- Runs one scheduled event (a meal or the daily transfer) exactly once: its stock
-- effect happens only when the meal_events primary-key insert succeeds. A day whose
-- WORK-147 Dinner already carried a transfer never gets a second one. Returns
-- {doc, ran, meal, fed, moved, want, entry}; entry is the history line (null for a
-- transfer configured to move 0). Caller holds the state row lock.
create or replace function dog_log._run_event(p_owner uuid, p_doc jsonb, p_day date, p_slot text, p_at timestamptz,
                                              p_tz text, p_device text, p_revision bigint)
returns jsonb language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare
  v_doc     jsonb := p_doc;
  v_fridge  numeric := coalesce((p_doc #>> '{stock,fridge}')::numeric, 0);
  v_freezer numeric := coalesce((p_doc #>> '{stock,freezer}')::numeric, 0);
  v_want    numeric;
  v_move    numeric;
  v_ins     int := 0;
  v_outcome text;
  v_source  text;
  v_label   text;
  v_entry   text;
begin
  if p_slot = 'transfer' then
    if exists (select 1 from dog_log.meal_events
                where owner_id = p_owner and meal_date = p_day and slot = 'dinner'
                  and freezer_to_fridge_count is not null) then
      return jsonb_build_object('doc', v_doc, 'ran', false);
    end if;
    v_want := (dog_log._setting(p_doc, 'fridgeTransferCount') #>> '{}')::numeric;
    v_move := least(greatest(v_freezer, 0), v_want);
    insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, freezer_to_fridge_count, slot_at, processed_by_device, state_revision, origin)
    values (p_owner, p_day, 'transfer', 'transferred', v_move::smallint, p_at, p_device, p_revision, 'server')
    on conflict do nothing;
    get diagnostics v_ins = row_count;
    if v_ins = 0 then return jsonb_build_object('doc', v_doc, 'ran', false); end if;
    if v_move > 0 then
      v_doc := jsonb_set(v_doc, '{stock,freezer}', to_jsonb(v_freezer - v_move));
      v_doc := jsonb_set(v_doc, '{stock,fridge}',  to_jsonb(v_fridge + v_move));
    end if;
    if v_want > 0 then
      v_label := to_char(p_at at time zone p_tz, 'HH24:MI') || ' freezer-to-fridge transfer ' || dog_log._fmt_day(p_at, p_tz);
      v_entry := v_label || case when v_move = 0 then ': no Full Containers available in Freezer'
                                 when v_move = 1 then ': 1 Full Container moved from Freezer to Fridge'
                                 else ': ' || v_move::bigint || ' Full Containers moved from Freezer to Fridge' end;
    end if;
    return jsonb_build_object('doc', v_doc, 'ran', true, 'meal', false, 'fed', false,
                              'moved', v_move, 'want', v_want, 'entry', v_entry);
  end if;

  if v_fridge + v_freezer > 0 then
    v_outcome := 'fed';
    v_source  := case when v_fridge > 0 then 'fridge' else 'freezer' end;
  else
    v_outcome := 'no-stock';
    v_source  := null;
  end if;
  insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, source_container, slot_at, processed_by_device, state_revision, origin)
  values (p_owner, p_day, p_slot, v_outcome, v_source, p_at, p_device, p_revision, 'server')
  on conflict do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then return jsonb_build_object('doc', v_doc, 'ran', false); end if;
  v_label := case p_slot when 'breakfast' then 'Breakfast' else 'Dinner' end || ' ' || dog_log._fmt_day(p_at, p_tz);
  if v_outcome = 'fed' then
    -- client deductPrepared(1): fridge first, remainder from freezer
    v_doc := jsonb_set(v_doc, '{stock,fridge}', to_jsonb(greatest(v_fridge - least(v_fridge, 1), 0)));
    if v_fridge < 1 then
      v_doc := jsonb_set(v_doc, '{stock,freezer}', to_jsonb(greatest(v_freezer - least(v_freezer, 1 - v_fridge), 0)));
    end if;
    v_entry := v_label || ': 1 Full Container used (' || v_source || ')';
  else
    v_entry := v_label || ': no Full Container available';
  end if;
  return jsonb_build_object('doc', v_doc, 'ran', true, 'meal', true, 'fed', v_outcome = 'fed', 'moved', 0, 'entry', v_entry);
end $$;

-- Processes every scheduled event in (meal_cursor, p_until] exactly once, using the
-- configured times. Each day's events run in time order; at an equal time the order
-- is Breakfast, Dinner, then the transfer. Caller holds the state row lock.
create or replace function dog_log._process_due_meals(p_owner uuid, p_until timestamptz, p_device text)
returns boolean language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare
  r           dog_log.state%rowtype;
  v_doc       jsonb;
  v_tz        text;
  v_from      timestamptz;
  v_cursor    timestamptz;
  v_day       date;
  v_slot      text;
  v_slots     text[];
  v_at        timestamptz;
  v_res       jsonb;
  v_entries   text[] := '{}';
  v_fed       int := 0;
  v_meals     int := 0;
  v_transfers int := 0;
  v_moved     numeric := 0;
  v_ttime     text;
  v_changed   boolean := false;
begin
  if (select auth.uid()) is not null and (select auth.uid()) <> p_owner then
    raise exception 'owner_mismatch' using errcode = '42501';
  end if;
  if p_until > now() then
    raise exception 'meal processing time is in the future' using errcode = '22023';
  end if;

  select * into r from dog_log.state where owner_id = p_owner for update;
  if not found then return false; end if;
  v_doc := r.doc; v_tz := r.time_zone; v_cursor := r.meal_cursor;
  v_ttime := dog_log._setting(v_doc, 'fridgeTransferTime') #>> '{}';
  select array_agg(x.s order by dog_log._sched_time(v_doc, x.s), x.o) into v_slots
    from (values ('breakfast', 0), ('dinner', 1), ('transfer', 2)) x(s, o);

  -- First run (WORK-135): start tracking now; today's already-passed slots are 'before-tracking'.
  if v_cursor is null then
    v_day := (p_until at time zone v_tz)::date;
    foreach v_slot in array v_slots loop
      v_at := (v_day + dog_log._sched_time(v_doc, v_slot)) at time zone v_tz;
      if v_at <= p_until then
        insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, processed_by_device, state_revision, origin)
        values (p_owner, v_day, v_slot, 'before-tracking', v_at, p_device, r.revision + 1, 'server')
        on conflict do nothing;
      end if;
    end loop;
    v_doc := dog_log._history_push(v_doc, now(),
      'Meal schedule started: Breakfast ' || (dog_log._setting(v_doc, 'breakfastTime') #>> '{}') ||
      ' and Dinner ' || (dog_log._setting(v_doc, 'dinnerTime') #>> '{}') ||
      ' each use 1 Full Container. Existing stock kept as recorded.');
    update dog_log.state
       set doc = v_doc, meal_cursor = p_until, meal_tracking_since = coalesce(meal_tracking_since, p_until)
     where owner_id = p_owner;
    return true;
  end if;

  if p_until <= v_cursor then return false; end if;
  -- Bound the catch-up walk (at most ~1200 events) so a corrupt or ancient cursor can
  -- never make every sync time out; older slots are beyond meal_events retention anyway.
  -- v_from stays fixed for the walk, so events sharing a time (Dinner and the transfer) are all due.
  v_from := greatest(v_cursor, p_until - interval '400 days');

  for v_day in select d::date from generate_series((v_from at time zone v_tz)::date, (p_until at time zone v_tz)::date, interval '1 day') d loop
    foreach v_slot in array v_slots loop
      v_at := (v_day + dog_log._sched_time(v_doc, v_slot)) at time zone v_tz;
      continue when v_at <= v_from or v_at > p_until;
      v_res := dog_log._run_event(p_owner, v_doc, v_day, v_slot, v_at, v_tz, p_device, r.revision + 1);
      v_doc := v_res -> 'doc';
      if (v_res ->> 'ran')::boolean then
        if (v_res ->> 'meal')::boolean then
          v_meals := v_meals + 1;
          if (v_res ->> 'fed')::boolean then v_fed := v_fed + 1; end if;
        elsif (v_res ->> 'want')::numeric > 0 then
          v_transfers := v_transfers + 1;
          v_moved := v_moved + (v_res ->> 'moved')::numeric;
        end if;
        if v_res ->> 'entry' is not null then v_entries := v_entries || (v_res ->> 'entry'); end if;
      end if;
      v_cursor := greatest(v_cursor, v_at);  -- the cursor advances past every due slot, processed or not
      v_changed := true;
    end loop;
  end loop;

  if v_meals > 6 then
    -- Push the transfer summary first so the meal catch-up summary remains the newest entry.
    if v_transfers > 0 then
      v_doc := dog_log._history_push(v_doc, now(),
        'Automatic ' || v_ttime || ' freezer-to-fridge transfers caught up: ' || v_moved::bigint ||
        ' Full Containers moved across ' || v_transfers || ' days');
    end if;
    v_doc := dog_log._history_push(v_doc, now(),
      'Scheduled meals caught up: ' || v_meals || ' meals, ' || v_fed || ' Full Containers used');
  else
    for i in 1 .. coalesce(cardinality(v_entries), 0) loop
      v_doc := dog_log._history_push(v_doc, now(), v_entries[i]);
    end loop;
  end if;

  if v_changed then
    update dog_log.state set doc = v_doc, meal_cursor = v_cursor where owner_id = p_owner;
  end if;
  return v_changed;
end; $$;

-- ----------------------------------------------------------------- operations
create or replace function dog_log._apply_op(p_owner uuid, p_op jsonb, p_cc timestamptz, p_start_revision bigint)
returns jsonb language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare
  r          dog_log.state%rowtype;
  v_doc      jsonb;
  v_type     text := p_op ->> 'type';
  v_key      text;
  v_label    text := case when jsonb_typeof(p_op -> 'label') = 'string' and length(p_op ->> 'label') > 0 then left(p_op ->> 'label', 500) end;
  v_cur      numeric;
  v_val      numeric;
  v_exp      numeric;
  v_delta    numeric;
  v_new      numeric;
  v_fed      numeric;
  v_transferred numeric := 0;
  v_effect   numeric := 0;
  v_move     numeric := 0;
  v_event    record;
  v_status   text := 'applied';
  v_detail   jsonb := '{}'::jsonb;
  v_conf     jsonb := '[]'::jsonb;
  v_dest     text;
  v_n        int;
  v_text     text;
  v_before   timestamptz;
  v_snapshot text;
  v_jcur     jsonb;
  v_jval     jsonb;
  v_jexp     jsonb;
  v_ok       boolean;
  v_max      numeric;
  v_set      jsonb;
  v_slot     text;
  v_day      date;
  v_at       timestamptz;
  v_res      jsonb;
  v_late     text;
begin
  select * into r from dog_log.state where owner_id = p_owner for update;
  v_doc := r.doc;

  if v_type = 'adjust' then
    v_key := p_op ->> 'key';
    if not dog_log._is_stock_key(v_key) or jsonb_typeof(p_op -> 'delta') is distinct from 'number' then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid adjust'));
    end if;
    v_delta := (p_op ->> 'delta')::numeric;
    if abs(v_delta) > 1000000 then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'delta out of range'));
    end if;
    if dog_log._is_count_key(v_key) and v_delta <> round(v_delta) then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'count delta must be an integer'));
    end if;
    v_cur := coalesce((v_doc #>> array['stock', v_key])::numeric, 0);
    v_new := dog_log._stock_val(v_key, v_cur + v_delta);
    if v_cur + v_delta < 0 then v_status := 'applied-clamped'; end if;
    v_doc := jsonb_set(v_doc, array['stock', v_key], to_jsonb(v_new));
    v_detail := jsonb_build_object('key', v_key, 'before', v_cur, 'after', v_new);

  elsif v_type = 'set' then
    -- Conditional recount rebased to its own time (R2).
    v_key := p_op ->> 'key';
    if not dog_log._is_stock_key(v_key) or jsonb_typeof(p_op -> 'value') is distinct from 'number' or jsonb_typeof(p_op -> 'expected') is distinct from 'number' then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid set'));
    end if;
    v_cur := coalesce((v_doc #>> array['stock', v_key])::numeric, 0);
    v_val := dog_log._stock_val(v_key, (p_op ->> 'value')::numeric);
    v_exp := dog_log._stock_val(v_key, (p_op ->> 'expected')::numeric);
    v_fed := 0;
    v_transferred := 0;
    v_effect := 0;
    if v_key in ('fridge', 'freezer') then
      select count(*) filter (where outcome = 'fed' and source_container = v_key),
             coalesce(sum(freezer_to_fridge_count), 0)
        into v_fed, v_transferred
        from dog_log.meal_events
       where owner_id = p_owner and slot_at > p_cc;
      -- Net server-side stock effect since the recount: meals consume from their recorded
      -- source; transfers (WORK-147 dinner rows and WORK-148 transfer rows) add to fridge
      -- and subtract from freezer.
      v_effect := case when v_key = 'fridge'
                       then -v_fed + v_transferred
                       else -v_fed - v_transferred end;
    end if;
    if dog_log._stock_val(v_key, v_cur - v_effect) <> v_exp then
      return jsonb_build_object('status', 'conflict', 'detail', jsonb_build_object(
        'key', v_key, 'current', v_cur, 'attempted', v_val, 'expected', v_exp,
        'rebased', dog_log._stock_val(v_key, v_val + v_effect),
        'fed_since', v_fed, 'transferred_since', v_transferred));
    end if;
    v_new := dog_log._stock_val(v_key, v_val + v_effect);
    if v_val + v_effect < 0 then v_status := 'applied-clamped'; end if;
    v_doc := jsonb_set(v_doc, array['stock', v_key], to_jsonb(v_new));
    v_detail := jsonb_build_object('key', v_key, 'before', v_cur, 'after', v_new,
                                   'fed_since', v_fed, 'transferred_since', v_transferred);

  elsif v_type = 'prep_batch' then
    v_dest := p_op ->> 'destination';
    if coalesce(v_dest, '') not in ('fridge', 'freezer') or jsonb_typeof(p_op -> 'containers') is distinct from 'number'
       or (p_op ->> 'containers')::numeric <= 0 or (p_op ->> 'containers')::numeric <> round((p_op ->> 'containers')::numeric)
       or jsonb_typeof(p_op -> 'batch') is distinct from 'object' then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid prep_batch'));
    end if;
    -- The batch and its containers are additive facts: always applied.
    v_doc := jsonb_set(v_doc, '{batches}',
      (select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) from (
         select e, ord from (
           select (dog_log._norm_doc(jsonb_build_object('batches', jsonb_build_array(p_op -> 'batch'))) -> 'batches' -> 0) as e, 0::bigint as ord
           union all
           select b.e, b.ord from jsonb_array_elements(v_doc -> 'batches') with ordinality as b(e, ord)
         ) x order by ord limit 50) y));
    v_cur := coalesce((v_doc #>> array['stock', v_dest])::numeric, 0);
    v_doc := jsonb_set(v_doc, array['stock', v_dest], to_jsonb(dog_log._count(v_cur + (p_op ->> 'containers')::numeric)));
    -- Ingredient left-overs are conditional sets, each able to conflict independently.
    foreach v_key in array array['minceKg', 'neckPackets'] loop
      v_text := case v_key when 'minceKg' then 'minceLeftKg' else 'neckPacketsLeft' end;
      if jsonb_typeof(p_op -> v_text) = 'number' then
        v_cur := coalesce((v_doc #>> array['stock', v_key])::numeric, 0);
        v_val := dog_log._stock_val(v_key, (p_op ->> v_text)::numeric);
        v_exp := case when jsonb_typeof(p_op -> case v_key when 'minceKg' then 'expectedMinceKg' else 'expectedNeckPackets' end) = 'number'
                      then dog_log._stock_val(v_key, (p_op ->> case v_key when 'minceKg' then 'expectedMinceKg' else 'expectedNeckPackets' end)::numeric) end;
        if v_exp is not null and v_cur = v_exp then
          v_doc := jsonb_set(v_doc, array['stock', v_key], to_jsonb(v_val));
        else
          v_conf := v_conf || jsonb_build_object('key', v_key, 'current', v_cur, 'attempted', v_val, 'expected', v_exp, 'rebased', v_val);
        end if;
      end if;
    end loop;
    v_detail := jsonb_build_object('destination', v_dest, 'containers', (p_op ->> 'containers')::numeric);
    if jsonb_array_length(v_conf) > 0 then
      v_status := 'conflict';
      v_detail := v_detail || jsonb_build_object('partial', true, 'conflicts', v_conf);
    end if;

  elsif v_type = 'settings' and (p_op ->> 'field') in ('totalContainers', 'mincePurchaseIncrementKg') then
    v_key := p_op ->> 'field';
    if jsonb_typeof(p_op -> 'value') is distinct from 'number' or jsonb_typeof(p_op -> 'expected') is distinct from 'number' then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid settings'));
    end if;
    v_cur := coalesce((v_doc #>> array['settings', v_key])::numeric, 0);
    if v_key = 'totalContainers' then
      v_val := round(greatest((p_op ->> 'value')::numeric, 0), 2);
      v_exp := round(greatest((p_op ->> 'expected')::numeric, 0), 2);
    else
      v_val := greatest(0.1, dog_log._kg((p_op ->> 'value')::numeric));
      v_exp := dog_log._kg((p_op ->> 'expected')::numeric);
    end if;
    if v_cur <> v_exp then
      return jsonb_build_object('status', 'conflict', 'detail', jsonb_build_object(
        'field', v_key, 'current', v_cur, 'attempted', v_val, 'expected', v_exp, 'rebased', v_val));
    end if;
    v_doc := jsonb_set(v_doc, array['settings', v_key], to_jsonb(v_val));
    v_detail := jsonb_build_object('field', v_key, 'before', v_cur, 'after', v_val);

  elsif v_type = 'settings' then
    -- WORK-148 Food settings: conditional on the effective (defaulted) current value.
    v_key  := p_op ->> 'field';
    v_jval := p_op -> 'value';
    v_jexp := p_op -> 'expected';
    if coalesce(v_key, '') in ('breakfastTime', 'dinnerTime', 'fridgeTransferTime') then
      v_ok := jsonb_typeof(v_jval) = 'string' and (v_jval #>> '{}') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              and jsonb_typeof(v_jexp) = 'string';
    elsif coalesce(v_key, '') in ('fridgeTransferCount', 'maxFreezerContainers', 'maxFridgeContainers') then
      -- Nested checks: the numeric cast only ever sees a JSON number.
      v_ok := false;
      if jsonb_typeof(v_jval) = 'number' then
        v_val := (v_jval #>> '{}')::numeric;
        v_max := case v_key when 'fridgeTransferCount' then 100 else 1000000 end;  -- no CASE inside an IF condition
        if v_val = round(v_val) and v_val between 0 and v_max then
          v_ok := true;
          v_jval := to_jsonb(round(v_val));
        end if;
      elsif v_key = 'maxFridgeContainers' and jsonb_typeof(v_jval) = 'null' then
        v_ok := true;
      end if;
      v_ok := v_ok and (jsonb_typeof(v_jexp) = 'number' or (v_key = 'maxFridgeContainers' and jsonb_typeof(v_jexp) = 'null'));
    else
      v_ok := false;
    end if;
    if not coalesce(v_ok, false) then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid settings'));
    end if;
    v_jcur := dog_log._setting(v_doc, v_key);
    if v_jcur is distinct from v_jexp then
      return jsonb_build_object('status', 'conflict', 'detail', jsonb_build_object(
        'field', v_key, 'current', v_jcur, 'attempted', v_jval, 'expected', v_jexp, 'rebased', v_jval));
    end if;
    v_set := case when jsonb_typeof(v_doc -> 'settings') = 'object' then v_doc -> 'settings' else '{}'::jsonb end;
    if v_key in ('breakfastTime', 'dinnerTime') then
      -- Breakfast must stay before Dinner. Both are written, so the stored pair is always the effective one.
      v_set := v_set || jsonb_build_object('breakfastTime', dog_log._setting(v_doc, 'breakfastTime'),
                                           'dinnerTime', dog_log._setting(v_doc, 'dinnerTime'));
      v_set := v_set || jsonb_build_object(v_key, v_jval);
      if (v_set ->> 'breakfastTime') >= (v_set ->> 'dinnerTime') then
        return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object(
          'reason', 'Breakfast must be before Dinner', 'field', v_key, 'attempted', v_jval));
      end if;
    else
      v_set := v_set || jsonb_build_object(v_key, v_jval);
    end if;
    v_doc := jsonb_set(v_doc, '{settings}', v_set);
    v_detail := jsonb_build_object('field', v_key, 'before', v_jcur, 'after', v_jval);
    -- A time moved to or before the cursor on the cursor's day would never be reached by the
    -- walker: if that day has not had this meal/transfer yet, it runs now, exactly once.
    if v_key in ('breakfastTime', 'dinnerTime', 'fridgeTransferTime') and r.meal_cursor is not null then
      v_slot := case v_key when 'breakfastTime' then 'breakfast' when 'dinnerTime' then 'dinner' else 'transfer' end;
      v_day  := (r.meal_cursor at time zone r.time_zone)::date;
      v_at   := (v_day + dog_log._sched_time(v_doc, v_slot)) at time zone r.time_zone;
      if v_at <= r.meal_cursor and v_at > coalesce(r.meal_tracking_since, '-infinity'::timestamptz) then
        v_res := dog_log._run_event(p_owner, v_doc, v_day, v_slot, v_at, r.time_zone,
                                    left(p_op ->> 'device_id', 100), r.revision + 1);
        v_doc := v_res -> 'doc';
        if (v_res ->> 'ran')::boolean then
          v_late := v_res ->> 'entry';
          v_detail := v_detail || jsonb_build_object('ran_now', v_slot);
        end if;
      end if;
    end if;

  elsif v_type = 'calendar_endpoint' then
    if jsonb_typeof(p_op -> 'value') is distinct from 'string' or jsonb_typeof(p_op -> 'expected') is distinct from 'string'
       or not ((p_op ->> 'value') = '' or (p_op ->> 'value') ~ '^https://script\.google\.com/macros/s/[^/\s]+/exec$') then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid calendar_endpoint'));
    end if;
    if coalesce(v_doc #>> '{calendar,endpoint}', '') <> (p_op ->> 'expected') then
      return jsonb_build_object('status', 'conflict', 'detail', jsonb_build_object(
        'field', 'calendar.endpoint', 'current', coalesce(v_doc #>> '{calendar,endpoint}', ''),
        'attempted', p_op ->> 'value', 'expected', p_op ->> 'expected'));
    end if;
    v_doc := jsonb_set(v_doc, '{calendar}', jsonb_build_object('endpoint', p_op ->> 'value'));

  elsif v_type = 'clear_history' then
    v_before := dog_log._try_ts(p_op ->> 'before');
    if v_before is null then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid clear_history'));
    end if;
    -- Only entries at or before the clear time go; entries synced later from another device survive.
    v_doc := jsonb_set(v_doc, '{history}',
      (select coalesce(jsonb_agg(h.e order by h.ord), '[]'::jsonb)
         from jsonb_array_elements(v_doc -> 'history') with ordinality as h(e, ord)
        where dog_log._try_ts(h.e ->> 'at') > v_before));

  elsif v_type = 'replace_state' then
    -- Explicit restore only; revision-checked against the revision the client observed.
    if jsonb_typeof(p_op -> 'doc') is distinct from 'object' or jsonb_typeof(p_op -> 'expected_revision') is distinct from 'number' then
      return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'invalid replace_state'));
    end if;
    if (p_op ->> 'expected_revision')::bigint <> p_start_revision then
      return jsonb_build_object('status', 'conflict', 'detail', jsonb_build_object(
        'current_revision', p_start_revision, 'expected_revision', (p_op ->> 'expected_revision')::bigint));
    end if;
    v_before := null;
    if coalesce((p_op ->> 'subtract_meals_since')::boolean, false) then
      v_before := dog_log._try_ts(p_op ->> 'backup_created_at');
      if v_before is null then
        return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'backup_created_at required'));
      end if;
    end if;
    v_snapshot := case when p_op ->> 'reason' = 'restore-backup' then 'pre-restore' else 'pre-replace' end;
    insert into dog_log.state_snapshots (owner_id, reason, revision, doc) values (p_owner, v_snapshot, r.revision, r.doc);
    -- The server meal cursor and meal_events are kept; the backup's own tracking is ignored (R8).
    v_doc := dog_log._norm_doc(p_op -> 'doc');
    v_n := 0;
    v_transferred := 0;
    if v_before is not null then
      -- Replay in processing order: at an equal time a meal precedes the transfer.
      for v_event in
        select outcome, freezer_to_fridge_count
          from dog_log.meal_events
         where owner_id = p_owner and slot_at > v_before
         order by slot_at, case slot when 'transfer' then 1 else 0 end
      loop
        if v_event.outcome = 'fed' then
          v_cur := (v_doc #>> '{stock,fridge}')::numeric;
          if v_cur > 0 then
            v_doc := jsonb_set(v_doc, '{stock,fridge}', to_jsonb(v_cur - 1));
          else
            v_doc := jsonb_set(v_doc, '{stock,freezer}', to_jsonb(greatest((v_doc #>> '{stock,freezer}')::numeric - 1, 0)));
          end if;
          v_n := v_n + 1;
        end if;
        if v_event.freezer_to_fridge_count is not null then
          v_cur := (v_doc #>> '{stock,freezer}')::numeric;
          v_move := least(v_cur, v_event.freezer_to_fridge_count);
          if v_move > 0 then
            v_doc := jsonb_set(v_doc, '{stock,freezer}', to_jsonb(v_cur - v_move));
            v_doc := jsonb_set(v_doc, '{stock,fridge}',
              to_jsonb((v_doc #>> '{stock,fridge}')::numeric + v_move));
            v_transferred := v_transferred + v_move;
          end if;
        end if;
      end loop;
    end if;
    v_detail := jsonb_build_object('snapshot', v_snapshot, 'meals_subtracted', v_n,
                                   'containers_transferred', v_transferred);

  else
    return jsonb_build_object('status', 'rejected', 'detail', jsonb_build_object('reason', 'unknown operation type'));
  end if;

  if v_label is not null then
    v_doc := dog_log._history_push(v_doc, p_cc, v_label);
  end if;
  if v_late is not null then
    v_doc := dog_log._history_push(v_doc, p_cc, v_late);
  end if;
  update dog_log.state set doc = v_doc where owner_id = p_owner;
  return jsonb_build_object('status', v_status, 'detail', v_detail);
end; $$;

-- recent_meals also reports each row's transfer count, so a client can mirror recount
-- rebasing and recognise WORK-147 dinner rows that already carried the day's transfer.
create or replace function dog_log._state_json(p_owner uuid)
returns jsonb language sql stable set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object(
    'revision', s.revision,
    'schema_version', s.schema_version,
    'min_client_version', s.min_client_version,
    'time_zone', s.time_zone,
    'doc', s.doc,
    'meal_cursor', s.meal_cursor,
    'meal_tracking_since', s.meal_tracking_since,
    'recent_meals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'meal_date', m.meal_date, 'slot', m.slot, 'outcome', m.outcome,
               'source_container', m.source_container, 'freezer_to_fridge_count', m.freezer_to_fridge_count,
               'slot_at', m.slot_at, 'processed_at', m.processed_at,
               'processed_by_device', m.processed_by_device, 'origin', m.origin)
             order by m.slot_at, case m.slot when 'transfer' then 1 else 0 end)
        from dog_log.meal_events m
       where m.owner_id = s.owner_id
         and m.meal_date >= (now() at time zone s.time_zone)::date - 13), '[]'::jsonb),
    'server_now', now())
  from dog_log.state s
  where s.owner_id = p_owner
$$;

-- --------------------------------------------------------------------- seeding
-- As before, plus the daily transfer. Every meal and transfer the device logged is
-- imported, so it can never run again even after its configured time moves (slot_at is
-- capped at the device cursor: the event is already accounted for). A WORK-148 device
-- logs transfers in tracking.transferLog; an older device had its transfer inside
-- Dinner (WORK-147), so each imported Dinner also closes that day's transfer.
create or replace function dog_log.seed_state(p_seed_id uuid, p_doc jsonb, p_device_id text default null, p_client_version integer default 1)
returns jsonb language plpgsql volatile security definer
set search_path = pg_catalog, pg_temp set lock_timeout = '3s' as $$
declare
  v_owner    uuid := (select auth.uid());
  v_device   text := left(p_device_id, 100);
  v_doc      jsonb;
  v_ms       numeric;
  v_cursor   timestamptz;
  v_since    timestamptz;
  v_existing uuid;
  v_inserted int;
  v_day      text;
  v_meals    jsonb;
  v_slot     text;
  v_status   text;
  v_out      text;
  v_at       timestamptz;
  v_ledger   boolean := coalesce(jsonb_typeof(p_doc #> '{tracking,transferLog}') = 'object', false);
  v_tlog     jsonb := case when jsonb_typeof(p_doc #> '{tracking,transferLog}') = 'object' then p_doc #> '{tracking,transferLog}' else '{}'::jsonb end;
  v_moved    jsonb;
  v_today    date := (now() at time zone 'Australia/Melbourne')::date;
begin
  if v_owner is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if coalesce(p_client_version, 0) < 1 then
    raise exception 'client_outdated' using errcode = '22023', hint = 'min_client_version=1';
  end if;
  if p_seed_id is null or p_doc is null or jsonb_typeof(p_doc) <> 'object' then
    raise exception 'invalid_seed' using errcode = '22023';
  end if;

  v_doc := dog_log._norm_doc(p_doc);
  v_ms := case when jsonb_typeof(p_doc #> '{tracking,mealCursor}') = 'number' then (p_doc #>> '{tracking,mealCursor}')::numeric end;
  v_cursor := case when v_ms is not null and v_ms between -8.64e15 and 8.64e15
                   then greatest(least(now(), to_timestamp(v_ms / 1000.0)), now() - interval '400 days') end;
  v_since := case when v_cursor is not null then coalesce(dog_log._try_ts(p_doc #>> '{tracking,mealTrackingSince}'), v_cursor) end;

  insert into dog_log.state (owner_id, doc, seed_id, seeded_from_device, meal_cursor, meal_tracking_since, updated_by_device)
  values (v_owner, v_doc, p_seed_id, v_device, v_cursor, v_since, v_device)
  on conflict (owner_id) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted = 0 then
    -- Nothing is overwritten: a retry of this seed, or another device's cloud copy.
    select seed_id into v_existing from dog_log.state where owner_id = v_owner;
    v_status := case when v_existing = p_seed_id then 'already-seeded' else 'cloud-exists' end;
    return jsonb_build_object('status', v_status) || jsonb_build_object('state', dog_log._state_json(v_owner));
  end if;

  if v_cursor is not null then
    -- Import the device's recent meal and transfer logs so those events can never run again.
    v_meals := case when jsonb_typeof(p_doc #> '{tracking,mealLog}') = 'object' then p_doc #> '{tracking,mealLog}' else '{}'::jsonb end;
    for v_day in select k from jsonb_object_keys(v_meals) k where k ~ '^\d{4}-\d{2}-\d{2}$' loop
      continue when dog_log._try_ts(v_day) is null;
      continue when v_day::date < v_today - 13 or v_day::date > v_today;
      continue when jsonb_typeof(v_meals -> v_day) is distinct from 'object';
      foreach v_slot in array array['breakfast', 'dinner'] loop
        v_out := v_meals -> v_day ->> v_slot;
        continue when v_out is null or v_out not in ('fed', 'no-stock', 'before-tracking');
        v_at := least((v_day::date + dog_log._sched_time(v_doc, v_slot)) at time zone 'Australia/Melbourne', v_cursor);
        insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, processed_by_device, state_revision, origin)
        values (v_owner, v_day::date, v_slot, v_out, v_at, v_device, 1, 'seed')
        on conflict do nothing;
        if v_slot = 'dinner' and not v_ledger and v_out <> 'before-tracking' then
          insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, processed_by_device, state_revision, origin)
          values (v_owner, v_day::date, 'transfer', 'transferred', v_at, v_device, 1, 'seed')
          on conflict do nothing;
        end if;
      end loop;
    end loop;
    for v_day in select k from jsonb_object_keys(v_tlog) k where k ~ '^\d{4}-\d{2}-\d{2}$' loop
      continue when dog_log._try_ts(v_day) is null;
      continue when v_day::date < v_today - 13 or v_day::date > v_today;
      continue when jsonb_typeof(v_tlog -> v_day) is distinct from 'object';
      v_out := case v_tlog -> v_day ->> 'outcome' when 'processed' then 'transferred' when 'before-tracking' then 'before-tracking' end;
      continue when v_out is null;
      v_moved := v_tlog -> v_day -> 'moved';
      v_at := least((v_day::date + dog_log._sched_time(v_doc, 'transfer')) at time zone 'Australia/Melbourne', v_cursor);
      insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, freezer_to_fridge_count, slot_at, processed_by_device, state_revision, origin)
      values (v_owner, v_day::date, 'transfer', v_out,
              case when v_out = 'transferred' and jsonb_typeof(v_moved) = 'number'
                        and (v_moved #>> '{}')::numeric between 0 and 100
                   then round((v_moved #>> '{}')::numeric)::smallint end,
              v_at, v_device, 1, 'seed')
      on conflict do nothing;
    end loop;
  else
    -- Device never started meal tracking: initialise exactly as WORK-135's first run.
    perform dog_log._process_due_meals(v_owner, now(), v_device);
  end if;

  insert into dog_log.state_snapshots (owner_id, reason, revision, doc)
  select owner_id, 'seed', revision, doc from dog_log.state where owner_id = v_owner;

  return jsonb_build_object('status', 'seeded', 'state', dog_log._state_json(v_owner));
end; $$;

-- ------------------------------------------------------------------ privileges
revoke all on function
  dog_log._setting(jsonb, text), dog_log._sched_time(jsonb, text), dog_log._norm_doc(jsonb),
  dog_log._run_event(uuid, jsonb, date, text, timestamptz, text, text, bigint),
  dog_log._process_due_meals(uuid, timestamptz, text), dog_log._apply_op(uuid, jsonb, timestamptz, bigint),
  dog_log._state_json(uuid), dog_log.seed_state(uuid, jsonb, text, integer)
  from public, anon, authenticated, service_role;
grant execute on function dog_log.seed_state(uuid, jsonb, text, integer) to authenticated;

comment on function dog_log._process_due_meals(uuid, timestamptz, text) is
  'Internal exactly-once processor for configured Breakfast/Dinner meals and the independent daily freezer-to-fridge transfer (WORK-148).';
notify pgrst, 'reload schema';
