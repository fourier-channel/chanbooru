// A post's applied view (post_view.js) against the cases the server is held
// to (test/unit/creator_gallery_post_view_test.rb reads the same fixture): one
// view, one style, in the editor and on the page. Then the editor's maths,
// ported from Technetium's uitransform: move, wheel scale, corner and edge.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { URL } from "node:url";
import { LIMITS, IDENTITY, clamp, isIdentity, transform, style, cellView, pictureStyle, toBox, fromBox, move, scaleBy, resize, HANDLES } from "../../app/javascript/src/javascripts/post_view.js";

const fixture = JSON.parse(readFileSync(new URL("../fixtures/files/post_views.json", import.meta.url), "utf8"));
const view = (over = {}) => ({ ...IDENTITY, ...over });
const frame = { width: 400, height: 200 };

test("the ranges are the server's", () => {
  assert.deepEqual(LIMITS, fixture.limits);
});

test("every shared view is drawn as the server draws it", () => {
  const wrong = fixture.views.flatMap(([v, expected]) => {
    const got = transform(v);
    return got === expected ? [] : [`${JSON.stringify(v)}: wanted ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`];
  });
  assert.deepEqual(wrong, []);
  assert.ok(fixture.views.filter(([, expected]) => expected).length >= 6);
  fixture.views.forEach(([v, expected]) => assert.equal(style(v), expected ? `--cg-view: ${expected}` : ""));
});

test("every shared harmonic picture is styled as the server styles it", () => {
  const wrong = fixture.pictures.flatMap(([picture, expected]) => {
    const got = pictureStyle(picture);
    return got === expected ? [] : [`${JSON.stringify(picture)}: wanted ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`];
  });
  assert.deepEqual(wrong, []);
});

// A hero band thumbnail takes the view as its cell's vars, the same pan and
// scale as the transform, the pan in the clip's container units.
test("every shared view is a hero band cell's vars, the transform's own numbers", () => {
  const wrong = fixture.views.flatMap(([v, expected]) => {
    const vars = cellView(v);
    const got = vars && `translate(${vars["--cv-translate"].replace("cqw ", "%, ").replace("cqh", "%")}) scale(${vars["--cv-scale"].replace(" ", ", ")})`;
    return got === (expected || null) ? [] : [`${JSON.stringify(v)}: wanted ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`];
  });
  assert.deepEqual(wrong, []);
  assert.deepEqual(cellView(view({ x: 125, y: -40, scale: 1500, stretch: 800, flip_h: true })), { "--cv-translate": "12.5cqw -4cqh", "--cv-scale": "-1.2 1.5" });
  assert.equal(cellView(undefined), null);
});

test("a picture with no view key is drawn as one with none", () => {
  assert.equal(pictureStyle({ focus_x: 30, focus_y: 60, zoom: 150 }), "object-position: 30% 60%; transform-origin: 30% 60%; transform: scale(1.5)");
});

test("clamp keeps every field whole and in range, and Reset is the identity", () => {
  assert.deepEqual(clamp({}), IDENTITY);
  assert.deepEqual(clamp(undefined), IDENTITY);
  assert.deepEqual(clamp({ flip_h: true, flip_v: "yes", x: -1200.4, y: 1500, scale: 100, stretch: 9000 }), view({ flip_h: true, x: -1000, y: 1000, scale: 200, stretch: 2000 }));
  assert.deepEqual(clamp({ x: 12.6, y: -0.4, scale: Number.NaN, stretch: "1200" }), view({ x: 13 }));
  assert.ok(Object.is(clamp({ y: -0.4 }).y, 0), "never a negative zero");
  assert.ok(isIdentity(null));
  assert.ok(isIdentity(IDENTITY));
  assert.ok(!isIdentity(view({ flip_v: true })));
  assert.ok(Object.isFrozen(IDENTITY));
});

test("a move is the pixel delta as permille of the frame, clamped", () => {
  assert.deepEqual(move(IDENTITY, 40, -10, frame), view({ x: 100, y: -50 }));
  assert.deepEqual(move(view({ flip_h: true, scale: 1300 }), 4000, 4000, frame), view({ flip_h: true, scale: 1300, x: 1000, y: 1000 }));
});

test("the wheel scales by a factor, clamped", () => {
  assert.deepEqual(scaleBy(IDENTITY, 0.9), view({ scale: 900 }));
  assert.deepEqual(scaleBy(view({ scale: 3900 }), 1.08), view({ scale: 4000 }));
  assert.deepEqual(scaleBy(view({ scale: 210 }), 0.5), view({ scale: 200 }));
});

test("the box is where the view draws the image in the frame, and back", () => {
  const v = view({ x: 100, y: -50, scale: 1100, stretch: 1200, flip_v: true });
  const box = toBox(v, frame);
  ["left", "top", "width", "height"].forEach((key, i) => assert.ok(Math.abs(box[key] - [-24, -20, 528, 220][i]) < 1e-9, `${key}: ${box[key]}`));
  assert.deepEqual(fromBox(box, v, frame), v);
  assert.deepEqual(toBox(IDENTITY, frame), { left: 0, top: 0, width: 400, height: 200 });
});

test("a corner drag scales uniformly, anchored on the opposite corner", () => {
  assert.deepEqual(resize(IDENTITY, "se", 440, 210, frame), view({ x: 50, y: 50, scale: 1100 }));
  assert.deepEqual(resize(view({ flip_h: true }), "nw", -40, 0, frame), view({ flip_h: true, x: -50, y: -50, scale: 1100 }));
});

test("an edge drag stretches, the opposite edge staying put", () => {
  assert.deepEqual(resize(IDENTITY, "e", 480, 999, frame), view({ x: 100, stretch: 1200 }));
  assert.deepEqual(resize(IDENTITY, "n", 999, -20, frame), view({ y: -50, scale: 1100, stretch: 909 }));
});

test("a drag past the limits stays inside them", () => {
  const tiny = resize(IDENTITY, "se", 0, 0, frame);
  assert.equal(tiny.scale, LIMITS.scale[0]);
  Object.entries(LIMITS).forEach(([key, [min, max]]) => assert.ok(tiny[key] >= min && tiny[key] <= max, `${key}: ${tiny[key]}`));
  assert.equal(resize(IDENTITY, "w", -5000, 0, frame).stretch, LIMITS.stretch[1]);
  assert.deepEqual(HANDLES, ["nw", "n", "ne", "e", "se", "s", "sw", "w"]);
});

test("the module is ASCII", () => {
  const source = readFileSync(new URL("../../app/javascript/src/javascripts/post_view.js", import.meta.url), "utf8");
  assert.ok([...source].every((ch) => ch.charCodeAt(0) < 128));
});
