// Service worker dog-log-v9: API traffic is never cached; v8 -> v9 keeps local data and the offline shell.
const { test, expect, g, APP, fixture, signIn, waitSynced, raw, EMAIL, PASSWORD } = require('../lib/helpers');

async function controlled(page) {
  await page.evaluate(() => navigator.serviceWorker.ready);
  if (!(await page.evaluate(() => !!navigator.serviceWorker.controller))) await page.reload();
  await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);
}
const cacheState = page => page.evaluate(async () => {
  const keys = await caches.keys();
  const urls = [];
  for (const k of keys) for (const r of await (await caches.open(k)).keys()) urls.push(r.url);
  return { keys, urls };
});

test('25 the service worker never caches or answers Supabase, Auth, RPC or Apps Script requests', async ({ device, backend }) => {
  await backend.createUser(EMAIL, PASSWORD);
  const { page } = await device({ raw: JSON.stringify(fixture()), serviceWorkers: 'allow' });
  await controlled(page);
  const api = [];
  page.on('response', r => { if (!r.url().startsWith(APP())) api.push({ url: r.url(), sw: r.fromServiceWorker() }); });
  await signIn(page);
  await page.click('#seedPanel button.primary');
  await waitSynced(page);
  await g(page, () => showView('food'));
  await page.click(`button[onclick="adjust('fridge',1)"]`);
  await waitSynced(page);
  await g(page, () => syncCalendar());
  await expect.poll(() => api.some(r => r.url.includes('/rest/v1/rpc/sync'))).toBe(true);
  expect(api.filter(r => r.sw)).toEqual([]);
  expect(api.some(r => r.url.includes('/auth/v1/token'))).toBe(true);
  const { keys, urls } = await cacheState(page);
  expect(keys).toEqual(['dog-log-v9']);
  expect(urls.every(u => u.startsWith(APP()))).toBe(true);
  expect(urls.some(u => /supabase\.co|script\.google/.test(u))).toBe(false);
  expect(urls).toEqual(expect.arrayContaining([`${APP()}/vendor/supabase-js-2.116.0.min.js`, `${APP()}/index.html`]));
});

test('26 upgrading from the v8 service worker keeps localStorage and the offline shell; icons stay network-only', async ({ device }) => {
  await fetch(`${APP()}/__test__/sw?version=v8`);
  try {
    const rawIn = JSON.stringify(fixture({ calendar: { endpoint: '', token: '', paired: false, lastSync: null, lastError: null } }));
    const { page, context } = await device({ raw: rawIn, serviceWorkers: 'allow' });
    await controlled(page);
    await expect.poll(async () => (await cacheState(page)).keys).toEqual(['dog-log-v8']);
    const storageBefore = await page.evaluate(() => JSON.stringify(Object.entries(localStorage).sort()));
    await fetch(`${APP()}/__test__/sw?version=v9`);
    await page.evaluate(async () => (await navigator.serviceWorker.getRegistration()).update());
    await expect.poll(async () => (await cacheState(page)).keys, { timeout: 15000 }).toEqual(['dog-log-v9']);
    await page.reload();
    expect(await page.evaluate(() => JSON.stringify(Object.entries(localStorage).sort()))).toBe(storageBefore);
    expect(await raw(page)).toBe(rawIn);
    // Icons are never answered by the service worker; cached assets are.
    const icon = page.waitForResponse(r => r.url().includes('/icons/icon-192.png'));
    await page.evaluate(() => fetch('/icons/icon-192.png?v=2'));
    expect((await icon).fromServiceWorker()).toBe(false);
    const man = page.waitForResponse(r => r.url().endsWith('/manifest.json'));
    await page.evaluate(() => fetch('/manifest.json'));
    expect((await man).fromServiceWorker()).toBe(true);
    // Offline start from the cached shell, with the vendored library available.
    await context.setOffline(true);
    await page.reload();
    await expect(page.locator('.title')).toHaveText('Dog Log');
    await expect(page.locator('#fridgeVal')).toHaveValue('5');
    expect(await page.evaluate(async () => !!(await caches.match('/vendor/supabase-js-2.116.0.min.js')))).toBe(true);
  } finally {
    await fetch(`${APP()}/__test__/sw?version=v9`);
  }
});
