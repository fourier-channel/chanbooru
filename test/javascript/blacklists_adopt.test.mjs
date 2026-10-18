// The blocklist engine's incremental adopt (blacklists.js): the post view's
// flank pool changes on every navigation, and rescan() rebuilt every matched
// element on the page -- a new Post each, every rule applied to each -- on the
// frame the enter animation starts. At 1000 blocks that measured 65-150 ms a
// press (2026-10-17 review). adopt() takes in only the elements a surface
// added and lets go of the ones it removed.
//
// blacklists.js imports './utility' (which pulls @rails/ujs, tippy and Alpine
// at load) and './cookie', extensionless, so this loads the REAL engine with
// those two resolved to stubs. The engine itself is not copied or edited.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";

const STUBS = {
  "./utility": "export function splitWords(string) { return string?.match(/\\S+/g) || []; }",
  "./cookie": "export default { remove() {} };",
};
registerHooks({
  resolve(specifier, context, next) {
    if (STUBS[specifier] !== undefined) {
      return { url: "data:text/javascript," + encodeURIComponent(STUBS[specifier]), shortCircuit: true };
    }
    return next(specifier, context);
  },
});

// The globals the engine reaches for: Alpine.reactive (identity here), jQuery's
// $(selector).toArray() over the page's elements, and document's event bus.
let page = [];
let announced = 0;
globalThis.Alpine = { reactive: (o) => o };
globalThis.$ = () => ({ toArray: () => page.slice() });
globalThis.document = { dispatchEvent() { announced += 1; }, querySelector() { return null; } };
globalThis.window = { addEventListener() {} };
globalThis.localStorage = { getItem() { return null; }, setItem() {}, removeItem() {}, key() { return null; }, length: 0 };

const { default: Blacklist } = await import("../../app/javascript/src/javascripts/blacklists.js");

class El {
  constructor(id, tags, cls = "mod-flank-poolitem") {
    this.attrs = { "data-id": String(id), "data-tags": tags, "data-rating": "g", "data-flags": "", "data-score": "0", "data-uploader-id": "1" };
    this.dataset = { id: String(id) };
    this.classes = new Set([cls]);
    this.classList = { add: (...a) => a.forEach(c => this.classes.add(c)), remove: (...a) => a.forEach(c => this.classes.delete(c)), contains: c => this.classes.has(c) };
    this.reads = 0;
  }
  getAttribute(k) { this.reads += 1; return this.attrs[k] ?? null; }
  querySelector() { return null; }
}
const blocked = (el) => el.classes.has("blacklisted-active");

let engine, centre, a, b;
beforeEach(() => {
  centre = new El(1, "cat", "mod-blacklist-target");
  a = new El(2, "dog");
  b = new El(3, "cat");
  page = [centre, a, b];
  engine = new Blacklist({});
  engine.initialize([{ rule: "cat", locked: false }], { signedIn: true });
  announced = 0;
});

test("adopt marks only the added elements, and leaves every other post as it was", () => {
  const before = page.map(el => el.post);
  const readsBefore = page.map(el => el.reads);
  const c = new El(4, "cat"), d = new El(5, "bird");

  engine.adopt([c, d], []);

  assert.ok(blocked(c), "an added element a block matches is marked");
  assert.ok(!blocked(d));
  assert.deepEqual(page.map(el => el.post), before, "no existing element got a new Post");
  assert.deepEqual(page.map(el => el.reads), readsBefore, "no existing element was re-read or re-matched");
  assert.equal(engine.posts.length, 5);
  assert.equal(announced, 1, "the marks changed, so it says so once");
});

test("adopt lets go of removed elements: out of the posts and out of every block's matches", () => {
  const rule = engine.rules[0];
  assert.ok([...rule.posts].some(p => p.post === b), "fixture: the block matches b");

  engine.adopt([], [b]);

  assert.ok(!engine.posts.some(p => p.post === b));
  assert.ok(![...rule.posts].some(p => p.post === b));
  assert.ok(engine.posts.some(p => p.post === centre) && engine.posts.some(p => p.post === a));
  assert.equal(rule.matchCount, 1, "the centre alone: the pool is never counted");
});

test("a block added afterwards reaches adopted elements too", () => {
  const c = new El(4, "bird");
  engine.adopt([c], []);
  engine.setRules([{ rule: "cat", locked: false }, { rule: "bird", locked: false }]);
  engine.apply();
  assert.ok(blocked(c));
});

// The counts describe the view (GALLERY_WINDOW.md section 2): the gallery
// window holds posts outside its box, and "hidden in this view" counts the
// box alone once the window sets the engine's scope. Filtering is untouched:
// every post on the page is still matched and marked.
test("a scope narrows the counts to the view and leaves the marks alone", () => {
  const c = new El(4, "cat", "modgal-card"), d = new El(5, "cat", "modgal-card");
  engine.adopt([c, d], []);
  assert.equal(engine.blacklistedPostCount, 3, "fixture: centre, c and d hidden");
  engine.scope = new Set(["4"]);
  assert.equal(engine.blacklistedPostCount, 1);
  assert.equal(engine.rules[0].matchCount, 1);
  assert.ok(blocked(d), "a post outside the view is still marked");
  engine.scope = null;
  assert.equal(engine.blacklistedPostCount, 3, "no scope: the whole page, as before");
});
