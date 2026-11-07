// The editor's list of applied views (post_view.js viewIn / putView): the
// draft's `views`, one per place and post, sorted by place and then post as
// CreatorGalleryLayout#views sends them, so a view set and then set back
// leaves the draft as it was saved. No entry is the identity.
import { test } from "node:test";
import assert from "node:assert/strict";
import { IDENTITY, viewIn, putView } from "../../app/javascript/src/javascripts/post_view.js";

const saved = [
  { place: "banner", post_id: 9, flip_h: false, flip_v: false, x: 0, y: 40, scale: 1000, stretch: 1000 },
  { place: "mini", post_id: 3, flip_h: true, flip_v: false, x: 0, y: -50, scale: 900, stretch: 1000 },
  { place: "mini", post_id: 9, flip_h: false, flip_v: false, x: 100, y: 0, scale: 1000, stretch: 1200 },
];

test("a post's view is its entry in that place, and the identity without one", () => {
  assert.deepEqual(viewIn(saved, "mini", 9), saved[2]);
  assert.deepEqual(viewIn(saved, "banner", 9), saved[0]);
  assert.deepEqual(viewIn(saved, "hero", 9), IDENTITY, "a view in one place is not the post's in another");
  assert.deepEqual(viewIn(saved, "mini", 4), IDENTITY);
  assert.deepEqual(viewIn(saved, "banner", null), IDENTITY);
});

test("a view goes in by its place and post, in order, its fields as the server sends them", () => {
  const put = putView(saved, "hero", 5, { flip_v: true, x: 12.4, y: 0, scale: 1000, stretch: 1000, extra: 1 });
  assert.deepEqual(put.map((v) => [v.place, v.post_id]), [["banner", 9], ["hero", 5], ["mini", 3], ["mini", 9]]);
  assert.deepEqual(Object.keys(put[1]), ["place", "post_id", "flip_h", "flip_v", "x", "y", "scale", "stretch"]);
  assert.deepEqual(put[1], { place: "hero", post_id: 5, flip_h: false, flip_v: true, x: 12, y: 0, scale: 1000, stretch: 1000 });
  assert.deepEqual(putView(saved, "mini", 5, { ...IDENTITY, x: 1 }).map((v) => [v.place, v.post_id]), [["banner", 9], ["mini", 3], ["mini", 5], ["mini", 9]]);
  assert.equal(saved.length, 3, "the list given is left as it was");
});

test("a view replaces the post's own in that place only, and the identity takes it out", () => {
  assert.deepEqual(putView(saved, "mini", 9, { ...IDENTITY, x: 7 }).map((v) => [v.place, v.post_id, v.x]), [["banner", 9, 0], ["mini", 3, 0], ["mini", 9, 7]]);
  assert.deepEqual(putView(saved, "mini", 9, IDENTITY), saved.slice(0, 2));
  assert.deepEqual(putView(saved, "hero", 9, IDENTITY), saved);
});

test("a view set and set back is the list as saved, to the letter", () => {
  const { place, post_id: id, ...view } = saved[1];
  const back = putView(putView(saved, place, id, IDENTITY), place, id, view);
  assert.equal(JSON.stringify(back), JSON.stringify(saved));
});
