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
  if (root.dataset.modlandBooted) return;
  root.dataset.modlandBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const region = (name) => root.querySelector(`[data-region="${name}"]`);
  const ride = region("ride");
  if (!ride) return;

  const cats = cfg.categories || [];
  if (!cats.length) return;

  let axis = 0;
  let pos = 0;
  let runLeft = 0;
  let advanceTimer = null;
  let resumeTimer = null;
  let paused = false;
  let busy = false;

  const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  // A slide the viewer's blacklist has marked is skipped. The marks live on the
  // hidden pool elements, because that is what the blacklist can see.
  const blocked = (id) => {
    const el = root.querySelector(`.modland-poolitem[data-id="${id}"]`);
    return !!el && el.classList.contains("blacklisted-active");
  };

  const slidesOf = (a) => (cats[a] && cats[a].slides ? cats[a].slides : []).filter((s) => !blocked(s.id));

  // Each axis wraps at its own length, which is what lets categories of
  // different sizes stay lined up under one shared position.
  function at(a, p) {
    const list = slidesOf(a);
    if (!list.length) return null;
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
  const RANKS = 3;             // cells visible either side of the focus
  const HEAD_H = 0.42;         // first neighbour's height, as a fraction of the focus
  const FALLOFF = 0.72;        // each further cell against the one before it
  const HEAD_O = 0.55;         // and the same idea for opacity
  const FALLOFF_O = 0.62;
  const THUMB_RATIO = 0.8;     // w/h of a non-focus cell: fixed, so the focal
                               // cell's true aspect is what makes the border
                               // morph as it arrives
  const GAP = 18;              // px between focus and first neighbour
  const GAP_FALLOFF = 0.78;

  const BASE_MS = 430;
  const MIN_MS = 130;          // floor for a held-down arrow
  const SETTLE_MS = 180;       // quiet time that counts as "the run stopped"
  // Lurch grows with the length of the burst, per the ask, but on a square root
  // rather than linearly: linear reached 72px after eight steps, which on a
  // 330px focal cell is a fifth of the picture and reads as the belt slipping
  // rather than settling. This gives 12px for a single step, 24 for four, 34
  // for eight -- clearly more emphatic the further you went, still a settle.
  const LURCH_PX = 12;
  const LURCH_CAP = 12;
  const NAV_MS = 260;

  const failed = new Set();    // slide ids whose media will not load
  const cells = new Map();     // `${axis}:${id}` -> element
  const aspect = new Map();    // slide id -> natural w/h, once known

  let burst = 0;               // steps since the run last came to rest
  let lastDelta = 1;
  let settleTimer = null;

  function mediaEl(slide) {
    const el = document.createElement(slide.kind === "video" ? "video" : "img");
    // Every cell's media carries .mod-image, so a failure anywhere on the belt
    // becomes an error card rather than a broken icon. That is a change from
    // the stacked flanks, where a card sized for the stage was unreadable at
    // 122px and six of them were worse than the glyph. A belt cell is far
    // larger, and a run of identical "401" cards reads as a locked archive --
    // which is exactly what it is.
    el.className = "mod-image";
    if (slide.kind === "video") {
      el.muted = true;
      el.playsInline = true;
      el.loop = true;
      el.autoplay = true;
    } else {
      el.alt = "";
      el.addEventListener("load", () => {
        if (el.naturalWidth <= 0) return;
        aspect.set(String(slide.id), el.naturalWidth / el.naturalHeight);
        // The focal cell is cut to its picture's shape, and at boot the first
        // picture has not loaded when the belt is first laid out -- so without
        // this it keeps the thumbnail's proportions until something else moves.
        // Prewarm covers every later cell; this covers the first one.
        const shown = at(axis, pos);
        if (shown && String(shown.id) === String(slide.id)) render();
      }, { once: true });
    }
    el.addEventListener("error", () => {
      failed.add(String(slide.id));
      const cell = el.closest(".mod-cell");
      if (cell) cell.classList.add("is-failed");
    }, { once: true });
    el.src = slide.src;
    return el;
  }

  function buildCell(a, slide) {
    const cell = document.createElement("a");
    cell.className = "mod-cell";
    cell.href = slide.url || "#";
    cell.title = cats[a].label;
    if (slide.src && !failed.has(String(slide.id))) cell.appendChild(mediaEl(slide));
    else cell.classList.add("is-failed");

    const tag = document.createElement("span");
    tag.className = "mod-cell-tag";
    tag.textContent = cats[a].label;
    cell.appendChild(tag);
    return cell;
  }

  function cellFor(a, slide) {
    const key = `${a}:${slide.id}`;
    if (!cells.has(key)) cells.set(key, buildCell(a, slide));
    return cells.get(key);
  }

  // A cell that failed while small carries the compact card, and cells change
  // size for a living here -- one promoted to the focus would otherwise keep a
  // thumbnail's card at full size, and one demoted keeps an unreadable essay.
  // The card has to follow the box it is in.
  const CARD_SRC = /^\/errors\/(\d+)\.svg/;
  const COMPACT_BELOW = 320; // matches error_card.js

  function retuneCard(cell, width) {
    const img = cell.querySelector("img");
    if (!img) return;
    const src = img.getAttribute("src") || "";
    const m = src.match(CARD_SRC);
    if (!m) return;
    const wanted = `/errors/${m[1]}.svg${width > 0 && width < COMPACT_BELOW ? "?compact=1" : ""}`;
    if (src !== wanted) img.setAttribute("src", wanted);
  }

  // Shortest signed distance around the ring, so a cell at the end of a short
  // category travels IN from the near side rather than all the way around.
  function ringDelta(i, p, n) {
    let d = (i - p) % n;
    if (d > n / 2) d -= n;
    if (d < -n / 2) d += n;
    return d;
  }

  function beltHeight() {
    const belt = region("belt");
    return belt ? belt.clientHeight || 400 : 400;
  }

  // Rank 0 is the focus, at the band's full height; each rank out is a fixed
  // fraction of the one before it, which is what makes the run recede.
  function cellHeight(k) {
    return k === 0 ? beltHeight() : beltHeight() * HEAD_H * Math.pow(FALLOFF, k - 1);
  }

  // The focal cell is cut to its picture's own aspect; every other cell is a
  // fixed portrait thumb. That difference is what the operator asked for as the
  // border "morphing its size as it moves into place" -- a cell arriving at the
  // centre changes shape as well as growing, because the box stops being a
  // thumbnail and becomes the picture.
  function cellWidth(k, slide) {
    const h = cellHeight(k);
    if (k !== 0) return h * THUMB_RATIO;
    const ratio = aspect.get(String(slide.id));
    if (!ratio) return h * THUMB_RATIO;
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
    for (let k = 1; k <= RANKS + 1; k++) {
      const prevW = k === 1 ? cellWidth(0, focus ? focus.slide : {}) : cellWidth(k - 1, {});
      acc += (prevW / 2) + (GAP * Math.pow(GAP_FALLOFF, k - 1)) + (cellWidth(k, {}) / 2);
      xs[k] = acc;
    }
    return xs;
  }

  function renderCredit(slide) {
    const el = region("credit");
    if (!el) return;
    if (!slide) { el.innerHTML = ""; el.hidden = true; return; }

    const creator = slide.creator && slide.creator.name;
    const platform = slide.platform && slide.platform.name;
    if (!creator && !platform) { el.innerHTML = ""; el.hidden = true; return; }

    el.hidden = false;
    const parts = [];
    if (creator) parts.push(`Created by <span class="modland-credit-creator">${esc(creator)}</span>`);
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
    if (!thumb || !active) return;
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
    for (let d = -(RANKS + 2); d <= RANKS + 2; d++) wanted.push([axis, at(axis, pos + d)]);
    cats.forEach((_, a) => { if (a !== axis) wanted.push([a, at(a, pos)], [a, at(a, pos + 1)]); });

    wanted.forEach(([a, slide]) => {
      if (!slide) return;
      const cell = cellFor(a, slide);
      if (!cell.isConnected) warmHolder().appendChild(cell);
    });
  }

  function render() {
    const belt = region("belt");
    if (!belt) return;
    const list = slidesOf(axis);
    if (!list.length) return;

    const placed = list.map((slide, i) => ({ slide, d: ringDelta(i, pos, list.length) }));
    const xs = layout(placed);

    placed.forEach(({ slide, d }) => {
      const k = Math.abs(d);
      const cell = cellFor(axis, slide);

      const shown = k <= RANKS;
      const x = (xs[Math.min(k, RANKS + 1)] || 0) * Math.sign(d);
      const w = cellWidth(k, slide);
      cell.style.setProperty("--cx", `${x}px`);
      cell.style.setProperty("--cw", `${w}px`);
      cell.style.setProperty("--ch", `${cellHeight(k)}px`);
      cell.style.setProperty("--co", k === 0 ? "1" : String(HEAD_O * Math.pow(FALLOFF_O, k - 1)));
      cell.style.setProperty("--cz", String(10 - k));
      cell.dataset.d = String(d);

      // Sized BEFORE it joins the belt, not after. An error card picks its
      // layout from the element's measured width, and a cell appended without
      // its width yet measures at the stylesheet's fallback -- so the focal
      // cell was being handed the compact card meant for thumbnails, losing
      // the explanation that is the entire reason the cards are written out.
      if (!cell.isConnected) belt.appendChild(cell);
      retuneCard(cell, w);

      cell.classList.toggle("is-offstage", !shown);
      cell.classList.toggle("is-focus", d === 0);
      cell.classList.toggle("is-incoming", k === 1);
      if (failed.has(String(slide.id))) cell.classList.add("is-failed");
    });

    // Cells belonging to other axes stay built but must not sit on this belt.
    cells.forEach((cell, key) => {
      if (!key.startsWith(`${axis}:`) && cell.isConnected) cell.remove();
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
  function settle() {
    const magnitude = Math.round(LURCH_PX * Math.sqrt(Math.min(burst, LURCH_CAP)));
    burst = 0;
    ride.style.setProperty("--belt-move-ms", `${BASE_MS}ms`);
    ride.style.setProperty("--lurch", `${magnitude * Math.sign(lastDelta)}px`);

    // Restart the animation from zero. Without the reflow the browser coalesces
    // remove-then-add into no change at all, and the lurch silently never runs
    // from the second time onward.
    ride.classList.remove("is-lurching");
    void ride.offsetWidth;
    ride.classList.add("is-lurching");
    setTimeout(() => ride.classList.remove("is-lurching"), 360);
  }

  function step(delta) {
    const list = slidesOf(axis);
    if (list.length < 2) return;

    pos += delta;
    lastDelta = delta;
    burst += 1;

    const ms = Math.max(MIN_MS, Math.round(BASE_MS / (1 + (burst * 0.38))));
    ride.style.setProperty("--belt-move-ms", `${ms}ms`);

    ride.classList.remove("is-lurching");
    render();

    // The run has stopped only when nothing else has arrived. Every step pushes
    // this out, so a held arrow never lurches mid-travel -- it lurches once, at
    // the end, harder for having gone further.
    if (settleTimer) clearTimeout(settleTimer);
    settleTimer = setTimeout(settle, ms + SETTLE_MS);
  }

  // Up/down changes axis and carries the position with it, so the centre really
  // does change -- the post view keeps its centre because the post IS the thing
  // being sorted; here the axes hold different images.
  function goToAxis(target, direction) {
    if (target === axis || target < 0 || target >= cats.length || busy) return;
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

  function resetRun(forAxis = axis) {
    runLeft = Math.max(slidesOf(forAxis).length - 1, 0);
  }

  function startTimer() {
    stopTimer();
    advanceTimer = setInterval(autoAdvance, cfg.advanceMs || 6000);
  }

  function stopTimer() {
    if (advanceTimer) { clearInterval(advanceTimer); advanceTimer = null; }
  }

  function pause() {
    if (paused) return;
    paused = true;
    stopTimer();
    showResume();
  }

  function showResume() {
    const box = region("resume");
    const fill = region("fill");
    if (!box || !fill) return;

    box.hidden = false;
    // Replay the fill from zero. Removing the class and forcing a reflow is what
    // makes it restart when the reader interacts again mid-fill; without the
    // reflow the browser coalesces the change and nothing happens.
    fill.classList.remove("is-filling");
    void fill.offsetWidth;
    fill.style.animationDuration = `${cfg.resumeMs || 10000}ms`;
    fill.classList.add("is-filling");

    if (resumeTimer) clearTimeout(resumeTimer);
    resumeTimer = setTimeout(resume, cfg.resumeMs || 10000);
  }

  function hideResume() {
    const box = region("resume");
    const fill = region("fill");
    if (resumeTimer) { clearTimeout(resumeTimer); resumeTimer = null; }
    if (fill) fill.classList.remove("is-filling");
    if (box) box.hidden = true;
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

  // --- interaction --------------------------------------------------------

  root.addEventListener("click", (e) => {
    const cell = e.target.closest(".mod-cell");
    if (cell && ride.contains(cell)) {
      const d = Number(cell.dataset.d || 0);
      // The cell under the microscope is the one you are looking at, so a click
      // there means "open this". Any other cell means "bring that one here",
      // which is the same gesture the arrows make, just aimed.
      if (d === 0) return;
      e.preventDefault();
      step(d);
      pause();
      return;
    }

    const act = e.target.closest("[data-act]");
    if (!act) return;

    if (act.dataset.act === "resume") { e.preventDefault(); resume(); return; }

    e.preventDefault();
    if (act.dataset.act === "next") step(1);
    else if (act.dataset.act === "prev") step(-1);
    else if (act.dataset.act === "axis") {
      selectAxis(Array.from(root.querySelectorAll("[data-act='axis']")).indexOf(act));
    }
    pause();
  });

  // Same keys and the same guard as the post view: left/right along the axis,
  // up/down between axes. A key pressed while typing belongs to the field.
  window.addEventListener("keydown", (e) => {
    if (e.target.closest("input, textarea, select, [contenteditable]")) return;
    if (e.key === "ArrowLeft") { step(-1); pause(); }
    else if (e.key === "ArrowRight") { step(1); pause(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); shiftAxis(-1); pause(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); shiftAxis(1); pause(); }
  });

  window.addEventListener("resize", positionThumb);

  resetRun();
  renderAll();
  startTimer();
}

function initAll() {
  document.querySelectorAll("[data-modland]").forEach(initLanding);
}

$(document).ready(initAll);

export default { initAll };
