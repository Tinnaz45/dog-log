// Regression tests for the independent review findings (M1-M3, minor 3).
const { test, expect, g, raw, outboxOps, waitSynced, seededDevice } = require('../lib/helpers');

test('M1 queued operations are never sent unless the signed-in user owns them', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  await g(a.page, () => { meta.owner_id = '00000000-0000-4000-8000-000000000000'; saveMeta(); });
  const before = backend.rpcCalls('sync').length;
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);
  await a.page.waitForTimeout(1500);
  expect(backend.rpcCalls('sync').slice(before).filter(c => JSON.parse(c.body).p_mutations.length)).toEqual([]);
  expect(await outboxOps(a.page)).toHaveLength(1);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(5);
});

test('M2 edits made to the legacy key while the app is running are backed up before the mirror is rewritten', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const edited = JSON.stringify({ ...JSON.parse(await raw(a.page)), stock: { ...JSON.parse(await raw(a.page)).stock, freezer: 55 } });
  await a.page.evaluate(v => localStorage.setItem('dog_food_stock_v2', v), edited); // e.g. a v8 tab still open
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);                        // next mirror write
  await waitSynced(a.page);
  expect((await g(a.page, () => backups())).find(b => b.reason === 'pre-resync').raw).toBe(edited);
  expect(await g(a.page, () => review.map(r => r.kind))).toEqual(['resync']);
  expect((await backend.state(a.owner)).doc.stock.freezer).toBe(12);
});

test('M3 restoring changes made while sync was off subtracts meals fed after the backup\'s own meal cursor', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const mirror = JSON.parse(await raw(a.page));
  const edited = JSON.stringify({ ...mirror, stock: { ...mirror.stock, fridge: 20 } });
  await a.page.evaluate(v => localStorage.setItem('dog_food_stock_v2', v), edited);
  await a.page.reload();
  await waitSynced(a.page);
  a.ctl.down = true;
  await g(a.page, () => showView('settings'));
  await a.page.click('#reviewList button:has-text("Restore to cloud")');
  const [op] = await outboxOps(a.page);
  expect(op).toMatchObject({ type: 'replace_state', subtract_meals_since: true, backup_created_at: new Date(mirror.tracking.mealCursor).toISOString(), expected_revision: await g(a.page, () => cache.revision) });
  expect(op.doc.tracking).toBeUndefined();
  a.ctl.down = false;
  await a.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await waitSynced(a.page);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(20);
  expect(await backend.count('state_snapshots', a.owner)).toBe(2); // the server snapshotted before replacing
});

test('minor 3: a recreated cloud row (lower revision) is backed up and adopted, not ignored', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  for (let i = 0; i < 3; i++) { await a.page.click(`button[onclick="adjust('fridge',1)"]`); await waitSynced(a.page); }
  await backend.pool.query('delete from dog_log.state where owner_id = $1', [a.owner]);
  await backend.rpc('seed_state', { p_seed_id: '11111111-2222-4333-8444-555555555555', p_doc: { stock: { fridge: 2 } }, p_device_id: 'recovery', p_client_version: 1 }, { sub: a.owner, role: 'authenticated' });
  await a.page.click(`button[onclick="adjust('freezer',1)"]`);
  await waitSynced(a.page);
  await expect(a.page.locator('#fridgeVal')).toHaveValue('2');
  expect(await g(a.page, () => cache.revision)).toBe((await backend.state(a.owner)).revision);
  expect((await g(a.page, () => backups())).some(b => b.reason === 'pre-adopt')).toBe(true);
});
