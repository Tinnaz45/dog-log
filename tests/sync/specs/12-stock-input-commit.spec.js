// Stock fields keep an in-progress edit (WORK-136 #27): render() from the minute tick, a return to the app, a sync or a
// realtime refresh never overwrites the field being edited (which silently dropped the edit on the installed iOS app), and
// hiding the app commits the edit to the outbox before iOS suspends it.
const { test, expect, g, raw, outboxOps, signIn, waitSynced, seededDevice, fixture, setOffline } = require('../lib/helpers');

const sentSets = backend => backend.rpcCalls('sync').flatMap(c => JSON.parse(c.body).p_mutations || []).filter(o => o.type === 'set');
async function typeInto(page, sel, text) {
  await page.locator(sel).focus(); // focus selects the current value, so typing replaces it
  await page.keyboard.type(text);
}
async function secondDevice({ device }) {
  const b = await device({ raw: JSON.stringify(fixture()) });
  await signIn(b.page);
  await waitSynced(b.page);
  await b.page.evaluate(() => showView('food'));
  return b;
}
async function subscribed(backend, owner, n) {
  await expect.poll(() => [...backend.conns].filter(c => [...c.topics.values()].some(t => t.bindings.some(x => x.filter === `owner_id=eq.${owner}`))).length).toBeGreaterThanOrEqual(n);
}
// What iOS does when the installed app is sent to the background: the page becomes hidden, the field stays focused.
async function hide(page, event = 'visibilitychange') {
  await page.evaluate(ev => {
    if (ev === 'pagehide') return window.dispatchEvent(new PageTransitionEvent('pagehide', { persisted: true }));
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  }, event);
}

for (const [name, trigger] of [
  ['the minute tick', () => tick()],
  ['returning to the app', () => resume('visible')],
  ['a cloud refresh', () => refreshView(false)],
]) {
  test(`42 ${name} during an edit keeps the typed value, and leaving the field saves it once`, async ({ device, backend }) => {
    const a = await seededDevice({ device, backend });
    await typeInto(a.page, '#lykaVal', '0');
    await g(a.page, trigger);
    await expect(a.page.locator('#lykaVal')).toHaveValue('0'); // previously reset to 4, dropping the edit
    await a.page.locator('#fridgeVal').focus();
    await waitSynced(a.page);
    expect(sentSets(backend)).toMatchObject([{ key: 'lykaPackets', value: 0, expected: 4 }]);
    expect(await backend.ledger(a.owner)).toMatchObject([{ op_type: 'set', status: 'applied', detail: { key: 'lykaPackets', before: 4, after: 0 } }]);
    await expect(a.page.locator('#lykaVal')).toHaveValue('0');
  });
}

test('43 a realtime change to another field arrives while editing; the edit is kept and applied, the other field updates', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  await subscribed(backend, a.owner, 2);
  await typeInto(b.page, '#fridgeVal', '7');
  await a.page.click(`button[onclick="adjust('freezer',1)"]`);
  await expect(b.page.locator('#freezerVal')).toHaveValue('13', { timeout: 5000 });
  await expect(b.page.locator('#fridgeVal')).toHaveValue('7');
  await b.page.keyboard.press('Enter');
  await waitSynced(b.page);
  const doc = (await backend.state(a.owner)).doc;
  expect(doc.stock).toMatchObject({ fridge: 7, freezer: 13 });
  expect((await backend.ledger(a.owner)).map(r => [r.op_type, r.status])).toEqual([['adjust', 'applied'], ['set', 'applied']]);
});

