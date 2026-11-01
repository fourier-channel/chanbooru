// The post deck's model: the arithmetic behind post_deck.js, with no DOM, so
// it runs under Node's own test runner (`npm run test-js`).
//
// withGhosts and the entrance stagger are ports of Technetium's
// src/client/useTagDiff.ts (withGhosts) and src/ui/pop.ts (usePopEnter's
// ENTER_LEAD_MS / ENTER_STEP_MS / ENTER_MAX_STAGGER_MS), kept to the same
// behaviour so a post card arrives and leaves the way a tag pill does.
import { words } from "./creator_gallery_model.js";

// How much of each card the row below covers. The rest -- its top 58% -- is
// the lip every card keeps in view (operator 2026-11-01: "at least partially
// seen").
export const REVEAL = 0.42;

// Kept in step with --mod-tag-pop-out-dur in formant/_tokens.scss.
export const POP_OUT_MS = 160;

const ENTER_LEAD_MS = 90;
const ENTER_STEP_MS = 14;
const ENTER_MAX_STAGGER_MS = 260;

// The distance from one row's top to the next one's, in whole pixels so a
// card's edge never lands on half of one.
export const pitch = (cardH, reveal = REVEAL) => Math.round(cardH * (1 - Math.min(1, Math.max(0, reveal))));

// The nth newcomer of one redraw waits this long, so a batch arrives in turn
// and a big one does not cascade for seconds.
export const enterDelay = (n) => Math.min(ENTER_LEAD_MS + (n * ENTER_STEP_MS), ENTER_LEAD_MS + ENTER_MAX_STAGGER_MS);

// The list to draw: the current ids in order, each `entering` or `steady`, with
// every gone id put back as `leaving` at the index it held in `before`, so its
// neighbours do not slide over and back as it pops out.
export function withGhosts(ids, before, entering, gone) {
  const phaseOf = (id) => (entering.has(id) ? "entering" : "steady");
  const slotOf = (id) => { const was = before.indexOf(id); return was < 0 ? ids.length : Math.min(was, ids.length); };
  const at = (i) => gone.filter((id) => slotOf(id) === i).map((id) => ({ id, phase: "leaving" }));
  return [...ids.flatMap((id, i) => [...at(i), { id, phase: phaseOf(id) }]), ...at(ids.length)];
}

// A staging strip's posts with `id` let go at `index`: counted among the
// others, so a post moved along the strip is never there twice.
export function placed(list, id, index) {
  const others = list.filter((p) => p !== id);
  return [...others.slice(0, index), id, ...others.slice(index)];
}

// post id -> the 1-based numbers of every OTHER miniband holding it. `minis` is
// the layout's minibands only; the caller trims draft.minis to the slot count.
export function usedMap(minis, i) {
  const pairs = minis.flatMap((m, j) => (j === i ? [] : (m.posts || []).map((id) => [id, j + 1])));
  return pairs.reduce((map, [id, n]) => map.set(id, [...(map.get(id) || []), n]), new Map());
}

export const usedWords = (bands) => `miniband${bands.length > 1 ? "s" : ""} ${words(bands.map(String), "and")}`;
