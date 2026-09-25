// Food settings autosave (WORK-136 #25): each field commits on Enter/blur as one reviewed settings mutation; nothing the
// app writes into the fields itself (render, adoption, realtime) ever saves; the prep batch stays one deliberate transaction.
const { test, expect, g, raw, outboxOps, signIn, waitSynced, seededDevice, fixture, setOffline } = require('../lib/helpers');

const SETTINGS = { totalContainers: 120, containersPerDay: 2, mincePurchaseIncrementKg: 1 };
const sentOps = backend => backend.rpcCalls('sync').flatMap(c => JSON.parse(c.body).p_mutations || []);
const sentSettings = backend => sentOps(backend).filter(o => o.type === 'settings');
async function settingsDevice(ctx) {
  const a = await seededDevice(ctx, fixture({ settings: SETTINGS }));
  await g(a.page, () => showView('settings'));
  return a;
}
async function secondDevice({ device }, opts = {}) {
  const b = await device({ raw: JSON.stringify(fixture({ settings: { totalContainers: 7, containersPerDay: 2, mincePurchaseIncrementKg: 3 } })), ...opts });
  await signIn(b.page);
  await waitSynced(b.page);
  return b;
}
async function subscribed(backend, owner, n) {
  await expect.poll(() => [...backend.conns].filter(c => [...c.topics.values()].some(t => t.bindings.some(x => x.filter === `owner_id=eq.${owner}`))).length).toBeGreaterThanOrEqual(n);
}

test('31 there is no Save settings button; Total containers saves on blur as exactly one settings mutation', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  await expect(a.page.locator('button:has-text("Save settings")')).toHaveCount(0);
  await expect(a.page.locator('#setTotal')).toHaveValue('120');
  await a.page.fill('#setTotal', '125');
  expect(await outboxOps(a.page)).toEqual([]); // typing alone saves nothing
  await a.page.locator('#setTotal').blur();
  await expect(a.page.locator('#settingsSaveStatus')).toHaveText(/Saving…|Saved/);
  await waitSynced(a.page);
  await expect(a.page.locator('#settingsSaveStatus')).toHaveText('Saved');
  expect(sentSettings(backend)).toMatchObject([{ field: 'totalContainers', value: 125, expected: 120, label: 'Food settings updated' }]);
  expect(await backend.ledger(a.owner)).toMatchObject([{ op_type: 'settings', status: 'applied', detail: { field: 'totalContainers', before: 120, after: 125 } }]);
  expect((await backend.state(a.owner)).doc.settings).toEqual({ totalContainers: 125, mincePurchaseIncrementKg: 1 });
  await expect(a.page.locator('#settingsSaveStatus')).toHaveText('', { timeout: 5000 }); // feedback clears itself
});

test('32 Mince increment commits on Enter once: the blur that follows does not save it again', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  await a.page.fill('#setMinceIncrement', '0.5');
  await a.page.press('#setMinceIncrement', 'Enter');
  await a.page.locator('#setTotal').focus();
  await a.page.locator('#setTotal').blur();
  await waitSynced(a.page);
  expect(sentSettings(backend)).toMatchObject([{ field: 'mincePurchaseIncrementKg', value: 0.5, expected: 1 }]);
  expect(await backend.ledger(a.owner)).toHaveLength(1);
  expect((await backend.state(a.owner)).doc.settings.mincePurchaseIncrementKg).toBe(0.5);
  await expect(a.page.locator('#setMinceIncrement')).toHaveValue('0.5');
});

test('33 focusing and leaving a field, or re-entering the same value, creates no mutation', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  const rev = (await backend.state(a.owner)).revision;
  for (const id of ['#setTotal', '#setMinceIncrement']) { await a.page.locator(id).focus(); await a.page.locator(id).blur(); }
  await a.page.fill('#setTotal', '120.0'); await a.page.locator('#setTotal').blur();        // same number, different text
  await a.page.fill('#setMinceIncrement', '1.000'); await a.page.press('#setMinceIncrement', 'Enter');
  await a.page.waitForTimeout(800);
  await waitSynced(a.page);
  expect(sentSettings(backend)).toEqual([]);
  expect(await outboxOps(a.page)).toEqual([]);
  expect((await backend.state(a.owner)).revision).toBe(rev);
  await expect(a.page.locator('#setTotal')).toHaveValue('120');
});

