// The creator gallery's model (creator_gallery_model.js): the band rule, the
// problems Save waits on, the adder's arithmetic, the layout's rows and a
// miniband post's look. No DOM, so it runs under Node's own test runner:
// `npm run test-js`.
//
// The operator's brief it is held to (2026-10-23): "Every non-character tag
// MUST be on every chosen image; up to 5 character tags, images may carry any
// combination of them, but each chosen character MUST be on at least one
// chosen image." The problem sentences are the server's, word for word.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bandRule, problemsOf, adderRow, ruleSentence, miniLook, miniRole, rowsOf, slotCount, words,
  HERO_MIN, MINI_MAX,
} from "../../app/javascript/src/javascripts/creator_gallery_model.js";

const gen = (name) => ({ name, category: "general" });
const chr = (name) => ({ name, category: "character" });
const slide = (id, tags) => ({ id, tags });
const SLIDES = [
  slide(1, "night neon maple"),
  slide(2, "night neon juniper"),
  slide(3, "night neon maple juniper"),
  slide(4, "night rain maple"),
  slide(5, "night neon"),
  slide(6, "night neon sable"),
  slide(7, "sea maple"),
];
const byId = new Map(SLIDES.map((s) => [s.id, s]));
const slideOf = (id) => byId.get(id);
const draftOf = (hero, minis = []) => ({ hero, layout: "1-2", minis });
const goodMinis = [{ tag: "rain", posts: [4] }, { tag: "sea", posts: [7] }, { tag: "neon", posts: [1] }];

test("bandRule: every general on the post, any one of the characters", () => {
  const rule = bandRule([gen("night"), gen("neon"), chr("maple"), chr("juniper")]);
  assert.deepEqual(rule.g, ["night", "neon"]);
  assert.deepEqual(rule.c, ["maple", "juniper"]);
  assert.deepEqual(SLIDES.filter(rule.ok).map((s) => s.id), [1, 2, 3]);
});

test("bandRule: generals alone take every post carrying all of them", () => {
  assert.deepEqual(SLIDES.filter(bandRule([gen("night"), gen("neon")]).ok).map((s) => s.id), [1, 2, 3, 5, 6]);
});

test("bandRule: characters alone are any-of", () => {
  assert.deepEqual(SLIDES.filter(bandRule([chr("juniper"), chr("sable")]).ok).map((s) => s.id), [2, 3, 6]);
});

test("bandRule: a band with no tags has no candidates", () => {
  assert.equal(SLIDES.filter(bandRule([]).ok).length, 0);
});

test("bandRule: a tag matches whole names, never a substring", () => {
  assert.equal(bandRule([gen("neo")]).ok(slide(9, "neon")), false);
});

test("problemsOf: a sound draft has none", () => {
  const draft = draftOf({ tags: [gen("night"), gen("neon"), chr("maple"), chr("juniper")], posts: [1, 2, 3, 1, 3] }, goodMinis);
  assert.deepEqual(problemsOf(draft, slideOf), []);
});

test("problemsOf: no tags, too few posts, and empty minibands, in the server's words", () => {
  const draft = draftOf({ tags: [], posts: [] }, [{ tag: "", posts: [] }, { tag: "rain", posts: [] }, { tag: "sea", posts: [7] }]);
  assert.deepEqual(problemsOf(draft, slideOf), [
    "The hero band has no tags. Add one with + Tag on the band.",
    `The hero band holds 0 of the ${HERO_MIN} posts it needs. Open Posts on the band and pick more.`,
    "Miniband 1 has no tag. Pick one on the miniband.",
    "Miniband 2 has no posts. Open Posts on it and pick at least one.",
  ]);
});

test("problemsOf: a character on none of the chosen posts names itself", () => {
  const draft = draftOf({ tags: [gen("night"), chr("maple"), chr("sable")], posts: [1, 3, 4, 1, 3] }, goodMinis);
  assert.deepEqual(problemsOf(draft, slideOf), ["sable is on none of the band's posts. Pick a post that has it, or take the tag off."]);
});

test("problemsOf: a chosen post that misses the rule says what it lacks", () => {
  const draft = draftOf({ tags: [gen("night"), gen("neon"), chr("maple")], posts: [1, 3, 4, 2, 3] }, goodMinis);
  assert.deepEqual(problemsOf(draft, slideOf), [
    "Post #4 does not carry neon. Take it off the band or change the band's tags.",
    "Post #2 does not carry any of maple. Take it off the band or change the band's tags.",
  ]);
});

