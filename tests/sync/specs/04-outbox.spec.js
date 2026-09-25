// Durable offline outbox: persisted before sending, replayed in order, removed only on a definitive result.
const { test, expect, g, raw, outboxOps, waitSynced, seededDevice } = require('../lib/helpers');

async function online(page, backend) { backend.down = false; await page.evaluate(() => window.dispatchEvent(new Event('online'))); await waitSynced(page); }

test('13 queued operations survive a reload (and app termination) while offline', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);
  await a.page.click(`button[onclick="adjust('fridge',1)"]`);
  const before = await outboxOps(a.page);
  await a.page.reload();
  expect(await outboxOps(a.page)).toEqual(before);
  await expect(a.page.locator('#fridgeVal')).toHaveValue('7');
  expect(JSON.parse(await raw(a.page)).stock.fridge).toBe(7); // the legacy mirror carries unacknowledged ops (R4)
  await expect(a.page.locator('#syncBadge')).toContainText('2 pending');
  await online(a.page, backend);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(7);
});

test('14 a retry after a lost acknowledgement reuses the same mutation id and applies once', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.dropResponses = 1;
  await a.page.click(`button[onclick="adjust('freezer',1)"]`);
  const [op] = await outboxOps(a.page);
  await waitSynced(a.page); // the automatic retry succeeds
  const sends = backend.rpcCalls('sync').map(c => JSON.parse(c.body).p_mutations).filter(m => m.length);
  expect(sends.length).toBeGreaterThanOrEqual(2);
  sends.forEach(m => expect(m.map(o => o.mutation_id)).toEqual([op.mutation_id]));
  expect((await backend.state(a.owner)).doc.stock.freezer).toBe(13);
  expect(await backend.ledger(a.owner)).toHaveLength(1);
  expect(await g(a.page, () => review.length)).toBe(0);
});

test('15 an acknowledged operation leaves the outbox and the cached revision advances', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  const rev = await g(a.page, () => cache.revision);
  await a.page.click(`button[onclick="adjust('lykaPackets',1)"]`);
  await waitSynced(a.page);
  expect(await outboxOps(a.page)).toEqual([]);
  expect(await g(a.page, () => cache.revision)).toBe(rev + 1);
  expect(await g(a.page, () => cache.revision)).toBe((await backend.state(a.owner)).revision);
});

test('16 a network failure keeps the operation queued with its error, and nothing is lost', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await a.page.click(`button[onclick="adjust('scratchPackets',-1)"]`);
  await expect.poll(() => a.page.evaluate(() => JSON.parse(localStorage.getItem('dog_log_outbox_v1'))[0].attempts)).toBeGreaterThanOrEqual(1);
  const [entry] = await a.page.evaluate(() => JSON.parse(localStorage.getItem('dog_log_outbox_v1')));
  expect(entry.last_error).toBeTruthy();
  await expect(a.page.locator('#syncBadge')).toContainText('1 pending');
  expect((await backend.state(a.owner)).doc.stock.scratchPackets).toBe(2);
  await online(a.page, backend);
  expect((await backend.state(a.owner)).doc.stock.scratchPackets).toBe(1);
});

test('23 offline changes replay in their original order, deterministically', async ({ device, backend }) => {
  const a = await seededDevice({ device, backend });
  backend.down = true;
  await a.page.click(`button[onclick="adjust('fridge',1)"]`); // 5 -> 6
  await a.page.fill('#fridgeVal', '9');                          // set 9, expected 6
  await a.page.locator('#fridgeVal').blur();
  await a.page.click(`button[onclick="adjust('fridge',-1)"]`); // 9 -> 8
  const ops = await outboxOps(a.page);
  expect(ops.map(o => [o.type, o.expected ?? o.delta])).toEqual([['adjust', 1], ['set', 6], ['adjust', -1]]);
  await a.page.reload();
  await expect(a.page.locator('#fridgeVal')).toHaveValue('8');
  await online(a.page, backend);
  expect((await backend.state(a.owner)).doc.stock.fridge).toBe(8);
  expect((await backend.ledger(a.owner)).map(r => [r.mutation_id, r.status])).toEqual(ops.map(o => [o.mutation_id, 'applied']));
  expect((await backend.state(a.owner)).doc.history.slice(0, 3).map(h => h.action)).toEqual(['Fridge -1', 'Fridge set to 9 containers', 'Fridge +1']);
});
