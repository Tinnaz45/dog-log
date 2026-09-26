const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

// The schedule helpers are one-line functions in index.html; run them as they are.
const html = fs.readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');
const lines = ['const SCHED0', 'const SCHED_KEYS', 'function hhmm', 'function whole', 'function sched', 'function dayEvents', 'function mealEvents', 'function projectMeal']
  .map(start => {
    const line = html.split(/\r?\n/).find(l => l.startsWith(start));
    assert.ok(line, `${start} must remain extractable from index.html`);
    return line;
  });
const context = { state: { settings: {} } };
vm.createContext(context);
vm.runInContext(`${lines.join('\n')}\nthis.sched = sched; this.dayEvents = dayEvents; this.mealEvents = mealEvents; this.projectMeal = projectMeal;`, context);
const plain = v => JSON.parse(JSON.stringify(v));

test('old settings read as the legacy schedule: 09:00, 18:00, 2 at 18:00, freezer 70, fridge unset', () => {
  assert.deepEqual(plain(context.sched({ totalContainers: 40, containersPerDay: 2 })), {
    breakfastTime: '09:00', dinnerTime: '18:00', fridgeTransferTime: '18:00', fridgeTransferCount: 2, maxFreezerContainers: 70, maxFridgeContainers: null,
  });
});

test('invalid values fall back per field; Breakfast not before Dinner falls back to both defaults (as the server)', () => {
  const c = context.sched({ breakfastTime: '7am', dinnerTime: '17:30', fridgeTransferTime: '25:00', fridgeTransferCount: 2.5, maxFreezerContainers: -1, maxFridgeContainers: 12 });
  assert.equal(c.breakfastTime, '09:00');
  assert.equal(c.dinnerTime, '17:30');
  assert.equal(c.fridgeTransferTime, '18:00');
  assert.equal(c.fridgeTransferCount, 2);
  assert.equal(c.maxFreezerContainers, 70);
  assert.equal(c.maxFridgeContainers, 12);
  const bad = context.sched({ breakfastTime: '19:00', dinnerTime: '08:00' });
  assert.deepEqual([bad.breakfastTime, bad.dinnerTime], ['09:00', '18:00']);
  assert.equal(context.sched({ fridgeTransferCount: 0 }).fridgeTransferCount, 0);
});

test('events run in time order; at an equal time Dinner comes before the transfer', () => {
  const ids = s => plain(context.dayEvents(context.sched(s)).map(e => `${e.id}@${e.time}`));
  assert.deepEqual(ids({}), ['breakfast@09:00', 'dinner@18:00', 'transfer@18:00']);
  assert.deepEqual(ids({ fridgeTransferTime: '07:00' }), ['transfer@07:00', 'breakfast@09:00', 'dinner@18:00']);
  assert.deepEqual(ids({ dinnerTime: '19:30', fridgeTransferTime: '19:30' }), ['breakfast@09:00', 'dinner@19:30', 'transfer@19:30']);
  assert.deepEqual(ids({ fridgeTransferTime: '09:00' }), ['breakfast@09:00', 'transfer@09:00', 'dinner@18:00']);
  assert.deepEqual(plain(context.mealEvents(context.sched({})).map(e => e.id)), ['breakfast', 'dinner']);
  assert.equal(context.dayEvents(context.sched({ fridgeTransferCount: 4 })).find(e => e.id === 'transfer').qty, 4);
});

test('projection conserves Full Containers in a transfer and never moves the cursor back', () => {
  const s = { stock: { fridge: 0, freezer: 5 }, tracking: { mealLog: {}, transferLog: {}, mealCursor: 500 } };
  const [, , transfer] = context.dayEvents(context.sched({ fridgeTransferCount: 3 }));
  assert.equal(context.projectMeal(s, { t: 100, day: '2026-09-26', meal: transfer }), true);
  assert.deepEqual(plain(s.stock), { fridge: 3, freezer: 2 });
  assert.equal(s.tracking.mealCursor, 500);
  assert.equal(context.projectMeal(s, { t: 600, day: '2026-09-26', meal: transfer }), false);
  assert.deepEqual(plain(s.stock), { fridge: 3, freezer: 2 });
  assert.equal(s.tracking.mealCursor, 600);
});
