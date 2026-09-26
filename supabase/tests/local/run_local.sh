#!/usr/bin/env bash
# =============================================================================
# Disposable local test run for Dog Log base sync + WORK-147 evening transfer.
#
# Creates a throwaway PostgreSQL cluster in a temp dir, loads the local Supabase
# stub, applies the migration, runs the SQL suite, then runs the two-session
# concurrency tests and the rollback test, and deletes the cluster.
# It never connects to Supabase DEV or PROD.
#
# Requirements: PostgreSQL 15+ server binaries (initdb, pg_ctl, postgres, psql).
# Run as a non-root user (initdb refuses root), e.g.:
#   PG_BINDIR=/usr/lib/postgresql/16/bin supabase/tests/local/run_local.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPA="$(cd "$HERE/../.." && pwd)"
BASE_MIGRATION="$SUPA/migrations/20260924225253_dog_log_create_sync_schema.sql"
MIGRATION="$SUPA/migrations/20260926005200_dog_log_add_evening_freezer_transfer.sql"
ROLLBACK="$SUPA/rollbacks/20260926005200_dog_log_add_evening_freezer_transfer.rollback.sql"
BASE_ROLLBACK="$SUPA/rollbacks/20260924225253_dog_log_create_sync_schema.rollback.sql"
PG_BINDIR="${PG_BINDIR:-$(pg_config --bindir)}"
PORT="${PGTEST_PORT:-55439}"

WORK="$(mktemp -d)"
cleanup() { "$PG_BINDIR/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

"$PG_BINDIR/initdb" -D "$WORK/data" -U postgres --auth=trust -E UTF8 >/dev/null
"$PG_BINDIR/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/log" -w start >/dev/null

export PGHOST="$WORK" PGPORT="$PORT" PGUSER=postgres PGDATABASE=postgres
PSQL=("$PG_BINDIR/psql" -X -q -v ON_ERROR_STOP=1 -tA)

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

echo "== install (clean database)"
"${PSQL[@]}" -f "$HERE/supabase_stub.sql"
"${PSQL[@]}" --single-transaction -f "$BASE_MIGRATION"
"${PSQL[@]}" --single-transaction -f "$MIGRATION"
pass "base + WORK-147 migrations applied to a clean database"

echo "== SQL suite"
"${PSQL[@]}" -f "$SUPA/tests/dog_log_sync.sql" 2>&1 | sed -e 's/^psql:[^ ]* NOTICE:  //' | grep -E '^(ok|FAIL|ALL)' || fail "SQL suite"
"${PSQL[@]}" -c "select 1 from dog_log.state limit 1" | grep -q . && fail "SQL suite left rows behind"
pass "SQL suite rolled back cleanly"

# as_user <uuid> <sql>: run one transaction as an authenticated Supabase user.
as_user() {
  printf '%s\n' "begin;" "set local role authenticated;" \
    "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', true) \\g /dev/null" \
    "$2" "commit;" | "${PSQL[@]}" -f -
}

echo "== concurrency: two clients sync the same due meals at once"
C=cccccccc-0000-4000-8000-00000000000c
"${PSQL[@]}" -c "insert into auth.users (id) values ('$C')"
as_user "$C" "select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 5, 'freezer', 0),
  'tracking', jsonb_build_object('mealCursor', (extract(epoch from now() - interval '30 hours') * 1000)::bigint)), 'seed', 1) \\g /dev/null"
# Session 1 holds the row lock for 2s after processing; session 2 must wait and then find nothing left to do.
as_user "$C" "select dog_log.sync('[]'::jsonb, 'desktop', 1) ->> 'revision'; select pg_sleep(2) \\g /dev/null" > "$WORK/s1" &
sleep 0.5
as_user "$C" "select dog_log.sync('[]'::jsonb, 'iphone', 1) ->> 'revision';" > "$WORK/s2" &
wait
EXPECTED=$("${PSQL[@]}" -c "select count(*) from (select (d::date + t) at time zone 'Australia/Melbourne' as at
  from generate_series(((now() - interval '31 hours') at time zone 'Australia/Melbourne')::date, (now() at time zone 'Australia/Melbourne')::date, interval '1 day') d,
  (values (time '09:00'), (time '18:00')) v(t)) s
  where at > (select meal_tracking_since from dog_log.state where owner_id = '$C') and at <= now()")
EVENTS=$("${PSQL[@]}" -c "select count(*) from dog_log.meal_events where owner_id = '$C' and origin = 'server'")
FRIDGE=$("${PSQL[@]}" -c "select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = '$C'")
DEVICES=$("${PSQL[@]}" -c "select string_agg(distinct processed_by_device, ',') from dog_log.meal_events where owner_id = '$C' and origin = 'server'")
[ "$EVENTS" = "$EXPECTED" ] || fail "concurrent meals: $EVENTS events, expected $EXPECTED"
[ "$FRIDGE" = "$((5 - (EXPECTED < 5 ? EXPECTED : 5)))" ] || fail "concurrent meals: fridge $FRIDGE"
[ "$(cat "$WORK/s1")" = "$(cat "$WORK/s2")" ] || fail "concurrent meals: sessions returned revisions $(cat "$WORK/s1") / $(cat "$WORK/s2")"
[ "$DEVICES" = "desktop" ] || fail "concurrent meals: processed by '$DEVICES' (expected only the first session)"
pass "concurrent syncs: $EVENTS meal events, one deduction each (fridge 5 -> $FRIDGE); second session saw them as already processed"

