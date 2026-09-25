// Conflicts are surfaced, never silently resolved: a stale value cannot overwrite a newer cloud value.
const { test, expect, g, outboxOps, signIn, waitSynced, seededDevice, fixture } = require('../lib/helpers');
const { setOffline } = require('../lib/helpers');

async function secondDevice({ device, backend }, opts = {}) {
  const b = await device({ raw: JSON.stringify(fixture()), ...opts });
  await signIn(b.page);
  await waitSynced(b.page);
  await b.page.evaluate(() => showView('food'));
  return b;
}

test('17 a stale recount becomes "Needs review", the cloud keeps the newer value, and "Use mine" re-applies deliberately', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  await setOffline(b, true);
  await b.page.fill('#fridgeVal', '7');           // B saw 5
  await b.page.locator('#fridgeVal').blur();
  await a.page.fill('#fridgeVal', '10');          // A also saw 5, and syncs first
  await a.page.locator('#fridgeVal').blur();
  await waitSynced(a.page);
  await setOffline(b, false);
  await waitSynced(b.page);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(10);
  expect(await backend.ledger(a.owner)).toMatchObject([{ status: 'applied' }, { status: 'conflict', detail: { current: 10, attempted: 7, expected: 5 } }]);
  await expect(b.page.locator('#fridgeVal')).toHaveValue('10');
  await expect(b.page.locator('#syncBadge')).toHaveText('Needs review · 1');
  await g(b.page, () => showView('settings'));
  await expect(b.page.locator('#reviewList')).toContainText('Cloud 10, yours 7');
  await b.page.click('#reviewList button:has-text("Use mine")');
  await waitSynced(b.page);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(7);
  expect((await outboxOps(b.page))).toEqual([]);
  expect(await g(b.page, () => review.length)).toBe(0);
});

test('24 a stale client can never overwrite a newer revision (restore and out-of-order responses)', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  // B queues a whole-state restore against the revision it last saw, while offline.
  await setOffline(b, true);
  const staleRev = await g(b.page, () => cache.revision);
  await g(b.page, () => enqueue('replace_state', { doc: { stock: { fridge: 1 } }, expected_revision: cache.revision, reason: 'restore-backup', subtract_meals_since: false, label: 'Restored device backup' }));
  await a.page.click(`button[onclick="adjust('fridge',1)"]`); // the cloud moves on
  await waitSynced(a.page);
  await setOffline(b, false);
  await waitSynced(b.page);
  const row = await backend.state(a.owner);
  expect(row.doc.stock.fridge).toBe(6);
  expect(row.revision).toBeGreaterThan(staleRev);
  expect((await backend.ledger(a.owner)).at(-1)).toMatchObject({ op_type: 'replace_state', status: 'conflict' });
  expect(await backend.count('state_snapshots', a.owner)).toBe(1); // only the seed snapshot: nothing was replaced
  await expect(b.page.locator('#fridgeVal')).toHaveValue('6');
  // An older response arriving late is ignored.
  const kept = await g(b.page, () => { const before = cache.revision; const applied = applyServerState({ ...cache, revision: before - 1, doc: { ...cache.doc, stock: { ...cache.doc.stock, fridge: 0 } } }); return [applied, cache.revision === before, cache.doc.stock.fridge]; });
  expect(kept).toEqual([false, true, 6]);
});
