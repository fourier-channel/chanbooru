// THE CREATOR GALLERY'S MODEL: the rules the editor previews live, the same
// rules CreatorGalleryLayout checks on Save. No DOM, no imports, no `window`,
// so test/javascript/creator_gallery_model.test.mjs runs it under Node;
// creator_gallery_component.js is the page's glue.
//
// The operator's brief (2026-10-23): the top of the gallery is the creator's
// own HERO BAND, and its tags define the candidates. Every non-character tag
// MUST be on every chosen post; up to five character tags, any-of, and each
// chosen character MUST be on at least one chosen post. Under the hero sit
// MINIBANDS in a layout ("two on top, three below"), ONE tag each.
//
// A tag here is { name, category } (Tag category names: general, character,
// copyright, artist, meta); a slide is LandingShowcase#slide_for's Hash, whose
// `tags` is the post's tag string. The problems are the server's sentences,
// word for word: Save waits on the server, the editor only says it sooner.

export const HERO_MIN = 5;
export const HERO_MAX = 24;
export const MINI_MAX = 6;
export const CHAR_MAX = 5;
export const CELLS = [3, 5, 7, 9];
export const HOLD_MIN = 2;
export const HOLD_MAX = 12;

export const HERO_EFFECTS = [{ v: "glide", label: "Glide" }, { v: "depth", label: "Depth" }, { v: "float", label: "Float" }];
export const MINI_EFFECTS = [{ v: "slide", label: "Slide" }, { v: "fade", label: "Fade" }, { v: "drift", label: "Drift" }, { v: "flip", label: "Flip" }, { v: "depth", label: "Depth" }];
// rot turns the one arrow glyph to point the way the posts travel.
export const DIRS = [{ v: "left", rot: 180, label: "Travel left" }, { v: "right", rot: 0, label: "Travel right" }, { v: "up", rot: -90, label: "Travel up" }, { v: "down", rot: 90, label: "Travel down" }];
export const LAYOUTS = [
  { v: "2-3", label: "Two over three", rows: [2, 3] },
  { v: "3-2", label: "Three over two", rows: [3, 2] },
  { v: "1-2", label: "One wide, two below", rows: [1, 2] },
  { v: "2-2", label: "Two by two", rows: [2, 2] },
  { v: "1-3", label: "One wide, three below", rows: [1, 3] },
  { v: "4", label: "Four across", rows: [4] },
];
// A row's height and its slots' narrowest width, by how many share the row.
export const ROW_H = { 1: 340, 2: 300, 3: 250, 4: 230 };
export const MIN_W = { 1: 560, 2: 360, 3: 250, 4: 220 };

export const BLANK_MINI = Object.freeze({ tag: "", effect: "slide", dir: "left", hold: 4, posts: [] });

export const layoutOf = (v) => LAYOUTS.find((l) => l.v === v) || LAYOUTS[0];
export const slotCount = (v) => layoutOf(v).rows.reduce((a, b) => a + b, 0);

// The layout's rows as the miniband indexes each holds: "2-3" => [[0, 1], [2, 3, 4]].
export function rowsOf(v) {
  const rows = layoutOf(v).rows;
  return rows.map((cnt, r) => {
    const from = rows.slice(0, r).reduce((a, b) => a + b, 0);
    return Array.from({ length: cnt }, (_, j) => from + j);
  });
}

// "a", "a and b", "a, b and c".
export const words = (xs, last) => (xs.length < 2 ? xs.join("") : `${xs.slice(0, -1).join(", ")} ${last} ${xs[xs.length - 1]}`);

export const tagsOf = (slide) => (slide && slide.tags ? slide.tags.split(" ") : []);

// THE BAND'S TAG RULE. g: every one on every post; c: characters, any-of.
// No tags, no fit: a band with no tags has no candidates.
export function bandRule(tags) {
  const g = tags.filter((t) => t.category !== "character").map((t) => t.name);
  const c = tags.filter((t) => t.category === "character").map((t) => t.name);
  const ok = (slide) => {
    const on = new Set(tagsOf(slide));
    return tags.length > 0 && g.every((t) => on.has(t)) && (c.length === 0 || c.some((t) => on.has(t)));
  };
  return { g, c, ok };
}

