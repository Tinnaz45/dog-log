// Food Settings layout (WORK-136 #28): on iPhone / installed-PWA widths the two settings stay side by side as two equal
// columns, their inputs line up even when only one label wraps, and nothing overflows the viewport.
const { test, expect, g, waitSynced, seededDevice } = require('../lib/helpers');

const IOS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const WIDTHS = [
  ['narrow iPhone (SE 1st gen)', 320, 568],
  ['iPhone SE 2nd/3rd gen', 375, 667],
  ['modern iPhone (15/16)', 393, 852],
  ['large iPhone (Pro Max)', 430, 932],
];

async function measure(page) {
  return page.evaluate(() => {
    const box = e => e.getBoundingClientRect();
    const a = box(setTotal), b = box(setMinceIncrement), row = box(setTotal.closest('.two'));
    const labels = [setTotal, setMinceIncrement].map(i => document.querySelector(`label[for="${i.id}"]`));
    return {
      a: { x: a.left, y: a.top, w: a.width, h: a.height, r: a.right }, b: { x: b.left, y: b.top, w: b.width, h: b.height, r: b.right },
      row: { x: row.left, r: row.right },
      overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      labelsClipped: labels.map(l => l.scrollWidth > l.clientWidth + 1),
      labelsLines: labels.map(l => Math.round(box(l).height / parseFloat(getComputedStyle(l).lineHeight || 15))),
      cols: getComputedStyle(setTotal.closest('.two')).gridTemplateColumns.split(' ').length,
    };
  });
}

for (const [name, width, height] of WIDTHS) {
  test(`53 ${name} (${width}px): the two Food Settings stay side by side, aligned, with no horizontal overflow`, async ({ device }) => {
    const d = await device({ raw: null, viewport: { width, height }, userAgent: IOS_UA });
    await g(d.page, () => showView('settings'));
    const m = await measure(d.page);
    expect(m.cols).toBe(2);
    expect(Math.abs(m.a.y - m.b.y)).toBeLessThan(1);            // same row, inputs start at the same vertical position
    expect(m.b.x).toBeGreaterThanOrEqual(m.a.r);                // side by side, not overlapping
    expect(Math.abs(m.a.w - m.b.w)).toBeLessThan(1);            // equal-width columns
    expect(m.a.w).toBeGreaterThan(100);                         // still comfortably usable
    expect(m.a.h).toBeGreaterThanOrEqual(44);                   // tap target
    expect(m.b.r).toBeLessThanOrEqual(width);                   // inside the viewport
    expect(m.overflowX).toBe(0);                                // no horizontal page scroll
    expect(m.labelsClipped).toEqual([false, false]);            // labels may wrap, never clip
  });
}

test('54 inputs stay aligned when only one label wraps (393px), and on desktop the row is unchanged', async ({ device }) => {
  const d = await device({ raw: null, viewport: { width: 393, height: 852 }, userAgent: IOS_UA });
  await g(d.page, () => showView('settings'));
  const heights = await d.page.evaluate(() => ['setTotal', 'setMinceIncrement'].map(id => Math.round(document.querySelector(`label[for="${id}"]`).getBoundingClientRect().height)));
  expect(heights[0]).not.toBe(heights[1]); // the labels really do wrap differently at this width
  const m = await measure(d.page);
  expect(Math.abs(m.a.y - m.b.y)).toBeLessThan(1);
  const desk = await device({ raw: null, viewport: { width: 1280, height: 900 } });
  await g(desk.page, () => showView('settings'));
  const dm = await measure(desk.page);
  expect(Math.abs(dm.a.y - dm.b.y)).toBeLessThan(1);
  expect(dm.b.x).toBeGreaterThanOrEqual(dm.a.r);
  expect(dm.a.w).toBeLessThanOrEqual(360); // the app column (max-width 760px) still bounds the row
  expect(dm.overflowX).toBe(0);
});

test('55 at iPhone width both settings still autosave by tap (click), type and Enter, and Save prep batch is unchanged', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend }, undefined, { viewport: { width: 375, height: 667 }, userAgent: IOS_UA });
  await g(a.page, () => showView('settings'));
  await expect(a.page.locator('button:has-text("Save settings")')).toHaveCount(0);
  await a.page.locator('#setTotal').click();
  await a.page.keyboard.type('44');
  await a.page.locator('#setMinceIncrement').click(); // moving to the next field commits the first
  await a.page.keyboard.type('0.6');
  await a.page.keyboard.press('Enter');
  await waitSynced(a.page);
  expect((await backend.ledger(a.owner)).map(r => [r.op_type, r.status, r.detail.field, r.detail.after])).toEqual([
    ['settings', 'applied', 'totalContainers', 44], ['settings', 'applied', 'mincePurchaseIncrementKg', 0.6]]);
  const m = await measure(a.page);
  expect(Math.abs(m.a.y - m.b.y)).toBeLessThan(1);
  await g(a.page, () => showView('prep'));
  await expect(a.page.locator('#prep button.primary')).toHaveText('Save prep batch');
  await expect(a.page.locator('#prep button[onclick="savePrepBatch()"]')).toHaveCount(1);
});
