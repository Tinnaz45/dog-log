-- =============================================================================
-- ROLLBACK for 20260924225253_dog_log_create_sync_schema.sql (WORK-136 PR-A)
--
-- !!! DESTRUCTIVE: drops the entire `dog_log` schema - every table, function,
-- !!! policy and row in it - and removes dog_log.state from supabase_realtime.
--
-- SUPPORTED ONLY BEFORE ADOPTION (pre-seed): i.e. while no device has seeded a
-- cloud copy and `dog_log.state` holds zero rows. In that state nothing
-- authoritative exists in the cloud (every device still runs from its own
-- localStorage), so dropping the schema loses no user data.
--
-- AFTER ANY SEED THIS SCRIPT REFUSES TO RUN. Once a row exists, the cloud copy
-- may be the only authoritative Dog Log state, and dropping it is not a rollback
-- but data destruction. Post-seed recovery is a different procedure (see
-- supabase/README.md "Post-seed recovery"): revert the client (devices resume
-- from their local mirror while cloud data stays intact), restore from
-- dog_log.state_snapshots, or - only with a separate, explicitly approved action -
-- export the data and delete the rows first, after which this script applies.
--
-- Apply only with the same per-environment approval as the forward migration
-- (ENVIRONMENT_LIFECYCLE 10.2). Manual follow-up this SQL cannot do: remove
-- `dog_log` from the project's Exposed schemas (10.4).
-- =============================================================================

-- One atomic block: the guard, the publication change and the drop cannot be
-- separated, and the state table is locked so no seed can land in between.
do $$
declare
  n bigint;
begin
  if to_regclass('dog_log.state') is not null then
    lock table dog_log.state in access exclusive mode;
    execute 'select count(*) from dog_log.state' into n;
    if n > 0 then
      raise exception 'dog_log rollback refused: % cloud state row(s) exist (post-seed). This is not a pre-adoption rollback; follow "Post-seed recovery" in supabase/README.md.', n;
    end if;
    if exists (select 1 from pg_catalog.pg_publication_tables
                where pubname = 'supabase_realtime' and schemaname = 'dog_log' and tablename = 'state') then
      execute 'alter publication supabase_realtime drop table dog_log.state';
    end if;
  end if;
  execute 'drop schema if exists dog_log cascade';
end $$;

notify pgrst, 'reload schema';
