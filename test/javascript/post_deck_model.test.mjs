// The post deck's model (post_deck_model.js): the row pitch that leaves a lip
// of every card, the entrance stagger, the ghost list that keeps a leaving
// card in its slot while it pops out, and the map of posts another miniband
// already holds. No DOM, so it runs under Node's own test runner:
// `npm run test-js`.
//
// The operator's brief it is held to (2026-11-01): rows of cards "at least
// partially seen", a post on one miniband shown as used on the others.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  pitch, enterDelay, withGhosts, usedMap, usedWords, placed, REVEAL,
} from "../../app/javascript/src/javascripts/post_deck_model.js";

test("a row starts where the card above it is 42% from its foot, so its top 58% shows", () => {
  assert.equal(REVEAL, 0.42);
  assert.equal(pitch(100), 58);
  assert.equal(pitch(125), 73);
  assert.equal(pitch(200, 0.5), 100);
});

test("a pitch is whole pixels, never more than the card or less than nothing", () => {
  assert.equal(pitch(100, 0), 100);
  assert.equal(pitch(100, 1), 0);
  assert.equal(pitch(100, 1.5), 0);
  assert.equal(pitch(100, -1), 100);
});

test("newcomers pop in after a lead, a step apart, and a big batch stops cascading", () => {
  assert.equal(enterDelay(0), 90);
  assert.equal(enterDelay(1), 104);
  assert.equal(enterDelay(5), 160);
  assert.equal(enterDelay(18), 342);
  assert.equal(enterDelay(19), 350);
  assert.equal(enterDelay(200), 350);
});

test("with nothing gone, the list is the current posts with newcomers marked", () => {
  assert.deepEqual(withGhosts([3, 1, 2], [3, 1], new Set([2]), []), [
    { id: 3, phase: "steady" }, { id: 1, phase: "steady" }, { id: 2, phase: "entering" },
  ]);
});

test("a leaving post keeps the slot it held, so its neighbours do not slide twice", () => {
  assert.deepEqual(withGhosts([1, 3], [1, 2, 3], new Set(), [2]), [
    { id: 1, phase: "steady" }, { id: 2, phase: "leaving" }, { id: 3, phase: "steady" },
  ]);
  assert.deepEqual(withGhosts([2, 3], [1, 2, 3], new Set(), [1]), [
    { id: 1, phase: "leaving" }, { id: 2, phase: "steady" }, { id: 3, phase: "steady" },
  ]);
});

test("a ghost past the end, or never seen, waits at the end; two in one slot keep their order", () => {
  assert.deepEqual(withGhosts([1], [1, 2, 3, 4], new Set(), [3, 4]), [
    { id: 1, phase: "steady" }, { id: 3, phase: "leaving" }, { id: 4, phase: "leaving" },
  ]);
  assert.deepEqual(withGhosts([1], [1], new Set(), [9]), [
    { id: 1, phase: "steady" }, { id: 9, phase: "leaving" },
  ]);
  // A slot is clamped to the current length, not shifted by earlier ghosts:
  // 2 held index 1, which is past the one current post.
  assert.deepEqual(withGhosts([4], [1, 2, 3, 4], new Set([4]), [1, 2]), [
    { id: 1, phase: "leaving" }, { id: 4, phase: "entering" }, { id: 2, phase: "leaving" },
  ]);
});

const minis = [{ posts: [1, 2] }, { posts: [3] }, { posts: [2, 4] }];

test("a miniband sees which of the OTHER minibands hold a post, numbered from 1", () => {
  assert.deepEqual([...usedMap(minis, 0)], [[3, [2]], [2, [3]], [4, [3]]]);
  assert.deepEqual([...usedMap(minis, 1)], [[1, [1]], [2, [1, 3]], [4, [3]]]);
});

test("a post kept on this miniband and another still shows the other", () => {
  assert.deepEqual(usedMap(minis, 2).get(2), [1]);
  assert.equal(usedMap(minis, 2).has(4), false);
});

test("only the minibands handed in count; the caller trims to the layout's slots", () => {
  assert.deepEqual([...usedMap(minis.slice(0, 2), 0)], [[3, [2]]]);
  assert.deepEqual([...usedMap([], 0)], []);
  assert.deepEqual([...usedMap([{ posts: [] }, {}], 0)], []);
});

test("the minibands read as words", () => {
  assert.equal(usedWords([2]), "miniband 2");
  assert.equal(usedWords([1, 3]), "minibands 1 and 3");
  assert.equal(usedWords([1, 2, 4]), "minibands 1, 2 and 4");
});

test("a post let go on the strip is staged before the card it was let go in front of", () => {
  assert.deepEqual(placed([1, 2, 3], 9, 0), [9, 1, 2, 3]);
  assert.deepEqual(placed([1, 2, 3], 9, 2), [1, 2, 9, 3]);
  assert.deepEqual(placed([1, 2, 3], 9, 3), [1, 2, 3, 9]);
  assert.deepEqual(placed([], 9, 0), [9]);
});

test("a staged post moved along the strip is counted without itself, and never doubled", () => {
  assert.deepEqual(placed([1, 2, 3], 1, 2), [2, 3, 1]);
  assert.deepEqual(placed([1, 2, 3], 3, 0), [3, 1, 2]);
  assert.deepEqual(placed([1, 2, 3], 2, 1), [1, 2, 3]);
  assert.deepEqual(placed([1, 2, 3], 2, 9), [1, 3, 2]);
});
