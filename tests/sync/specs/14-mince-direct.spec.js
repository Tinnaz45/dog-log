// Mince purchase increment removed (WORK-136 #29): Pet Mince is recorded as any decimal kg amount, Total containers owned is
// the only Food setting, Suggested mince to buy is the plain shortfall, and older copies holding the retired field still load.
const { test, expect, g, raw, signIn, waitSynced, seededDevice, fixture } = require('../lib/helpers');

const IOS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
// No Full Containers and nothing in the other containers: every owned container is empty, so the planner maths is fixed.
// One batch of 10 containers from 4 kg learns 0.4 kg/container; 23 containers therefore need 9.2 kg of mince.
const EMPTY_STOCK = { fridge: 0, freezer: 0, minceKg: 7.5, neckBags: 3, necksOnly: 0, minceOnly: 0, lykaPackets: 0, scratchPackets: 0 };
const OLD_SETTINGS = { totalContainers: 23, containersPerDay: 2, mincePurchaseIncrementKg: 3 };
const planFixture = (over = {}) => fixture({ stock: EMPTY_STOCK, settings: OLD_SETTINGS, ...over });
function pageErrors(page) { const errs = []; page.on('pageerror', e => errs.push(e.message)); return errs; }

test('60 Food Settings shows only Total containers owned; there is no Mince purchase increment field', async ({ device }) => {
  const d = await device({ raw: JSON.stringify(planFixture()) });
  await g(d.page, () => showView('settings'));
  const card = d.page.locator('.card', { has: d.page.locator('#setTotal') });
  await expect(card.locator('h2')).toHaveText('Food settings');
  await expect(card.locator('input')).toHaveCount(1);
  await expect(card.locator('label')).toHaveText(['Total containers owned']);
  await expect(d.page.locator('#setMinceIncrement')).toHaveCount(0);
  await expect(d.page.getByText(/purchase increment/i)).toHaveCount(0);
  await expect(d.page.locator('#setTotal')).toHaveValue('23');
});

test('61 Pet Mince takes decimal kg directly (7.5, 10, 12.3, 20) and each value syncs unrounded', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  for (const v of ['10', '12.3', '20', '7.5']) {
    await a.page.fill('#minceVal', v);
    await a.page.locator('#minceVal').blur();
    await waitSynced(a.page);
    expect((await backend.state(a.owner)).doc.stock.minceKg).toBe(Number(v));
    await expect(a.page.locator('#minceVal')).toHaveValue(v);
  }
  expect((await backend.ledger(a.owner)).map(r => [r.op_type, r.status, r.detail.after])).toEqual([
    ['set', 'applied', 10], ['set', 'applied', 12.3], ['set', 'applied', 20], ['set', 'applied', 7.5]]);
  // Another device and a reload of this one both read back exactly 7.5 kg.
  const b = await device({ raw: null });
  await signIn(b.page);
  await waitSynced(b.page);
  await g(b.page, () => showView('food'));
  await expect(b.page.locator('#minceVal')).toHaveValue('7.5');
  await a.page.reload();
  await waitSynced(a.page);
  await expect(a.page.locator('#minceVal')).toHaveValue('7.5');
  expect(JSON.parse(await raw(a.page)).stock.minceKg).toBe(7.5);
});

test('62 Suggested mince to buy is the shortfall itself, never rounded up to a purchase increment', async ({ device }) => {
  // The stored (retired) increment of 3 kg would have turned the 1.7 kg shortfall into 3 kg.
  const d = await device({ raw: JSON.stringify(planFixture()) });
  await g(d.page, () => showView('plan'));
  await expect(d.page.locator('#emptyContainers')).toHaveText('23');
  await expect(d.page.locator('#minceNeeded')).toHaveText('9.2 kg');
  await expect(d.page.locator('#minceToBuy')).toHaveText('1.7 kg');
  expect(await g(d.page, () => calc().minceBuy)).toBeCloseTo(1.7, 9);
  // Same result whatever increment an older copy holds, or with none at all.
  for (const inc of [0.5, 1, 10, undefined]) {
    const settings = { ...OLD_SETTINGS, mincePurchaseIncrementKg: inc };
    if (inc === undefined) delete settings.mincePurchaseIncrementKg;
    const e = await device({ raw: JSON.stringify(planFixture({ settings })) });
    await g(e.page, () => showView('plan'));
    await expect(e.page.locator('#minceToBuy')).toHaveText('1.7 kg');
  }
  // Enough mince on hand means nothing to buy; a small shortfall keeps its decimals.
  await g(d.page, () => showView('food'));
  for (const [v, buy] of [['12.3', '0 kg'], ['9.2', '0 kg'], ['9.15', '0.05 kg']]) {
    await d.page.fill('#minceVal', v);
    await d.page.locator('#minceVal').blur();
    await expect(d.page.locator('#minceToBuy')).toHaveText(buy);
  }
});

test('63 an older cloud copy holding mincePurchaseIncrementKg loads without error, is ignored, and is kept as stored', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend }, planFixture());
  expect((await backend.state(a.owner)).doc.settings).toEqual({ totalContainers: 23, mincePurchaseIncrementKg: 3 });
  const b = await device({ raw: null, viewport: { width: 375, height: 667 }, userAgent: IOS_UA });
  const errs = pageErrors(b.page);
  await signIn(b.page);
  await waitSynced(b.page);
  await g(b.page, () => showView('plan'));
  await expect(b.page.locator('#minceToBuy')).toHaveText('1.7 kg');
  await g(b.page, () => showView('settings'));
  await expect(b.page.locator('#setTotal')).toHaveValue('23');
  await expect(b.page.locator('#setMinceIncrement')).toHaveCount(0);
  // Total containers owned still autosaves, and the untouched old field stays exactly as stored (no migration).
  await b.page.fill('#setTotal', '24');
  await b.page.press('#setTotal', 'Enter');
  await waitSynced(b.page);
  expect((await backend.ledger(a.owner)).map(r => [r.op_type, r.status, r.detail.field, r.detail.after])).toEqual([['settings', 'applied', 'totalContainers', 24]]);
  expect((await backend.state(a.owner)).doc.settings).toEqual({ totalContainers: 24, mincePurchaseIncrementKg: 3 });
  await expect(a.page.locator('#minceToBuy')).toHaveText('2.1 kg', { timeout: 5000 }); // 24 × 0.4 − 7.5, realtime to A
  expect(errs).toEqual([]);
});

test('64 an older device-only copy holding mincePurchaseIncrementKg loads without error and round-trips it unchanged', async ({ device }) => {
  const d = await device({ raw: JSON.stringify(planFixture()) });
  const errs = pageErrors(d.page);
  await d.page.reload();
  await g(d.page, () => showView('settings'));
  await d.page.fill('#setTotal', '25');
  await d.page.locator('#setTotal').blur();
  await expect(d.page.locator('#settingsSaveStatus')).toHaveText('Saved');
  await g(d.page, () => showView('food'));
  await d.page.fill('#minceVal', '7.5');
  await d.page.locator('#minceVal').blur();
  const s = JSON.parse(await raw(d.page));
  expect(s.settings).toEqual({ totalContainers: 25, containersPerDay: 2, mincePurchaseIncrementKg: 3 });
  expect(s.stock.minceKg).toBe(7.5);
  await g(d.page, () => showView('plan'));
  await expect(d.page.locator('#minceToBuy')).toHaveText('2.5 kg'); // 25 × 0.4 − 7.5
  expect(errs).toEqual([]);
});
