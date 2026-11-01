// The editor's list of applied views (post_view.js viewIn / putView): the
// draft's `views`, one per post, sorted by post as CreatorGalleryLayout#views
// sends them, so a view set and then set back leaves the draft as it was
// saved. No entry is the identity.
import { test } from "node:test";
import assert from "node:assert/strict";
import { IDENTITY, viewIn, putView } from "../../app/javascript/src/javascripts/post_view.js";

const saved = [
  { post_id: 3, flip_h: true, flip_v: false, x: 0, y: -50, scale: 900, stretch: 1000 },
  { post_id: 9, flip_h: false, flip_v: false, x: 100, y: 0, scale: 1000, stretch: 1200 },
];

test("a post's view is its entry, and the identity without one", () => {
  assert.deepEqual(viewIn(saved, 9), saved[1]);
  assert.deepEqual(viewIn(saved, 4), IDENTITY);
  assert.deepEqual(viewIn(saved, null), IDENTITY);
});

test("a view goes in by its post, in order, its fields as the server sends them", () => {
  const put = putView(saved, 5, { flip_v: true, x: 12.4, y: 0, scale: 1000, stretch: 1000, extra: 1 });
  assert.deepEqual(put.map((v) => v.post_id), [3, 5, 9]);
  assert.deepEqual(Object.keys(put[1]), ["post_id", "flip_h", "flip_v", "x", "y", "scale", "stretch"]);
  assert.deepEqual(put[1], { post_id: 5, flip_h: false, flip_v: true, x: 12, y: 0, scale: 1000, stretch: 1000 });
  assert.equal(saved.length, 2, "the list given is left as it was");
});

test("a view replaces the post's own, and the identity takes it out", () => {
  assert.deepEqual(putView(saved, 3, { ...IDENTITY, x: 7 }).map((v) => [v.post_id, v.x]), [[3, 7], [9, 100]]);
  assert.deepEqual(putView(saved, 3, IDENTITY), [saved[1]]);
  assert.deepEqual(putView(saved, 4, IDENTITY), saved);
});

test("a view set and set back is the list as saved, to the letter", () => {
  const back = putView(putView(saved, 3, IDENTITY), 3, saved[0]);
  assert.equal(JSON.stringify(back), JSON.stringify(saved));
});
