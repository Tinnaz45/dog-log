// Disposable local PostgreSQL for the sync tests: loads the local Supabase stub and the real dog_log
// migration, so the tests exercise the exact server functions the app talks to. Never touches Supabase.
const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const SUPA = path.resolve(__dirname, '../../../supabase');
const MIGRATIONS = [
  path.join(SUPA, 'migrations/20260924225253_dog_log_create_sync_schema.sql'),
  path.join(SUPA, 'migrations/20260926005200_dog_log_add_evening_freezer_transfer.sql'),
  path.join(SUPA, 'migrations/20260926130000_dog_log_configurable_food_schedule.sql'),
];
const STUB = path.join(SUPA, 'tests/local/supabase_stub.sql');

function binDir() {
  if (process.env.PG_BINDIR) return process.env.PG_BINDIR;
  try { return execFileSync('pg_config', ['--bindir']).toString().trim(); } catch (e) { /* fall through */ }
  const base = '/usr/lib/postgresql';
  const v = fs.existsSync(base) ? fs.readdirSync(base).sort((a, b) => b - a)[0] : null;
  if (!v) throw new Error('PostgreSQL 15+ server binaries not found; set PG_BINDIR');
  return path.join(base, v, 'bin');
}

// initdb refuses to run as root; in a root container run the server as "nobody".
function run(cmd, args) {
  const root = process.getuid && process.getuid() === 0;
  const r = root
    ? spawnSync('su', ['nobody', '-s', '/bin/sh', '-c', [cmd, ...args].map(a => `'${a.replace(/'/g, `'\\''`)}'`).join(' ')], { encoding: 'utf8' })
    : spawnSync(cmd, args, { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`${cmd} failed: ${r.stderr || r.stdout}`);
  return r.stdout;
}

function start(port) {
  const bin = binDir();
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'doglog-pg-'));
  fs.chmodSync(work, 0o777);
  for (const f of [STUB, ...MIGRATIONS]) { fs.copyFileSync(f, path.join(work, path.basename(f))); fs.chmodSync(path.join(work, path.basename(f)), 0o644); }
  run(path.join(bin, 'initdb'), ['-D', path.join(work, 'data'), '-U', 'postgres', '--auth=trust', '-E', 'UTF8']);
  // Unix socket in the work directory; on Windows, TCP on 127.0.0.1 (and the server must not inherit pg_ctl's pipes).
  const win = process.platform === 'win32', host = win ? '127.0.0.1' : work;
  const listen = win ? `-p ${port} -c listen_addresses=127.0.0.1` : `-p ${port} -k ${work} -c listen_addresses=''`;
  const ctl = [path.join(bin, 'pg_ctl'), ['-D', path.join(work, 'data'), '-o', listen, '-l', path.join(work, 'log'), '-w', 'start']];
  if (win) { if (spawnSync(...ctl, { stdio: 'ignore' }).status !== 0) throw new Error('pg_ctl start failed'); } else run(...ctl);
  const psql = (file) => run(path.join(bin, 'psql'), ['-h', host, '-p', String(port), '-U', 'postgres', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '--single-transaction', '-f', path.join(work, path.basename(file))]);
  psql(STUB);
  for (const migration of MIGRATIONS) psql(migration);
  return {
    host,
    port,
    stop() {
      try { run(path.join(bin, 'pg_ctl'), ['-D', path.join(work, 'data'), '-m', 'immediate', 'stop']); } catch (e) { /* already stopped */ }
      fs.rmSync(work, { recursive: true, force: true });
    },
  };
}

module.exports = { start };
