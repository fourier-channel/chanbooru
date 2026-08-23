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

  const NAV_MS = 260;
  const SHUFFLE_MS = 430;

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

  // --- media nodes --------------------------------------------------------
  //
  // Every slide's picture is built ONCE and kept; rendering moves the cached
  // node into place rather than rebuilding markup around a fresh source.
  //
  // What this replaces: the centre and both flank columns each had their
  // innerHTML reassigned on every advance. Seven elements destroyed and seven
  // created, six times a minute, every one of them re-requesting its source.
  // For media that loads, that is a decode per advance for a picture already
  // decoded. For media that does not -- which is every picture on this site for
  // a signed-out visitor -- it is a fresh round trip to be told "no" again, and
  // a fresh empty panel while it waits. Nodes that persist have neither
  // problem: a picture that arrived stays arrived, and one that failed stays
  // failed without asking twice.
  const failed = new Set();      // slide ids whose media will not load
  const centreNodes = new Map(); // id -> .mod-frame
  const rowNodes = new Map();    // `${side}:${axis}:${id}` -> .mod-sortrow

  function mediaEl(slide, className, playing) {
    const el = document.createElement(slide.kind === "video" ? "video" : "img");
    if (className) el.className = className;
    if (slide.kind === "video") {
      el.muted = true;
      el.playsInline = true;
      // Looping and playing in the centre; a poster frame in the flanks,
      // because three looping videos around a fourth is a slot machine.
      if (playing) { el.loop = true; el.autoplay = true; } else { el.preload = "metadata"; }
    } else {
      el.alt = "";
    }
    el.addEventListener("error", () => failed.add(String(slide.id)), { once: true });
    el.src = slide.src;
    return el;
  }

  function buildCentre(slide) {
    const frame = document.createElement("div");
    if (!slide || !slide.src) {
      frame.className = "mod-frame mod-image mod-image--placeholder";
      frame.textContent = "nothing here";
      return frame;
    }
    frame.className = "mod-frame";
    frame.appendChild(mediaEl(slide, "mod-image", true));
    return frame;
  }

  function centreFor(slide) {
    if (!slide || !slide.src) return buildCentre(null);
    const key = String(slide.id);
    if (!centreNodes.has(key)) centreNodes.set(key, buildCentre(slide));
    return centreNodes.get(key);
  }

  // A thumbnail that cannot load becomes the empty-slot hatch, not the browser's
  // broken-file icon (Chrome) or a blank hole (Firefox). The stage already has a
  // treatment for "no picture here"; a failed one is the same situation.
  function markRowEmpty(row) {
    if (!row) return;
    row.classList.add("is-empty");
    const m = row.querySelector("img, video");
    if (m) m.remove();
  }

  function buildRow(a, slide, side) {
    const row = document.createElement("a");
    row.className = "mod-sortrow";
    row.dataset.a = String(a);
    row.dataset.side = side;
    row.href = (slide && slide.url) || "#";
    row.title = cats[a].label;

    // A slide already known to fail is built hatched and never asked for. The
    // flanks meet every picture before the centre does, so by the time one
    // reaches the middle its outcome is usually already settled.
    if (slide && slide.src && !failed.has(String(slide.id))) {
      const m = mediaEl(slide, "", false);
      m.addEventListener("error", () => markRowEmpty(row), { once: true });
      row.appendChild(m);
    } else {
      row.classList.add("is-empty");
    }

    const tag = document.createElement("span");
    tag.className = "mod-sortrow-tag";
    tag.textContent = cats[a].label;
    row.appendChild(tag);
    return row;
  }

  function rowFor(a, slide, side) {
    const key = `${side}:${a}:${slide ? slide.id : "none"}`;
    if (!rowNodes.has(key)) rowNodes.set(key, buildRow(a, slide, side));
    const row = rowNodes.get(key);
    // A cached row that failed after it was built still carries its broken
    // media, since the error fired on a node nobody was looking at.
    if (slide && failed.has(String(slide.id)) && !row.classList.contains("is-empty")) markRowEmpty(row);
    return row;
  }

  // A cached row keeps whatever inline transform a shuffle left on it -- it is
  // no longer thrown away between renders. Clearing that with the transition
  // suppressed is what stops a reused row animating back from a journey it made
  // at some previous position.
  function settleRows() {
    rowNodes.forEach((row) => {
      if (!row.style.transform && !row.style.transition) return;
      row.style.transition = "none";
      row.style.transform = "";
      row.classList.remove("is-travelling");
    });
  }

  function releaseRows() {
    rowNodes.forEach((row) => { if (row.style.transition) row.style.transition = ""; });
  }

  // --- prewarm ------------------------------------------------------------
  //
  // Build the pictures the reader is one step away from before they are needed,
  // in a holder that is off-screen but REAL -- a node in the document fetches
  // its media, and if that media fails it has already been turned into an error
  // card by the time it is moved into the stage.
  //
  // This is what removes the blank-panel-then-populate: the panel arrives
  // resolved, whichever way it resolved. The old code chased the same goal by
  // awaiting an `Image()` before starting the animation, which got it backwards
  // -- it made the chrome wait on the network instead of making the picture
  // ready ahead of it.
  //
  // Off-screen at full size rather than `display: none` or a 1px box, because
  // the error card chooses its layout from the element's measured width, and a
  // card measured at 1px is the compact one meant for thumbnails.
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
    const wanted = [at(axis, pos + 1), at(axis, pos - 1)];
    cats.forEach((_, a) => { if (a !== axis) wanted.push(at(a, pos)); });
    wanted.filter(Boolean).forEach((slide) => {
      const node = centreFor(slide);
      if (!node.isConnected) warmHolder().appendChild(node);
    });
  }

  // --- rendering ----------------------------------------------------------

  function renderCentre() {
    const slide = at(axis, pos);
    region("center").replaceChildren(centreFor(slide));
    renderCredit(slide);
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

  function renderFlanks() {
    ["prev", "next"].forEach((side) => {
      const col = region(`flank-${side}`);
      const rows = cats.map((_, a) => rowFor(a, at(a, side === "prev" ? pos - 1 : pos + 1), side));
      col.replaceChildren(...rows);
    });
    applyRanks();
  }

  // Rank is the axis's distance from the active one; the stylesheet turns that
  // into vertical offset and scale.
  function applyRanks() {
    ride.querySelectorAll(".mod-sortrow").forEach((el) => {
      const a = Number(el.dataset.a);
      el.style.setProperty("--rank", a - axis);
      el.classList.toggle("is-current", a === axis);
    });
  }

  function renderTabs() {
    root.querySelectorAll("[data-act='axis']").forEach((tab, i) => {
      const on = i === axis;
      tab.classList.toggle("is-active", on);
      tab.setAttribute("aria-selected", String(on));
    });
    positionThumb();
  }

  function positionThumb() {
    const thumb = region("thumb");
    const active = root.querySelector("[data-act='axis'].is-active");
    if (!thumb || !active) return;
    thumb.style.width = `${active.offsetWidth}px`;
    thumb.style.transform = `translateX(${active.offsetLeft}px)`;
  }

  function renderAll() { renderCentre(); renderFlanks(); renderTabs(); prewarm(); }

  // --- movement -----------------------------------------------------------

  const rectOf = (el) => (el ? el.getBoundingClientRect() : null);
  const centreOf = (r) => ({ x: r.left + r.width / 2, y: r.top + r.height / 2 });

  // A shuffle, not a swap.
  //
  // The whole strip moves one place: the neighbour on the incoming side travels
  // into the centre and grows to fill it, while the centre travels out to the
  // opposite flank and shrinks to its size. That is what a carousel does, and
  // it is what the previous version did NOT do -- it shrank the centre away and
  // grew the neighbour in place, which reads as two separate things happening
  // rather than one row of pictures sliding along.
  //
  // Positions are measured rather than assumed, so the motion stays correct if
  // the flank size, the gap or the stage width change.
  //
  // It begins in the same frame the reader asked for it. There is deliberately
  // no wait on the incoming picture: prewarm has already fetched it, and if it
  // has not arrived the stage still owes the reader the movement they asked for.
  function shuffle(delta) {
    if (busy) return;
    const inSide = delta > 0 ? "next" : "prev";
    const outSide = delta > 0 ? "prev" : "next";

    const centre = region("center");
    const inRow = ride.querySelector(`.mod-flank-col--${inSide} .mod-sortrow.is-current`);
    const outRow = ride.querySelector(`.mod-flank-col--${outSide} .mod-sortrow.is-current`);

    // No flank to move from (a single-slide axis): fall back to a plain swap.
    if (!inRow || !centre) { pos += delta; renderAll(); return; }

    busy = true;

    const cRect = rectOf(centre);
    const iRect = rectOf(inRow);
    const oRect = rectOf(outRow);
    const c = centreOf(cRect);
    const i = centreOf(iRect);

    // Scale by height: the flank crops its picture and the centre letterboxes
    // it, so no single factor matches both dimensions. Height is the one the
    // eye tracks in a horizontal move.
    const growTo = cRect.height / iRect.height;
    const shrinkTo = oRect ? oRect.height / cRect.height : 0.3;

    ride.classList.add("is-shuffling");
    inRow.classList.add("is-travelling");

    // Incoming: flank slot -> centre. The row's own transform already carries
    // translate(-50%,-50%), so the journey is composed on top of it.
    inRow.style.transform =
      `translate(-50%, -50%) translate(${c.x - i.x}px, ${c.y - i.y}px) scale(${growTo})`;

    // Outgoing: centre -> opposite flank slot.
    if (oRect) {
      const o = centreOf(oRect);
      centre.style.transform = `translate(${o.x - c.x}px, ${o.y - c.y}px) scale(${shrinkTo})`;
    } else {
      centre.style.transform = `translateX(${delta > 0 ? -cRect.width : cRect.width}px) scale(0.4)`;
    }
    centre.style.opacity = "0.15";

    setTimeout(() => {
      // Land: adopt the new position, redraw canonically, and drop the journey
      // transforms in the same frame so nothing animates back.
      pos += delta;
      centre.style.transition = "none";
      centre.style.transform = "";
      centre.style.opacity = "";
      settleRows();
      renderAll();
      ride.classList.remove("is-shuffling");

      requestAnimationFrame(() => requestAnimationFrame(() => {
        centre.style.transition = "";
        releaseRows();
        busy = false;
      }));
    }, SHUFFLE_MS);
  }

  function step(delta) {
    shuffle(delta);
  }

  // Up/down changes axis and carries the position with it, so the centre really
  // does change -- the post view keeps its centre because the post IS the thing
  // being sorted; here the axes hold different images.
  //
  // One entry point, and the new axis is set inside the swap's callback. An
  // earlier version assigned it straight after calling the animated move, which
  // raced: the callback then overwrote it a quarter-second later with the value
  // it had captured.
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
      settleRows();
      renderAll();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        ride.classList.remove(inClass);
        releaseRows();
        busy = false;
      }));
    }, NAV_MS);
  }

  function shiftAxis(delta) {
    goToAxis(((axis + delta) % cats.length + cats.length) % cats.length, delta);
  }

  function selectAxis(a) {
    goToAxis(a, a > axis ? 1 : -1);
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
    const row = e.target.closest(".mod-sortrow");
    if (row && ride.contains(row)) {
      e.preventDefault();
      const a = Number(row.dataset.a);
      // The post view's rule: the active row navigates, any other selects.
      if (a === axis) step(row.dataset.side === "next" ? 1 : -1);
      else selectAxis(a);
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
