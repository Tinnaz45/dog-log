// Operation mapping: every user action becomes one reviewed operation type; rendering never writes.
const { test, expect, g, raw, outboxOps, waitSynced, seededDevice } = require('../lib/helpers');

const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
async function online(page, backend) { backend.down = false; await page.evaluate(() => window.dispatchEvent(new Event('online'))); await waitSynced(page); }

test('07 render-only activity creates no mutation and no revision change', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const rev = (await backend.state(a.owner)).revision;
  await g(a.page, () => { for (let i = 0; i < 5; i++) ['food', 'prep', 'plan', 'history', 'settings'].forEach(showView); render(); tick(); refreshView(); document.dispatchEvent(new Event('visibilitychange')); window.dispatchEvent(new Event('focus')); });
  await a.page.waitForTimeout(1000);
  await waitSynced(a.page);
  expect(await outboxOps(a.page)).toEqual([]);
  expect(backend.rpcCalls('sync').every(c => JSON.parse(c.body).p_mutations.length === 0)).toBe(true);
  expect(await backend.count('mutations', a.owner)).toBe(0);
  expect((await backend.state(a.owner)).revision).toBe(rev);
});

test('08 adjust (± buttons) becomes an adjust operation, applied once', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);
  const [op] = await outboxOps(a.page);
  expect(op).toMatchObject({ type: 'adjust', key: 'fridge', delta: 1, label: 'Fridge +1', device_id: await g(a.page, () => deviceId) });
  expect(op.mutation_id).toMatch(uuidRe);
  expect(Math.abs(Date.parse(op.client_created_at) - Date.now())).toBeLessThan(10000);
  await expect(a.page.locator('#fridgeVal')).toHaveValue('6'); // optimistic
  await online(a.page, backend);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(6);
  expect(await backend.ledger(a.owner)).toMatchObject([{ mutation_id: op.mutation_id, op_type: 'adjust', status: 'applied' }]);
});

test('09 typed stock entry becomes a conditional set carrying the value the user saw', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await a.page.fill('#fridgeVal', '9');
  await a.page.locator('#fridgeVal').blur();
  const [op] = await outboxOps(a.page);
  expect(op).toMatchObject({ type: 'set', key: 'fridge', value: 9, expected: 5, label: 'Fridge set to 9 containers' });
  await online(a.page, backend);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(9);
});

test('10 a prep batch maps to prep_batch with conditional ingredient left-overs', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await g(a.page, () => showView('prep'));
  await a.page.fill('#prepContainers', '6');
  await a.page.fill('#prepMinceStart', '2.5');
  await a.page.fill('#prepMinceLeft', '0.5');
  await a.page.fill('#prepNecksStart', '3');
  await a.page.fill('#prepNecksLeft', '1');
  await a.page.selectOption('#prepDestination', 'freezer');
  await a.page.click('#prep button.primary');
  const [op] = await outboxOps(a.page);
  expect(op).toMatchObject({ type: 'prep_batch', destination: 'freezer', containers: 6, minceLeftKg: 0.5, neckPacketsLeft: 1, expectedMinceKg: 2.5, expectedNeckPackets: 3, label: 'Prep batch: 6 containers from 2 kg mince and 2 neck packets', batch: { containers: 6, minceUsedKg: 2, neckPacketsUsed: 2, minceLeftKg: 0.5, neckPacketsLeft: 1 } });
  await online(a.page, backend);
  const doc = (await backend.state(a.owner)).doc;
  expect(doc.stock).toMatchObject({ freezer: 18, minceKg: 0.5, neckPackets: 1 });
  expect(doc.batches).toHaveLength(2);
  expect(doc.batches[0]).toMatchObject({ containers: 6, minceUsedKg: 2, neckPacketsUsed: 2 });
});

test('11 food settings map to one conditional settings operation per changed field', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await g(a.page, () => showView('settings'));
  await a.page.fill('#setTotal', '45');
  await a.page.fill('#setMinceIncrement', '1');
  await a.page.click('button:has-text("Save settings")');
  const ops = await outboxOps(a.page);
  expect(ops).toMatchObject([
    { type: 'settings', field: 'totalContainers', value: 45, expected: 40, label: 'Food settings updated' },
    { type: 'settings', field: 'mincePurchaseIncrementKg', value: 1, expected: 0.5 },
  ]);
  expect(ops[1].label).toBeUndefined();
  await online(a.page, backend);
  expect((await backend.state(a.owner)).doc.settings).toEqual({ totalContainers: 45, mincePurchaseIncrementKg: 1 });
});

test('12 the calendar endpoint syncs as a setting; the pairing token never leaves the device', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  await g(a.page, () => showView('settings'));
  const ep = 'https://script.google.com/macros/s/AKfy-new-endpoint/exec';
  await a.page.fill('#calendarEndpoint', ep);
  await a.page.click('button:has-text("Connect calendar")');
  await waitSynced(a.page);
  expect((await backend.state(a.owner)).doc.calendar).toEqual({ endpoint: ep });
  const sent = backend.calls.flatMap(c => JSON.parse(c.body || '{}').p_mutations || []);
  expect(sent.filter(o => o.type === 'calendar_endpoint')).toMatchObject([{ value: ep, expected: 'https://script.google.com/macros/s/AKfy-local-test/exec' }]);
  const token = JSON.parse(await raw(a.page)).calendar.token;
  expect(token).toBe('device-secret-token-0123456789abcdef');
  expect(backend.calls.some(c => JSON.stringify(c).includes(token))).toBe(false);
  await expect.poll(() => backend.calendarPosts.some(b => (b || '').includes(token))).toBe(true); // only the Apps Script bridge sees it
});
