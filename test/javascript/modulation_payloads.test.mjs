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
import { mergeVisit, payloadStore } from "../../app/javascript/src/javascripts/modulation_payloads.js";

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

// More lookahead means more payloads held, and the store never let one go:
// a long walk kept every post it passed in memory for the life of the page.
test("the cache is bounded: past max, the least recently used payload goes", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load, { max: 2 });
  const ask = async (key, v) => { const p = store.get(key); pending[pending.length - 1].resolve({ v }); return p; };
  await ask("1|q", 1);
  await ask("2|q", 2);
  await store.get("1|q"); // used again: 1 is now the newest
  await ask("3|q", 3); // evicts 2
  assert.equal(pending.length, 3);
  assert.deepEqual(await store.get("1|q"), { v: 1 }, "kept: answered from the cache");
  assert.equal(pending.length, 3);
  const again = store.get("2|q");
  assert.equal(pending.length, 4, "evicted: asked again");
  pending[3].resolve({ v: 2 });
  assert.deepEqual(await again, { v: 2 });
});

test("has: true for a cached payload or one in flight, false otherwise", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  assert.equal(store.has("5|q"), false);
  const a = store.get("5|q");
  assert.equal(store.has("5|q"), true, "in flight");
  pending[0].resolve({ v: 1 });
  await a;
  assert.equal(store.has("5|q"), true, "cached");
  store.clear();
  assert.equal(store.has("5|q"), false);
});

// A press uses whatever is already on its way: a prefetched payload (no
// comments, random's preset possibly deferred) over a fresh request, and a
// cached answer of either flavour over one still in flight.
test("choose: cached before in flight, in the order given; neither -> the first key", async () => {
  const { load, pending } = loader();
  const store = payloadStore(load);
  assert.equal(store.choose(["full", "pre"]), "full", "nothing held: the first key");
  const pre = store.get("pre");
  assert.equal(store.choose(["full", "pre"]), "pre", "the prefetch in flight");
  const full = store.get("full");
  assert.equal(store.choose(["full", "pre"]), "full", "both in flight: the order given");
  pending[0].resolve({ v: "pre" });
  await pre;
  assert.equal(store.choose(["full", "pre"]), "pre", "a cached prefetch beats a full one still in flight");
  pending[1].resolve({ v: "full" });
  await full;
  assert.equal(store.choose(["full", "pre"]), "full");
});

// THE VISIT READ (?visit=1) carries only what a prefetch lacked: random's
// preset, that preset's candidates and the comments. It replaces those and
// keeps the rest of what the page shows -- the score, the tags, every other
// mode's candidates -- because a full re-read applied after the viewer voted
// put the pre-vote score back on screen (review, 2026-10-18).
const shown = () => ({
  id: 7,
  score: { total: 3, vote: "up" },
  presets: [
    { key: "search", search: "a order:id_desc", next_candidates: [{ id: 6 }] },
    { key: "random", search: "a order:random", deferred: true, prev_candidates: [], next_candidates: [] },
  ],
  candidates: { 6: { thumb: "t6" } },
});
const visit = {
  id: 7,
  presets: [{ key: "random", search: "a order:random", prev_candidates: [{ id: 2 }], next_candidates: [{ id: 9 }] }],
  candidates: { 2: { thumb: "t2" }, 9: { thumb: "t9" } },
  comments_html: "<p>c</p>",
};

test("mergeVisit: random's preset, its candidates and the comments replaced; everything else kept", () => {
  const before = shown();
  const after = mergeVisit(before, visit);
  assert.deepEqual(after.score, { total: 3, vote: "up" });
  assert.equal(after.presets[0], before.presets[0], "the search mode's preset is the same object");
  assert.deepEqual(after.presets[1], visit.presets[0]);
  assert.deepEqual(Object.keys(after.candidates).sort(), ["2", "6", "9"]);
  assert.equal(after.comments_html, "<p>c</p>");
  assert.equal(before.presets[1].deferred, true, "the payload given (the store's copy) is not edited");
  assert.equal(before.comments_html, undefined);
});

test("mergeVisit: refuses another post's visit", () => {
  assert.throws(() => mergeVisit(shown(), { ...visit, id: 8 }), /post #8.*post #7/);
});

test("mergeVisit: a mode the visit does not name stays as it was", () => {
  const after = mergeVisit(shown(), { id: 7, presets: [], candidates: {}, comments_html: "" });
  assert.equal(after.presets[1].deferred, true);
  assert.equal(after.comments_html, "");
});
