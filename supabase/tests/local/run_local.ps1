# =============================================================================
# Windows PowerShell equivalent of run_local.sh: disposable local test run for the
# Dog Log base sync schema, WORK-147 evening transfer and WORK-148 configurable
# Food Settings. Creates a throwaway PostgreSQL cluster (TCP on 127.0.0.1 only),
# loads the local Supabase stub, applies the migrations, runs the SQL suite, the
# two-session concurrency tests and the rollback tests, then deletes the cluster.
# It never connects to Supabase DEV or PROD.
#
#   $env:PG_BINDIR = 'C:\path\to\pgsql\bin'   # PostgreSQL 15+ (initdb, pg_ctl, psql)
#   powershell -File supabase\tests\local\run_local.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Supa = (Resolve-Path (Join-Path $Here '..\..')).Path
$Base      = Join-Path $Supa 'migrations\20260924225253_dog_log_create_sync_schema.sql'
$W147      = Join-Path $Supa 'migrations\20260926005200_dog_log_add_evening_freezer_transfer.sql'
$W148      = Join-Path $Supa 'migrations\20260926130000_dog_log_configurable_food_schedule.sql'
$W148Rb    = Join-Path $Supa 'rollbacks\20260926130000_dog_log_configurable_food_schedule.rollback.sql'
$W147Rb    = Join-Path $Supa 'rollbacks\20260926005200_dog_log_add_evening_freezer_transfer.rollback.sql'
$BaseRb    = Join-Path $Supa 'rollbacks\20260924225253_dog_log_create_sync_schema.rollback.sql'
$Bin  = if ($env:PG_BINDIR) { $env:PG_BINDIR } else { (& pg_config --bindir) }
$Port = if ($env:PGTEST_PORT) { $env:PGTEST_PORT } else { '55439' }
$Work = Join-Path ([IO.Path]::GetTempPath()) ('doglog-pg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $Work | Out-Null

$env:PGHOST = '127.0.0.1'; $env:PGPORT = $Port; $env:PGUSER = 'postgres'; $env:PGDATABASE = 'postgres'; $env:PGCLIENTENCODING = 'UTF8'
function Fail($m) { Write-Host "FAIL $m"; throw "FAIL $m" }
function Pass($m) { Write-Host "ok   $m" }
# Run psql; returns stdout lines. Throws on a non-zero exit unless -AllowFail.
function Psql([string[]]$a, [switch]$AllowFail) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $o = & (Join-Path $Bin 'psql.exe') -X -q -v ON_ERROR_STOP=1 -tA @a 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE; $ErrorActionPreference = $prev
  if ($code -ne 0 -and -not $AllowFail) { $o | ForEach-Object { Write-Host $_ }; Fail "psql $($a -join ' ')" }
  $script:LastCode = $code
  return $o
}
function Val([string]$sql) { ((Psql @('-c', $sql)) | Where-Object { $_ -notmatch 'WARNING|HINT' } | Select-Object -Last 1) }
# One transaction as an authenticated Supabase user, as a background job.
function AsUserJob([string]$uid, [string]$sql) {
  $script = "begin;`nset local role authenticated;`nselect set_config('request.jwt.claims', '{""sub"":""$uid"",""role"":""authenticated""}', true) \g`n$sql`ncommit;"
  Start-Job -ArgumentList (Join-Path $Bin 'psql.exe'), $script, $Port -ScriptBlock {
    param($psql, $s, $port)
    $env:PGHOST = '127.0.0.1'; $env:PGPORT = $port; $env:PGUSER = 'postgres'; $env:PGDATABASE = 'postgres'
    $s | & $psql -X -q -v ON_ERROR_STOP=1 -tA -f - 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -ne '' -and $_ -notmatch 'set_config|^\s*$' }
  }
}
function LastLine($job) { (Receive-Job $job -Wait -AutoRemoveJob | Where-Object { $_ -ne '' }) | Select-Object -Last 1 }

