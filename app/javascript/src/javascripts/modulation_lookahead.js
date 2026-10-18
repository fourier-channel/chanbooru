// The post view's lookahead: the box the centre reserves before its picture
// exists, which posts to warm ahead of the viewer and what of each to warm,
// the bounded keep of warmed images, and the one-slot queue a press lands in
// while a step is under way.
//
// The bug this exists for (operator, 2026-10-18): stepping through posts at
// normal speed reached a post whose image had not loaded. The stage had no
// height of its own, so it collapsed to its frame's border, the flank
// thumbnails vanished with it, and the tag panel rode up by the image's height
// and back down when it landed. Two causes, one exposing the other: nothing
// reserved the picture's space, and nothing fetched the post two ahead until
// the viewer was already on the one before it.
//
// The Modulation post page is one inline script that cannot `import`, so this
// is also hung on window.FourierLookahead for it, as modulation_flanks.js is.

// box: [width, height] of the rendition the centre will show (the payload's
// media.box, or a flank candidate's). The style the stage reads, or "" when
// there is no box -- the stage then falls back to the placeholder's size.
// Numbers only: this string is written into a style attribute.
export function centerBoxStyle(box) {
  if (!Array.isArray(box) || box.length !== 2) { return ""; }
  const [w, h] = box;
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) { return ""; }
  return "--mod-bw:" + w + ";--mod-bh:" + h;
}

// list: one side's candidates ({ id }), nearest first. markedIds: the ids the
// blocklist engine has marked, AS STRINGS (dataset.id). pickIndex: the index of
// the candidate already chosen (-1 for none). The next `depth` candidates past
// it that the blocklist allows, nearest first -- never a blocked one.
export function lookahead(list, markedIds, pickIndex, depth) {
  return list.slice(pickIndex + 1).filter((ref) => !markedIds.has(String(ref.id))).slice(0, Math.max(0, depth));
}

// What warming a post's picture fetches: an image's (or preview's) src, a
// video's POSTER -- never the video file, which an Image would download whole
// -- or null when there is nothing this viewer may see.
export function warmSource(media) {
  if (!media) { return null; }
  if (media.kind === "video") { return media.poster || null; }
  return media.src || null;
}

// A keep of at most `max` values by key, least recently used out first.
// take(key, make) answers the kept value, making it once; keys() oldest
// first. The warmed Image objects live here, so a redraw (every blocklist
// apply) does not make the same Image again, and a kept one is already
// decoded: Chromium drew a kept picture at once and an unkept one in 6 ms
// (scratch test, 2026-10-18). Whether the BYTES are reused is the HTTP
// cache's business either way: the edge answers with a cacheable 200, and a
// no-store answer was fetched again in Chromium even from a kept Image.
export function boundedKeep(max) {
  const kept = new Map();
  return {
    take(key, make) {
      if (kept.has(key)) {
        const value = kept.get(key);
        kept.delete(key);
        kept.set(key, value);
        return value;
      }
      const value = make();
      kept.set(key, value);
      while (kept.size > max) { kept.delete(kept.keys().next().value); }
      return value;
    },
    keys() { return [...kept.keys()]; },
  };
}

// A press while a step is under way is queued, not dropped: one slot, the
// latest press wins, drained when the step ends. Held with the mode it was
// made in (key), because a press taken after the viewer switched modes would
// step where they never pressed. side: "prev", "next", or null for no press.
// The slot is { side, key } or null.
export function queuePress(slot, side, key) {
  return side ? { side, key } : slot;
}

// The side a queued press steps to now that the active mode is `key`: its
// own side in the mode it was pressed in, else null (dropped).
export function queuedFor(slot, key) {
  return slot && slot.key === key ? slot.side : null;
}

if (typeof window !== "undefined") { window.FourierLookahead = { centerBoxStyle, lookahead, warmSource, boundedKeep, queuePress, queuedFor }; }
