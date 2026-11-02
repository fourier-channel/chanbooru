// A creator gallery's About boxes (creator_about_model.js): the heights a
// viewer may give a box, by drag and by key. No DOM, so it runs under Node's
// own test runner: `npm run test-js`.
//
// The operator's brief (2026-11-02): "Allow each viewer to resize the boxes
// vertically." The bounds are the server's (ModulationSetting
// creator_about_boxes takes 80..2000); a height outside them is refused there.
import { test } from "node:test";
import assert from "node:assert/strict";
import { BOX_MAX, BOX_MIN, clampHeight, keyHeight } from "../../app/javascript/src/javascripts/creator_about_model.js";

test("the bounds are the server's", () => {
  assert.equal(BOX_MIN, 80);
  assert.equal(BOX_MAX, 2000);
});

test("a dragged height is a whole pixel count inside the bounds", () => {
  assert.equal(clampHeight(320.6), 321);
  assert.equal(clampHeight(12), BOX_MIN);
  assert.equal(clampHeight(-400), BOX_MIN);
  assert.equal(clampHeight(9000), BOX_MAX);
});

test("ArrowDown grows a box and ArrowUp shrinks it, Shift by more, never past the bounds", () => {
  assert.equal(keyHeight("ArrowDown", false, 300), 324);
  assert.equal(keyHeight("ArrowUp", false, 300), 276);
  assert.equal(keyHeight("ArrowDown", true, 300), 420);
  assert.equal(keyHeight("ArrowUp", true, 300), 180);
  assert.equal(keyHeight("ArrowUp", true, 100), BOX_MIN);
  assert.equal(keyHeight("ArrowDown", false, 1990), BOX_MAX);
  // A box at its content's height measures a fraction; a key starts from it.
  assert.equal(keyHeight("ArrowDown", false, 211.4), 235);
});

test("Home gives the box back its content's height; any other key is not the grip's", () => {
  assert.equal(keyHeight("Home", false, 300), null);
  assert.equal(keyHeight("Enter", false, 300), undefined);
  assert.equal(keyHeight("ArrowLeft", false, 300), undefined);
});
