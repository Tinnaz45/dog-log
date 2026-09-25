// Session lifecycle and rollback safety: sign-out, expired sessions, the legacy mirror (R4), outdated clients.
const { test, expect, g, raw, outboxOps, signIn, waitSynced, seededDevice } = require('../lib/helpers');

test('sign-out keeps the last cloud copy read-only and warns about unsynced changes first', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  a.ctl.down = true;
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);
  a.dialogs.answers.push(false);
  await g(a.page, () => showView('settings'));
  await a.page.click('button:has-text("Sign out")');
  expect(a.dialogs.at(-1)).toContain('1 unsynced change will stay on this device');
  expect(await g(a.page, () => meta.mode)).toBe('synced');
  await a.page.click('button:has-text("Sign out")');
  await expect.poll(() => g(a.page, () => meta.mode)).toBe('signed-out');
  await expect(a.page.locator('#syncBadge')).toHaveText('Sign in to sync');
  await g(a.page, () => { showView('food'); adjust('fridge', 1); });
  expect(a.dialogs.at(-1)).toContain('Sign in to sync to make changes');
  expect((await outboxOps(a.page))).toHaveLength(1);
  a.ctl.down = false;
  await signIn(a.page);
  await waitSynced(a.page);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(6);
});

test('an expired session keeps queuing locally and flushes after signing in again', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.expired = true;
  await a.page.click(`button[onclick="adjust('freezer',-1)"]`);
  await expect(a.page.locator('#syncBadge')).toContainText('Session expired');
  expect((await outboxOps(a.page))).toHaveLength(1);
  backend.expired = false;
  await signIn(a.page);
  await waitSynced(a.page);
  expect((await backend.state(a.owner)).doc.stock.freezer).toBe(11);
});

test('R4: the legacy mirror carries the server meal cursor; edits made while sync was off are backed up and reviewed', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const row = await backend.state(a.owner);
  const mirror = JSON.parse(await raw(a.page));
  expect(mirror.tracking.mealCursor).toBe(new Date(row.meal_cursor).getTime());
  expect(mirror.stock).toEqual(row.doc.stock);
  // Simulate a rolled-back (v8) app editing dog_food_stock_v2 directly, then the sync app starting again.
  const edited = JSON.stringify({ ...mirror, stock: { ...mirror.stock, fridge: 77 } });
  await a.page.evaluate(v => localStorage.setItem('dog_food_stock_v2', v), edited);
  await a.page.reload();
  await waitSynced(a.page);
  const list = await g(a.page, () => backups());
  expect(list.find(b => b.reason === 'pre-resync').raw).toBe(edited);
  expect(await g(a.page, () => review.map(r => r.kind))).toEqual(['resync']);
  expect(JSON.parse(await raw(a.page)).stock.fridge).toBe(5); // mirror restored from the cloud; the edit is preserved in Backups
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(5);
});

test('an outdated client stops writing, keeps its outbox and asks for a reload', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  await backend.pool.query('update dog_log.state set min_client_version = 2 where owner_id = $1', [a.owner]);
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);
  await expect(a.page.locator('#syncBadge')).toHaveText('Update available — reload');
  expect((await outboxOps(a.page))).toHaveLength(1);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(5);
});
