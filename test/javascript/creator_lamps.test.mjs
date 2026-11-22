// The creator's lamp (creator_lamps.js) lights a pill that carries
// data-creator-lamp and data-tag: the marker, not an interface's class, so
// core names no interface's classes (Modulation stage 2, step 1b) and a new
// interface's artist pill is lit by carrying the marker. Run by
// `npm run test-js`.
import { test } from "node:test";
import assert from "node:assert/strict";

import CreatorLamps from "../../app/javascript/src/javascripts/creator_lamps.js";

class FakePill {
  constructor(tag, { marked, cls = "mod-pill--cat-artist" }) {
    this.dataset = marked ? { tag, creatorLamp: "" } : { tag };
    this.classes = new Set([cls]);
    this.classList = { toggle: (c, on) => (on ? this.classes.add(c) : this.classes.delete(c)) };
    this.title = "";
  }

  // The two forms a lamp query may take: [data-creator-lamp][data-tag], or
  // .<class>[data-tag].
  matches(selector) {
    const m = selector.match(/^(\[data-creator-lamp\]|\.[\w-]+)\[data-tag\]$/);
    if (!m) { throw new Error(`FakePill cannot read the selector ${selector}; fix: teach FakePill#matches its form`); }
    const head = m[1] === "[data-creator-lamp]" ? this.dataset.creatorLamp !== undefined : this.classes.has(m[1].slice(1));
    return head && this.dataset.tag !== undefined;
  }
}

const rootOf = (pills) => ({ querySelectorAll: (selector) => pills.filter((p) => p.matches(selector)) });

test("a pill carrying data-creator-lamp is lit while its creator is active", () => {
  const pill = new FakePill("lit_artist", { marked: true, cls: "some-interface-pill" });
  new CreatorLamps(rootOf([pill]), { live: ["lit_artist"] }).paintAll();
  assert.equal(pill.classes.has("is-live"), true);
  assert.match(pill.title, /^active/);
});

test("an artist pill without the marker is left alone, whatever its class", () => {
  const pill = new FakePill("lit_artist", { marked: false });
  new CreatorLamps(rootOf([pill]), { live: ["lit_artist"] }).paintAll();
  assert.equal(pill.classes.has("is-live"), false);
  assert.equal(pill.title, "");
});

test("the names asked about by default are the marked pills' tags", () => {
  const pills = [new FakePill("a", { marked: true }), new FakePill("b", { marked: false }), new FakePill("a", { marked: true })];
  assert.deepEqual(new CreatorLamps(rootOf(pills)).names(), ["a"]);
});
