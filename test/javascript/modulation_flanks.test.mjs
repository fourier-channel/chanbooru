// The flank pick (modulation_flanks.js): which of a side's candidates the
// post view shows, given the ids the blocklist engine has marked. Pure, so it
// runs under Node's own test runner: `npm run test-js`.
//
// The marks come off the pool elements' dataset.id, which is a STRING; the
// candidate ids come from the JSON payload, which are NUMBERS. A pick that
// compared them as they are would never see a block -- the bug this replaces,
// arriving by another door.
import { test } from "node:test";
import assert from "node:assert/strict";
import { extendRun, flankState, flankWords, runsKey } from "../../app/javascript/src/javascripts/modulation_flanks.js";

const c = (...ids) => ids.map((id) => ({ id, url: `/posts/${id}` }));
const blocked = (...ids) => new Set(ids.map(String));

test("picks the first candidate the blocklist allows, counting the blocked ones before it", () => {
  assert.deepEqual(flankState(c(1, 2, 3), false, blocked(), 4), { kind: "pick", index: 0, skipped: 0 });
  assert.deepEqual(flankState(c(1, 2, 3), false, blocked(1), 4), { kind: "pick", index: 1, skipped: 1 });
  assert.deepEqual(flankState(c(1, 2, 3), true, blocked(1, 2), 4), { kind: "pick", index: 2, skipped: 2 });
  assert.deepEqual(flankState(c(1, 2, 3), false, blocked(2), 4), { kind: "pick", index: 0, skipped: 0 }, "a block past the pick changes nothing");
});

test("matches string marks against number ids", () => {
  const marks = new Set(["10"]);
  assert.deepEqual(flankState(c(10, 11), false, marks, 4), { kind: "pick", index: 1, skipped: 1 });
});

test("all blocked with more beyond: look further while the hop budget lasts", () => {
  assert.deepEqual(flankState(c(1, 2), true, blocked(1, 2), 4), { kind: "blocked-more", blocked: 2, canHop: true });
  assert.deepEqual(flankState(c(1, 2), true, blocked(1, 2), 1), { kind: "blocked-more", blocked: 2, canHop: true });
  assert.deepEqual(flankState(c(1, 2), true, blocked(1, 2), 0), { kind: "blocked-more", blocked: 2, canHop: false });
});

test("all blocked with nothing beyond: a blocked end, not a plain one", () => {
  assert.deepEqual(flankState(c(1, 2), false, blocked(1, 2), 4), { kind: "blocked-end", blocked: 2 });
});

test("no candidates and nothing beyond: the end of the trail", () => {
  assert.deepEqual(flankState([], false, blocked(), 4), { kind: "end" });
});

// Every candidate dropped server-side (a post this viewer may not see) still
// leaves the search going on: that is an unanswered lookup, never the end.
test("no candidates but more beyond: look further, not the end", () => {
  assert.deepEqual(flankState([], true, blocked(), 4), { kind: "blocked-more", blocked: 0, canHop: true });
});

test("is pure: same inputs, same answer, inputs untouched", () => {
  const list = Object.freeze(c(1, 2, 3).map(Object.freeze));
  const marks = blocked(1);
  const before = [...marks];
  const a = flankState(list, true, marks, 2);
  const b = flankState(list, true, marks, 2);
  assert.deepEqual(a, b);
  assert.notEqual(a, b, "a fresh answer each call");
  assert.deepEqual([...marks], before);
});

// What a side's state says, on the tile's title and on the status line. A
// count of one is "1 blocked post", never "1 blocked posts": random mode's
// fresh arrival carries exactly one candidate a side, so it is an everyday
// count, not an edge.
test("words: the blocked count agrees with its noun", () => {
  assert.equal(flankWords({ kind: "blocked-more", blocked: 1, canHop: true, looking: false }, "prev"), "Looking further back past 1 blocked post.");
  assert.equal(flankWords({ kind: "blocked-more", blocked: 3, canHop: false, looking: true }, "next"), "Looking further forward past 3 blocked posts.");
  assert.equal(flankWords({ kind: "blocked-more", blocked: 1, canHop: false, looking: false }, "next"),
    "Stopped looking forward after 1 blocked post. Press again to look further, or change mode with the up/down arrows.");
  assert.equal(flankWords({ kind: "blocked-end", blocked: 1 }, "next"),
    "The only post left forward here is on your blocklist. Fix: lift a block, or change mode with the up/down arrows.");
  assert.equal(flankWords({ kind: "blocked-end", blocked: 7 }, "prev"),
    "Every post left back here is on your blocklist (7). Fix: lift a block, or change mode with the up/down arrows.");
});

