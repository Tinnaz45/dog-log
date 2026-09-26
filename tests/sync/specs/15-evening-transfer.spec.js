// WORK-147 local/offline path. The cloud path is exercised by the database migration suite.
const { test, expect, fixture, APP, raw } = require('../lib/helpers');

async function fixedLocal(device, { now, cursor, fridge, freezer }) {
  const data = fixture();
  data.stock = { ...data.stock, fridge, freezer };
  data.tracking = { ...data.tracking, mealCursor: cursor, mealTrackingSince: new Date(cursor - 86400000).toISOString(), mealLog: {} };
  data.calendar = { endpoint: '', token: '', paired: false, lastSync: null, lastError: null };
  data.history = [];
  const d = await device({ raw: JSON.stringify(data), load: false });
  await d.context.addInitScript(({ fixed }) => {
    const RealDate = Date;
    class FixedDate extends RealDate {
      constructor(...args) { super(...(args.length ? args : [fixed])); }
      static now() { return fixed; }
    }
    window.Date = FixedDate;
  }, { fixed: now });
  await d.page.goto(APP() + '/');
  return d;
}

function localTime(s) { return Date.parse(s); }
test('18:00 Dinner is consumed first, then two remaining freezer containers move to fridge exactly once', async ({ device }) => {
  const cursor = localTime('2026-09-20T17:59:00+10:00');
  const now = localTime('2026-09-20T18:01:00+10:00');
  const d = await fixedLocal(device, { now, cursor, fridge: 0, freezer: 3 });
  let s = JSON.parse(await raw(d.page));
  expect(s.stock.fridge).toBe(2);
  expect(s.stock.freezer).toBe(0);
  expect(s.history.slice(0, 2).map(h => h.action)).toEqual([
    expect.stringContaining('18:00 freezer-to-fridge transfer'),
    expect.stringContaining('Dinner'),
  ]);
  expect(s.history[0].action).toContain('2 Full Containers moved from Freezer to Fridge');
  expect(s.history[1].action).toContain('1 Full Container used (freezer)');

  await d.page.reload();
  s = JSON.parse(await raw(d.page));
  expect(s.stock).toMatchObject({ fridge: 2, freezer: 0 });
  expect(s.history.filter(h => h.action.includes('18:00 freezer-to-fridge transfer'))).toHaveLength(1);
});

test('18:00 transfer clamps safely to one or zero remaining freezer containers', async ({ device }) => {
  const cursor1 = localTime('2026-09-21T17:59:00+10:00');
  const d1 = await fixedLocal(device, { now: localTime('2026-09-21T18:01:00+10:00'), cursor: cursor1, fridge: 0, freezer: 2 });
  let s = JSON.parse(await raw(d1.page));
  expect(s.stock).toMatchObject({ fridge: 1, freezer: 0 });
  expect(s.history[0].action).toContain('1 Full Container moved from Freezer to Fridge');

  const cursor0 = localTime('2026-09-22T17:59:00+10:00');
  const d0 = await fixedLocal(device, { now: localTime('2026-09-22T18:01:00+10:00'), cursor: cursor0, fridge: 1, freezer: 0 });
  s = JSON.parse(await raw(d0.page));
  expect(s.stock).toMatchObject({ fridge: 0, freezer: 0 });
  expect(s.history[0].action).toContain('no Full Containers available in Freezer');
});