echo "== concurrency: the same mutation retried from two tabs at once"
M=44444444-4444-4444-8444-444444444444
OP="jsonb_build_array(jsonb_build_object('mutation_id', '$M', 'type', 'adjust', 'key', 'freezer', 'delta', 1, 'client_created_at', now(), 'label', 'Freezer +1'))"
as_user "$C" "select dog_log.sync($OP, 'tab1', 1) -> 'results' -> 0 ->> 'status'; select pg_sleep(1.5) \\g /dev/null" > "$WORK/m1" &
sleep 0.3
as_user "$C" "select dog_log.sync($OP, 'tab2', 1) -> 'results' -> 0 ->> 'status';" > "$WORK/m2" &
wait
[ "$(sort "$WORK/m1" "$WORK/m2" | tr '\n' ' ')" = "applied duplicate " ] || fail "retried mutation: $(cat "$WORK/m1") / $(cat "$WORK/m2")"
[ "$("${PSQL[@]}" -c "select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = '$C'")" = "1" ] || fail "retried mutation applied twice"
pass "retried mutation applied once, second copy returned duplicate"

echo "== concurrency: two devices seed an empty cloud at the same moment"
S=55555555-0000-4000-8000-000000000005
"${PSQL[@]}" -c "insert into auth.users (id) values ('$S')"
as_user "$S" "select dog_log.seed_state('aaaaaaaa-1111-4111-8111-111111111111', '{\"stock\":{\"fridge\":9}}', 'iphone', 1) ->> 'status'; select pg_sleep(1.5) \\g /dev/null" > "$WORK/k1" &
sleep 0.3
as_user "$S" "select dog_log.seed_state('bbbbbbbb-2222-4222-8222-222222222222', '{\"stock\":{\"fridge\":0}}', 'desktop', 1) ->> 'status';" > "$WORK/k2" &
wait
[ "$(cat "$WORK/k1")" = "seeded" ] && [ "$(cat "$WORK/k2")" = "cloud-exists" ] || fail "seed race: $(cat "$WORK/k1") / $(cat "$WORK/k2")"
[ "$("${PSQL[@]}" -c "select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = '$S'")" = "9" ] || fail "seed race overwrote the first seed"
pass "seed race: first seeded, second got cloud-exists, nothing overwritten"

echo "== WORK-147 rollback"
ROWS_BEFORE=$("${PSQL[@]}" -c "select count(*) from dog_log.state")
"${PSQL[@]}" -f "$ROLLBACK" >/dev/null
[ "$("${PSQL[@]}" -c "select count(*) from dog_log.state")" = "$ROWS_BEFORE" ] || fail "WORK-147 rollback changed cloud rows"
[ "$("${PSQL[@]}" -c "select position('freezer-to-fridge transfer' in pg_get_functiondef('dog_log._process_due_meals(uuid,timestamptz,text)'::regprocedure))")" = "0" ] || fail "WORK-147 rollback did not restore prior meal function"
[ "$("${PSQL[@]}" -c "select position('transferred_since' in pg_get_functiondef('dog_log._apply_op(uuid,jsonb,timestamptz,bigint)'::regprocedure))")" != "0" ] || fail "WORK-147 rollback lost transfer-aware reconciliation"
[ "$("${PSQL[@]}" -c "select count(*) from information_schema.columns where table_schema='dog_log' and table_name='meal_events' and column_name='freezer_to_fridge_count'")" = "1" ] || fail "WORK-147 rollback lost transfer ledger"
pass "WORK-147 rollback stops future transfers while preserving transfer-aware reconciliation and cloud rows"
"${PSQL[@]}" --single-transaction -f "$MIGRATION"
[ "$("${PSQL[@]}" -c "select position('freezer-to-fridge transfer' in pg_get_functiondef('dog_log._process_due_meals(uuid,timestamptz,text)'::regprocedure))")" != "0" ] || fail "WORK-147 meal function did not reapply"
[ "$("${PSQL[@]}" -c "select position('transferred_since' in pg_get_functiondef('dog_log._apply_op(uuid,jsonb,timestamptz,bigint)'::regprocedure))")" != "0" ] || fail "WORK-147 operation function did not reapply"
pass "WORK-147 migration re-applies cleanly"

echo "== base rollback"
if "${PSQL[@]}" -f "$BASE_ROLLBACK" >/dev/null 2>"$WORK/rb.err"; then fail "base rollback ran while cloud state exists"; fi
grep -q "rollback refused" "$WORK/rb.err" || fail "base rollback failed for the wrong reason: $(cat "$WORK/rb.err")"
[ "$("${PSQL[@]}" -c "select count(*) from dog_log.state")" = "2" ] || fail "refused base rollback changed data"
pass "post-seed base rollback refused; data intact"
"${PSQL[@]}" -c "delete from dog_log.state"
"${PSQL[@]}" -f "$BASE_ROLLBACK" >/dev/null
[ -z "$("${PSQL[@]}" -c "select 1 from pg_namespace where nspname = 'dog_log'")" ] || fail "schema still present after base rollback"
[ -z "$("${PSQL[@]}" -c "select 1 from pg_publication_tables where schemaname = 'dog_log'")" ] || fail "publication still references dog_log"
pass "pre-adoption base rollback removed the schema and the publication entry"
"${PSQL[@]}" --single-transaction -f "$BASE_MIGRATION"
"${PSQL[@]}" --single-transaction -f "$MIGRATION"
pass "base + WORK-147 migrations re-apply cleanly after rollback"

echo "ALL LOCAL DOG_LOG DATABASE TESTS PASSED"
