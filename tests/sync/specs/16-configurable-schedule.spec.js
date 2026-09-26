// WORK-148 configurable Food settings: local-mode scheduling, catch-up, identities and the settings UI.
// The cloud path (dog_log._process_due_meals / _apply_op / seed_state) is exercised by the database suite.
const { test, expect, fixture, APP, raw } = require('../lib/helpers');

const T = s => Date.parse(s);  // September 2026 in Melbourne is AEST (+10:00)

// A local-mode device whose clock is fixed at `now`; setNow() moves the clock and reloads, keeping localStorage.
async function fixedLocal(device, { now, cursor, fridge, freezer, settings = {}, tracking = {} }) {
  const data = fixture();
  data.stock = { ...data.stock, fridge, freezer };
  data.settings = { ...data.settings, ...settings };
  data.tracking = { lastAutoDate: null, mealCursor: cursor, mealTrackingSince: new Date(cursor - 86400000).toISOString(), mealLog: {}, ...tracking };
  data.calendar = { endpoint: '', token: '', paired: false, lastSync: null, lastError: null };
  data.history = [];
  const d = await device({ raw: JSON.stringify(data), load: false });
  await d.context.addInitScript(({ first }) => {
    const fixed = Number(sessionStorage.getItem('__fixedNow')) || first;
    const RealDate = Date;
    class FixedDate extends RealDate {
      constructor(...args) { super(...(args.length ? args : [fixed])); }
      static now() { return fixed; }
    }
    window.Date = FixedDate;
  }, { first: now });
  await d.page.goto(APP() + '/');
  d.setNow = async ms => { await d.page.evaluate(v => sessionStorage.setItem('__fixedNow', String(v)), ms); await d.page.reload(); };
  return d;
}
const doc = async page => JSON.parse(await raw(page));
const actions = s => s.history.map(h => h.action);
async function commit(page, sel, value) {
  await page.evaluate(() => showView('settings'));
  await page.fill(sel, value);
  await page.locator(sel).press('Tab');
}

test('legacy data keeps Breakfast 09:00, Dinner 18:00 and a 2-container 18:00 transfer after Dinner, exactly once', async ({ device }) => {
  const d = await fixedLocal(device, { now: T('2026-09-14T18:01:00+10:00'), cursor: T('2026-09-14T08:59:00+10:00'), fridge: 1, freezer: 4 });
  let s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 2, freezer: 1 });
  expect(actions(s).slice(0, 3)).toEqual([
    expect.stringMatching(/^18:00 freezer-to-fridge transfer .*: 2 Full Containers moved from Freezer to Fridge$/),
    expect.stringMatching(/^Dinner .*: 1 Full Container used \(freezer\)$/),
    expect.stringMatching(/^Breakfast .*: 1 Full Container used \(fridge\)$/),
  ]);
  // Defaults are not written into old data; the transfer gets its own daily identity.
  expect(Object.keys(s.settings).sort()).toEqual(['containersPerDay', 'mincePurchaseIncrementKg', 'totalContainers']);
  expect(s.tracking.transferLog['2026-09-14']).toMatchObject({ outcome: 'processed', moved: 2 });

  await expect(d.page.locator('#todayList .label')).toHaveText(['Breakfast · 09:00', 'Dinner · 18:00', 'Fridge transfer · 18:00']);
  await expect(d.page.locator('#feedSchedule')).toHaveText('09:00 & 18:00');
  await expect(d.page.locator('#transferSchedule')).toHaveText('Up to 2 at 18:00');
  await expect(d.page.locator('#todayNote')).toContainText('At 18:00, after Dinner, up to 2 Full Containers');
  await d.page.evaluate(() => showView('settings'));
  await expect(d.page.locator('#setTotal')).toHaveValue('40');
  await expect(d.page.locator('#setMaxFreezer')).toHaveValue('70');
  await expect(d.page.locator('#setMaxFridge')).toHaveValue('');
  await expect(d.page.locator('#setTransferQty')).toHaveValue('2');
  await expect(d.page.locator('#setTransferTime')).toHaveValue('18:00');
  await expect(d.page.locator('#setBreakfast')).toHaveValue('09:00');
  await expect(d.page.locator('#setDinner')).toHaveValue('18:00');
  await expect(d.page.locator('#settings')).not.toContainText('fixed');

  await d.page.reload();
  s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 2, freezer: 1 });
  expect(actions(s).filter(a => a.includes('freezer-to-fridge transfer'))).toHaveLength(1);
});

