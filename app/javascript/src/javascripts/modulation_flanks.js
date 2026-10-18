// The post view's flank pick: which of a side's candidates the thumbnail
// shows, and where the arrow goes.
//
// The blocklist is client-side on purpose -- a block added or lifted
// re-filters the page in place, no reload (operator, 2026-10-13, 2026-10-17).
// The flank thumbnails carried no tags, so the engine never saw them and a
// blocked post sat beside the centre in plain view. So each side now carries a
// few candidates with their tags (ModulationPostComponent#payload, presets[]
// and candidates), the page writes them onto hidden pool elements the engine
// marks (Blacklist.POST_SELECTOR), and this reads the marks: the first
// candidate not marked is the pick (GALLERY_WINDOW.md section 2).
//
// It does NO matching. The engine's Rule.match is the one matcher on the page;
// a second here would be a second opinion about what a block means.
//
// The Modulation post page is one inline script that cannot `import`, so this
// is also hung on window.FourierFlanks for it, as fourier_wheel_step.js is.

// candidates: [{ id, url }], nearest first. more: whether the search goes on
// past them. blockedIds: a Set of the marked ids AS STRINGS (dataset.id), while
// candidate ids are numbers from the payload -- hence String(). hopsLeft: how
// many automatic looks further this side has left.
//
// Returns one of:
//   { kind: "pick", index, skipped }  -- show candidates[index]; skipped is how
//                                        many blocked ones came before it
//   { kind: "end" }                   -- no candidates and nothing beyond
//   { kind: "blocked-end", blocked }  -- every candidate blocked, nothing beyond
//   { kind: "blocked-more", blocked, canHop } -- none allowed yet, more beyond:
//                                        look further (canHop) or stop and ask
export function flankState(candidates, more, blockedIds, hopsLeft) {
  const index = candidates.findIndex((candidate) => !blockedIds.has(String(candidate.id)));
  if (index >= 0) { return { kind: "pick", index, skipped: index }; }
  if (more) { return { kind: "blocked-more", blocked: candidates.length, canHop: hopsLeft > 0 }; }
  if (candidates.length === 0) { return { kind: "end" }; }
  return { kind: "blocked-end", blocked: candidates.length };
}

// What a side's state says, for the tile's title and the status line: every
// state that stops a press says what happened and what fixes it. st is a
// flankState answer, or one of the page's own states (failed: { why },
// unavailable, no-access, fault: { why }, deferred). side: "prev" or "next".
export function flankWords(st, side) {
  const way = side === "prev" ? "back" : "forward";
  const blocked = st.blocked + " blocked " + (st.blocked === 1 ? "post" : "posts");
  switch (st.kind) {
  case "blocked-end": return (st.blocked === 1 ? "The only post left " + way + " here is on your blocklist." : "Every post left " + way + " here is on your blocklist (" + st.blocked + ").") +
    " Fix: lift a block, or change mode with the up/down arrows.";
  case "blocked-more": return st.looking || st.canHop
    ? "Looking further " + way + " past " + blocked + "."
    : "Stopped looking " + way + " after " + blocked + ". Press again to look further, or change mode with the up/down arrows.";
  case "failed": return "Could not look further " + way + " (" + st.why + "). Fix: reload the page.";
  case "unavailable": return "This mode's search could not run (the server logged why). Fix: change mode with the up/down arrows, or reload the page.";
  case "no-access": return "The next posts " + way + " here are not open to this account. Fix: change mode with the up/down arrows.";
  case "fault": return st.why || "The blocklist has not applied yet, so the neighbours are not shown.";
  // Random's side on a payload fetched ahead (?prefetch=1), which names no
  // neighbours until the full read that follows the commit lands.
  case "deferred": return "Still loading the next post " + way + " in this mode; the press will go through when it arrives.";
  default: return "";
  }
}

// What the page's look-further extensions belong to: the post and every
// run they extend (each mode's search, candidate ids and more flags). A
// re-read of the same post -- a vote, a favourite, an edit's optimistic copy
// -- is a new object with the same key, so what looking further found is
// kept; a re-read whose runs changed (random's frontier rolled again) gets a
// new key, so stale extensions are never glued onto new lists.
export function runsKey(payload) {
  if (!payload) { return ""; }
  return JSON.stringify([payload.id, (payload.presets || []).map((p) => [
    p.search,
    (p.prev_candidates || []).map((ref) => ref.id), Boolean(p.prev_more),
    (p.next_candidates || []).map((ref) => ref.id), Boolean(p.next_more),
  ])]);
}

// One look further along a side. held: the run's candidates so far.
// selfId: the post the page stands on. answer: the anchor's preset for the
// same search. Returns { added, more, dead }: the candidates not already held
// (nor the post itself), the answer's more, and whether the look was a dead
// end -- nothing new while the answer still says more, which asked again
// from the same anchor would give the same nothing forever.
export function extendRun(held, selfId, answer, side) {
  const known = new Set(held.map((ref) => String(ref.id)).concat([String(selfId)]));
  const added = (answer[side + "_candidates"] || []).filter((ref) => !known.has(String(ref.id)));
  const more = Boolean(answer[side + "_more"]);
  return { added, more, dead: added.length === 0 && more };
}

if (typeof window !== "undefined") { window.FourierFlanks = { flankState, flankWords, runsKey, extendRun }; }
