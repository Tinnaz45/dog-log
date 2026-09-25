// Shared-account sign-in, first-device seeding and second-device adoption.
const { test, expect, fixture, g, raw, signIn, waitSynced, seededDevice, EMAIL, PASSWORD } = require('../lib/helpers');

test('03 sign-in with an empty cloud does not seed automatically', async ({ device, backend }) => {
  await backend.createUser(EMAIL, PASSWORD);
  const rawIn = JSON.stringify(fixture());
  const { page } = await device({ raw: rawIn });
  await signIn(page);
  await expect(page.locator('#seedPanel button.primary')).toBeVisible();
  expect(backend.rpcCalls('seed_state')).toHaveLength(0);
  expect(backend.rpcCalls('sync').map(c => JSON.parse(c.body).p_mutations)).toEqual([[]]);
  expect(await g(page, () => [meta.mode, meta.awaiting, meta.migration])).toEqual(['local', 'seed-decision', 'backed-up']);
  expect((await backend.pool.query('select count(*)::int n from dog_log.state')).rows[0].n).toBe(0);
  expect(await raw(page)).toBe(rawIn);
  expect(backend.calls.filter(c => /signup|admin/.test(c.path))).toHaveLength(0);
});

test('03b an empty device offers only a separately confirmed "Start fresh", and wrong credentials explain the account may not exist', async ({ device, backend }) => {
  await backend.createUser(EMAIL, PASSWORD);
  const { page } = await device({});
  await signIn(page, EMAIL, 'wrong password');
  await expect(page.locator('#cloudStatus')).toContainText('not been set up yet');
  expect(await page.inputValue('#authPassword')).toBe('');
  await signIn(page);
  await expect(page.locator('#seedPanel')).toContainText('sign in first on the device that has your Dog Log data');
  await expect(page.locator('#seedPanel button.primary')).toHaveCount(0);
  expect(backend.rpcCalls('seed_state')).toHaveLength(0);
});

test('04 first-device seed requires explicit confirmation and strips device-local calendar credentials', async ({ device, backend }) => {
  const owner = await backend.createUser(EMAIL, PASSWORD);
  const { page, dialogs } = await device({ raw: JSON.stringify(fixture()) });
  await signIn(page);
  dialogs.answers.push(false);
  await page.click('#seedPanel button.primary');
  await page.waitForTimeout(300);
  expect(dialogs[0]).toContain("Use this device's Dog Log data as the household cloud copy?");
  expect(backend.rpcCalls('seed_state')).toHaveLength(0);
  dialogs.answers.push(true);
  await page.click('#seedPanel button.primary');
  await waitSynced(page);
  expect(backend.rpcCalls('seed_state')).toHaveLength(1);
  const row = await backend.state(owner);
  expect(row.doc.stock).toMatchObject({ fridge: 5, freezer: 12, minceKg: 2.5, neckPackets: 3, necksOnly: 1, lykaPackets: 4, scratchPackets: 2 });
  expect(row.doc.calendar).toEqual({ endpoint: 'https://script.google.com/macros/s/AKfy-local-test/exec' });
  expect(JSON.stringify(row.doc)).not.toContain('device-secret-token');
  expect(backend.calls.some(c => (c.body || '').includes('device-secret-token'))).toBe(false);
  expect(await g(page, () => [meta.mode, meta.migration])).toEqual(['synced', 'seeded']);
  expect(JSON.parse(await raw(page)).calendar.token).toBe('device-secret-token-0123456789abcdef'); // stays on the device
});

test('04b an interrupted seed retries with the same seed identity and edits stay paused until it is confirmed', async ({ device, backend }) => {
  const owner = await backend.createUser(EMAIL, PASSWORD);
  const { page, dialogs } = await device({ raw: JSON.stringify(fixture()) });
  await signIn(page);
  await expect(page.locator('#seedPanel button.primary')).toBeVisible();
  backend.dropResponses = 1; // the server commits the seed, the response is lost
  await page.click('#seedPanel button.primary');
  await expect(page.locator('#syncBadge')).toHaveText('Finishing cloud upload…');
  expect(await g(page, () => meta.migration)).toBe('seeding');
  await g(page, () => adjust('fridge', 1));
  expect(dialogs.at(-1)).toContain('changes are paused');
  await page.reload();
  await waitSynced(page);
  const seeds = backend.rpcCalls('seed_state').map(c => JSON.parse(c.body).p_seed_id);
  expect(seeds.length).toBeGreaterThanOrEqual(2);
  expect(new Set(seeds).size).toBe(1);
  expect(await backend.count('state_snapshots', owner)).toBe(1);
  expect((await backend.state(owner)).doc.stock.fridge).toBe(5); // the paused edit was never applied
});

test('05 when cloud data already exists, a device never seeds its own local data over it', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const before = await backend.state(a.owner);
  const bRaw = JSON.stringify(fixture({ stock: { fridge: 99, freezer: 99, minceKg: 9, neckPackets: 9, necksOnly: 0, minceOnly: 0, lykaPackets: 0, scratchPackets: 0 } }));
  const b = await device({ raw: bRaw });
  await signIn(b.page);
  await waitSynced(b.page);
  expect(backend.rpcCalls('seed_state')).toHaveLength(1); // only device A's
  const after = await backend.state(a.owner);
  expect(after.doc).toEqual(before.doc);
  await expect(b.page.locator('#fridgeVal')).toHaveValue('5');
  expect(await g(b.page, () => meta.migration)).toBe('adopted-cloud');
});

test('06 a second device backs up its legacy local data verbatim before adopting the cloud copy', async ({ device, backend }) => {
  await seededDevice({ device, backend });
  const bRaw = JSON.stringify(fixture({ stock: { fridge: 42, freezer: 0, minceKg: 0, neckPackets: 0, necksOnly: 0, minceOnly: 0, lykaPackets: 0, scratchPackets: 0 }, calendar: { endpoint: '', token: 'device-b-token', paired: true, lastSync: null, lastError: null } }));
  const b = await device({ raw: bRaw });
  await signIn(b.page);
  await waitSynced(b.page);
  const list = await g(b.page, () => backups());
  expect(list.find(x => x.reason === 'pre-adopt').raw).toBe(bRaw);
  expect(list.find(x => x.reason === 'pre-sync').raw).toBe(bRaw);
  const mirror = JSON.parse(await raw(b.page));
  expect(mirror.stock.fridge).toBe(5);
  expect(mirror.calendar.token).toBe('device-b-token');
  await g(b.page, () => showView('settings'));
  await expect(b.page.locator('#backupList')).toContainText('Before adopting the cloud copy');
  await expect(b.page.locator('#backupList')).toContainText('42 Full Containers');
  await expect(b.page.locator('#cloudStatus')).toContainText('Its previous data is kept under Backups');
});
