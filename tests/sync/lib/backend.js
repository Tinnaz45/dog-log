// Local stand-in for Supabase, wired into each browser context with Playwright routing:
//   - Auth (GoTrue): password + refresh-token grants, logout. Sign-up is recorded and refused.
//   - PostgREST RPC: dog_log.sync / dog_log.seed_state executed in the disposable local database as the
//     `authenticated` role with request.jwt.claims, i.e. the real migration's functions and privileges.
//   - Realtime: a minimal Phoenix (vsn 2.0.0) channel server that pushes dog_log.state UPDATEs.
// Every other request outside the app origin is aborted, so a test can never reach Supabase DEV or PROD.
const crypto = require('crypto');
const { Pool } = require('pg');

const PROJECT = 'https://wgcqzamuspuqpedqasbc.supabase.co';
const SECRET = 'local-emulator-only-secret';
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PATCH,DELETE,OPTIONS', 'access-control-expose-headers': '*' };
const b64 = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');

class Backend {
  constructor() {
    this.pool = new Pool({ host: process.env.DOGLOG_PGHOST, port: Number(process.env.DOGLOG_PGPORT), user: 'postgres', database: 'postgres', max: 6 });
    this.users = new Map();
    this.conns = new Set();
    this.reset();
  }

  reset() {
    this.calls = [];          // every request that reached the emulator
    this.calendarPosts = [];  // Apps Script bridge posts
    this.down = false;        // true: every Supabase request fails like a dropped network
    this.dropResponses = 0;   // >0: run the RPC and commit, then lose the response (lost ack)
    this.rpcDelayMs = 0;
    this.realtimeBlocked = false;
    this.expired = false;     // true: every access token is rejected as expired
    this.revisions = new Map();
  }

  async resetDb() {
    this.reset();
    await this.pool.query('truncate dog_log.state, dog_log.meal_events, dog_log.mutations, dog_log.state_snapshots cascade');
    await this.pool.query('delete from auth.users');
    this.users.clear();
  }

  async createUser(email, password) {
    const id = crypto.randomUUID();
    await this.pool.query('insert into auth.users (id, email) values ($1, $2)', [id, email]);
    this.users.set(email, { id, email, password });
    return id;
  }

