// The error card (error_card.js): an image that failed to load is replaced
// by a card naming the status the server gave. A 503 from the media gate is
// its TRANSIENT refusal -- fourier-auth fails closed when it cannot ask the
// booru in time, and says Retry-After: 2 -- so that card tries the image
// again, once. Run by `npm run test-js`.
//
// Incident 2026-10-19 04:58-05:01 UTC: 78 images were refused with a 503
// while the booru was slow to answer; each card stayed up until the reader
// middle-clicked, though the next ask would have succeeded.
//
// A reload that loads says so on the image (HEALED), so a page that marked
// the picture failed when it first failed -- the hero band's conveyor does,
// and shapes and promotes its cells by that -- can take the mark back.
//
// error_card.js listens on document at module scope and reaches for jQuery's
// ready, so this loads the REAL module against the few globals it touches,
// as blacklists_adopt.test.mjs does. The module itself is not copied or edited.
import { test, beforeEach, afterEach, mock } from "node:test";
import assert from "node:assert/strict";
import { setImmediate as settle } from "node:timers/promises";

const SRC = "https://media.example.org/thumb/abc.webp";
const HEALED = "errorcard:healed";

let errorListener = null;
let status = 503;
let probes = 0;

class FakeImage {
  constructor(src) {
    this.attrs = { src };
    this.currentSrc = src;
    this.clientWidth = 180;
    this.dataset = {};
    this.classes = new Set(["post-preview-image"]);
    this.classList = { add: (c) => this.classes.add(c), remove: (c) => this.classes.delete(c) };
    this.srcs = [];
    this.listeners = [];
    this.events = [];
  }
  addEventListener(type, fn, opts = {}) { this.listeners.push({ type, fn, once: Boolean(opts.once) }); }
  dispatchEvent(event) {
    this.events.push(event);
    this.fire(event.type, event);
    return true;
  }
  // The browser finished loading whatever src now holds.
  fire(type, event = { type, target: this }) {
    const hit = this.listeners.filter((l) => l.type === type);
    this.listeners = this.listeners.filter((l) => l.type !== type || !l.once);
    hit.forEach((l) => l.fn(event));
  }
  getAttribute(k) { return this.attrs[k] ?? null; }
  setAttribute(k, v) { this.attrs[k] = v; if (k === "src") { this.srcs.push(v); this.currentSrc = v; } }
  removeAttribute(k) { delete this.attrs[k]; }
  matches() { return true; }
  closest() { return null; }
}

globalThis.HTMLImageElement = FakeImage;
globalThis.location = { href: "https://booru.41chan.net/posts", origin: "https://booru.41chan.net" };
globalThis.document = {
  addEventListener(type, fn) { if (type === "error") { errorListener = fn; } },
  querySelectorAll() { return []; },
};
globalThis.$ = () => ({ ready() {} });
globalThis.fetch = async () => { probes += 1; return { status }; };

await import("../../app/javascript/src/javascripts/error_card.js");

// The image failed: the browser fires `error` at it, and the card resolves
// (settle: the status probe's promise chain runs out before the next turn).
async function fail(img) {
  errorListener({ target: img });
  await settle();
}

// How many times the image was pointed back at its own source.
const reloads = (img) => img.srcs.filter((s) => s === SRC).length;

// How many times the image said it came back.
const healed = (img) => img.events.filter((e) => e.type === HEALED).length;

beforeEach(() => {
  probes = 0;
  mock.timers.enable({ apis: ["setTimeout"] });
});

afterEach(() => {
  mock.timers.reset();
});

test("a 503 card reloads its image once, after about three seconds", async () => {
  status = 503;
  const img = new FakeImage(SRC);
  await fail(img);
  assert.equal(img.attrs.src.startsWith("/errors/503.svg"), true, "the card is shown first");
  assert.equal(reloads(img), 0, "not at once");

  mock.timers.tick(2900);
  assert.equal(reloads(img), 0, "not before about three seconds");

  mock.timers.tick(10_000);
  assert.equal(reloads(img), 1, "once");
  assert.equal(img.attrs.src, SRC);
});

test("a 503 card never loops: the reload failing with a 503 again leaves the card up", async () => {
  status = 503;
  const img = new FakeImage(SRC);
  await fail(img);
  mock.timers.tick(10_000);
  assert.equal(reloads(img), 1);

  await fail(img);
  assert.equal(probes, 2, "the second failure is probed and carded like the first");
  assert.equal(img.attrs.src.startsWith("/errors/503.svg"), true, "the card is back");

  mock.timers.tick(60_000);
  assert.equal(reloads(img), 1, "and nothing tries again");
});

test("the reload is jittered, so a gallery's cards do not all come back in one instant", async () => {
  status = 503;
  const rolls = [0, 0.999];
  const random = mock.method(Math, "random", () => rolls.shift() ?? 0.5);
  const early = new FakeImage(SRC);
  const late = new FakeImage(SRC);
  await fail(early);
  await fail(late);
  random.mock.restore();

  mock.timers.tick(3000);
  assert.equal(reloads(early), 1);
  assert.equal(reloads(late), 0, "a later roll waits longer");
  mock.timers.tick(10_000);
  assert.equal(reloads(late), 1);
});

for (const refused of [403, 404]) {
  test(`a ${refused} card is final: no reload`, async () => {
    status = refused;
    const img = new FakeImage(SRC);
    await fail(img);
    assert.equal(img.attrs.src.startsWith(`/errors/${refused}.svg`), true);

    mock.timers.tick(60_000);
    assert.equal(reloads(img), 0);
  });
}

test("a 503 reload that loads says the image came back, once, bubbling to the page", async () => {
  status = 503;
  const img = new FakeImage(SRC);
  await fail(img);
  img.fire("load"); // the card itself loading is not the image coming back
  assert.equal(healed(img), 0);

  mock.timers.tick(10_000);
  assert.equal(reloads(img), 1);
  img.fire("load");
  assert.equal(healed(img), 1);
  assert.equal(img.events[0].bubbles, true);
  assert.equal(img.dataset.errorCarded, undefined, "and is no longer carded");

  img.fire("load");
  assert.equal(healed(img), 1, "said once");
});

test("a 503 reload that fails again says nothing when its new card loads", async () => {
  status = 503;
  const img = new FakeImage(SRC);
  await fail(img);
  mock.timers.tick(10_000);
  await fail(img);
  img.fire("load");
  assert.equal(healed(img), 0);
});

test("a 403 card never says the image came back", async () => {
  status = 403;
  const img = new FakeImage(SRC);
  await fail(img);
  mock.timers.tick(60_000);
  img.fire("load");
  assert.equal(healed(img), 0);
});