test('a WORK-147 device whose Dinner already moved containers never transfers twice that day', async ({ device }) => {
  const d = await fixedLocal(device, {
    now: T('2026-09-15T18:30:00+10:00'), cursor: T('2026-09-15T18:00:00+10:00'), fridge: 3, freezer: 3,
    tracking: { mealLog: { '2026-09-15': { breakfast: 'fed', dinner: 'fed' } } },
  });
  let s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 3, freezer: 3 });
  expect(s.tracking).not.toHaveProperty('transferLog');  // a load that processes nothing leaves saved data as it was
  await expect(d.page.locator('#todayTransfer')).toHaveText('✓ Done');
  await commit(d.page, '#setTransferTime', '20:00');
  await d.setNow(T('2026-09-15T20:30:00+10:00'));
  s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 3, freezer: 3 });
  expect(actions(s).some(a => a.includes('freezer-to-fridge transfer'))).toBe(false);
  expect(s.tracking.transferLog['2026-09-15']).toMatchObject({ outcome: 'processed' });
});

test('configured Breakfast, Dinner and an earlier transfer run in time order with the configured quantity', async ({ device }) => {
  const d = await fixedLocal(device, {
    now: T('2026-09-16T17:30:00+10:00'), cursor: T('2026-09-16T07:00:00+10:00'), fridge: 0, freezer: 5,
    settings: { breakfastTime: '07:30', dinnerTime: '17:00', fridgeTransferTime: '16:00', fridgeTransferCount: 3 },
  });
  const s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 2, freezer: 1 });
  expect(actions(s).slice(0, 3)).toEqual([
    expect.stringMatching(/^Dinner .*: 1 Full Container used \(fridge\)$/),
    expect.stringMatching(/^16:00 freezer-to-fridge transfer .*: 3 Full Containers moved from Freezer to Fridge$/),
    expect.stringMatching(/^Breakfast .*: 1 Full Container used \(freezer\)$/),
  ]);
  await expect(d.page.locator('#todayList .label')).toHaveText(['Breakfast · 07:30', 'Fridge transfer · 16:00', 'Dinner · 17:00']);
  await expect(d.page.locator('#feedSchedule')).toHaveText('07:30 & 17:00');
  await expect(d.page.locator('#transferSchedule')).toHaveText('Up to 3 at 16:00');
});

test('at an equal configured time Dinner is served before the transfer', async ({ device }) => {
  const d = await fixedLocal(device, {
    now: T('2026-09-17T19:01:00+10:00'), cursor: T('2026-09-17T18:00:00+10:00'), fridge: 0, freezer: 3,
    settings: { dinnerTime: '19:00', fridgeTransferTime: '19:00', fridgeTransferCount: 1 },
  });
  const s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 1, freezer: 1 });
  expect(actions(s).slice(0, 2)).toEqual([
    expect.stringMatching(/^19:00 freezer-to-fridge transfer .*: 1 Full Container moved from Freezer to Fridge$/),
    expect.stringMatching(/^Dinner .*: 1 Full Container used \(freezer\)$/),
  ]);
});

test('an independent transfer time catches up over days; only meals consume Full Containers', async ({ device }) => {
  const d = await fixedLocal(device, {
    now: T('2026-09-20T21:00:00+10:00'), cursor: T('2026-09-17T08:00:00+10:00'), fridge: 2, freezer: 20,
    settings: { fridgeTransferTime: '20:00' },
  });
  let s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 2, freezer: 12 });
  expect(actions(s).slice(0, 2)).toEqual([
    'Scheduled meals caught up: 8 meals, 8 Full Containers used',
    'Automatic 20:00 freezer-to-fridge transfers caught up: 8 Full Containers moved across 4 days',
  ]);
  expect(Object.keys(s.tracking.transferLog).sort()).toEqual(['2026-09-17', '2026-09-18', '2026-09-19', '2026-09-20']);
  await d.page.reload();
  s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 2, freezer: 12 });
});

