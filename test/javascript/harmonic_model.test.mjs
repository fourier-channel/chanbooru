// The Tuner's link model (harmonic_model.js) against the cases Save is held
// to (test/unit/creator_gallery_harmonic_test.rb reads the same fixture): one
// paste, one answer, in the builder and on the server.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { URL } from "node:url";
import { harmonicModel, domain, strip, prefixes, fingerprint } from "../../app/javascript/src/javascripts/harmonic_model.js";

const read = (path) => JSON.parse(readFileSync(new URL(path, import.meta.url), "utf8"));
const registry = read("../../config/creator_harmonics.json");
const { cases } = read("../fixtures/files/harmonic_links.json");
const model = harmonicModel(registry);
const pick = (result, keys) => Object.fromEntries(keys.map((key) => [key, result[key]]));

test("every shared case is answered as the server answers it", () => {
  const wrong = cases.flatMap(([raw, expected]) => {
    const got = pick(model.link(raw), Object.keys(expected));
    try {
      assert.deepEqual(got, expected);
      return [];
    } catch {
      return [`${JSON.stringify(raw)}: wanted ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`];
    }
  });
  assert.deepEqual(wrong, []);
});

test("an accepted link comes back the same when pasted again", () => {
  const urls = cases.map(([, expected]) => expected.url).filter(Boolean);
  assert.ok(urls.length >= 10);
  assert.deepEqual(urls.map((url) => model.link(url).url), urls);
});

test("every site's own example link is accepted as that site", () => {
  assert.deepEqual(model.sites.filter((site) => model.link(site.shape).site !== site.key).map((site) => site.key), []);
});