test('34 populating the fields from the cloud (adoption, reload, render) never saves', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  const b = await secondDevice({ device, backend }); // its own local settings (7 / 3) are backed up, not uploaded
  await g(b.page, () => showView('settings'));
  await expect(b.page.locator('#setTotal')).toHaveValue('120');
  await expect(b.page.locator('#setMinceIncrement')).toHaveValue('1');
  await b.page.reload();
  await waitSynced(b.page);
  await g(b.page, () => { for (let i = 0; i < 5; i++) { showView('settings'); render(); refreshView(); } });
  await a.page.reload();
  await waitSynced(a.page);
  await b.page.waitForTimeout(800);
  expect(sentOps(backend)).toEqual([]);
  expect(await backend.ledger(a.owner)).toEqual([]);
  expect((await backend.state(a.owner)).doc.settings).toEqual({ totalContainers: 120, mincePurchaseIncrementKg: 1 });
});

test('35 a realtime change updates the other device\'s fields with no echo; an edit started before it becomes Needs review', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  await g(b.page, () => showView('settings'));
  await subscribed(backend, a.owner, 2);
  await a.page.fill('#setTotal', '130');
  await a.page.locator('#setTotal').blur();
  await expect(b.page.locator('#setTotal')).toHaveValue('130', { timeout: 5000 });
  await b.page.waitForTimeout(800);
  expect(sentSettings(backend)).toHaveLength(1); // A's edit only: B applied it without sending anything back
  // Stale-value race: B starts editing at 130, A changes it to 140 meanwhile, then B commits 125.
  await b.page.locator('#setTotal').focus();
  await a.page.fill('#setTotal', '140');
  await a.page.locator('#setTotal').blur();
  await waitSynced(a.page);
  await expect.poll(() => g(b.page, () => cache.revision)).toBe((await backend.state(a.owner)).revision);
  await b.page.fill('#setTotal', '125');
  await b.page.locator('#setTotal').blur();
  await waitSynced(b.page);
  expect((await backend.state(a.owner)).doc.settings.totalContainers).toBe(140);
  expect((await backend.ledger(a.owner)).map(r => r.status)).toEqual(['applied', 'applied', 'conflict']);
  await expect(b.page.locator('#syncBadge')).toHaveText('Needs review · 1');
  await expect(b.page.locator('#settingsSaveStatus')).toHaveText('Not applied: see Needs review above.');
  await expect(b.page.locator('#setTotal')).toHaveValue('140');
});

test('36 invalid values are not saved and the last good value is kept', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  for (const [id, bad] of [['#setTotal', ''], ['#setTotal', '-3'], ['#setTotal', '12.5'], ['#setMinceIncrement', '0'], ['#setMinceIncrement', '-1'], ['#setMinceIncrement', '']]) {
    await a.page.fill(id, bad);
    await a.page.locator(id).blur();
    await expect(a.page.locator('#settingsSaveStatus')).toContainText('Not saved');
  }
  await a.page.waitForTimeout(500);
  expect(sentSettings(backend)).toEqual([]);
  expect(await outboxOps(a.page)).toEqual([]);
  await expect(a.page.locator('#setTotal')).toHaveValue('120');
  await expect(a.page.locator('#setMinceIncrement')).toHaveValue('1');
  expect((await backend.state(a.owner)).doc.settings).toEqual({ totalContainers: 120, mincePurchaseIncrementKg: 1 });
  await a.page.fill('#setTotal', '121'); // a valid value afterwards still saves normally
  await a.page.locator('#setTotal').blur();
  await waitSynced(a.page);
  expect(sentSettings(backend)).toMatchObject([{ field: 'totalContainers', value: 121, expected: 120 }]);
});