test("problemsOf: a post the page never saw is left to the server", () => {
  const draft = draftOf({ tags: [gen("night")], posts: [1, 2, 3, 5, 404] }, goodMinis);
  assert.deepEqual(problemsOf(draft, slideOf), []);
});

// The editor starts from the stored posts, some of which the curator is not
// shown: one of those may be the post carrying a character.
test("problemsOf: a character may be on a post the page never saw, so the server judges it", () => {
  const draft = draftOf({ tags: [gen("night"), chr("maple"), chr("sable")], posts: [1, 3, 4, 1, 404] }, goodMinis);
  assert.deepEqual(problemsOf(draft, slideOf), []);
});

test("problemsOf: too many posts, too many characters, an overfull miniband", () => {
  const posts = Array.from({ length: 25 }, (_, i) => (i % 3) + 1);
  const chars = ["a", "b", "c", "d", "e", "maple"].map(chr);
  const minis = [{ tag: "rain", posts: [4, 4, 4, 4, 4, 4, 4] }, goodMinis[1], goodMinis[2]];
  const out = problemsOf(draftOf({ tags: chars, posts }, minis), slideOf);
  assert.ok(out.includes("The hero band holds 25 posts; 24 is the most. Take some off."));
  assert.ok(out.includes("The hero band has more than 5 character tags. Take one off."));
  assert.ok(out.includes(`Miniband 1 holds 7 posts; ${MINI_MAX} is the most.`));
});

test("problemsOf: minibands past the layout's slots are not asked about", () => {
  const draft = draftOf({ tags: [gen("night")], posts: [1, 2, 3, 4, 5] }, [...goodMinis, { tag: "", posts: [] }]);
  assert.deepEqual(problemsOf(draft, slideOf), []);
});

test("problems are ASCII: the apostrophes are not curly", () => {
  const draft = draftOf({ tags: [], posts: [] }, [{ tag: "", posts: [] }]);
  problemsOf(draft, slideOf).forEach((p) => assert.match(p, /^[\x20-\x7e]*$/));
});

test("adderRow: with no tags, a tag fits its palette count", () => {
  const row = adderRow([], gen("night"), { base: [], count: 6, chosen: [] });
  assert.deepEqual(row, { kind: "on every post", note: "6 fit", fits: 6, drops: 0, disabled: false });
});

test("adderRow: a general narrows the base and counts the chosen posts that would leave", () => {
  const tags = [gen("night")];
  const base = SLIDES.filter(bandRule(tags).ok);
  const row = adderRow(tags, gen("neon"), { base, count: 5, chosen: [slideOf(1), slideOf(4)] });
  assert.equal(row.fits, 5);
  assert.equal(row.note, "5 fit, 1 of yours leave");
});

test("adderRow: with no generals a new character also reaches posts outside the base", () => {
  const tags = [chr("juniper")];
  const base = SLIDES.filter(bandRule(tags).ok);
  // maple is on 1, 3, 4, 7; 3 is in the base already; juniper-or-maple is 1, 2, 3, 4, 7.
  const row = adderRow(tags, chr("maple"), { base, count: 4, chosen: [] });
  assert.equal(row.fits, 5);
  assert.equal(row.kind, "character, any of");
});

test("adderRow: the sixth character is refused, and so is a tag no post fits", () => {
  const chars = ["a", "b", "c", "d", "e"].map(chr);
  assert.deepEqual(adderRow(chars, chr("f"), { base: [], count: 3, chosen: [] }).note, "five is the limit");
  const row = adderRow([gen("sea")], gen("neon"), { base: [slideOf(7)], count: 5, chosen: [] });
  assert.equal(row.note, "no post fits");
  assert.equal(row.disabled, true);
  assert.equal(adderRow([], { name: "wren", category: "artist" }, { base: [], count: 7, chosen: [] }).kind, "your artist tag");
});