  token(user) {
    const now = Math.floor(Date.now() / 1000);
    const body = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: user.id, email: user.email, role: 'authenticated', aud: 'authenticated', iat: now, exp: now + 3600, session_id: crypto.randomUUID() })}`;
    return `${body}.${crypto.createHmac('sha256', SECRET).update(body).digest('base64url')}`;
  }

  claims(req) {
    const auth = req.headers()['authorization'] || '';
    const t = auth.replace(/^Bearer /, '');
    const [h, p, sig] = t.split('.');
    if (!sig || crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url') !== sig) return null;
    const c = JSON.parse(Buffer.from(p, 'base64url').toString());
    if (this.expired || c.exp * 1000 < Date.now()) return { expired: true };
    return c;
  }

  session(user) {
    const refresh = crypto.randomBytes(16).toString('hex');
    this.users.get(user.email).refresh = refresh;
    const now = Math.floor(Date.now() / 1000);
    return { access_token: this.token(user), token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: refresh,
      user: { id: user.id, aud: 'authenticated', role: 'authenticated', email: user.email, app_metadata: { provider: 'email', providers: ['email'] }, user_metadata: {}, identities: [], created_at: new Date().toISOString() } };
  }

  // Returns a per-device controller: ctl.down = true drops only this device's Supabase traffic.
  async install(context, appUrl) {
    const ctl = { down: false };
    await context.route(() => true, route => {
      const u = route.request().url();
      if (u.startsWith(appUrl) || u.startsWith('data:') || u.startsWith('blob:')) return route.continue();
      if (u.startsWith('https://script.google.com/')) { this.calendarPosts.push(route.request().postData()); return route.fulfill({ status: 200, body: '' }); }
      return route.abort('blockedbyclient');
    });
    await context.route(`${PROJECT}/**`, route => this.handle(route, ctl));
    await context.routeWebSocket(/wgcqzamuspuqpedqasbc\.supabase\.co\/realtime/, ws => this.realtime(ws, ctl));
    return ctl;
  }

  async handle(route, ctl = {}) {
    const req = route.request();
    const url = new URL(req.url());
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
    const call = { method: req.method(), path: url.pathname, search: url.search, body: req.postData(), headers: req.headers() };
    this.calls.push(call);
    if (this.down || ctl.down) return route.abort('internetdisconnected');
    const json = (status, body) => route.fulfill({ status, headers: { ...CORS, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    if (url.pathname === '/auth/v1/token') {
      const b = JSON.parse(req.postData() || '{}');
      const grant = url.searchParams.get('grant_type');
      const user = grant === 'password' ? this.users.get(b.email) : [...this.users.values()].find(u => u.refresh && u.refresh === b.refresh_token);
      if (!user || (grant === 'password' && user.password !== b.password)) return json(400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials', error: 'invalid_grant', error_description: 'Invalid login credentials' });
      return json(200, this.session(user));
    }
    if (url.pathname === '/auth/v1/logout') return route.fulfill({ status: 204, headers: CORS });
    if (url.pathname === '/auth/v1/user') {
      const c = this.claims(req);
      const user = c && !c.expired && [...this.users.values()].find(u => u.id === c.sub);
      return user ? json(200, this.session(user).user) : json(401, { code: 401, msg: 'invalid JWT' });
    }
    if (url.pathname === '/auth/v1/signup') return json(403, { code: 403, msg: 'Signups not allowed for this instance' });
    const m = url.pathname.match(/^\/rest\/v1\/rpc\/(\w+)$/);
    if (m && req.method() === 'POST') {
      if (this.rpcDelayMs) await new Promise(r => setTimeout(r, this.rpcDelayMs));
      const c = this.claims(req);
      if (c && c.expired) return json(401, { code: 'PGRST303', message: 'JWT expired', details: null, hint: null });
      if (req.headers()['content-profile'] !== 'dog_log') return json(406, { code: 'PGRST106', message: 'Invalid schema' });
      const out = await this.rpc(m[1], JSON.parse(req.postData() || '{}'), c);
      if (this.dropResponses > 0) { this.dropResponses--; return route.abort('connectionreset'); }
      return json(out.status, out.body);
    }
    return json(404, { message: 'not emulated' });
  }

  async rpc(fn, a, claims) {
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await client.query(`set local role ${claims ? 'authenticated' : 'anon'}`);
      await client.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims || { role: 'anon' })]);
      let r;
      if (fn === 'sync') r = await client.query('select dog_log.sync($1::jsonb, $2::text, $3::int) as r', [JSON.stringify(a.p_mutations ?? []), a.p_device_id ?? null, a.p_client_version ?? 1]);
      else if (fn === 'seed_state') r = await client.query('select dog_log.seed_state($1::uuid, $2::jsonb, $3::text, $4::int) as r', [a.p_seed_id, JSON.stringify(a.p_doc), a.p_device_id ?? null, a.p_client_version ?? 1]);
      else { await client.query('rollback'); return { status: 404, body: { code: 'PGRST202', message: `Could not find the function dog_log.${fn}` } }; }
      await client.query('commit');
      if (claims) this.afterCommit(claims.sub);
      return { status: 200, body: r.rows[0].r };
    } catch (e) {
      await client.query('rollback').catch(() => {});
      return { status: e.code === '42501' ? (claims ? 403 : 401) : 400, body: { code: e.code, message: e.message, details: e.detail || null, hint: e.hint || null } };
    } finally { client.release(); }
  }

  async afterCommit(owner) {
    const r = await this.pool.query('select revision from dog_log.state where owner_id = $1', [owner]);
    const rev = r.rows[0] && Number(r.rows[0].revision);
    if (rev == null || this.revisions.get(owner) === rev) return;
    this.revisions.set(owner, rev);
    if (!this.realtimeBlocked) this.push(owner, { owner_id: owner, revision: rev });
  }

  realtime(ws, ctl = {}) {
    const conn = { ws, topics: new Map(), ctl };
    this.conns.add(conn);
    const send = (m) => { try { ws.send(JSON.stringify(m)); } catch (e) { /* closed */ } };
    ws.onMessage(raw => {
      let msg; try { msg = JSON.parse(String(raw)); } catch (e) { return; }
      const [joinRef, ref, topic, event, payload] = Array.isArray(msg) ? msg : [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload];
      if (topic === 'phoenix' && event === 'heartbeat') return send([null, ref, 'phoenix', 'phx_reply', { status: 'ok', response: {} }]);
      if (event === 'phx_join') {
        const bindings = ((payload.config && payload.config.postgres_changes) || []).map((p, i) => ({ id: 7000 + i, event: p.event, schema: p.schema, table: p.table, ...(p.filter ? { filter: p.filter } : {}) }));
        conn.topics.set(topic, { joinRef, bindings });
        return send([joinRef, ref, topic, 'phx_reply', { status: 'ok', response: { postgres_changes: bindings } }]);
      }
      if (event === 'phx_leave') { conn.topics.delete(topic); return send([joinRef, ref, topic, 'phx_reply', { status: 'ok', response: {} }]); }
    });
    ws.onClose(() => this.conns.delete(conn));
  }

  push(owner, record) {
    for (const { topics, ws, ctl } of this.conns) if (!ctl.down) for (const [topic, t] of topics) for (const b of t.bindings) {
      if (b.schema !== 'dog_log' || b.table !== 'state' || !['UPDATE', '*'].includes(b.event) || b.filter !== `owner_id=eq.${owner}`) continue;
      try {
        ws.send(JSON.stringify([t.joinRef, null, topic, 'postgres_changes', { ids: [b.id], data: { schema: 'dog_log', table: 'state', commit_timestamp: new Date().toISOString(), type: 'UPDATE', record, old_record: {}, columns: [{ name: 'owner_id', type: 'uuid' }, { name: 'revision', type: 'int8' }], errors: null } }]));
      } catch (e) { /* closed */ }
    }
  }

  // --- direct database reads for assertions ---
  async state(owner) { const r = await this.pool.query('select * from dog_log.state where owner_id = $1', [owner]); const row = r.rows[0]; return row ? { ...row, revision: Number(row.revision) } : null; }
  async count(table, owner) { const r = await this.pool.query(`select count(*)::int as n from dog_log.${table} where owner_id = $1`, [owner]); return r.rows[0].n; }
  async ledger(owner) { const r = await this.pool.query('select mutation_id, op_type, status, detail from dog_log.mutations where owner_id = $1 order by applied_at, client_created_at', [owner]); return r.rows; }
  rpcCalls(fn) { return this.calls.filter(c => c.path === `/rest/v1/rpc/${fn}`); }
  close() { return this.pool.end(); }
}

module.exports = { Backend, PROJECT };