test("a refusal's sentence fills every blank it names, and refuses one it lacks", () => {
  for (const [key, words] of Object.entries(registry.problems)) {
    const vars = Object.fromEntries([...words.matchAll(/%\{(\w+)\}/g)].map(([, name]) => [name, `<${name}>`]));
    assert.doesNotMatch(model.sentence(key, vars), /%\{/, key);
  }
  assert.throws(() => model.sentence("link_removed", {}), /needs url/);
});

test("a small card keeps the registrable domain", () => {
  assert.equal(domain("www.civitai.com"), "civitai.com");
  assert.equal(domain("x.com"), "x.com");
});

// The list as Save answers it: the cases test/unit/creator_gallery_tuner_test.rb
// holds CreatorGalleryLayout#plan_harmonics to, answered alike before Save.
const CORNER = registry.presets[0][2];
const harmonic = (over = {}) => ({
  url: "https://civitai.com/user/maple", title: "Maple LoRA", subtitle: "SDXL style, v3", cta: "visit", places: CORNER, background_gradient: "1", ...over,
});
const picture = (over = {}) => harmonic({ background_gradient: null, background_post_id: 5, focus_x: 50, focus_y: 40, zoom: 120, shade: 45, ...over });
const listed = (entries, { stored = new Map(), removed = new Set(), stale = () => false, cap = 5 } = {}) =>
  model.problems(entries, { stored, removed, stale, cap }).map(({ text }) => text);

test("a list Save accepts has no problems", () => {
  assert.deepEqual(listed([harmonic(), picture({ url: "https://x.com/maple", title: "On X" })]), []);
  assert.deepEqual(listed([]), []);
  assert.deepEqual(listed([harmonic({ cta: "", places: { ...CORNER, mark: undefined } })]), []);
  assert.deepEqual(registry.presets.filter(([, , places]) => listed([harmonic({ places })]).length).map(([key]) => key), []);
});

test("each harmonic's problems come in Save's order, numbered, a site to ask for with its host", () => {
  const found = model.problems([harmonic(), harmonic({ url: "http://x.com/maple" }), harmonic({ url: "https://example.org/me", title: "" })],
    { stored: new Map(), removed: new Set(), stale: () => false, cap: 5 });
  assert.deepEqual(found, [
    { n: 2, text: "Harmonic 2's link uses http://. Use the https:// address of the same page.", ask: null },
    { n: 3, text: "Harmonic 3's link is to example.org, which is not on the Tuner's list yet. Ask for it to be added, or link a site that is on the list.", ask: "example.org" },
    { n: 3, text: "Harmonic 3's title is empty. Give it a title of up to 48 characters.", ask: null },
  ]);
});

test("the words, places and background settings name what they allow", () => {
  assert.deepEqual(listed([harmonic({ title: "t".repeat(49), subtitle: "s".repeat(81), cta: "buy", places: { ...CORNER, host: undefined } })]), [
    "Harmonic 1's title is 49 characters long. Shorten it to 48 or fewer.",
    "Harmonic 1's subtitle is 81 characters long. Shorten it to 80 or fewer.",
    "Harmonic 1's button word \"buy\" is not one of: visit, follow, download, view_model, support, join, commission. Pick one of those, or none.",
    "Harmonic 1's host place \"\" is not one of: tl, tc, tr, ml, mc, mr, bl, bc, br. Pick one of those.",
  ]);
  assert.deepEqual(listed([harmonic({ title: "\u{1F341}".repeat(48) })]), []);
  assert.deepEqual(listed([picture({ background_gradient: "2" })]), ["Harmonic 1 has both a picture and a gradient for its background. Pick one."]);
  assert.deepEqual(listed([harmonic({ background_gradient: "7" })]), ["Harmonic 1's gradient \"7\" is not one of: 1 (Sea), 2 (Ember), 3 (Violet). Pick one of those."]);
  assert.deepEqual(listed([picture({ zoom: 250, shade: "" })]), [
    "Harmonic 1's zoom is 250; it runs from 100 to 200. Set it within that.",
    "Harmonic 1's shade is empty; it runs from 0 to 85. Set it within that.",
  ]);
  assert.deepEqual(listed([picture({ shade: 20 })]), ["Harmonic 1's shade is 20%; over a picture it is at least 35%, so its words stay readable. Set it to 35 or more."]);
  assert.deepEqual(listed([picture({ shade: 0 })], { stale: (entry) => entry.background_post_id === 5 }), [
    "Harmonic 1's background is no longer one of your showable posts. Pick another, or a gradient.",
    "Harmonic 1's shade is 0%; over a picture it is at least 35%, so its words stay readable. Set it to 35 or more.",
  ]);
});

test("a host that would be cut short at the smallest size", () => {
  assert.deepEqual(listed([harmonic({ places: { ...CORNER, mark: "bc", host: "br" } })]), [
    "Harmonic 1's link host (civitai.com) shares its row with a centre and a side element, and at the smallest size it would be cut short. Move the host or one of the others to another row.",
  ]);
  assert.deepEqual(listed([harmonic({ url: "https://x.com/maple", places: { ...CORNER, mark: "bc", host: "br" } })]), []);
});

test("the list's own rules: one page a link, one support link, the cap, the rows kept", () => {
  assert.deepEqual(model.problems([harmonic(), harmonic({ url: "https://ko-fi.com/maple" }), harmonic({ url: "https://civitai.com/user/maple/" }), harmonic({ url: "https://patreon.com/maple" })],
    { stored: new Map(), removed: new Set(), stale: () => false, cap: 5 }).map(({ n, text }) => [n, text]), [
    [3, "Harmonics 1 and 3 link to the same page. Remove one of them."],
    [4, "Harmonic 4 links to Patreon, a support site, and harmonic 2 already links to Ko-fi. A gallery carries one support link: change or remove one of the two."],
  ]);

  const urls = ["https://civitai.com/user/maple", "https://x.com/maple", "https://bsky.app/profile/maple.bsky.social", "https://pixiv.net/users/1", "https://deviantart.com/maple", "https://instagram.com/maple"];
  const six = urls.map((url) => harmonic({ url }));
  assert.deepEqual(listed(six), ["This gallery has 6 harmonics and holds 5. Remove one."]);
  assert.deepEqual(listed([...six.slice(0, 5), { ...six[5], shown: false }]), []);
  assert.deepEqual(listed(six, { cap: 6 }), []);
  assert.deepEqual(listed(six, { cap: 3 }), ["This gallery has 6 harmonics and holds 3. Remove 3."]);

  assert.deepEqual(listed(Array.from({ length: 31 }, (_, i) => harmonic({ url: `https://x.com/maple${i}`, shown: false }))),
    ["This gallery lists 31 harmonics, counting hidden ones, and keeps 30. Remove one."]);
  const hidden = new Map([[9, { url: "https://x.com/dusk", host: "x.com", site: "x", staff_hidden: true }]]);
  assert.deepEqual(listed(Array.from({ length: 30 }, (_, i) => harmonic({ url: `https://x.com/maple${i}`, shown: false })), { stored: hidden }),
    ["This gallery lists 31 harmonics, counting hidden ones, and keeps 30. Remove one."]);
});

test("stored rows: unknown ids, staff-hidden rows, removed links, a site that left the list", () => {
  const stored = new Map([
    [1, { url: "https://x.com/maple", host: "x.com", site: "x", staff_hidden: true }],
    [2, { url: "https://myspace.com/maple", host: "myspace.com", site: "myspace", staff_hidden: false }],
    [3, { url: "https://civitai.com/user/maple", host: "civitai.com", site: "civitai", staff_hidden: false }],
  ]);
  const removed = new Set([fingerprint("https://civitai.com/user/maple")]);
  assert.deepEqual(listed([harmonic({ id: 44 })], { stored }), ["Harmonic 1 is not one of this gallery's harmonics. Reload the page and build it again."]);
  assert.deepEqual(listed([harmonic({ id: 3, url: "https://x.com/maple" }), harmonic({ id: "3" })], { stored }),
    ["Harmonics 1 and 2 are the same harmonic, listed twice. Reload the page and build the list again."]);
  // A staff-hidden row is not the owner's: whatever the list says of it is not checked.
  assert.deepEqual(listed([harmonic({ id: "1", url: "http://bad", title: "" })], { stored }), []);
  // Unchanged, a link to a site off the list stands, and does not count.
  assert.deepEqual(listed([harmonic({ id: 2, url: "https://myspace.com/maple" }), ...Array.from({ length: 5 }, (_, i) => harmonic({ url: `https://x.com/m${i}` }))], { stored }), []);
  assert.deepEqual(listed([harmonic({ id: 2, url: "https://myspace.com/other" })], { stored }),
    ["Harmonic 1's link is to myspace.com, which is not on the Tuner's list yet. Ask for it to be added, or link a site that is on the list."]);
  assert.deepEqual(listed([harmonic({ id: 3 })], { stored, removed }),
    ["That link (civitai.com/user/maple) was removed by site staff and cannot be added to any page. Remove it from your list, or write to staff if you think this was a mistake."]);
});

// The removals reach the page as fingerprints (CreatorHarmonicRemoval.fingerprint),
// and a link is checked by every cut a removal could sit at, as on the server.
test("a removal covers its link, what lies under it, and the link in capitals or with a query", () => {
  assert.equal(fingerprint("a"), "af63dc4c8601ec8c");
  assert.equal(fingerprint("https://civitai.com/user/bad"), "6bcd98040aa60c8e");
  assert.deepEqual(prefixes("https://x.com/A/b?q=1"), ["https://x.com/a/b?q=1", "https://x.com/a/b", "https://x.com", "https://x.com/a"]);

  const removed = new Set([fingerprint("https://civitai.com/user/bad"), fingerprint("https://patreon.com")]);
  const sentences = (url) => listed([harmonic({ url })], { removed });
  const refused = (url) => [`That link (${url}) was removed by site staff and cannot be added to any page. Remove it from your list, or write to staff if you think this was a mistake.`];
  assert.deepEqual(sentences("https://civitai.com/user/bad/models"), refused("civitai.com/user/bad/models"));
  assert.deepEqual(sentences("https://civitai.com/user/BAD"), refused("civitai.com/user/BAD"));
  assert.deepEqual(sentences("https://patreon.com/dusk"), refused("patreon.com/dusk"));
  assert.deepEqual(sentences("https://civitai.com/user/badger"), []);
  // A covered link holds no place under the cap.
  const urls = ["https://civitai.com/user/bad", "https://x.com/maple", "https://bsky.app/profile/maple.bsky.social", "https://pixiv.net/users/1", "https://deviantart.com/maple"];
  assert.deepEqual(model.problems([...urls, "https://instagram.com/maple"].map((url) => harmonic({ url })), { stored: new Map(), removed, stale: () => false, cap: 5 })
    .map(({ text }) => text), [refused("civitai.com/user/bad")[0]]);
});

// What counts as typed is what Rails reads (String#strip, blank?, Integer()),
// not what a browser's trim() would make of it.
test("spaces, blanks and numbers are read as the server reads them", () => {
  assert.equal(strip("\u0000 Maple\t\u00a0"), "Maple\t\u00a0");
  assert.deepEqual(listed([harmonic({ title: "\u00a0" })]), []);
  assert.deepEqual(listed([harmonic({ title: `\u0000${"t".repeat(48)}` })]), []);
  assert.deepEqual(listed([harmonic({ title: `\ufeff${"t".repeat(48)}` })]), ["Harmonic 1's title is 49 characters long. Shorten it to 48 or fewer."]);
  assert.deepEqual(listed([harmonic({ cta: "\u0085" })]), []);
  assert.deepEqual(listed([picture({ zoom: "1_50" })]), []);
  assert.deepEqual(listed([picture({ zoom: "\u00a0150" })]), ["Harmonic 1's zoom is \u00a0150; it runs from 100 to 200. Set it within that."]);
  assert.deepEqual(listed([harmonic({ id: " 3\n" })], { stored: new Map([[3, { url: "https://civitai.com/user/maple", host: "civitai.com", site: "civitai", staff_hidden: false }]]) }), []);
});
