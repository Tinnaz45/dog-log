// Cross-device convergence: realtime, focus/visibility, reconnect, and server-processed scheduled meals.
const { test, expect, g, signIn, waitSynced, seededDevice, fixture, EMAIL, PASSWORD } = require('../lib/helpers');
const { setOffline } = require('../lib/helpers');

const IPHONE = { viewport: { width: 390, height: 844 }, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1' };
async function secondDevice({ device, backend }, opts = {}) {
  const b = await device({ raw: JSON.stringify(fixture()), ...opts });
  await signIn(b.page);
  await waitSynced(b.page);
  await b.page.evaluate(() => showView('food'));
  return b;
}

test('18 a realtime UPDATE refreshes another device promptly, without focus or polling', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend }, IPHONE);
  await expect.poll(() => [...backend.conns].some(c => [...c.topics.values()].some(t => t.bindings.some(x => x.filter === `owner_id=eq.${a.owner}`)))).toBe(true);
  const before = backend.rpcCalls('sync').length;
  await a.page.click(`button[onclick="adjust('freezer',1)"]`);
  await expect(b.page.locator('#freezerVal')).toHaveValue('13', { timeout: 5000 });
  expect(backend.rpcCalls('sync').length).toBeGreaterThan(before + 1); // A's write plus B's realtime-triggered fetch
  expect(await g(b.page, () => cache.revision)).toBe((await backend.state(a.owner)).revision);
  expect(await g(b.page, () => JSON.parse(localStorage.getItem('dog_food_stock_v2')).stock.freezer)).toBe(13);
});

test('19 reconnecting flushes changes made offline', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  await setOffline(a, true);
  await a.page.click(`button[onclick="adjust('necksOnly',1)"]`);
  await expect(a.page.locator('#syncBadge')).toContainText('pending');
  expect((await backend.state(a.owner)).doc.stock.necksOnly).toBe(1);
  await setOffline(a, false);
  await waitSynced(a.page);
  expect((await backend.state(a.owner)).doc.stock.necksOnly).toBe(2);
});

test('20 focus / visibility return refreshes even when realtime is unavailable', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const b = await secondDevice({ device, backend });
  backend.realtimeBlocked = true;
  await a.page.click(`button[onclick="adjust('minceOnly',1)"]`);
  await waitSynced(a.page);
  await b.page.waitForTimeout(1000);
  await expect(b.page.locator('#minceOnlyVal')).toHaveValue('0'); // not pushed
  await b.page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await expect(b.page.locator('#minceOnlyVal')).toHaveValue('1');
  await a.page.click(`button[onclick="adjust('minceOnly',1)"]`);
  await waitSynced(a.page);
  await b.page.waitForTimeout(5200); // focus right after a visibility return is deliberately de-duplicated (5s)
  await b.page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(b.page.locator('#minceOnlyVal')).toHaveValue('2');
});

test('21 scheduled meals are processed once by the server and every device shows the result', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend }, fixture({ stock: { fridge: 3, freezer: 2, minceKg: 0, neckPackets: 0, necksOnly: 0, minceOnly: 0, lykaPackets: 0, scratchPackets: 0 } }));
  // Every device was closed for two days: the server cursor is 48h old, so about four slots are due.
  await backend.pool.query("update dog_log.state set meal_cursor = now() - interval '48 hours' where owner_id = $1", [a.owner]);
  await a.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect.poll(async () => backend.count('meal_events', a.owner)).toBeGreaterThanOrEqual(3);
  await waitSynced(a.page);
  const events = (await backend.pool.query("select slot, outcome, source_container, processed_by_device from dog_log.meal_events where owner_id = $1 and origin = 'server' order by slot_at", [a.owner])).rows;
  const meals = events.filter(e => e.slot !== 'transfer');
  const transfers = events.filter(e => e.slot === 'transfer');
  const fed = meals.filter(e => e.outcome === 'fed').length;
  expect(meals.length).toBeGreaterThanOrEqual(3);
  expect(meals.length).toBeLessThanOrEqual(5);
  expect(transfers.length).toBeGreaterThanOrEqual(1);
  expect(meals.map(e => e.source_container).filter(Boolean)).toEqual(meals.filter(e => e.outcome === 'fed').map((e, i) => (i < 3 ? 'fridge' : 'freezer')));
  const row = await backend.state(a.owner);
  expect(row.doc.stock.fridge + row.doc.stock.freezer).toBe(5 - fed);
  await expect(a.page.locator('#fridgeVal')).toHaveValue(String(row.doc.stock.fridge));
  await expect(a.page.locator('#freezerVal')).toHaveValue(String(row.doc.stock.freezer));
  await g(a.page, () => showView('history'));
  await expect(a.page.locator('#historyList')).toContainText('1 Full Container used (fridge)');
  // A second device adopts the result and never deducts again.
  const b = await secondDevice({ device, backend });
  await expect(b.page.locator('#fridgeVal')).toHaveValue(String(row.doc.stock.fridge));
  await g(b.page, () => { tick(); refreshView(); });
  await b.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await waitSynced(b.page);
  expect(await backend.count('meal_events', a.owner)).toBe(events.length);
  expect((await backend.state(a.owner)).doc.stock).toEqual(row.doc.stock);
});

test('21b offline, due meals are projected on screen but never written or deducted twice', async ({ device, backend }) => {
  const local = fixture();
  const a = await seededDevice({ device, backend }, local);
  // Pretend the server cursor is 24h old in this device's cache while offline: exactly two slots are due.
  await setOffline(a, true);
  const view = await g(a.page, () => { cache.meal_cursor = new Date(Date.now() - 24 * 3600 * 1000).toISOString(); saveCache(); refreshView(); const persisted=JSON.parse(localStorage.getItem('dog_food_stock_v2')).stock; return [state.stock.fridge + state.stock.freezer, projectedSlots.length, persisted.fridge + persisted.freezer]; });
  expect(view[1]).toBe(3);       // Breakfast + Dinner + independent daily transfer
  expect(view[0]).toBe(17 - 2); // only the two meals reduce total Full Containers
  expect(view[2]).toBe(17);     // projection is never written to the mirror
  expect(await backend.count('meal_events', a.owner)).toBe(0);
});

test('22 two devices (desktop and iPhone) editing at the same time converge to one authoritative state', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend }, fixture(), { viewport: { width: 1280, height: 800 } });
  const b = await secondDevice({ device, backend }, IPHONE);
  await Promise.all([
    a.page.click(`button[onclick="adjust('fridge',1)"]`),
    b.page.click(`button[onclick="adjust('freezer',1)"]`),
  ]);
  await b.page.click(`button[onclick="adjust('freezer',1)"]`);
  await a.page.click(`button[onclick="adjust('minceKg',.5)"]`);
  await waitSynced(a.page); await waitSynced(b.page);
  await a.page.evaluate(() => window.dispatchEvent(new Event('online'))); await b.page.evaluate(() => window.dispatchEvent(new Event('online')));
  await waitSynced(a.page); await waitSynced(b.page);
  const row = await backend.state(a.owner);
  expect(row.doc.stock).toMatchObject({ fridge: 6, freezer: 14, minceKg: 3 });
  const view = p => p.evaluate(() => ({ stock: state.stock, settings: state.settings, batches: state.batches, history: state.history, rev: cache.revision }));
  await expect.poll(async () => JSON.stringify(await view(a.page))).toBe(JSON.stringify(await view(b.page)));
  expect((await view(a.page)).rev).toBe(row.revision);
  expect((await view(a.page)).history).toEqual(row.doc.history);
});
