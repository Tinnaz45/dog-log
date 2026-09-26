# Dog Log database (WORK-136 cloud sync)

This folder holds the Dog Log cloud-sync database: the `dog_log` schema in the shared Supabase projects. The design is recorded on Linear WORK-136: Investigation Record `work136-investigation-record-1`, plus findings comments `fdda47e8` and `fd0b771e`.

| File | Purpose |
|---|---|
| `migrations/20260924225253_dog_log_create_sync_schema.sql` | Creates the schema, tables, RLS, RPCs and the realtime publication entry |
| `migrations/20260926005200_dog_log_add_evening_freezer_transfer.sql` | WORK-147: after Dinner at 18:00, move up to 2 remaining Full Containers from Freezer to Fridge |
| `rollbacks/20260926005200_dog_log_add_evening_freezer_transfer.rollback.sql` | Stops future transfers by restoring the old meal processor, while retaining the ledger and transfer-aware recount/restore reconciliation |
| `rollbacks/20260924225253_dog_log_create_sync_schema.rollback.sql` | Pre-adoption rollback only (see below) |
| `tests/dog_log_sync.sql` | SQL assertion suite. Runs in one transaction that is rolled back |
| `tests/local/supabase_stub.sql` | Minimal Supabase stand-in for a **disposable local** Postgres only |
| `tests/local/run_local.sh` | Throwaway-cluster runner: install, SQL suite, two-session concurrency, rollback |

## What the migration creates

- **Tables:**
  - `dog_log.state`: one row per owner, holding `doc jsonb` and a server `revision`.
  - `dog_log.meal_events`: primary key `(owner_id, meal_date, slot)`, one row per Melbourne-local scheduled meal. WORK-147 adds a nullable `freezer_to_fridge_count`: `NULL` means the transfer feature did not run for that meal; Dinner events processed with WORK-147 record `0`, `1`, or `2`.
  - `dog_log.mutations`: idempotency ledger with primary key `(owner_id, mutation_id)`.
  - `dog_log.state_snapshots`: recovery copies; the newest 20 per owner are kept.
- **Client RPCs** (`EXECUTE` is granted to `authenticated` only):
  - `dog_log.seed_state(p_seed_id, p_doc, p_device_id, p_client_version)` creates the cloud copy only if none exists. Its statuses are `seeded`, `already-seeded` (the same `seed_id` retried) and `cloud-exists`.
  - `dog_log.sync(p_mutations, p_device_id, p_client_version)` is the only write path. It locks the owner's row and processes due 09:00/18:00 meals interleaved with the submitted operations by time. Each `mutation_id` is applied at most once. The revision bumps once, and only when something changed. The call returns the fresh state and a per-operation result.
- **Internal functions** (`_process_due_meals`, `_apply_op` and helpers) are executable by no client role.

## Security model

- Clients need only three things: the project URL, the **publishable** key and an authenticated email/password session. They never need a service-role key.
- `anon` has no schema usage and no privileges.
- `authenticated` has only `SELECT` on the four tables, restricted by RLS to `owner_id = auth.uid()`. No client role has `INSERT`, `UPDATE` or `DELETE`, so every write goes through the two RPCs.
- The RPCs are `SECURITY DEFINER`. Every function pins `search_path = pg_catalog, pg_temp`, with `pg_temp` explicitly last so a caller's temporary objects cannot shadow type names. They take the owner only from `auth.uid()` and never from a parameter, and they refuse to run without a JWT subject.
- Privileges are revoked explicitly on every object, not only through default privileges. PostgreSQL grants `EXECUTE` on new functions to `PUBLIC`, and Supabase's "automatically expose new tables" setting can add grants. The local test stub installs hostile global defaults to prove the revokes still hold.
- The calendar pairing token, `paired`, `lastSync` and `lastError` are stripped server-side. They stay on the device.

## Applying (not done by merging)

Merging this folder applies nothing (ENVIRONMENT_LIFECYCLE §10.1). Each step below is a separate act.

**Dog Log is Supabase PROD-only** (operator decision, WORK-136, 2026-09-25). It is a personal app with a `main`-only repository and one Production deployment. The shared Supabase DEV project is **not** a persistent Dog Log target: Dog Log keeps no schema, data or Exposed-schemas entry there.

1. **DEV** (`kctctvpobbizhkiqkgqw`): **do not re-apply.**
   - This exact reviewed migration was applied to DEV once and validated there (history `20260924234922`).
   - It was then rolled back with the rollback file, recorded as `dog_log_create_sync_schema_rollback` (`20260925001719`).
   - DEV now holds no `dog_log` objects, and `dog_log` was never exposed there.
   - Because the migration was tested in DEV before the rollback, it already meets the DEV-before-PROD requirement of ENVIRONMENT_LIFECYCLE §10.2.
2. **PROD** (`wgcqzamuspuqpedqasbc`): applying needs **explicit operator approval for this specific migration**. After applying, verify grants with `has_table_privilege` and `has_function_privilege`.
3. **Later controlled steps, each separate from the apply:**
   - Add `dog_log` to PROD *Settings → API → Exposed schemas*. Add it; never remove another app's entry.
   - Create the PROD Auth identities.
4. The migration adds only `dog_log.state` to the `supabase_realtime` publication.

**Future Dog Log migrations** remain subject to §10.2 as written. Local tests (below) do not replace it. Each future migration needs either a temporary, disposable DEV validation that is rolled back afterwards, or a separately governed policy exception or amendment.

## Local tests (disposable database only)

```sh
# as a non-root user, with PostgreSQL 15+ server binaries installed
PG_BINDIR=/usr/lib/postgresql/16/bin supabase/tests/local/run_local.sh
```

The runner never connects to Supabase. It creates and deletes its own temporary cluster.

## Rollback boundaries

- **Pre-adoption (supported):** no device has seeded yet, so `dog_log.state` is empty. The rollback file removes the publication entry and drops the schema in one atomic, locked block. Afterwards, remove `dog_log` from Exposed schemas by hand. No user data exists in the cloud at this point, so none is lost.
- **Post-seed:** once any `dog_log.state` row exists, **the rollback file refuses to run**. At that point the cloud copy may be the only authoritative Dog Log state, and dropping it would destroy user data.

### Post-seed recovery

1. **Disable sync without data loss:** revert the client (PR-B) or promote the previous Production deployment. Devices fall back to their local mirror (`dog_food_stock_v2`), and cloud data stays intact for a later retry.
2. **Bad cloud state:** restore from `dog_log.state_snapshots`. Use the app's Backups → *Replace cloud with this backup* (a `replace_state` operation that takes a snapshot first), or operator SQL with per-action approval.
3. **Removing the schema after adoption** is a separate, explicitly approved action. First export `dog_log.state`, `meal_events` and `state_snapshots`, then delete the rows. Only then does the rollback file apply.
