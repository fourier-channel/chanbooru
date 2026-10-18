// THE GALLERY WINDOW, on the page: the Modulation grid's box of 20 over its
// search (GALLERY_WINDOW.md section 2). gallery_window_model.js decides which
// posts the box shows; this reads the blocklist's marks into it, moves the
// box for the pager, the keys and the wheel, fetches chunks of the same
// search as the run nears its end, and keeps the address on the post at the
// top left. Auto-loaded by the src/javascripts require.context glob; boots
// where the grid is.
//
// THE BLOCKLIST STAYS CLIENT-SIDE AND LIVE (operator, 2026-10-13/17): the
// engine (blacklists.js, #blacklist-box) marks every card, this never
// matches anything itself, and a block added or lifted re-fills the box in
// place from the cards in hand -- no reload, no request, no change of
// address. A card the engine has not judged yet counts as blocked.
//
// Chunks come from the existing /posts route (variant=window: the cards
// alone, drawn by the gallery's own GridComponent), built from the grid's
// own search and cursors, never from the address bar. One request at a time
// per direction; a failure stops that direction with a note that names it
// and its fix, and a Retry. Nothing is retried by itself.
import { GalleryWindow } from "./gallery_window_model";
import { WHEEL_IDLE, wheelStep } from "./fourier_wheel_step";

// How long the blocklist engine may take to start before the page says so.
const ENGINE_WAIT_MS = 5000;
// How long the wheel's address update waits for the wheel to rest.
const WHEEL_ADDRESS_MS = 250;

function showEmpty(gallery, which) {
  gallery.querySelectorAll(".modgal-empty--blocked, .modgal-empty--capped").forEach((el) => {
    el.hidden = !el.classList.contains(`modgal-empty--${which}`);
  });
}

// One persistent note per cause, under the pager, with an optional button.
function alertNote(gallery, cause, text, button) {
  let note = gallery.querySelector(`.modgal-window-alert[data-cause="${cause}"]`);
  if (!note) {
    note = document.createElement("div");
    note.className = "modgal-window-alert";
    note.setAttribute("role", "alert");
    note.dataset.cause = cause;
    gallery.querySelector(".modgal-window-status").after(note);
  }
  note.textContent = text;
  if (button) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = button.label;
    // The note leaves with its button; focus that was on it goes to the
    // status line, which says what happens next, not to the top of the page.
    b.addEventListener("click", () => {
      const focused = note.contains(document.activeElement);
      note.remove();
      if (focused) { gallery.querySelector(".modgal-window-status")?.focus(); }
      button.act();
    });
    note.appendChild(b);
  }
  return note;
}

function clearAlerts(gallery, keep = []) {
  gallery.querySelectorAll(".modgal-window-alert").forEach((note) => { if (!keep.includes(note.dataset.cause)) { note.remove(); } });
}

// The engine's mark on a card: true blocked, false shown, null not judged.
function markOf(card) {
  if (!card.classList.contains("blacklist-initialized")) { return null; }
  return card.classList.contains("blacklisted-active");
}

// Without the engine nothing may show (a blocked post is never visible:
// operator, 2026-10-01), and the cards stay hidden by the stylesheet. Say so
// rather than leave an empty box.
function watchEngine(gallery, start) {
  const box = document.querySelector("#blacklist-box");
  if (!box) {
    alertNote(gallery, "engine", "This page has no blocklist, so its posts stay hidden. Fix: reload the page; if this stays, the page is missing its header.");
    return null;
  }
  let started = false;
  const timer = setTimeout(() => { if (!started) { alertNote(gallery, "engine", "The blocklist did not start, so posts stay hidden. Fix: reload the page."); } }, ENGINE_WAIT_MS);
  // Late is not never: an engine that starts after the note takes it down.
  const go = () => {
    if (started) { return; }
    started = true;
    clearTimeout(timer);
    gallery.querySelector('.modgal-window-alert[data-cause="engine"]')?.remove();
    start(box);
  };
  document.addEventListener("danbooru:blacklist-applied", go);
  if (box.blacklist && gallery.querySelector(".modgal-card.blacklist-initialized")) { go(); }
  return box;
}

