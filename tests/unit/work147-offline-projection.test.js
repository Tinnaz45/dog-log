const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const html = fs.readFileSync(path.join(__dirname, '..', '..', 'index.html'), 'utf8');
const match = html.match(/function projectMeal\(s,x\)\{[^\n]+\}/);
assert.ok(match, 'projectMeal must remain extractable from index.html');
const context = {};
vm.createContext(context);
vm.runInContext(`${match[0]}; this.projectMeal = projectMeal;`, context);

function state(fridge, freezer) {
  return { stock: { fridge, freezer }, tracking: { mealLog: {}, transferLog: {}, mealCursor: 0 } };
}
function mealSlot(id) {
  return { t: 123, day: '2026-09-26', meal: { id, kind: 'meal' } };
}
function transferSlot(qty = 2) {
  return { t: 123, day: '2026-09-26', meal: { id: 'transfer', kind: 'transfer', qty } };
}

test('offline cloud projection consumes Dinner first, then transfers freezer containers', () => {
  const s = state(0, 3);
  context.projectMeal(s, mealSlot('dinner'));
  context.projectMeal(s, transferSlot(2));
  assert.deepEqual(s.stock, { fridge: 2, freezer: 0 });
  assert.equal(s.tracking.mealLog['2026-09-26'].dinner, 'fed');
  assert.equal(s.tracking.transferLog['2026-09-26'].moved, 2);
});

test('offline cloud projection clamps transfer and preserves transfer total', () => {
  const s = state(4, 3);
  const before = s.stock.fridge + s.stock.freezer;
  context.projectMeal(s, mealSlot('dinner'));
  context.projectMeal(s, transferSlot(2));
  assert.deepEqual(s.stock, { fridge: 5, freezer: 1 });
  assert.equal(s.stock.fridge + s.stock.freezer, before - 1);
});

test('breakfast projection does not move freezer stock', () => {
  const s = state(0, 3);
  context.projectMeal(s, mealSlot('breakfast'));
  assert.deepEqual(s.stock, { fridge: 0, freezer: 2 });
});

test('transfer event is idempotent for a day', () => {
  const s = state(1, 5);
  context.projectMeal(s, transferSlot(3));
  context.projectMeal(s, transferSlot(3));
  assert.deepEqual(s.stock, { fridge: 4, freezer: 2 });
});