// What a chosen post lacks, said the way the server says it: the generals it
// does not carry, or -- carrying them -- that it has none of the characters.
function lacking(rule, slide) {
  const on = new Set(tagsOf(slide));
  const missing = rule.g.filter((t) => !on.has(t));
  return missing.length ? words(missing, "and") : `any of ${words(rule.c, "or")}`;
}

// @param draft {hero: {tags, posts}, layout, minis: [{tag, posts}]} -- posts
//   are ids in order
// @param slideOf id => slide, or undefined for a post the page has not seen
//   (then only the server can judge it)
export function problemsOf(draft, slideOf) {
  const { hero } = draft;
  const rule = bandRule(hero.tags);
  const chosen = hero.posts.map((id) => [id, slideOf(id)]).filter(([, s]) => s);
  // A character may be on a post the page has not seen; then only the
  // server can say it is on none.
  const unseen = chosen.length < hero.posts.length;
  const n = hero.posts.length;
  const heroProblems = [
    !hero.tags.length && "The hero band has no tags. Add one with + Tag on the band.",
    n < HERO_MIN && `The hero band holds ${n} of the ${HERO_MIN} posts it needs. Open Posts on the band and pick more.`,
    n > HERO_MAX && `The hero band holds ${n} posts; ${HERO_MAX} is the most. Take some off.`,
    rule.c.length > CHAR_MAX && `The hero band has more than ${CHAR_MAX} character tags. Take one off.`,
    ...rule.c.filter((c) => !unseen && !chosen.some(([, s]) => tagsOf(s).includes(c)))
      .map((c) => `${c} is on none of the band's posts. Pick a post that has it, or take the tag off.`),
    ...(hero.tags.length ? chosen.filter(([, s]) => !rule.ok(s)) : [])
      .map(([id, s]) => `Post #${id} does not carry ${lacking(rule, s)}. Take it off the band or change the band's tags.`),
  ];
  const miniProblems = draft.minis.slice(0, slotCount(draft.layout)).map((m, i) => (
    (!m.tag && `Miniband ${i + 1} has no tag. Pick one on the miniband.`) ||
    (!m.posts.length && `Miniband ${i + 1} has no posts. Open Posts on it and pick at least one.`) ||
    (m.posts.length > MINI_MAX && `Miniband ${i + 1} holds ${m.posts.length} posts; ${MINI_MAX} is the most.`)
  ));
  return [...heroProblems, ...miniProblems].filter(Boolean);
}

// What adding `tag` to the band would do, for the "+ Tag" adder's row.
// base: the candidates the page fetched for the band's GENERALS (or, with no
// generals, for its characters), so every rule over them is exact; count: the
// tag's palette count over all eligible posts. With no generals a new
// character also reaches posts outside base -- those carrying it and none of
// the other characters, which is its count less the base posts carrying it.
// chosen: the band's chosen slides, to say how many would leave. capped: base
// is the newest posts only (CreatorGalleryLayout#candidates' cap), so a count
// over it is a floor and none fitting refuses nothing -- but with no tags,
// where the palette count alone decides.
export function adderRow(tags, tag, { base, count, chosen, capped = false }) {
  const rule = bandRule(tags);
  const next = bandRule(tags.concat([tag]));
  const isChar = tag.category === "character";
  const carrying = base.filter((s) => tagsOf(s).includes(tag.name)).length;
  const outside = !tags.length || (isChar && rule.g.length === 0) ? count - carrying : 0;
  const fits = base.filter(next.ok).length + Math.max(0, outside);
  const drops = chosen.filter((s) => !next.ok(s)).length;
  const full = isChar && rule.c.length >= CHAR_MAX;
  const kind = isChar ? "character, any of" : tag.category === "artist" ? "your artist tag" : "on every post";
  const floor = capped && tags.length > 0;
  const none = floor ? "none of the newest fit" : "no post fits";
  const note = full ? "five is the limit" : `${fits === 0 ? none : `${floor ? "at least " : ""}${fits} fit`}${drops ? `, ${drops} of yours leave` : ""}`;
  return { kind, note, fits, drops, disabled: full || (fits === 0 && !floor) };
}

