// The post view's payload store (modulation_payloads.js): one cache of
// modulation.json answers, with a request already in flight shared rather
// than repeated. Pure apart from the loader it is handed, so it runs under
// Node's own test runner: `npm run test-js`.
//
// The race it must not lose: a write (a vote, a favourite) re-reads the post
// with refresh(). A request sent BEFORE that write may still be in flight --
// an earlier refresh, a preload -- and its answer predates the write. Handing
// that answer to the refresh, or letting it land in the cache after the
// refresh or a clear, shows the viewer a state the server no longer holds.
import { test } from "node:test";
import assert from "node:assert/strict";
import { payloadStore } from "../../app/javascript/src/javascripts/modulation_payloads.js";

// A loader whose answers the test releases by hand, in any order.
function loader() {
  const pending = [];
  const load = (key) => new Promise((resolve, reject) => { pending.push({ key, resolve, reject }); });
  return { load, pending };
}

test("get: a request in flight is shared, and its answer is cached", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  const a = store.get("5|q");
  const b = store.get("5|q");
  assert.equal(pending.length, 1, "one request for two asks");
  pending[0].resolve({ v: 1 });
  assert.deepEqual(await a, { v: 1 });
  assert.equal(await b, await a);
  assert.equal(await store.get("5|q"), await a, "answered from the cache");
  assert.equal(pending.length, 1);
});

test("refresh: never shares a request sent before it, and its answer wins", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  const before = store.get("5|q"); // sent before the write
  const after = store.refresh("5|q"); // the write's re-read
  assert.equal(pending.length, 2, "the refresh sent its own request");
  pending[1].resolve({ v: "after" });
  pending[0].resolve({ v: "before" }); // the older answer lands last
  assert.deepEqual(await after, { v: "after" });
  assert.deepEqual(await before, { v: "before" }, "the older ask still gets its own answer");
  assert.deepEqual(await store.get("5|q"), { v: "after" }, "the cache holds the refreshed answer");
  assert.equal(pending.length, 2);
});

test("refresh: of two refreshes, only the later answer is current", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  const first = store.refresh("5|q");
  const second = store.refresh("5|q");
  pending[1].resolve({ v: 2 });
  pending[0].resolve({ v: 1 });
  const [p1, p2] = await Promise.all([first, second]);
  assert.equal(store.current("5|q", p1), false, "the first refresh's answer is stale");
  assert.equal(store.current("5|q", p2), true);
  assert.deepEqual(await store.get("5|q"), { v: 2 });
});

test("clear: an answer still in flight does not refill the cache", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  const old = store.get("5|q");
  store.clear();
  pending[0].resolve({ v: "old" });
  await old;
  const fresh = store.get("5|q");
  assert.equal(pending.length, 2, "asked again after the clear");
  pending[1].resolve({ v: "new" });
  assert.deepEqual(await fresh, { v: "new" });
});

test("a failed request is not cached and is not shared afterwards", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  const a = store.get("5|q");
  pending[0].reject(503);
  await assert.rejects(a, (why) => why === 503);
  const b = store.get("5|q");
  assert.equal(pending.length, 2);
  pending[1].resolve({ v: 1 });
  assert.deepEqual(await b, { v: 1 });
});
