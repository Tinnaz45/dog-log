// Food Settings layout (WORK-136 #28, #29; WORK-148 seven fields): on iPhone / installed-PWA widths every Food setting
// spans the card, keeps a 44px tap target and its label is never clipped, and nothing overflows the viewport.
const { test, expect, g, waitSynced, seededDevice } = require('../lib/helpers');

const IOS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';
const FIELDS = [
  ['Total containers owned', 'number'], ['Maximum freezer storage', 'number'], ['Maximum fridge storage', 'number'],
  ['Daily fridge transfer', 'number'], ['Fridge transfer time', 'time'], ['Breakfast time', 'time'], ['Dinner time', 'time'],
];
const WIDTHS = [
  ['narrow iPhone (SE 1st gen)', 320, 568],
  ['iPhone SE 2nd/3rd gen', 375, 667],
  ['modern iPhone (15/16)', 393, 852],
  ['large iPhone (Pro Max)', 430, 932],
];

async function measure(page) {
  return page.evaluate(() => {
    const card = setTotal.closest('.card');
    const pad = parseFloat(getComputedStyle(card).paddingLeft) + parseFloat(getComputedStyle(card).paddingRight);
    const fields = [...card.querySelectorAll('input')].map(i => {
      const a = i.getBoundingClientRect(), label = document.querySelector(`label[for="${i.id}"]`);
      return { label: label && label.textContent, type: i.type, w: a.width, h: a.height, r: a.right, clipped: !label || label.scrollWidth > label.clientWidth + 1 };
    });
    return { fields, inner: card.clientWidth - pad, overflowX: document.documentElement.scrollWidth - document.documentElement.clientWidth };
  });
}

for (const [name, width, height] of WIDTHS) {
  test(`53 ${name} (${width}px): the seven Food settings are full width, with no horizontal overflow`, async ({ device }) => {
    const d = await device({ raw: null, viewport: { width, height }, userAgent: IOS_UA });
    await g(d.page, () => showView('settings'));
    const m = await measure(d.page);
    expect(m.fields.map(f => [f.label, f.type])).toEqual(FIELDS);
    for (const f of m.fields) {
      expect(Math.abs(f.w - m.inner)).toBeLessThan(1);          // spans the card, no leftover half column
      expect(f.h).toBeGreaterThanOrEqual(44);                   // tap target
      expect(f.r).toBeLessThanOrEqual(width);                   // inside the viewport
      expect(f.clipped).toBe(false);
    }
    expect(m.overflowX).toBe(0);                                // no horizontal page scroll
  });
}

test('54 on desktop the fields are bounded by the app column and do not overflow', async ({ device }) => {
  const desk = await device({ raw: null, viewport: { width: 1280, height: 900 } });
  await g(desk.page, () => showView('settings'));
  const dm = await measure(desk.page);
  expect(dm.fields).toHaveLength(7);
  expect(Math.max(...dm.fields.map(f => f.w))).toBeLessThanOrEqual(760); // the app column (max-width 760px) still bounds them
  expect(dm.overflowX).toBe(0);
});

test('55 at iPhone width Total containers still autosaves by tap (click), type and Enter, and Save prep batch is unchanged', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend }, undefined, { viewport: { width: 375, height: 667 }, userAgent: IOS_UA });
  await g(a.page, () => showView('settings'));
  await expect(a.page.locator('button:has-text("Save settings")')).toHaveCount(0);
  await a.page.locator('#setTotal').click();
  await a.page.keyboard.type('44');
  await a.page.keyboard.press('Enter');
  await waitSynced(a.page);
  expect((await backend.ledger(a.owner)).map(r => [r.op_type, r.status, r.detail.field, r.detail.after])).toEqual([
    ['settings', 'applied', 'totalContainers', 44]]);
  await expect(a.page.locator('#setTotal')).toHaveValue('44');
  await g(a.page, () => showView('prep'));
  await expect(a.page.locator('#prep button.primary')).toHaveText('Save prep batch');
  await expect(a.page.locator('#prep button[onclick="savePrepBatch()"]')).toHaveCount(1);
});