// One sentence of what the band's tags ask of a post; `capped` when fitting
// was counted over the newest posts only, and is a floor.
export function ruleSentence(tags, fitting, total, capped = false) {
  if (!tags.length) { return "Add tags first. The band's candidates are every post that fits them."; }
  const { g, c } = bandRule(tags);
  const chars = c.length ? `${g.length ? ", and " : " and "}at least one of ${words(c, "or")}` : "";
  return `Every post here carries ${g.length ? words(g, "and") : "your pick of tags"}${chars}. ${capped ? "At least " : ""}${fitting} of your ${total} posts fit.`;
}

// One miniband post's place in its cycle: the current one, the one leaving,
// or one of the rest, waiting where the next arrival enters from. Returns the
// transform, opacity, transition and stacking order to give it.
export function miniLook(effect, dir, role, hold) {
  const v = { left: [-1, 0], right: [1, 0], up: [0, -1], down: [0, 1] }[dir] || [-1, 0];
  const E = "cubic-bezier(.22,.8,.2,1)";
  const pick = (cur, prev, other) => (role === "cur" ? cur : role === "prev" ? prev : other);
  if (effect === "fade") {
    return pick({ tf: "none", op: 1, tr: "opacity 1000ms ease", z: 2 }, { tf: "none", op: 0, tr: "opacity 1000ms ease", z: 1 }, { tf: "none", op: 0, tr: "none", z: 0 });
  }
  if (effect === "drift") {
    const dr = `scale(1.16) translate(${v[0] * 3}%, ${v[1] * 3}%)`;
    return pick({ tf: dr, op: 1, tr: `opacity 1200ms ease, transform ${hold + 1.2}s linear`, z: 2 }, { tf: dr, op: 0, tr: "opacity 1200ms ease", z: 1 }, { tf: "scale(1) translate(0, 0)", op: 0, tr: "none", z: 0 });
  }
  if (effect === "flip") {
    const ax = v[0] !== 0 ? "Y" : "X";
    const ang = ax === "Y" ? v[0] * 180 : -v[1] * 180;
    return pick({ tf: `rotate${ax}(0deg)`, op: 1, tr: `transform 900ms ${E}`, z: 2 }, { tf: `rotate${ax}(${ang}deg)`, op: 1, tr: `transform 900ms ${E}`, z: 1 }, { tf: `rotate${ax}(${-ang}deg)`, op: 1, tr: "none", z: 0 });
  }
  if (effect === "depth") {
    const tr = `transform 1000ms ${E}, opacity 800ms ease`;
    return pick({ tf: "scale(1)", op: 1, tr, z: 2 }, { tf: "scale(1.22)", op: 0, tr, z: 3 }, { tf: "scale(.8)", op: 0, tr: "none", z: 0 });
  }
  const ex = `translate(${v[0] * 100}%, ${v[1] * 100}%)`;
  const en = `translate(${-v[0] * 100}%, ${-v[1] * 100}%)`;
  return pick({ tf: "translate(0, 0)", op: 1, tr: `transform 900ms ${E}`, z: 2 }, { tf: ex, op: 1, tr: `transform 900ms ${E}`, z: 1 }, { tf: en, op: 1, tr: "none", z: 0 });
}

// The role of post j in a miniband of n at cycle position pos; the one before
// the current is "prev" only until the step has settled.
export function miniRole(j, n, pos, settled) {
  const cur = ((pos % n) + n) % n;
  if (j === cur) { return "cur"; }
  return n > 1 && j === (cur - 1 + n) % n && !settled ? "prev" : "other";
}