test('a daily transfer of 0 moves nothing and records no transfer history', async ({ device }) => {
  const d = await fixedLocal(device, {
    now: T('2026-09-18T18:01:00+10:00'), cursor: T('2026-09-18T17:59:00+10:00'), fridge: 0, freezer: 3,
    settings: { fridgeTransferCount: 0 },
  });
  const s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 0, freezer: 2 });
  expect(actions(s)[0]).toMatch(/^Dinner /);
  expect(actions(s).some(a => a.includes('freezer-to-fridge transfer'))).toBe(false);
  await expect(d.page.locator('#transferSchedule')).toHaveText('Off (0)');
});

test('Food settings autosave; Breakfast must precede Dinner; a meal moved before the cursor runs once, now', async ({ device }) => {
  const d = await fixedLocal(device, {
    now: T('2026-09-21T13:00:00+10:00'), cursor: T('2026-09-21T08:00:00+10:00'), fridge: 3, freezer: 3,
    settings: { fridgeTransferTime: '12:00' },
  });
  let s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 4, freezer: 1 });  // Breakfast 09:00, then the 12:00 transfer

  await commit(d.page, '#setDinner', '11:00');
  await expect(d.page.locator('#settingsSaveStatus')).toHaveText('Saved');
  s = await doc(d.page);
  expect(s.settings).toMatchObject({ breakfastTime: '09:00', dinnerTime: '11:00' });
  expect(s.stock).toMatchObject({ fridge: 3, freezer: 1 });
  expect(actions(s).slice(0, 2)).toEqual([expect.stringMatching(/^Dinner .*: 1 Full Container used \(fridge\)$/), 'Dinner time set to 11:00']);
  await d.setNow(T('2026-09-21T23:00:00+10:00'));
  s = await doc(d.page);
  expect(s.stock).toMatchObject({ fridge: 3, freezer: 1 });

  await commit(d.page, '#setBreakfast', '12:00');
  await expect(d.page.locator('#settingsSaveStatus')).toContainText('Breakfast must be before Dinner');
  await expect(d.page.locator('#setBreakfast')).toHaveValue('09:00');
  expect((await doc(d.page)).settings.breakfastTime).toBe('09:00');

  await commit(d.page, '#setMaxFridge', '12');
  await commit(d.page, '#setMaxFreezer', '80');
  await commit(d.page, '#setTransferQty', '3');
  s = await doc(d.page);
  expect(s.settings).toMatchObject({ maxFridgeContainers: 12, maxFreezerContainers: 80, fridgeTransferCount: 3 });
  await expect(d.page.locator('#fridgeCap')).toHaveText(' · holds up to 12');
  await expect(d.page.locator('#planMaxFreezer')).toHaveText('80');
  expect(s.stock).toMatchObject({ fridge: 3, freezer: 1 });  // capacities never clamp counts
  await commit(d.page, '#setMaxFridge', '');
  expect((await doc(d.page)).settings.maxFridgeContainers).toBeNull();
  await commit(d.page, '#setTransferQty', '101');
  await expect(d.page.locator('#settingsSaveStatus')).toContainText('0 to 100');
});

test('cloud rows: transfer events fill the transfer log, never the meal log', async ({ device }) => {
  const d = await fixedLocal(device, { now: T('2026-09-22T19:00:00+10:00'), cursor: T('2026-09-22T18:30:00+10:00'), fridge: 1, freezer: 1 });
  const r = await d.page.evaluate(() => docToState({ doc: {}, recent_meals: [
    { meal_date: '2026-09-21', slot: 'dinner', outcome: 'fed', source_container: 'fridge', freezer_to_fridge_count: 2, slot_at: '2026-09-21T08:00:00Z' },
    { meal_date: '2026-09-22', slot: 'dinner', outcome: 'fed', source_container: 'fridge', freezer_to_fridge_count: null, slot_at: '2026-09-22T08:00:00Z' },
    { meal_date: '2026-09-22', slot: 'transfer', outcome: 'transferred', freezer_to_fridge_count: 1, slot_at: '2026-09-22T08:00:00Z' },
  ] }, {}).tracking);
  expect(r.mealLog).toEqual({ '2026-09-21': { dinner: 'fed' }, '2026-09-22': { dinner: 'fed' } });
  expect(r.transferLog).toEqual({ '2026-09-21': { outcome: 'processed', moved: 2 }, '2026-09-22': { outcome: 'processed', moved: 1 } });
});
