import Notice from "./notice";

// The landing carousel, built on the post view's stage.
//
// Two axes, exactly as the post view has two: left/right moves along the
// current category, up/down changes which category. The position is SHARED --
// image X of "Newest Posts" sits opposite image X of "Community Favorites", so
// moving up or down is a straight swap at the same place in the run. Every
// category holds that place whether or not it is the one on screen.
//
// Categories are different lengths, so each wraps at its own: position 4 of a
// three-slide category is its second image. That is what makes the axes line up
// without needing to be the same size.
//
// Auto-advance runs the current category once, then moves to the next one. Any
// manual interaction stops it until the reader asks for it back.
//
// THE CHROME NEVER WAITS ON THE MEDIA. The panel is a structure with its own
// size and its own cadence; a picture is a fill that arrives into it, or does
// not. Nothing about whether a picture loads may change when the stage moves or
// how big anything is. The first version of this file broke that rule twice --
// see `prewarm` and the node caches below for what replaced each -- and the
// result was a carousel that stuttered for exactly as long as the network took
// to answer, on every single advance.

function initLanding(root) {
  if (root.dataset.modlandBooted) { return; }
  root.dataset.modlandBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const region = (name) => root.querySelector(`[data-region="${name}"]`);
  const ride = region("ride");
  if (!ride) { return; }

  const cats = cfg.categories || [];
  if (!cats.length) { return; }

  let axis = 0;
  let pos = 0;
  let runLeft = 0;
  let advanceTimer = null;
  let resumeTimer = null;
  let paused = false;
  let busy = false;

  const esc = (s) => String(s === null || s === undefined ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  // A slide the viewer's blacklist has marked is skipped. The marks live on the
  // hidden pool elements, because that is what the blacklist can see.
  const blocked = (id) => {
    const el = root.querySelector(`.modland-poolitem[data-id="${id}"]`);
    return Boolean(el) && el.classList.contains("blacklisted-active");
  };

  const slidesOf = (a) => (cats[a] && cats[a].slides ? cats[a].slides : []).filter((s) => !blocked(s.id));

  // Each axis wraps at its own length, which is what lets categories of
  // different sizes stay lined up under one shared position.
  function at(a, p) {
    const list = slidesOf(a);
    if (!list.length) { return null; }
    return list[((p % list.length) + list.length) % list.length];
  }

  // --- the belt -----------------------------------------------------------
  //
  // One run of cells along the current axis, magnified in the middle. Every
  // cell is built ONCE per slide and thereafter only moved: its position, size
  // and opacity are custom properties derived from its signed distance from the
  // centre, and advancing the position rewrites all of them in the same frame.
  //
  // That is the whole mechanism, and it is why the run now moves as one object.
  // The version this replaces animated exactly two cells -- the incoming
  // neighbour and the outgoing centre -- by measuring their rects and
  // transforming them, then re-rendered everything else at the destination. Two
  // things sliding while the rest cut is not a conveyor; it reads as a swap
  // with scenery. Nothing here is measured, nothing is destroyed, and no cell
  // is special-cased for travelling. The belt just gets a new set of numbers.
  const RANKS = 3; // cells visible either side of the focus, by default
  // Per axis, from the payload. A row may say how many slides it wants on
  // screen (`visible`); a creators row defaults to one per creator. Halved
  // and rounded UP, because the belt is symmetric about a focus and a count
  // with no middle rounds to the wider belt rather than hiding a creator.
  // Capped by what the row actually has, so a belt is never told to show
  // more cells than it holds.
  // The outermost cell must stay a cell. FALLOFF is tuned for three a side;
  // applied to fifteen it leaves the far ones at two percent of the focus,
  // which is a paint for nothing and a run that looks like seven slides
  // whatever the setting says. For a wider run the shrink per rank is chosen
  // so the last rank is still MIN_OUTER of the first neighbour.
  const MIN_OUTER = 0.12;
  const FALLOFF = 0.72; // each further cell against the one before it
  function falloffFor(ranks) {
    if (ranks <= RANKS) { return FALLOFF; }
    return Math.pow(MIN_OUTER, 1 / (ranks - 1));
  }
  // THE HERO BAND shows more of the run, in proportion to the width it
  // gained: the band's normal width is the column's, and every extra column's
  // worth of belt is another column's worth of cards. Measured, not assumed --
  // a 1440px screen is 1.3 columns, a 2560px one is 2.3 -- so the setting's
  // count still means what the admin set on a band that has not been widened.
  const COLUMN_W = 1120;
  function heroScale() {
    if (!root.classList.contains("is-hero-max")) { return 1; }
    const belt = region("belt");
    return belt && belt.clientWidth > COLUMN_W ? belt.clientWidth / COLUMN_W : 1;
  }
  function ranksFor(a) {
    const cat = cats[a];
    const want = cat && cat.visible;
    if (!want) { return RANKS; }
    // NOT capped by how many slides the row holds. `at()` wraps each axis at
    // its own length, so a belt wider than the row simply repeats -- and
    // capping here let a data value (how many posts were gathered) quietly
    // decide a presentation one. Operator ruling 2026-09-22: unlink them.
    const wanted = Math.round(want * heroScale());
    return Math.max(0, Math.ceil((wanted - 1) / 2));
  }
  const HEAD_H = 0.42; // first neighbour's height, as a fraction of the focus
  const HEAD_O = 0.55; // and the same idea for opacity
  const FALLOFF_O = 0.62;
  const THUMB_RATIO = 0.8; // w/h of a non-focus cell: fixed, so the focal
  // cell's true aspect is what makes the border
  // morph as it arrives
  const GAP = 18; // px between focus and first neighbour
  const GAP_FALLOFF = 0.78;

  const BASE_MS = 430;
  const MIN_MS = 130; // floor for a held-down arrow
  const SETTLE_MS = 180; // quiet time that counts as "the run stopped"
  // Overshoot is part of the travel, not a twitch after it. A back-out curve
  // carries a cell past its slot and brings it back inside one continuous
  // movement -- which is what the ask was: the cell arrives at speed, goes too
  // far, and settles. What this replaces played a separate keyframe animation
  // on the whole belt AFTER the move had finished, so the picture visibly came
  // to a stop and only then jerked, which reads as a glitch rather than mass.
  //
  // y1 is what sets how far past. It grows with the run so a long scroll lands
  // harder, and it is capped where the overshoot reaches roughly one cell --
  // beyond that the incoming cell crosses into its neighbour's slot and the run
  // stops reading as a run.
  // Tuned against measurement, not taste. The overshoot a back-out curve
  // produces is a fraction of the distance THAT transition covers, and during a
  // fast run the last one covers several slots -- so a curve that is a pleasant
  // nudge on a single step became 225px, or 162% of a cell, after ten. These
  // numbers keep the worst case inside one cell while leaving a single step
  // clearly springy.
  const EASE_Y1_BASE = 1.38;
  const EASE_Y1_STEP = 0.22;
  const EASE_Y1_MAX = 2.72;

  function easeFor(n) {
    const y1 = Math.min(EASE_Y1_BASE + (n * EASE_Y1_STEP), EASE_Y1_MAX);
    return `cubic-bezier(0.32, ${y1.toFixed(2)}, 0.62, 1)`;
  }
  const NAV_MS = 260;

  const failed = new Set(); // slide ids whose media will not load
  const cells = new Map(); // `${axis}:${id}` -> element

  let burst = 0; // steps since the run last came to rest
  let settleTimer = null;

  // A failure changes a cell's SHAPE, not just its contents -- a failed cell is
  // card-shaped rather than picture-shaped -- so the run has to be laid out
  // again once one arrives. Coalesced to one redraw per frame because on a
  // signed-out visit every cell fails, and each of them failing separately
  // would otherwise relayout the whole belt.
  let redrawQueued = false;

  function scheduleRender() {
    if (redrawQueued) { return; }
    redrawQueued = true;
    // render() is declared after the geometry helpers it calls, so writing it
    // above scheduleRender only moves this error onto those ten. The reference
    // lives in a frame callback and resolves long after the declaration is
    // evaluated. The disable is one line because a multi-line one does not
    // reach past its own continuation comments.
    // eslint-disable-next-line no-use-before-define
    requestAnimationFrame(() => { redrawQueued = false; render(); });
  }

  function mediaEl(slide) {
    const el = document.createElement(slide.kind === "video" ? "video" : "img");
    // Every cell's media carries .mod-image, so a failure anywhere on the belt
    // becomes an error card rather than a broken icon. That is a change from
    // the stacked flanks, where a card sized for the stage was unreadable at
    // 122px and six of them were worse than the glyph. A belt cell is far
    // larger, and a run of identical "401" cards reads as a locked archive --
    // which is exactly what it is.
    el.className = "mod-image";
    // A VIDEO PLAYS ONLY WHILE IT CAN BE SEEN. render() starts it when its
    // cell is shown AND inside the panel, and stops it otherwise; nothing here
    // starts it. It used to autoplay from the moment it was built, and a cell
    // is built two ranks before it is shown and kept two ranks after -- at
    // opacity 0, still in the viewport, so the browser kept decoding a picture
    // nobody could see: one offstage loop measured 31.7% of a core against
    // 13.0% paused, same page, headless Chromium with GPU compositing
    // (2026-09-25). "Shown" is not enough on its own: the panel clips the run,
    // and with a wide picture in focus only two ranks either side are inside
    // it (measured: 5 of the 13 shown cells at 1600px).
    // preload="auto" is what keeps the rule above: the first frame is fetched
    // and decoded while the cell waits, so it arrives as a picture, not a hole.
    if (slide.kind === "video") {
      el.muted = true;
      el.playsInline = true;
      el.loop = true;
      el.preload = "auto";
    } else {
      el.alt = "";
    }
    el.addEventListener("error", () => {
      failed.add(String(slide.id));
      const cell = el.closest(".mod-cell");
      if (cell) { cell.classList.add("is-failed"); }
      scheduleRender();
    }, { once: true });
    el.src = (slide.kind === "video" ? null : slide.thumb) || slide.src;
    return el;
  }

  function buildCell(a, slide) {
    const cell = document.createElement("a");
    cell.className = "mod-cell";
    cell.href = slide.url || "#";
    cell.title = cats[a].label;
    if (slide.src && !failed.has(String(slide.id))) { cell.appendChild(mediaEl(slide)); } else { cell.classList.add("is-failed"); }

    const tag = document.createElement("span");
    tag.className = "mod-cell-tag";
    tag.textContent = cats[a].label;
    cell.appendChild(tag);

    // THE CREATOR'S NAME TRAVELS WITH THE CARD, just underneath it, and
    // shrinks and dims as the card does (operator, 2026-09-19). It is a
    // SIBLING of the cell rather than a child: the cell clips to its own
    // box, and "underneath" is outside that box. It reads the cell's own
    // variables -- --cx, --ch, --co -- so it is positioned by the same
    // numbers and moved by the same transition, never measured.
    const creator = slide.creator && slide.creator.name;
    if (creator) {
      const name = document.createElement("span");
      name.className = "mod-cell-name";
      name.textContent = creator;
      cell.nameEl = name;
    }
    return cell;
  }
  // The name goes wherever its cell goes, carrying the cell's variables.
  function placeName(cell, belt) {
    const name = cell.nameEl;
    if (!name) { return; }
    ["--cx", "--cw", "--ch", "--co", "--cz"].forEach((v) => name.style.setProperty(v, cell.style.getPropertyValue(v)));
    name.dataset.d = cell.dataset.d;
    name.classList.toggle("is-offstage", cell.classList.contains("is-offstage"));
    name.classList.toggle("is-focus", cell.classList.contains("is-focus"));
    if (belt && name.parentNode !== belt) { belt.appendChild(name); }
  }

  // THE WINDOW IS WHAT EXISTS, not what is visible.
  //
  // render() used to walk the whole category and build a cell for every slide
  // in it, marking the far ones is-offstage -- so a row of N slides fetched N
  // images on its first frame whatever was on screen. That was survivable at a
  // row of ten and is not at a row of several hundred, which is what a row
  // holding every cached lap now is. Beyond this window a cell is not hidden,
  // it is not built; come back and it rebuilds.
  const REACH_MARGIN = 2;
  function reachFor(a) { return ranksFor(a) + REACH_MARGIN; }

  // Give a cell back. `failed` is deliberately NOT cleared: it is keyed by
  // slide id, and a slide whose media would not load will not load on the next
  // lap either. Forgetting that would re-request every broken file every time
  // the belt came round.
  function dropCell(a, slide) {
    const key = `${a}:${slide.id}`;
    const cell = cells.get(key);
    if (!cell) { return; }
    if (cell.nameEl) { cell.nameEl.remove(); }
    cell.remove();
    cells.delete(key);
  }

  // Promote a cell's image to the full sample. Once, and only for the focus:
  // reassigning src to the value it already holds would restart the fetch.
  function promoteMedia(cell, slide) {
    const el = cell.querySelector("img.mod-image");
    if (!el || !slide.thumb || cell.dataset.promoted === "1") { return; }
    cell.dataset.promoted = "1";
    el.src = slide.src;
  }

  function cellFor(a, slide) {
    const key = `${a}:${slide.id}`;
    if (!cells.has(key)) { cells.set(key, buildCell(a, slide)); }
    return cells.get(key);
  }

  // A cell that failed while small carries the compact card, and cells change
  // size for a living here -- one promoted to the focus would otherwise keep a
  // thumbnail's card at full size, and one demoted keeps an unreadable essay.
  // The card has to follow the box it is in.
  const CARD_RATIO = 640 / 362; // the full error card's own viewBox
  const CARD_SRC = /^\/errors\/(\d+)\.svg/;
  const COMPACT_BELOW = 320; // matches error_card.js

  function retuneCard(cell, width) {
    const img = cell.querySelector("img");
    if (!img) { return; }
    const src = img.getAttribute("src") || "";
    const m = src.match(CARD_SRC);
    if (!m) { return; }
    const wanted = `/errors/${m[1]}.svg${width > 0 && width < COMPACT_BELOW ? "?compact=1" : ""}`;
    if (src !== wanted) { img.setAttribute("src", wanted); }
  }

  // Shortest signed distance around the ring, so a cell at the end of a short
  // category travels IN from the near side rather than all the way around.
  function ringDelta(i, p, n) {
    let d = (i - p) % n;
    if (d > n / 2) { d -= n; }
    if (d < -n / 2) { d += n; }
    return d;
  }

  function beltHeight() {
    const belt = region("belt");
    return belt ? belt.clientHeight || 400 : 400;
  }

  // Rank 0 is the focus, at the band's full height; each rank out is a fixed
  // fraction of the one before it, which is what makes the run recede.
  function cellHeight(k) {
    return k === 0 ? beltHeight() : beltHeight() * HEAD_H * Math.pow(falloffFor(ranksFor(axis)), k - 1);
  }

  // The focal cell is cut to its picture's own aspect; every other cell is a
  // fixed portrait thumb. That difference is what the operator asked for as the
  // border "morphing its size as it moves into place" -- a cell arriving at the
  // centre changes shape as well as growing, because the box stops being a
  // thumbnail and becomes the picture.
  function cellWidth(k, slide) {
    const h = cellHeight(k);
    if (k !== 0) { return h * THUMB_RATIO; }
    // The payload carries the picture's real dimensions, so the focal cell is
    // cut to the right shape BEFORE the picture arrives -- and stays right when
    // it never arrives at all, which is what every image on this site does for
    // a signed-out visitor. An earlier version measured naturalWidth on load
    // instead, so on production the focal cell would have kept a thumbnail's
    // proportions permanently and the border would have had nothing to morph
    // into. The server knew the answer the whole time.
    // A cell whose picture will not load has no picture's shape to keep, and
    // keeping it anyway is actively bad: a portrait slide gives a 272px focal
    // cell, the error card's explanation renders under 9px inside that, and the
    // reader is served the thumbnail-sized card on the one cell that exists to
    // be read. So a failed cell takes the CARD's shape instead. The box should
    // fit what it actually contains, and what it contains is a sentence.
    const ratio = failed.has(String(slide.id))
      ? CARD_RATIO
      : (slide.w > 0 && slide.h > 0 ? slide.w / slide.h : 0);
    if (!ratio) { return h * THUMB_RATIO; }
    const belt = region("belt");
    const maxW = (belt ? belt.clientWidth : 800) * 0.62;
    return Math.min(h * ratio, maxW);
  }

  // Walk outward from the centre, accumulating half-widths and a shrinking gap.
  // Positions are cumulative rather than a fixed pitch because the cells are
  // different sizes; a constant pitch leaves the outer ones swimming in space.
  function layout(list) {
    const focus = list.find((e) => e.d === 0);
    const xs = { 0: 0 };
    let acc = 0;
    const ranks = ranksFor(axis);
    for (let k = 1; k <= ranks + 1; k++) {
      const prevW = k === 1 ? cellWidth(0, focus ? focus.slide : {}) : cellWidth(k - 1, {});
      acc += (prevW / 2) + (GAP * Math.pow(GAP_FALLOFF, k - 1)) + (cellWidth(k, {}) / 2);
      xs[k] = acc;
    }
    return xs;
  }

  function renderCredit(slide) {
    const el = region("credit");
    if (!el) { return; }
    if (!slide) { el.innerHTML = ""; el.hidden = true; return; }

    const creator = slide.creator && slide.creator.name;
    const platform = slide.platform && slide.platform.name;
    if (!creator && !platform) { el.innerHTML = ""; el.hidden = true; return; }

    el.hidden = false;
    const parts = [];
    if (creator) { parts.push(`Created by <span class="modland-credit-creator">${esc(creator)}</span>`); }
    if (platform) {
      // The slug rides on the element so a per-site logo is later a rule per
      // platform, and the display name never becomes an identifier.
      const key = esc((slide.platform && slide.platform.key) || "");
      parts.push(`posted on <span class="modland-credit-platform" data-platform="${key}">${esc(platform)}</span>`);
    }
    el.innerHTML = `${parts.join(" and ")}.`;
  }

  function positionThumb() {
    const thumb = region("thumb");
    const active = root.querySelector("[data-act='axis'].is-active");
    if (!thumb || !active) { return; }
    thumb.style.width = `${active.offsetWidth}px`;
    thumb.style.transform = `translateX(${active.offsetLeft}px)`;
  }

  function renderTabs() {
    root.querySelectorAll("[data-act='axis']").forEach((tab, i) => {
      const on = i === axis;
      tab.classList.toggle("is-active", on);
      tab.setAttribute("aria-selected", String(on));
    });
    positionThumb();
  }

  // --- prewarm ------------------------------------------------------------
  //
  // Build what the reader is a few steps away from, off-screen but real, so a
  // cell arrives resolved -- its picture fetched, or its failure already turned
  // into an error card. Off-screen at full size rather than display:none or a
  // 1px box, because the card picks its layout from measured width.
  let holder = null;

  function warmHolder() {
    if (!holder) {
      holder = document.createElement("div");
      holder.className = "modland-warm";
      holder.setAttribute("aria-hidden", "true");
      root.appendChild(holder);
    }
    return holder;
  }

  function prewarm() {
    const wanted = [];
    const reach = reachFor(axis);
    for (let d = -reach; d <= reach; d++) { wanted.push([axis, at(axis, pos + d)]); }
    cats.forEach((_, a) => { if (a !== axis) { wanted.push([a, at(a, pos)], [a, at(a, pos + 1)]); } });

    wanted.forEach(([a, slide]) => {
      if (!slide) { return; }
      const cell = cellFor(a, slide);
      // Only adopt a cell that is nowhere. isConnected would be true of a cell
      // already ON the belt, but so would it be of one already in the holder --
      // see render(), where that distinction is the whole bug.
      if (!cell.parentNode) { warmHolder().appendChild(cell); }
    });
  }

  function render() {
    const belt = region("belt");
    if (!belt) { return; }
    const list = slidesOf(axis);
    if (!list.length) { return; }

    const placed = list.map((slide, i) => ({ slide, d: ringDelta(i, pos, list.length) }));
    const xs = layout(placed);
    const ranks = ranksFor(axis);

    const reach = reachFor(axis);
    // The panel clips at its padding box, and the belt is centred in it, so a
    // cell is inside it while its near edge is within half the panel's width.
    const panel = root.querySelector(".modland-stage-wrap");
    const halfPanel = panel ? panel.clientWidth / 2 : Infinity;
    placed.forEach(({ slide, d }) => {
      const k = Math.abs(d);
      // Outside the window: not built, and released if it was.
      if (k > reach) { dropCell(axis, slide); return; }

      const cell = cellFor(axis, slide);

      const shown = k <= ranks;
      const x = (xs[Math.min(k, ranks + 1)] || 0) * Math.sign(d);
      const w = cellWidth(k, slide);
      cell.style.setProperty("--cx", `${x}px`);
      cell.style.setProperty("--cw", `${w}px`);
      cell.style.setProperty("--ch", `${cellHeight(k)}px`);
      cell.style.setProperty("--co", k === 0 ? "1" : String(HEAD_O * Math.pow(ranks > RANKS ? falloffFor(ranks) : FALLOFF_O, k - 1)));
      cell.style.setProperty("--cz", String(10 - k));
      cell.dataset.d = String(d);

      // Sized BEFORE it joins the belt, not after. An error card picks its
      // layout from the element's measured width, and a cell appended without
      // its width yet measures at the stylesheet's fallback -- so the focal
      // cell was being handed the compact card meant for thumbnails, losing
      // the explanation that is the entire reason the cards are written out.
      // parentNode, NOT isConnected. A cell prewarmed for another axis sits in
      // the off-screen holder, which is in the document -- so isConnected is
      // true of it, and the cell was never moved onto the belt when its axis
      // became the current one. Its position was still computed and its
      // variables still written, so the run had a correctly-spaced hole in it
      // that moved with the conveyor, and stayed there: nothing ever
      // reconsidered a cell once it was "connected".
      if (cell.parentNode !== belt) { belt.appendChild(cell); }
      retuneCard(cell, w);

      cell.classList.toggle("is-offstage", !shown);
      // See mediaEl: a video plays while its cell is shown and overlaps the
      // panel, judged on where the cell is going, so one sliding into view
      // starts as it arrives. play() on a playing video is a no-op, and its
      // rejection (a file that will not load) is already an error card by way
      // of the error listener.
      const video = cell.querySelector("video");
      if (video && shown && Math.abs(x) - (w / 2) < halfPanel) { video.play().catch(() => null); } else if (video) { video.pause(); }
      cell.classList.toggle("is-focus", d === 0);
      if (d === 0) { promoteMedia(cell, slide); }
      cell.classList.toggle("is-incoming", k === 1);
      if (failed.has(String(slide.id))) { cell.classList.add("is-failed"); }
      placeName(cell, belt);
    });

    // Cells belonging to other axes stay built but must not sit on this belt.
    cells.forEach((cell, key) => {
      if (!key.startsWith(`${axis}:`) && cell.parentNode === belt) { cell.remove(); if (cell.nameEl) { cell.nameEl.remove(); } }
    });

    renderCredit(at(axis, pos));
    renderTabs();
    prewarm();
  }

  function renderAll() { render(); }

  // --- movement -----------------------------------------------------------
  //
  // A step is not an animation to be scheduled and waited on; it is a change of
  // one number. The transitions do the rest, which is what lets input arrive
  // mid-flight: the belt simply re-targets from wherever it currently is.
  //
  // That is also the whole of "holding the arrow plays smoothly but faster" --
  // there is no queue to drain and no busy flag to bounce off. The duration
  // shortens as the burst grows so the belt keeps up with the key repeat.
  // The run has come to rest. Nothing to animate here any more -- the overshoot
  // has already happened, inside the last step's own travel. This just puts the
  // pace and the curve back where a fresh, unhurried step expects them.
  function settle() {
    burst = 0;
    ride.style.setProperty("--belt-move-ms", `${BASE_MS}ms`);
    ride.style.setProperty("--belt-ease", easeFor(1));
  }

  // A fresh set ARRIVES AT THE RIGHT-HAND EDGE, one slide at a time.
  //
  // This replaced the whole payload at once, dropped every cell and rendered
  // again -- correct, and a visible reload: the entire belt blinked and
  // restarted. Operator, 2026-09-22: base it on the card entering from the far
  // right instead of on the focus, so new images scroll into view naturally.
  //
  // So a pull does not swap. It queues, and each advance installs ONE queued
  // slide into the slot about to enter the window. Over one traverse of the
  // row the whole set turns over and nothing ever blinks.
  const pending = new Map(); // category key -> slides still to be fed in

  // The queued slides' pool elements are added IMMEDIATELY, before any of them
  // is installed, because blocked() reads those elements and a slide whose
  // element is not there yet reads as not-blacklisted. Appended, not replaced:
  // the slides currently on the belt still need theirs.
  function queueFreshSet(next, poolHtml) {
    const pool = root.querySelector(".modland-pool");
    if (pool && typeof poolHtml === "string") {
      const seen = new Set(Array.from(pool.querySelectorAll("[data-id]"), (el) => el.dataset.id));
      const staging = document.createElement("div");
      staging.innerHTML = poolHtml;
      Array.from(staging.children).forEach((el) => {
        if (!seen.has(el.dataset.id)) { pool.appendChild(el); }
      });
      const box = document.querySelector("#blacklist-box");
      if (box && box.blacklist) { box.blacklist.rescan(); }
    }

    next.forEach((c) => {
      if (Array.isArray(c.slides) && c.slides.length) { pending.set(c.key, c.slides.slice()); }
    });
  }

  // Pool elements for slides nothing refers to any more. Left alone while a
  // queue is still draining, because a queued slide's element is what blocked()
  // will be asked about.
  function prunePool() {
    if (pending.size) { return; }
    const pool = root.querySelector(".modland-pool");
    if (!pool) { return; }
    const live = new Set();
    cats.forEach((c) => (c.slides || []).forEach((slide) => live.add(String(slide.id))));
    Array.from(pool.querySelectorAll("[data-id]")).forEach((el) => {
      if (!live.has(el.dataset.id)) { el.remove(); }
    });
  }

  // Install one queued slide into the slot that is about to enter the window
  // from the right, and give back the cell of whatever was there.
  //
  // The raw list and the list the ring walks are not the same array --
  // slidesOf filters out what the viewer's blacklist marked -- so the ring
  // index is mapped back to a raw one. A blocked slide is discarded rather
  // than installed: dropping one would shorten the filtered list under the
  // belt, and every position after it would jump.
  function feedOne(a) {
    const cat = cats[a];
    const queue = cat && pending.get(cat.key);
    if (!queue || !queue.length) { return; }

    const list = slidesOf(a);
    if (!list.length) { return; }

    // IDS MUST STAY UNIQUE WITHIN A CATEGORY.
    //
    // cellFor keys a cell by `${axis}:${id}`, so two entries sharing an id
    // share one DOM element -- and an element can only be in one place, so
    // render() moves it to the second position and the first draws NOTHING.
    // The server dedupes within one set, but this feed MIXES two: a fresh
    // random draw from the same creators overlaps the set already on the belt,
    // heavily. That is where the missing cards came from, and it showed on the
    // second lap because that is when fed-in slides first reach the eye.
    const present = new Set(cat.slides.map((slide) => String(slide.id)));

    let incoming = null;
    while (queue.length) {
      const candidate = queue.shift();
      if (blocked(candidate.id)) { continue; }
      // Already on the belt: nothing to gain by moving it, and a hole to pay
      // for putting it in twice.
      if (present.has(String(candidate.id))) { continue; }
      incoming = candidate;
      break;
    }
    if (!queue.length) { pending.delete(cat.key); prunePool(); }
    if (!incoming) { return; }

    // The far right-hand edge: one past the outermost cell the window builds.
    const ringIndex = (((pos + reachFor(a) + 1) % list.length) + list.length) % list.length;
    const outgoing = list[ringIndex];
    if (!outgoing) { return; }

    const rawIndex = cat.slides.indexOf(outgoing);
    if (rawIndex < 0) { return; }

    cat.slides[rawIndex] = incoming;
    // Only give the cell back if nothing else still shows that slide. The list
    // is unique going forward, but this also holds if it ever was not.
    if (!cat.slides.some((slide) => String(slide.id) === String(outgoing.id))) {
      dropCell(a, outgoing);
    }
  }

  function step(delta) {
    const list = slidesOf(axis);
    if (list.length < 2) { return; }

    pos += delta;
    burst += 1;
    // One slide per step, at the edge the step is uncovering.
    feedOne(axis);

    const ms = Math.max(MIN_MS, Math.round(BASE_MS / (1 + (burst * 0.38))));
    ride.style.setProperty("--belt-move-ms", `${ms}ms`);
    // Every step gets the overshoot, and mid-run you never see it resolve: the
    // next step re-targets the transition from wherever the cell has got to,
    // so the settle-back only plays on the step nobody follows. That is the
    // "no lurch while still scrolling" rule, and it costs no bookkeeping --
    // the curve simply runs out of time on every step but the last.
    ride.style.setProperty("--belt-ease", easeFor(burst));

    render();

    // The run has stopped only when nothing else has arrived. Every step pushes
    // this out, so a held arrow never lurches mid-travel -- it lurches once, at
    // the end, harder for having gone further.
    if (settleTimer) { clearTimeout(settleTimer); }
    settleTimer = setTimeout(settle, ms + SETTLE_MS);
  }

  // Up/down changes axis and carries the position with it, so the centre really
  // does change -- the post view keeps its centre because the post IS the thing
  // being sorted; here the axes hold different images.
  function goToAxis(target, direction) {
    if (target === axis || target < 0 || target >= cats.length || busy) { return; }
    busy = true;

    const outClass = direction > 0 ? "is-axis-down" : "is-axis-up";
    const inClass = direction > 0 ? "is-enter-down" : "is-enter-up";

    ride.classList.add(outClass);
    setTimeout(() => {
      axis = target;
      ride.classList.remove(outClass);
      ride.classList.add(inClass);
      render();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        ride.classList.remove(inClass);
        busy = false;
      }));
    }, NAV_MS);
  }

  function selectAxis(a) {
    goToAxis(a, a > axis ? 1 : -1);
  }

  function shiftAxis(delta) {
    goToAxis(((((axis + delta) % cats.length) + cats.length) % cats.length), delta);
  }

  // --- the ride -----------------------------------------------------------

  function resetRun(forAxis = axis) {
    runLeft = Math.max(slidesOf(forAxis).length - 1, 0);
  }

  function autoAdvance() {
    if (runLeft > 0) {
      runLeft -= 1;
      step(1);
    } else {
      // A full run of this category is done; hand over to the next one.
      resetRun((axis + 1) % cats.length);
      shiftAxis(1);
    }
  }

  function stopTimer() {
    if (advanceTimer) { clearInterval(advanceTimer); advanceTimer = null; }
  }

  function startTimer() {
    stopTimer();
    advanceTimer = setInterval(autoAdvance, cfg.advanceMs || 6000);
  }

  function hideResume() {
    const box = region("resume");
    const fill = region("fill");
    if (resumeTimer) { clearTimeout(resumeTimer); resumeTimer = null; }
    if (fill) { fill.classList.remove("is-filling"); }
    if (box) { box.hidden = true; }
  }

  // A shove backwards before going forward, so the restart reads as picking up
  // where it left off rather than as the page twitching.
  function resume() {
    hideResume();
    paused = false;
    ride.classList.add("is-lurching");
    setTimeout(() => {
      ride.classList.remove("is-lurching");
      resetRun();
      step(1);
      startTimer();
    }, 260);
  }

  function showResume() {
    const box = region("resume");
    const fill = region("fill");
    if (!box || !fill) { return; }

    box.hidden = false;
    // Replay the fill from zero. Removing the class and forcing a reflow is what
    // makes it restart when the reader interacts again mid-fill; without the
    // reflow the browser coalesces the change and nothing happens.
    fill.classList.remove("is-filling");
    void fill.offsetWidth;
    fill.style.animationDuration = `${cfg.resumeMs || 10000}ms`;
    fill.classList.add("is-filling");

    if (resumeTimer) { clearTimeout(resumeTimer); }
    resumeTimer = setTimeout(resume, cfg.resumeMs || 10000);
  }

  function pause() {
    if (paused) { return; }
    paused = true;
    stopTimer();
    showResume();
  }

  // MAXIMIZE HERO BAND. The class does the widening (stylesheet); the run is
  // re-laid for the width it now has; the choice is remembered server-side
  // through the same endpoint every other Modulation view choice uses.
  function toggleHero(btn) {
    const on = !root.classList.contains("is-hero-max");
    root.classList.toggle("is-hero-max", on);
    btn.setAttribute("aria-pressed", String(on));
    btn.title = on ? "Restore Hero Band" : "Maximize Hero Band";
    requestAnimationFrame(() => { render(); positionThumb(); });
    fetch("/modulation/settings", {
      method: "PATCH",
      headers: { "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') || {}).content || "", "Content-Type": "application/json", Accept: "application/json" },
      credentials: "same-origin",
      body: JSON.stringify({ hero_band: on }),
    }).catch(() => {
      Notice.error("Could not save the hero band setting; it will not be remembered.");
    });
  }


  // --- the fresh set --------------------------------------------------------
  //
  // The candidates behind a random row are recomputed server-side every few
  // minutes (LandingShowcaseCache::REFRESH_EVERY). Until this was wired the
  // only way to see a new draw was to reload the page, and /landing/slides.json
  // was rendered by the controller and fetched by nobody.
  //
  // The swap replaces the hidden pool as well as the payload, and re-runs the
  // blacklist over it. A slide whose pool element the blacklist never saw is a
  // slide it never filtered.
  async function pullFreshSet() {
    if (!cfg.slidesUrl) { return; }
    // Not while someone is using it, and not while the tab is in the
    // background: a set swapped under a reader's hand is a set that loses their
    // place, and one swapped where nobody is looking is work for nothing. The
    // next tick asks again.
    if (document.hidden) { return; }

    try {
      const r = await fetch(cfg.slidesUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" });
      if (!r.ok) { throw new Error(`HTTP ${r.status}`); }
      const data = await r.json();
      if (Array.isArray(data.categories) && data.categories.length) {
        queueFreshSet(data.categories, data.pool);
      }
    } catch {
      // The page keeps the set it already has, which is the whole reason this
      // is a refresh and not a load. Reporting a background poll that will run
      // again in a few minutes would be noise over something the reader cannot
      // act on and has not lost.
    }
  }

  if (cfg.slidesUrl && cfg.refreshMs) {
    setInterval(pullFreshSet, cfg.refreshMs);
  }

  // --- interaction --------------------------------------------------------

  root.addEventListener("click", (e) => {
    const cell = e.target.closest(".mod-cell");
    if (cell && ride.contains(cell)) {
      const d = Number(cell.dataset.d || 0);
      // The cell under the microscope is the one you are looking at, so a click
      // there means "open this". Any other cell means "bring that one here",
      // which is the same gesture the arrows make, just aimed.
      if (d === 0) { return; }
      e.preventDefault();
      step(d);
      pause();
      return;
    }

    const act = e.target.closest("[data-act]");
    if (!act) { return; }

    if (act.dataset.act === "resume") { e.preventDefault(); resume(); return; }
    if (act.dataset.act === "hero") { e.preventDefault(); toggleHero(act); return; }

    e.preventDefault();
    if (act.dataset.act === "next") { step(1); } else if (act.dataset.act === "prev") { step(-1); } else if (act.dataset.act === "axis") {
      selectAxis(Array.from(root.querySelectorAll("[data-act='axis']")).indexOf(act));
    }
    pause();
  });

  // Same keys and the same guard as the post view: left/right along the axis,
  // up/down between axes. A key pressed while typing belongs to the field.
  window.addEventListener("keydown", (e) => {
    if (e.target.closest("input, textarea, select, [contenteditable]")) { return; }
    if (e.key === "ArrowLeft") { step(-1); pause(); } else if (e.key === "ArrowRight") { step(1); pause(); } else if (e.key === "ArrowUp") { e.preventDefault(); shiftAxis(-1); pause(); } else if (e.key === "ArrowDown") { e.preventDefault(); shiftAxis(1); pause(); }
  });

  window.addEventListener("resize", () => { positionThumb(); if (root.classList.contains("is-hero-max")) { scheduleRender(); } });

  resetRun();
  renderAll();
  startTimer();
}

function initAll() {
  document.querySelectorAll("[data-modland]").forEach(initLanding);
}

$(document).ready(initAll);

export default { initAll };
