const { test, expect, fixture, seededDevice, backend } = require('../lib/helpers');

test('harness: sign in and seed the emulated cloud', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const row = await backend.state(a.owner);
  expect(row.revision).toBeGreaterThanOrEqual(1);
  expect(row.doc.stock.fridge).toBe(5);
  await expect(a.page.locator('#syncBadge')).toContainText('Synced');
});
