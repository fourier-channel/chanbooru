// The post view's lookahead (modulation_lookahead.js): the box the centre
// reserves before its image exists, which posts to warm ahead of the viewer,
// what of each to warm, the bounded keep of warmed images, and the one-slot
// queue a press lands in while a step is under way. Pure, so it runs under
// Node's own test runner: `npm run test-js`.
//
// The bug these guard (operator, 2026-10-18): stepping at normal speed reached
// a post whose image had not loaded, and the stage collapsed to its frame's
// border -- the flank thumbnails vanished with it and the tag panel rode up by
// the image's height, then back down when it landed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { boundedKeep, centerBoxStyle, lookahead, queuePress, queuedFor, warmSource } from "../../app/javascript/src/javascripts/modulation_lookahead.js";

const c = (...ids) => ids.map((id) => ({ id, url: `/posts/${id}` }));
const marked = (...ids) => new Set(ids.map(String));

test("centerBoxStyle: the rendition's own size, as the two variables the stage reads", () => {
  assert.equal(centerBoxStyle([480, 720]), "--mod-bw:480;--mod-bh:720");
  assert.equal(centerBoxStyle([600, 400]), "--mod-bw:600;--mod-bh:400");
});

test("centerBoxStyle: no box, no style -- the stage falls back to the placeholder's size", () => {
  assert.equal(centerBoxStyle(null), "");
  assert.equal(centerBoxStyle(undefined), "");
  assert.equal(centerBoxStyle([]), "");
  assert.equal(centerBoxStyle([0, 720]), "", "a zero side is no box");
  assert.equal(centerBoxStyle(["480", 720]), "", "only numbers: the value is written into a style attribute");
});

test("lookahead: the next allowed candidates after the pick, nearest first", () => {
  assert.deepEqual(lookahead(c(1, 2, 3, 4), marked(), 0, 2).map((r) => r.id), [2, 3]);
  assert.deepEqual(lookahead(c(1, 2, 3, 4), marked(), -1, 2).map((r) => r.id), [1, 2], "from before the first: the pick itself is first");
});

test("lookahead: blocked candidates are stepped over, never returned", () => {
  assert.deepEqual(lookahead(c(1, 2, 3, 4, 5), marked(2, 3), 0, 2).map((r) => r.id), [4, 5]);
  assert.deepEqual(lookahead(c(1, 2, 3), marked(1, 2, 3), -1, 2), []);
});

test("lookahead: the end of the run ends the list; depth bounds it", () => {
  assert.deepEqual(lookahead(c(1, 2), marked(), 1, 2), []);
  assert.deepEqual(lookahead(c(1, 2, 3), marked(), 1, 5).map((r) => r.id), [3]);
  assert.deepEqual(lookahead(c(1, 2, 3), marked(), 0, 0), []);
  assert.deepEqual(lookahead([], marked(), -1, 2), []);
});

test("lookahead: string marks match number ids", () => {
  assert.deepEqual(lookahead(c(10, 11, 12), new Set(["11"]), 0, 1).map((r) => r.id), [12]);
});

test("warmSource: an image warms its src, a video its poster and never the file", () => {
  assert.equal(warmSource({ kind: "image", src: "/a.webp", box: [480, 720] }), "/a.webp");
  assert.equal(warmSource({ kind: "other", src: "/a.jpg", box: [180, 120] }), "/a.jpg");
  assert.equal(warmSource({ kind: "video", src: "/a.mp4", poster: "/a.jpg", box: [1280, 720] }), "/a.jpg");
  assert.equal(warmSource({ kind: "video", src: "/a.mp4", poster: null }), null);
  assert.equal(warmSource({ kind: "image", src: null }), null, "a gated post has nothing to warm");
  assert.equal(warmSource(null), null);
});

test("boundedKeep: holds at most max entries, the least recently used goes first", () => {
  const made = [];
  const keep = boundedKeep(3);
  const make = (k) => () => { made.push(k); return { k }; };
  keep.take("a", make("a"));
  keep.take("b", make("b"));
  keep.take("c", make("c"));
  keep.take("a", make("a")); // used again: kept, not remade, now newest
  keep.take("d", make("d")); // evicts b, the least recently used
  assert.deepEqual(made, ["a", "b", "c", "d"]);
  assert.deepEqual(keep.keys(), ["c", "a", "d"]);
  keep.take("b", make("b"));
  assert.deepEqual(made, ["a", "b", "c", "d", "b"], "an evicted key is made again");
  assert.deepEqual(keep.keys(), ["a", "d", "b"]);
});

test("boundedKeep: take answers the kept value", () => {
  const keep = boundedKeep(2);
  const first = keep.take("x", () => ({ n: 1 }));
  assert.equal(keep.take("x", () => ({ n: 2 })), first);
});

test("queuePress: one slot, the latest press wins, held with the mode it was made in", () => {
  assert.deepEqual(queuePress(null, "next", "search"), { side: "next", key: "search" });
  assert.deepEqual(queuePress({ side: "next", key: "search" }, "prev", "search"), { side: "prev", key: "search" });
  assert.deepEqual(queuePress({ side: "next", key: "search" }, "next", "random"), { side: "next", key: "random" });
  assert.deepEqual(queuePress({ side: "prev", key: "all" }, null, "all"), { side: "prev", key: "all" }, "nothing pressed keeps what was queued");
});

// A press queued in one mode and taken after the viewer switched modes would
// step where they never pressed (review, 2026-10-18).
test("queuedFor: the queued side only in the mode it was pressed in", () => {
  assert.equal(queuedFor({ side: "next", key: "search" }, "search"), "next");
  assert.equal(queuedFor({ side: "next", key: "search" }, "all"), null);
  assert.equal(queuedFor(null, "search"), null);
});
