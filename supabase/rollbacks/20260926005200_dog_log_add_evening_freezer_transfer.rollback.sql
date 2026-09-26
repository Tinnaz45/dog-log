-- WORK-147 rollback: stop future transfers while preserving the transfer ledger and transfer-aware recount/restore reconciliation.
create or replace function dog_log._process_due_meals(p_owner uuid, p_until timestamptz, p_device text)
returns boolean language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
declare
  r         dog_log.state%rowtype;
  v_doc     jsonb;
  v_tz      text;
  v_cursor  timestamptz;
  v_day     date;
  v_slot    text;
  v_label   text;
  v_at      timestamptz;
  v_fridge  numeric;
  v_freezer numeric;
  v_outcome text;
  v_source  text;
  v_ins     int;
  v_entries text[] := '{}';
  v_fed     int := 0;
  v_changed boolean := false;
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

  -- First run (WORK-135): start tracking now; today's already-passed slots are 'before-tracking'.
  if v_cursor is null then
    v_day := (p_until at time zone v_tz)::date;
    foreach v_slot in array array['breakfast', 'dinner'] loop
      v_at := dog_log._slot_at(v_day, v_slot, v_tz);
      if v_at <= p_until then
        insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, slot_at, processed_by_device, state_revision, origin)
        values (p_owner, v_day, v_slot, 'before-tracking', v_at, p_device, r.revision + 1, 'server')
        on conflict do nothing;
      end if;
    end loop;
    v_doc := dog_log._history_push(v_doc, now(),
      'Meal schedule started: Breakfast 09:00 and Dinner 18:00 each use 1 Full Container. Existing stock kept as recorded.');
    update dog_log.state
       set doc = v_doc, meal_cursor = p_until, meal_tracking_since = coalesce(meal_tracking_since, p_until)
     where owner_id = p_owner;
    return true;
  end if;

  if p_until <= v_cursor then return false; end if;
  -- Bound the catch-up walk (at most ~800 slots) so a corrupt or ancient cursor can
  -- never make every sync time out; older slots are beyond meal_events retention anyway.
  v_cursor := greatest(v_cursor, p_until - interval '400 days');

  for v_day in select d::date from generate_series((v_cursor at time zone v_tz)::date, (p_until at time zone v_tz)::date, interval '1 day') d loop
    foreach v_slot in array array['breakfast', 'dinner'] loop
      v_at := dog_log._slot_at(v_day, v_slot, v_tz);
      continue when v_at <= v_cursor or v_at > p_until;

      v_fridge  := coalesce((v_doc #>> '{stock,fridge}')::numeric, 0);
      v_freezer := coalesce((v_doc #>> '{stock,freezer}')::numeric, 0);
      if v_fridge + v_freezer > 0 then
        v_outcome := 'fed';
        v_source  := case when v_fridge > 0 then 'fridge' else 'freezer' end;
      else
        v_outcome := 'no-stock';
        v_source  := null;
      end if;

      insert into dog_log.meal_events (owner_id, meal_date, slot, outcome, source_container, slot_at, processed_by_device, state_revision, origin)
      values (p_owner, v_day, v_slot, v_outcome, v_source, v_at, p_device, r.revision + 1, 'server')
      on conflict do nothing;
      get diagnostics v_ins = row_count;

      if v_ins = 1 then
        v_label := case v_slot when 'breakfast' then 'Breakfast' else 'Dinner' end || ' ' || dog_log._fmt_day(v_at, v_tz);
        if v_outcome = 'fed' then
          -- client deductPrepared(1): fridge first, remainder from freezer
          v_doc := jsonb_set(v_doc, '{stock,fridge}', to_jsonb(greatest(v_fridge - least(v_fridge, 1), 0)));
          if v_fridge < 1 then
            v_doc := jsonb_set(v_doc, '{stock,freezer}', to_jsonb(greatest(v_freezer - least(v_freezer, 1 - v_fridge), 0)));
          end if;
          v_fed := v_fed + 1;
          v_entries := v_entries || (v_label || ': 1 Full Container used (' || v_source || ')');
        else
          v_entries := v_entries || (v_label || ': no Full Container available');
        end if;
      end if;
      v_cursor := v_at;       -- the cursor advances past every due slot, fed or not
      v_changed := true;
    end loop;
  end loop;

  if cardinality(v_entries) > 6 then
    v_doc := dog_log._history_push(v_doc, now(),
      'Scheduled meals caught up: ' || cardinality(v_entries) || ' meals, ' || v_fed || ' Full Containers used');
  else
    for i in 1 .. coalesce(cardinality(v_entries), 0) loop
      v_doc := dog_log._history_push(v_doc, now(), v_entries[i]);
    end loop;
  end if;

  if v_changed then
    update dog_log.state set doc = v_doc, meal_cursor = v_cursor where owner_id = p_owner;
  end if;
  return v_changed;
end $$;

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
      -- Net server-side stock effect since the recount: meals consume from their
      -- recorded source; WORK-147 dinner transfers add to fridge and subtract from freezer.
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

  elsif v_type = 'settings' then
    v_key := p_op ->> 'field';
    if coalesce(v_key, '') not in ('totalContainers', 'mincePurchaseIncrementKg')
       or jsonb_typeof(p_op -> 'value') is distinct from 'number' or jsonb_typeof(p_op -> 'expected') is distinct from 'number' then
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
      for v_event in
        select outcome, freezer_to_fridge_count
          from dog_log.meal_events
         where owner_id = p_owner and slot_at > v_before
         order by slot_at
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
  update dog_log.state set doc = v_doc where owner_id = p_owner;
  return jsonb_build_object('status', v_status, 'detail', v_detail);
end $$;

revoke all on function dog_log._process_due_meals(uuid,timestamptz,text) from public, anon, authenticated, service_role;
revoke all on function dog_log._apply_op(uuid,jsonb,timestamptz,bigint) from public, anon, authenticated, service_role;
comment on function dog_log._process_due_meals(uuid,timestamptz,text) is 'Internal exactly-once scheduled meal processor.';
notify pgrst, 'reload schema';