test('44 an edit begun before another device changed the same field becomes Needs review, never a silent overwrite', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  await subscribed(backend, a.owner, 2);
  await b.page.locator('#fridgeVal').focus(); // B sees 5
  await a.page.fill('#fridgeVal', '10');
  await a.page.locator('#fridgeVal').blur();
  await waitSynced(a.page);
  await expect.poll(() => g(b.page, () => cache.revision)).toBe((await backend.state(a.owner)).revision);
  await expect(b.page.locator('#fridgeVal')).toHaveValue('5'); // B's field is not rewritten mid-edit
  await b.page.keyboard.type('7');
  await b.page.keyboard.press('Enter');
  await waitSynced(b.page);
  expect(sentSets(backend).map(o => [o.value, o.expected])).toEqual([[10, 5], [7, 5]]);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(10);
  expect((await backend.ledger(a.owner)).map(r => r.status)).toEqual(['applied', 'conflict']);
  await expect(b.page.locator('#syncBadge')).toHaveText('Needs review · 1');
  await expect(b.page.locator('#fridgeVal')).toHaveValue('10');
});

test('45 leaving a field without editing shows the value that changed meanwhile, and saves nothing', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  await subscribed(backend, a.owner, 2);
  await b.page.locator('#scratchVal').focus();
  await a.page.click(`button[onclick="adjust('scratchPackets',1)"]`);
  await waitSynced(a.page);
  await expect.poll(() => g(b.page, () => cache.revision)).toBe((await backend.state(a.owner)).revision);
  await expect(b.page.locator('#scratchVal')).toHaveValue('2');
  await b.page.locator('#scratchVal').blur();
  await expect(b.page.locator('#scratchVal')).toHaveValue('3');
  await b.page.waitForTimeout(500);
  expect(sentSets(backend)).toEqual([]);
});

test('46 hiding the app mid-edit commits the edit to the outbox; it survives a restart and applies once', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  a.ctl.down = true; // Supabase unreachable, as when iOS suspends the app before the request can go out
  await typeInto(a.page, '#lykaVal', '1');
  await hide(a.page);
  const ops = await outboxOps(a.page);
  expect(ops).toMatchObject([{ type: 'set', key: 'lykaPackets', value: 1, expected: 4 }]);
  await a.page.reload(); // the suspended app is later relaunched
  expect(await outboxOps(a.page)).toEqual(ops);
  await expect(a.page.locator('#lykaVal')).toHaveValue('1');
  a.ctl.down = false;
  await a.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await waitSynced(a.page);
  expect(await backend.ledger(a.owner)).toMatchObject([{ mutation_id: ops[0].mutation_id, op_type: 'set', status: 'applied' }]);
  expect(new Set(sentSets(backend).map(o => o.mutation_id))).toEqual(new Set([ops[0].mutation_id]));
  expect((await backend.state(a.owner)).doc.stock.lykaPackets).toBe(1);
});

test('47 pagehide also commits the edit; hiding with an unchanged field saves nothing', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  await a.page.locator('#scratchVal').focus();
  await hide(a.page); // focused, unchanged
  await a.page.waitForTimeout(400);
  expect(await outboxOps(a.page)).toEqual([]);
  await typeInto(a.page, '#scratchVal', '1');
  await hide(a.page, 'pagehide');
  await waitSynced(a.page);
  expect(sentSets(backend)).toMatchObject([{ key: 'scratchPackets', value: 1, expected: 2 }]);
  expect(await backend.ledger(a.owner)).toHaveLength(1);
});

test('48 a Food Settings field being edited is also committed when the app is hidden', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  await g(a.page, () => showView('settings'));
  await typeInto(a.page, '#setTotal', '44');
  await hide(a.page);
  await waitSynced(a.page);
  expect(await backend.ledger(a.owner)).toMatchObject([{ op_type: 'settings', status: 'applied', detail: { field: 'totalContainers', before: 40, after: 44 } }]);
});

test('49 without cloud sync, a re-render during an edit keeps the typed value and saves it locally', async ({ device }) => {
  const d = await device({ raw: JSON.stringify(fixture()) });
  await typeInto(d.page, '#freezerVal', '9');
  await g(d.page, () => { tick(); render(); }); // local mode re-renders on meals, other tabs' storage events, etc.
  await expect(d.page.locator('#freezerVal')).toHaveValue('9');
  await d.page.locator('#fridgeVal').focus();
  expect(JSON.parse(await raw(d.page)).stock.freezer).toBe(9);
});