// The base is the newest posts the curator may see, cut at the cap: past
// it, a count over the base is a floor, and none of the newest fitting says
// nothing of the older ones.
test("adderRow: over a capped base the fits are at least, and none fitting refuses nothing", () => {
  const tags = [gen("night")];
  const base = SLIDES.filter(bandRule(tags).ok);
  const row = adderRow(tags, gen("neon"), { base, count: 5, chosen: [slideOf(1), slideOf(4)], capped: true });
  assert.equal(row.note, "at least 5 fit, 1 of yours leave");
  const none = adderRow([gen("sea")], gen("neon"), { base: [slideOf(7)], count: 5, chosen: [], capped: true });
  assert.deepEqual([none.note, none.disabled], ["none of the newest fit", false]);
  const leaving = adderRow([gen("sea")], gen("neon"), { base: [slideOf(7)], count: 5, chosen: [slideOf(7)], capped: true });
  assert.equal(leaving.note, "none of the newest fit, 1 of yours leave");
  // With no tags the palette count is exact, capped or not.
  assert.equal(adderRow([], gen("night"), { base: [], count: 6, chosen: [], capped: true }).note, "6 fit");
});

test("ruleSentence says the rule in words", () => {
  assert.equal(ruleSentence([], 0, 7), "Add tags first. The band's candidates are every post that fits them.");
  assert.equal(ruleSentence([gen("night"), gen("neon"), chr("maple"), chr("juniper")], 3, 7),
    "Every post here carries night and neon, and at least one of maple or juniper. 3 of your 7 posts fit.");
  assert.equal(ruleSentence([chr("maple")], 4, 7), "Every post here carries your pick of tags and at least one of maple. 4 of your 7 posts fit.");
  assert.equal(ruleSentence([gen("night")], 4, 700, true), "Every post here carries night. At least 4 of your 700 posts fit.");
});

test("words joins a list the way a sentence does", () => {
  assert.equal(words([], "and"), "");
  assert.equal(words(["a"], "and"), "a");
  assert.equal(words(["a", "b", "c"], "or"), "a, b or c");
});

test("rowsOf splits the layout into rows of miniband indexes", () => {
  assert.deepEqual(rowsOf("2-3"), [[0, 1], [2, 3, 4]]);
  assert.deepEqual(rowsOf("1-3"), [[0], [1, 2, 3]]);
  assert.deepEqual(rowsOf("4"), [[0, 1, 2, 3]]);
  assert.deepEqual(rowsOf("nonsense"), rowsOf("2-3"));
  assert.deepEqual(["2-3", "3-2", "1-2", "2-2", "1-3", "4"].map(slotCount), [5, 5, 3, 4, 4, 4]);
});

test("miniRole: the current post, the one leaving until it settles, the rest", () => {
  assert.deepEqual([0, 1, 2, 3].map((j) => miniRole(j, 4, 5, false)), ["prev", "cur", "other", "other"]);
  assert.deepEqual([0, 1, 2, 3].map((j) => miniRole(j, 4, 5, true)), ["other", "cur", "other", "other"]);
  assert.deepEqual([0, 1, 2].map((j) => miniRole(j, 3, -1, false)), ["other", "prev", "cur"]);
  assert.equal(miniRole(0, 1, 7, false), "cur");
});

test("miniLook: a slide leaves the way it travels and enters from the other side", () => {
  assert.equal(miniLook("slide", "left", "prev", 4).tf, "translate(-100%, 0%)");
  assert.equal(miniLook("slide", "left", "other", 4).tf, "translate(100%, 0%)");
  assert.equal(miniLook("slide", "up", "prev", 4).tf, "translate(0%, -100%)");
  assert.equal(miniLook("slide", "left", "other", 4).tr, "none");
});

test("miniLook: flip turns about the axis across its direction", () => {
  assert.equal(miniLook("flip", "right", "prev", 4).tf, "rotateY(180deg)");
  assert.equal(miniLook("flip", "down", "prev", 4).tf, "rotateX(-180deg)");
});

test("miniLook: fade, drift and depth hide the posts waiting their turn", () => {
  ["fade", "drift", "depth"].forEach((fx) => {
    assert.equal(miniLook(fx, "left", "other", 4).op, 0);
    assert.equal(miniLook(fx, "left", "cur", 4).op, 1);
    assert.equal(miniLook(fx, "left", "other", 4).tr, "none");
  });
  assert.match(miniLook("drift", "left", "cur", 4).tr, /transform 5.2s linear/);
  assert.equal(miniLook("depth", "left", "prev", 4).z, 3);
});

test("miniLook: an unknown direction travels left", () => {
  assert.deepEqual(miniLook("slide", "sideways", "prev", 4), miniLook("slide", "left", "prev", 4));
});