test("words: every state that stops a press names its fix", () => {
  assert.match(flankWords({ kind: "failed", why: "HTTP 500" }, "next"), /\(HTTP 500\)\. Fix: reload the page\.$/);
  assert.match(flankWords({ kind: "unavailable" }, "next"), /Fix: change mode/);
  assert.match(flankWords({ kind: "no-access" }, "prev"), /back.*Fix: change mode/);
  assert.equal(flankWords({ kind: "fault", why: "The blocklist did not load. Fix: reload the page." }, "next"), "The blocklist did not load. Fix: reload the page.");
  assert.match(flankWords({ kind: "fault", why: "" }, "next"), /not applied yet/);
  assert.equal(flankWords({ kind: "pick", index: 0, skipped: 0 }, "next"), "");
  assert.equal(flankWords({ kind: "end" }, "next"), "");
});

// What the page's look-further extensions belong to: the post AND the runs
// they extend. A re-read of the same post (a vote, a favourite, a tag edit's
// optimistic copy) is a new object with the same runs, and must keep what
// looking further found; a re-read whose runs changed (random's frontier
// rolled again) must not have stale extensions glued onto the new lists.
test("runsKey: the same post and runs keep their key across re-reads", () => {
  const payload = () => ({
    id: 5, score: { up: 1 },
    presets: [{ key: "all", search: "order:id_desc", prev_candidates: c(6, 7), next_candidates: c(4), prev_more: true, next_more: false }],
  });
  const a = payload(), b = payload();
  b.score = { up: 2 };
  assert.notEqual(a, b);
  assert.equal(runsKey(a), runsKey(b));
});

test("runsKey: another post, other candidates, another more or another search is another key", () => {
  const base = { id: 5, presets: [{ key: "all", search: "order:id_desc", prev_candidates: c(6, 7), next_candidates: c(4), prev_more: true, next_more: false }] };
  const variant = (f) => { const p = JSON.parse(JSON.stringify(base)); f(p); return p; };
  assert.notEqual(runsKey(base), runsKey(variant(p => { p.id = 6; })));
  assert.notEqual(runsKey(base), runsKey(variant(p => { p.presets[0].next_candidates = c(3); })));
  assert.notEqual(runsKey(base), runsKey(variant(p => { p.presets[0].prev_more = false; })));
  assert.notEqual(runsKey(base), runsKey(variant(p => { p.presets[0].search = "flankq order:id_desc"; })));
  assert.equal(runsKey(null), "");
});

// One look further: the anchor's answer for the same search, minus what the
// run already holds. An answer that adds nothing while still saying `more`
// would be asked again from the same anchor forever -- that is a dead end,
// said once, not a loop.
test("extendRun: appends the new candidates and takes the answer's more", () => {
  const r = extendRun(c(1, 2), 9, { next_candidates: c(2, 3, 4), next_more: true }, "next");
  assert.deepEqual(r, { added: c(3, 4), more: true, dead: false });
});

test("extendRun: never re-adds the post itself or a candidate already held", () => {
  const r = extendRun(c(1, 2), 9, { prev_candidates: c(9, 1, 5), prev_more: false }, "prev");
  assert.deepEqual(r, { added: c(5), more: false, dead: false });
});

test("extendRun: nothing new while more beyond is a dead end; nothing new at the end is not", () => {
  assert.deepEqual(extendRun(c(1, 2), 9, { next_candidates: c(2), next_more: true }, "next"), { added: [], more: true, dead: true });
  assert.deepEqual(extendRun(c(1, 2), 9, { next_candidates: [], next_more: true }, "next"), { added: [], more: true, dead: true });
  assert.deepEqual(extendRun(c(1, 2), 9, { next_candidates: [], next_more: false }, "next"), { added: [], more: false, dead: false });
});