try {
  & (Join-Path $Bin 'initdb.exe') -D "$Work\data" -U postgres --auth=trust -E UTF8 | Out-Null
  # Start-Process, not a pipeline: the server inherits pg_ctl's handles and would keep a pipe open forever.
  $p = Start-Process -FilePath (Join-Path $Bin 'pg_ctl.exe') -ArgumentList @('-D', "`"$Work\data`"", '-o', "`"-p $Port -c listen_addresses=127.0.0.1`"", '-l', "`"$Work\log`"", '-w', 'start') -NoNewWindow -PassThru
  $p.WaitForExit()   # not -Wait: in Windows PowerShell that also waits for the (long-lived) server process
  if ($p.ExitCode -ne 0) { Fail 'pg_ctl start' }

  Write-Host '== install (clean database)'
  Psql @('-f', (Join-Path $Here 'supabase_stub.sql')) | Out-Null
  foreach ($m in $Base, $W147, $W148) { Psql @('--single-transaction', '-f', $m) | Out-Null }
  Pass 'base + WORK-147 + WORK-148 migrations applied to a clean database'

  Write-Host '== SQL suite'
  $out = Psql @('-f', (Join-Path $Supa 'tests\dog_log_sync.sql')) -AllowFail
  $out | ForEach-Object { $_ -replace '^psql:[^ ]* NOTICE:  ', '' } | Where-Object { $_ -match '^(ok|FAIL|ALL)|ERROR' } | ForEach-Object { Write-Host $_ }
  if ($LastCode -ne 0 -or -not ($out -match 'ALL DOG_LOG SQL TESTS PASSED')) { Fail 'SQL suite' }
  if ((Val 'select count(*) from dog_log.state') -ne '0') { Fail 'SQL suite left rows behind' }
  Pass 'SQL suite rolled back cleanly'

  Write-Host '== concurrency: two clients sync the same due events at once'
  $C = 'cccccccc-0000-4000-8000-00000000000c'
  Psql @('-c', "insert into auth.users (id) values ('$C')") | Out-Null
  $seed = "select dog_log.seed_state(gen_random_uuid(), jsonb_build_object('stock', jsonb_build_object('fridge', 5, 'freezer', 0), 'tracking', jsonb_build_object('mealCursor', (extract(epoch from now() - interval '30 hours') * 1000)::bigint)), 'seed', 1) \g"
  Receive-Job (AsUserJob $C $seed) -Wait -AutoRemoveJob | Out-Null
  $s1 = AsUserJob $C "select dog_log.sync('[]'::jsonb, 'desktop', 1) ->> 'revision';`nselect pg_sleep(2) \g"
  Start-Sleep -Milliseconds 700
  $s2 = AsUserJob $C "select dog_log.sync('[]'::jsonb, 'iphone', 1) ->> 'revision';"
  $r1 = LastLine $s1; $r2 = LastLine $s2
  $expected = Val "select count(*) from (select (d::date + t) at time zone 'Australia/Melbourne' as at from generate_series(((now() - interval '31 hours') at time zone 'Australia/Melbourne')::date, (now() at time zone 'Australia/Melbourne')::date, interval '1 day') d, (values (time '09:00'), (time '18:00')) v(t)) s where at > (select meal_tracking_since from dog_log.state where owner_id = '$C') and at <= now()"
  $events  = Val "select count(*) from dog_log.meal_events where owner_id = '$C' and origin = 'server' and slot <> 'transfer'"
  $fridge  = Val "select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = '$C'"
  $devices = Val "select string_agg(distinct processed_by_device, ',') from dog_log.meal_events where owner_id = '$C' and origin = 'server'"
  if ($events -ne $expected) { Fail "concurrent meals: $events events, expected $expected" }
  if ([int]$fridge -ne 5 - [math]::Min([int]$expected, 5)) { Fail "concurrent meals: fridge $fridge" }
  if ($r1 -ne $r2) { Fail "concurrent meals: sessions returned revisions $r1 / $r2" }
  if ($devices -ne 'desktop') { Fail "concurrent meals: processed by '$devices'" }
  Pass "concurrent syncs: $events meal events, one deduction each (fridge 5 -> $fridge); second session saw them as already processed"

  Write-Host '== concurrency: the same mutation retried from two tabs at once'
  $M = '44444444-4444-4444-8444-444444444444'
  $op = "jsonb_build_array(jsonb_build_object('mutation_id', '$M', 'type', 'adjust', 'key', 'freezer', 'delta', 1, 'client_created_at', now(), 'label', 'Freezer +1'))"
  $freezer0 = [int](Val "select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = '$C'")
  $m1 = AsUserJob $C "select dog_log.sync($op, 'tab1', 1) -> 'results' -> 0 ->> 'status';`nselect pg_sleep(1.5) \g"
  Start-Sleep -Milliseconds 500
  $m2 = AsUserJob $C "select dog_log.sync($op, 'tab2', 1) -> 'results' -> 0 ->> 'status';"
  $st = @((LastLine $m1), (LastLine $m2)) | Sort-Object
  if (($st -join ' ') -ne 'applied duplicate') { Fail "retried mutation: $($st -join ' / ')" }
  if ([int](Val "select (doc #>> '{stock,freezer}')::int from dog_log.state where owner_id = '$C'") -ne $freezer0 + 1) { Fail 'retried mutation applied twice' }
  Pass 'retried mutation applied once, second copy returned duplicate'

  Write-Host '== concurrency: two devices seed an empty cloud at the same moment'
  $S = '55555555-0000-4000-8000-000000000005'
  Psql @('-c', "insert into auth.users (id) values ('$S')") | Out-Null
  $k1 = AsUserJob $S "select dog_log.seed_state('aaaaaaaa-1111-4111-8111-111111111111', '{""stock"":{""fridge"":9}}', 'iphone', 1) ->> 'status';`nselect pg_sleep(1.5) \g"
  Start-Sleep -Milliseconds 500
  $k2 = AsUserJob $S "select dog_log.seed_state('bbbbbbbb-2222-4222-8222-222222222222', '{""stock"":{""fridge"":0}}', 'desktop', 1) ->> 'status';"
  $a = LastLine $k1; $b = LastLine $k2
  if ($a -ne 'seeded' -or $b -ne 'cloud-exists') { Fail "seed race: $a / $b" }
  if ((Val "select (doc #>> '{stock,fridge}')::int from dog_log.state where owner_id = '$S'") -ne '9') { Fail 'seed race overwrote the first seed' }
  Pass 'seed race: first seeded, second got cloud-exists, nothing overwritten'

  Write-Host '== WORK-148 rollback'
  $rows = Val 'select count(*) from dog_log.state'
  $transfers = Val "select count(*) from dog_log.meal_events where slot = 'transfer'"
  Psql @('-f', $W148Rb) | Out-Null
  if ((Val 'select count(*) from dog_log.state') -ne $rows) { Fail 'WORK-148 rollback changed cloud rows' }
  if ((Val "select count(*) from dog_log.meal_events where slot = 'transfer'") -ne $transfers) { Fail 'WORK-148 rollback lost transfer rows' }
  if ((Val "select to_regprocedure('dog_log._setting(jsonb,text)') is null and to_regprocedure('dog_log._sched_time(jsonb,text)') is null") -ne 't') { Fail 'WORK-148 helpers still present' }
  if ((Val "select position('v_dinners' in pg_get_functiondef('dog_log._process_due_meals(uuid,timestamptz,text)'::regprocedure)) > 0") -ne 't') { Fail 'WORK-148 rollback did not restore the WORK-147 meal function' }
  if ((Val "select position('transferred_since' in pg_get_functiondef('dog_log._apply_op(uuid,jsonb,timestamptz,bigint)'::regprocedure)) > 0") -ne 't') { Fail 'WORK-148 rollback lost transfer-aware reconciliation' }
  if ((Val "select has_function_privilege('authenticated', 'dog_log.seed_state(uuid,jsonb,text,integer)', 'execute') and not has_function_privilege('authenticated', 'dog_log._apply_op(uuid,jsonb,timestamptz,bigint)', 'execute')") -ne 't') { Fail 'WORK-148 rollback changed privileges' }
  $syncAfter = AsUserJob $C "select dog_log.sync('[]'::jsonb, 'after-rollback', 1) ->> 'status';"
  if ((LastLine $syncAfter) -ne 'ok') { Fail 'sync fails after WORK-148 rollback' }
  Pass 'WORK-148 rollback restores the WORK-147 functions, keeps rows, transfer ledger and privileges; sync still works'
  Psql @('--single-transaction', '-f', $W148) | Out-Null
  if ((Val "select to_regprocedure('dog_log._setting(jsonb,text)') is not null and position('fridgeTransferTime' in pg_get_functiondef('dog_log._process_due_meals(uuid,timestamptz,text)'::regprocedure)) > 0") -ne 't') { Fail 'WORK-148 did not reapply' }
  Pass 'WORK-148 migration re-applies cleanly'

  Write-Host '== WORK-147 rollback (after rolling WORK-148 back)'
  Psql @('-f', $W148Rb) | Out-Null
  Psql @('-f', $W147Rb) | Out-Null
  if ((Val "select position('freezer-to-fridge transfer' in pg_get_functiondef('dog_log._process_due_meals(uuid,timestamptz,text)'::regprocedure))") -ne '0') { Fail 'WORK-147 rollback did not restore prior meal function' }
  Psql @('--single-transaction', '-f', $W147) | Out-Null
  Psql @('--single-transaction', '-f', $W148) | Out-Null
  Pass 'WORK-147 rollback still applies beneath WORK-148; both re-apply cleanly'

  Write-Host '== base rollback'
  Psql @('-f', $BaseRb) -AllowFail | Out-Null
  if ($LastCode -eq 0) { Fail 'base rollback ran while cloud state exists' }
  if ((Val 'select count(*) from dog_log.state') -ne '2') { Fail 'refused base rollback changed data' }
  Pass 'post-seed base rollback refused; data intact'
  Psql @('-c', 'delete from dog_log.state') | Out-Null
  Psql @('-f', $BaseRb) | Out-Null
  if (Val "select 1 from pg_namespace where nspname = 'dog_log'") { Fail 'schema still present after base rollback' }
  foreach ($m in $Base, $W147, $W148) { Psql @('--single-transaction', '-f', $m) | Out-Null }
  Pass 'base + WORK-147 + WORK-148 migrations re-apply cleanly after rollback'

  Write-Host 'ALL LOCAL DOG_LOG DATABASE TESTS PASSED'
}
finally {
  & (Join-Path $Bin 'pg_ctl.exe') -D "$Work\data" -m immediate stop 2>$null | Out-Null
  Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