test('37 an offline change is persisted once, survives a reload, and applies once on reconnect', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  await setOffline(a, true);
  await a.page.fill('#setTotal', '118');
  await a.page.locator('#setTotal').blur();
  await expect(a.page.locator('#settingsSaveStatus')).toHaveText('Saved on this device. It will sync when you are back online.');
  const ops = await outboxOps(a.page);
  expect(ops).toMatchObject([{ type: 'settings', field: 'totalContainers', value: 118, expected: 120 }]);
  // App restart while Supabase is still unreachable (the page itself must load, so only the backend stays down).
  await a.context.setOffline(false);
  await a.page.reload();
  expect(await outboxOps(a.page)).toEqual(ops);
  await g(a.page, () => showView('settings'));
  await expect(a.page.locator('#setTotal')).toHaveValue('118');
  await expect(a.page.locator('#syncBadge')).toContainText('1 pending');
  await setOffline(a, false);
  await waitSynced(a.page);
  const ledger = await backend.ledger(a.owner);
  expect(ledger).toMatchObject([{ mutation_id: ops[0].mutation_id, op_type: 'settings', status: 'applied' }]);
  expect(new Set(sentSettings(backend).map(o => o.mutation_id))).toEqual(new Set([ops[0].mutation_id])); // retries reuse the id
  expect((await backend.state(a.owner)).doc.settings.totalContainers).toBe(118);
});

test('38 inventory fields still autosave alongside settings', async ({ device, backend }) => {
  const a = await settingsDevice({ device, backend });
  await g(a.page, () => showView('food'));
  await a.page.fill('#freezerVal', '15');
  await a.page.locator('#freezerVal').blur();
  await g(a.page, () => showView('settings'));
  await a.page.fill('#setTotal', '124');
  await a.page.press('#setTotal', 'Enter');
  await waitSynced(a.page);
  expect(sentOps(backend).map(o => [o.type, o.key || o.field, o.value])).toEqual([['set', 'freezer', 15], ['settings', 'totalContainers', 124]]);
  expect((await backend.state(a.owner)).doc.stock.freezer).toBe(15);
});

test('39 prep fields change nothing until Save prep batch, which applies the whole batch exactly once', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const before = await backend.state(a.owner);
  await g(a.page, () => showView('prep'));
  for (const [id, v] of [['#prepContainers', '6'], ['#prepMinceStart', '2.5'], ['#prepMinceLeft', '0.5'], ['#prepNecksStart', '3'], ['#prepNecksLeft', '1']]) {
    await a.page.fill(id, v);
    await a.page.locator(id).blur();
  }
  await a.page.selectOption('#prepDestination', 'fridge');
  await a.page.waitForTimeout(800);
  expect(await outboxOps(a.page)).toEqual([]);
  expect(sentOps(backend)).toEqual([]);
  expect((await backend.state(a.owner)).revision).toBe(before.revision);
  await g(a.page, () => showView('food'));
  await expect(a.page.locator('#fridgeVal')).toHaveValue('5');
  await expect(a.page.locator('#minceVal')).toHaveValue('2.5');
  await g(a.page, () => showView('prep'));
  await expect(a.page.locator('#prep button.primary')).toHaveText('Save prep batch');
  await a.page.click('#prep button.primary');
  await waitSynced(a.page);
  const ledger = await backend.ledger(a.owner);
  expect(ledger).toMatchObject([{ op_type: 'prep_batch', status: 'applied' }]);
  const doc = (await backend.state(a.owner)).doc;
  expect(doc.stock).toMatchObject({ fridge: 11, freezer: 12, minceKg: 0.5, neckPackets: 1 });
  expect(doc.batches).toHaveLength(2);
  expect((await backend.state(a.owner)).revision).toBe(before.revision + 1);
});

test('40 without cloud sync, a settings field saves locally on blur with no button', async ({ device }) => {
  const d = await device({ raw: JSON.stringify(fixture({ settings: SETTINGS })) });
  await g(d.page, () => showView('settings'));
  await d.page.fill('#setTotal', '126');
  await d.page.locator('#setTotal').blur();
  await expect(d.page.locator('#settingsSaveStatus')).toHaveText('Saved');
  const s = JSON.parse(await raw(d.page));
  expect(s.settings).toMatchObject({ totalContainers: 126, mincePurchaseIncrementKg: 1 });
  expect(s.history[0].action).toBe('Food settings updated');
  await d.page.fill('#setMinceIncrement', '0');
  await d.page.locator('#setMinceIncrement').blur();
  await expect(d.page.locator('#settingsSaveStatus')).toContainText('Not saved');
  expect(JSON.parse(await raw(d.page)).settings.mincePurchaseIncrementKg).toBe(1);
});