// A grid with no window (one page: below the browsing tier, order:none, an
// old id-cursor link): the blocklist hides cards and nothing refills; say so
// when it has hidden them all.
function bootStatic(grid, gallery) {
  watchEngine(gallery, () => {
    const update = () => {
      const cards = [...grid.querySelectorAll(".modgal-card[data-id]")];
      const allHidden = cards.length > 0 && cards.every((card) => markOf(card) === true);
      showEmpty(gallery, allHidden ? (grid.dataset.onePage ? "capped" : "blocked") : "none");
    };
    document.addEventListener("danbooru:blacklist-applied", update);
    update();
  });
}

function bootWindow(grid, gallery) {
  const config = JSON.parse(grid.dataset.window);
  const version = grid.dataset.windowV;
  const kind = grid.dataset.windowKind;
  const tags = grid.dataset.windowTags || "";
  const status = gallery.querySelector(".modgal-window-status");
  const pager = gallery.querySelector(".modgal-pager");
  const links = { next: pager?.querySelector('[data-window-go="next"]'), prev: pager?.querySelector('[data-window-go="prev"]') };
  const serverStatus = status ? status.textContent : "";

  const byId = new Map();
  const entryOf = (card) => ({ id: card.dataset.id, key: card.dataset.key || null });
  const initial = [...grid.querySelectorAll(".modgal-card[data-id]")];
  initial.forEach((card) => byId.set(card.dataset.id, card));
  const model = new GalleryWindow(config, {
    entries: initial.map(entryOf),
    anchorId: initial[0]?.dataset.id ?? null,
    headDone: grid.dataset.moreBehind !== "true",
    tailDone: grid.dataset.moreAhead !== "true",
    drawn: kind === "draw",
  });

  let box = null;
  // The engine has applied once: until then no card is judged, and nothing
  // may move or be fetched (a fetched card could not be judged either).
  let started = false;
  let controller = new AbortController();
  const inflight = { ahead: false, behind: false };
  // The address change a pending move makes once it lands: "push" for the
  // pager and keys, "replace" for the wheel.
  let pendingAddress = null;
  let shownKey = "";
  let wheelState = WHEEL_IDLE;
  let wheelOwned = false;
  let wheelTimer = null;

  // The window's own adopt() is announced like a block change; only a block
  // change is the viewer's action, with a fresh budget.
  let adopting = false;
  // pump, reached from a Retry button made before it is defined: the one
  // cycle in here (a fetch fails, its Retry asks for the fetch again).
  const loop = {};

  const say = (text) => { if (status) { status.textContent = text; } };
  // A move waiting on its chunk. Stopped (a failure, the budget) it is not
  // busy: any press starts a new action, and Retry or "keep looking"
  // finishes the waiting one.
  const busy = () => Boolean(model.pending) && (inflight.ahead || inflight.behind);

  function setBusy() {
    grid.setAttribute("aria-busy", String(busy() || inflight.ahead || inflight.behind));
  }

  // While a move waits for its chunk the box may be short: hold its height,
  // so the pager below does not jump up and back (no-forced-reflow).
  function holdHeight() {
    if (!grid.style.minHeight) { grid.style.minHeight = `${grid.getBoundingClientRect().height}px`; }
  }

  function releaseHeight() {
    if (!busy()) { grid.style.minHeight = ""; }
  }

  function placeHref(cursor) {
    const url = new URL(location.href);
    ["page", "before", "anchor"].forEach((p) => url.searchParams.delete(p));
    if (cursor && kind !== "draw") { url.searchParams.set("anchor", cursor); }
    return url.toString();
  }

  // The address names the post at the top left from the page's own entry
  // on: an old page=N link (or a bare-id anchor) is rewritten in place to
  // the anchor the server opened at, so back to this entry returns here
  // rather than to the head of the search.
  function settleAddress() {
    if (kind === "draw") { return; }
    const here = new URL(location.href).searchParams;
    const cursor = grid.dataset.windowAnchor || null;
    if (here.has("page") || here.has("before") || here.get("anchor") !== cursor) {
      history.replaceState(history.state, "", placeHref(cursor));
    }
  }

  function setAddress(how) {
    if (kind === "draw") { return; }
    const href = placeHref(model.anchorCursor());
    if (href === location.href) { return; }
    if (how === "push") { history.pushState({ modgalWindow: true }, "", href); } else { history.replaceState({ modgalWindow: true }, "", href); }
  }

  function flushWheelAddress() {
    if (wheelTimer) { clearTimeout(wheelTimer); wheelTimer = null; setAddress("replace"); }
  }

  function updatePager() {
    const { shown } = model.layout();
    const next = model.peek("next");
    const prev = model.peek("prev");
    const nextOk = shown.length === config.slots && next.answer !== "end";
    const prevOk = prev.answer !== "start";
    // The hrefs serve a middle or modified click; a plain click is the
    // window's. Each names where its move lands when that is in hand (prev
    // at the head: the head). Next not in hand: the first post past the box,
    // where a page opened at it starts at the first one the blocklist lets
    // render. Prev not in hand keeps the href it has.
    const nextCursor = next.answer === "moved" ? next.cursor : model.run[shown.at(-1) + 1]?.key;
    [[links.next, nextOk, nextCursor], [links.prev, prevOk, prev.cursor]].forEach(([link, ok, cursor]) => {
      if (!link) { return; }
      link.setAttribute("aria-disabled", String(!ok));
      // A disabled link has no href, except the one being pressed: taking it
      // would take the focus with it (aria-disabled refuses the press).
      if (!ok) {
        if (document.activeElement !== link) { link.removeAttribute("href"); }
      } else if (cursor !== undefined) {
        link.href = placeHref(cursor);
      } else if (!link.hasAttribute("href")) {
        link.href = location.href;
      }
    });
  }

  // The cards the next move reveals are fetched now, while still off, so a
  // move shows pictures rather than empty tiles filling in: a box of them
  // each way, rendered ones only (a blocked card is never fetched). The rest
  // of the run stays lazy.
  function preload(shown) {
    if (!shown.length) { return; }
    [model.run.slice(shown.at(-1) + 1), model.run.slice(0, shown[0]).reverse()].forEach((side) => {
      side.filter((e) => e.blocked === false).slice(0, config.slots).forEach((e) => {
        const img = byId.get(e.id)?.querySelector("img.modgal-thumb[loading=lazy]");
        if (img) { img.loading = "eager"; }
      });
    });
  }

  // Place the cards: the box's on, every other card off.
  function render() {
    model.setMarks(new Map([...byId].map(([id, card]) => [id, markOf(card)])));
    const { shown } = model.layout();
    const on = new Set(shown.map((i) => model.run[i].id));
    byId.forEach((card, id) => card.classList.toggle("is-off", !on.has(id)));
    if (box?.blacklist) { box.blacklist.scope = new Set(model.scope()); }
    const key = [...on].join(" ");
    if (key !== shownKey) {
      shownKey = key;
      grid.dispatchEvent(new CustomEvent("modgal:window-change", { bubbles: true }));
    }
    // "Every post here is hidden" only once the run holds the end of the
    // search: a stop for the budget or a failure has not looked that far,
    // and its own note says so.
    showEmpty(gallery, shown.length === 0 && model.tailDone && !busy() ? "blocked" : "none");
    preload(shown);
    updatePager();
    setBusy();
  }

  // Where the box is, for the status line: a move is announced (the cards
  // are links with no alt text, so the change says nothing by itself).
  function placeText() {
    const { shown } = model.layout();
    const where = shown.length ? `Showing posts #${model.run[shown[0]].id} to #${model.run[shown.at(-1)].id}.` : "";
    return [serverStatus, where].filter(Boolean).join(" ");
  }

  // The hover panel's maps grow with each chunk: a tag on a fetched card is
  // shown only if the server named it for that card.
  function mergeMaps(chunk) {
    ["tagCategories", "tagCounts"].forEach((name) => {
      try {
        const merged = { ...JSON.parse(grid.dataset[name] || "{}"), ...JSON.parse(chunk.dataset[name] || "{}") };
        grid.dataset[name] = JSON.stringify(merged);
      } catch {
        // A map that does not parse is left as it was: the panel then shows
        // only the tags it already knew, never more.
      }
    });
  }

  function edgeCursor(dir) {
    const keyed = model.run.filter((e) => e.key);
    return dir === "ahead" ? keyed.at(-1)?.key : keyed[0]?.key;
  }

  const FAILURES = {
    cap: "The booru refused to page further for this account.",
    rate: "Too many requests: the booru asked the window to slow down. Fix: wait a minute, then Retry.",
    network: "Could not reach the booru. Fix: check your connection, then Retry.",
    server: "The booru failed to send more posts.",
    http: "The booru refused the request for more posts.",
    dead: "The booru said there were more posts here but sent nothing new. Fix: Retry, or reload the page.",
    place: "The booru could not find this place in the search.",
  };

  function failed(dir, cause, message) {
    say("");
    const text = message || FAILURES[cause] || FAILURES.http;
    alertNote(gallery, `fail-${dir}`, /Fix:/.test(text) ? text : `${text} Fix: Retry, or reload the page.`, {
      label: "Retry",
      act: () => { model.retry(); if (model.pending) { holdHeight(); } loop.pump(); },
    });
    releaseHeight();
    render();
  }

  // One chunk of the search. `from`: the cursor to fetch from, for a reset
  // (the back button to a place the run does not hold); else the run's edge.
  async function fetchChunk(dir, need, from = undefined) {
    const epoch = model.epoch;
    const reset = from !== undefined;
    inflight[dir] = true;
    setBusy();
    const params = new URLSearchParams({ tags, preset: "modulation", variant: "window", limit: String(model.chunkSize(need)) });
    const cursor = reset ? from : (kind === "draw" ? null : edgeCursor(dir));
    if (cursor) { params.set(dir === "ahead" ? "anchor" : "before", cursor); }

    const got = await fetch(`/posts?${params}`, { credentials: "same-origin", signal: controller.signal, headers: { Accept: "text/html" } })
      .then(async (response) => ({ response, text: await response.text() }))
      .catch((error) => ({ error }));
    inflight[dir] = false;
    if (got.error) {
      if (got.error.name !== "AbortError") { model.fail(dir, 0); failed(dir, "network"); }
      return;
    }
    if (epoch !== model.epoch) { return; }

    const { response } = got;
    const doc = new DOMParser().parseFromString(got.text, "text/html");
    if (!response.ok) {
      const cause = model.fail(dir, response.status);
      failed(dir, cause, doc.querySelector(".modgal-window-error")?.textContent.trim());
      return;
    }
    const chunk = doc.querySelector(".modgal-grid");
    if (!chunk) {
      model.fail(dir, 500);
      failed(dir, "server", "The booru answered without any posts. Fix: reload the page.");
      return;
    }
    const cards = [...chunk.querySelectorAll(".modgal-card[data-id]")];
    const more = (dir === "ahead" ? chunk.dataset.moreAhead : chunk.dataset.moreBehind) === "true";
    const entries = cards.map(entryOf);

    // A reset replaces the run with this chunk, opening at its first card.
    // A forward chunk does not say whether the search goes on behind it
    // (GridComponent#grid_data): a reset to no anchor is the head, and one
    // to an anchor finds out with its first prev.
    const replacing = reset && chunk.dataset.windowV === version;
    const removed = replacing ? [...byId.keys()] : [];
    if (replacing) {
      model.reset({ entries, anchorId: entries[0]?.id ?? null, headDone: from === null, tailDone: !more });
    }
    const answer = replacing ? "ok" : model.receive(dir, epoch, { entries, more, version: chunk.dataset.windowV }, version);
    if (answer === "stale") { return; }
    if (answer === "version") {
      alertNote(gallery, "version", "This page is older than the booru it is talking to. Fix: reload the page.");
      say("");
      releaseHeight();
      return;
    }
    if (answer === "dead") {
      failed(dir, "dead");
      return;
    }
    // Not a failure: a small set drawn out. The move waiting on it ends
    // here, and the next press draws again (act clears the stop).
    if (answer === "drawn") {
      model.pending = null;
      pendingAddress = null;
      say("This random draw brought nothing new, so it has likely shown every post. Press next to draw again, or reload the page for a fresh order.");
      releaseHeight();
      render();
      return;
    }

    // Take in the new cards, hidden, in run order; let go of the far ones.
    const removedEls = removed.map((id) => byId.get(id)).filter(Boolean);
    removed.forEach((id) => byId.delete(id));
    const fresh = cards.filter((card) => !byId.has(card.dataset.id)).map((card) => {
      const el = document.importNode(card, true);
      el.classList.add("is-off");
      byId.set(el.dataset.id, el);
      return el;
    });
    if (dir === "ahead" || reset) { grid.append(...fresh); } else { grid.prepend(...fresh); }
    removedEls.forEach((el) => el.remove());
    const trimmed = model.trim().map((id) => { const el = byId.get(id); byId.delete(id); el?.remove(); return el; }).filter(Boolean);
    mergeMaps(chunk);
    // The engine judges the new cards and says so; the box is placed then.
    adopting = true;
    try {
      box.blacklist.adopt(fresh, removedEls.concat(trimmed));
    } finally {
      adopting = false;
    }
    // A reset is a landing (the back button's): its "Loading" gives way to
    // where the box is now, as a move's does.
    if (replacing) { say(placeText()); }
  }

  // Ask for what the window wants, if nothing is already on its way there.
  function pump() {
    const want = model.wants();
    // The budget note lasts as long as its cause: a lifted block that fills
    // the box takes it down.
    if (!want?.budget) { gallery.querySelector('.modgal-window-alert[data-cause="budget"]')?.remove(); }
    if (!want) { setBusy(); return; }
    if (want.budget) {
      say("");
      alertNote(gallery, "budget", `Your blocklist hid most of the last ${model.budget.raw} posts. Fix: press Keep looking, or lift a block.`, {
        label: "Keep looking",
        act: () => { model.keepLooking(); pump(); },
      });
      releaseHeight();
      return;
    }
    if (!inflight[want.dir]) { fetchChunk(want.dir, want.need); }
  }
  loop.pump = pump;

  function landed(answer, how) {
    if (answer === "moved") {
      render();
      say(placeText());
      if (how === "replace") {
        clearTimeout(wheelTimer);
        wheelTimer = setTimeout(flushWheelAddress, WHEEL_ADDRESS_MS);
      } else {
        setAddress(how);
        // The pager and the keys set a new top left: put it in view. The
        // pager sits under the grid, so on a phone or in a short panel the
        // box would otherwise land above the screen. The wheel steps only
        // with the grid's edge in view and is left alone.
        if (grid.getBoundingClientRect().top < 0) { grid.scrollIntoView({ block: "start", behavior: "instant" }); }
      }
      releaseHeight();
    } else if (answer === "fetch") {
      pendingAddress = how;
      say("Loading more posts.");
      render();
    } else if (answer === "end") {
      say("That is the end of the results.");
      releaseHeight();
    } else if (answer === "start") {
      say("That is the start of the results.");
      releaseHeight();
    }
    pump();
  }

  function act(kind2, cols = 0) {
    if (!started) {
      // The engine's own note (missing, or late past ENGINE_WAIT_MS) stays
      // as it is; before then, say why the press did nothing.
      if (!gallery.querySelector('.modgal-window-alert[data-cause="engine"]')) {
        alertNote(gallery, "engine", "The blocklist has not started yet, so the posts cannot move. Fix: wait a moment; if this stays, reload the page.");
      }
      return;
    }
    if (busy()) { return; }
    // A press is the viewer asking: it clears a stop the way Retry does.
    clearAlerts(gallery, ["engine", "version"]);
    if (model.stopped.ahead !== "version") { model.retry(); }
    holdHeight();
    const answer = model.move(kind2, cols);
    landed(answer, kind2.startsWith("row") ? "replace" : "push");
  }

  function columns() {
    return getComputedStyle(grid).gridTemplateColumns.split(" ").filter(Boolean).length || 1;
  }

  function onApplied() {
    if (!adopting) { model.beginAction(); }
    render();
    if (model.pending) {
      const answer = model.resume();
      if (answer === "moved") { const how = pendingAddress; pendingAddress = null; landed("moved", how || "push"); return; }
      if (answer !== "fetch") { landed(answer, pendingAddress || "push"); pendingAddress = null; return; }
    }
    releaseHeight();
    pump();
  }

  function start(engineBox) {
    started = true;
    box = engineBox;
    document.addEventListener("danbooru:blacklist-applied", onApplied);
    model.beginAction();
    render();
    pump();
  }

  settleAddress();
  box = watchEngine(gallery, start);

  pager?.addEventListener("click", (event) => {
    const link = event.target.closest("[data-window-go]");
    if (!link) { return; }
    // A modified click (a new tab, a new window) is the browser's: the href
    // names the same place.
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) {
      if (link.getAttribute("aria-disabled") === "true") { event.preventDefault(); }
      return;
    }
    event.preventDefault();
    if (link.getAttribute("aria-disabled") === "true") { return; }
    flushWheelAddress();
    act(link.dataset.windowGo);
  });

  // The wheel steps a row per notch (Technetium's rule, fourier_wheel_step
  // .js) only while the grid's edge in that direction is in view and a step
  // is possible there; otherwise the page scrolls as it always does. A
  // touch screen has the pager.
  grid.addEventListener("wheel", (event) => {
    // Ctrl+wheel and a trackpad pinch (a ctrlKey wheel) are the browser's
    // zoom; Cmd and Alt are the system's. None of them steps the box.
    if (!started || event.ctrlKey || event.metaKey || event.altKey) { return; }
    const r = wheelStep(wheelState, { dx: event.deltaX, dy: event.deltaY, mode: event.deltaMode, t: event.timeStamp });
    wheelState = r.state;
    if (!r.step) { if (wheelOwned) { event.preventDefault(); } return; }
    const rect = grid.getBoundingClientRect();
    const forward = r.step > 0;
    const edge = forward ? rect.bottom <= window.innerHeight : rect.top >= 0;
    if (!edge || busy()) { wheelOwned = false; return; }
    const before = model.anchorId;
    model.beginAction();
    const answer = model.move(forward ? "rowNext" : "rowPrev", columns());
    wheelOwned = answer === "moved" || answer === "fetch";
    if (wheelOwned) { event.preventDefault(); }
    if (answer === "moved" && model.anchorId === before) { return; }
    if (wheelOwned) { landed(answer, "replace"); }
  }, { passive: false });

  window.addEventListener("pagehide", flushWheelAddress);

  // Back and forward: the address names the post at the top left.
  window.addEventListener("popstate", () => {
    if (!started) { return; }
    const anchor = new URL(location.href).searchParams.get("anchor");
    const held = anchor ? model.run.find((e) => e.key === anchor) : (model.headDone ? model.run[0] : null);
    clearAlerts(gallery, ["engine", "version"]);
    if (held) {
      model.pending = null;
      model.anchorId = held.id;
      model.beginAction();
      render();
      say(placeText());
      pump();
      return;
    }
    if (kind === "draw") { return; }
    controller.abort();
    controller = new AbortController();
    inflight.ahead = false;
    inflight.behind = false;
    model.pending = null;
    model.beginAction();
    holdHeight();
    say("Loading more posts.");
    fetchChunk("ahead", config.slots, anchor || null);
  });
}

function boot() {
  const grid = document.querySelector(".modgal-grid");
  if (!grid || grid.dataset.windowBooted) { return; }
  grid.dataset.windowBooted = "1";
  const gallery = grid.closest(".modgal");
  if (grid.dataset.window) { bootWindow(grid, gallery); } else { bootStatic(grid, gallery); }
}

$(document).ready(boot);

export default { boot };
