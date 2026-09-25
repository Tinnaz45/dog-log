// Upgrade safety and unchanged local-only behaviour (no account, never signed in).
const { test, expect, fixture, g, raw } = require('../lib/helpers');

// Unpaired calendar: a paired one legitimately records lastSync at startup (unchanged v8 behaviour).
const unpaired = () => fixture({ calendar: { endpoint: '', token: '', paired: false, lastSync: null, lastError: null } });

test('01 existing dog_food_stock_v2 survives the upgrade byte-for-byte, with a verified pre-sync backup', async ({ device }) => {
  const rawIn = JSON.stringify(unpaired());
  const { page } = await device({ raw: rawIn });
  expect(await raw(page)).toBe(rawIn);
  const b = await g(page, () => backups());
  expect(b.filter(x => x.reason === 'pre-sync')).toHaveLength(1);
  expect(b[0].raw).toBe(rawIn);
  await expect(page.locator('#fridgeVal')).toHaveValue('5');
  await expect(page.locator('#freezerVal')).toHaveValue('12');
  await expect(page.locator('#necksVal')).toHaveValue('3'); // legacy neckBags still maps to Chicken-neck packets
  await expect(page.locator('#syncBadge')).toHaveText('Saved locally');
});

test('02 signed-out startup and ordinary use never alter local data or contact the cloud', async ({ device, backend }) => {
  const rawIn = JSON.stringify(unpaired());
  const { page } = await device({ raw: rawIn });
  await g(page, () => { ['food', 'prep', 'plan', 'history', 'settings', 'food'].forEach(showView); tick(); render(); window.dispatchEvent(new Event('focus')); document.dispatchEvent(new Event('visibilitychange')); });
  await page.waitForTimeout(500);
  expect(await raw(page)).toBe(rawIn);
  expect(backend.calls).toHaveLength(0);
  expect(await g(page, () => [meta.mode, typeof window.supabase, localStorage.getItem('dog_log_outbox_v1')])).toEqual(['local', 'undefined', null]);
});

test('local mode keeps the WORK-135 behaviour: edits, history and prep batches stay on the device', async ({ device, backend }) => {
  const { page } = await device({ raw: JSON.stringify(fixture()) });
  await page.click(`button[onclick="adjust('fridge',1)"]`);
  await page.fill('#freezerVal', '10');
  await page.locator('#freezerVal').blur();
  await g(page, () => showView('prep'));
  await page.fill('#prepContainers', '4');
  await page.fill('#prepMinceStart', '2.5');
  await page.fill('#prepMinceLeft', '1');
  await page.fill('#prepNecksStart', '3');
  await page.fill('#prepNecksLeft', '1');
  await page.selectOption('#prepDestination', 'fridge');
  await page.click('#prep button.primary');
  const s = JSON.parse(await raw(page));
  expect(s.stock).toMatchObject({ fridge: 10, freezer: 10, minceKg: 1, neckPackets: 1 });
  expect(s.history.slice(0, 3).map(h => h.action)).toEqual(['Prep batch: 4 containers from 1.5 kg mince and 2 neck packets', 'Freezer set to 10 containers', 'Fridge +1']);
  expect(s.batches).toHaveLength(2);
  expect(backend.calls).toHaveLength(0);
});
