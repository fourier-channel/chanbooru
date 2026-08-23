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

  // --- rendering ----------------------------------------------------------

  function frameHTML(slide) {
    if (!slide || !slide.src) return '<div class="mod-frame mod-image mod-image--placeholder">nothing here</div>';
    return `<div class="mod-frame"><img class="mod-image" src="${esc(slide.src)}" alt=""></div>`;
  }

  function renderCentre() {
    const slide = at(axis, pos);
    region("center").innerHTML = frameHTML(slide);
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

  function rowHTML(a, side) {
    const slide = at(a, side === "prev" ? pos - 1 : pos + 1);
    const label = cats[a].label;
    const inner = slide && slide.src
      ? `<img src="${esc(slide.src)}" alt="" loading="lazy">`
      : '<span class="fill"></span>';
    const empty = slide ? "" : " is-empty";
    return `<a class="mod-sortrow${empty}" data-a="${a}" data-side="${side}" href="${esc((slide && slide.url) || "#")}" title="${esc(label)}">` +
      `${inner}<span class="mod-sortrow-tag">${esc(label)}</span></a>`;
  }

  function renderFlanks() {
    region("flank-prev").innerHTML = cats.map((_, a) => rowHTML(a, "prev")).join("");
    region("flank-next").innerHTML = cats.map((_, a) => rowHTML(a, "next")).join("");
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

  function renderAll() { renderCentre(); renderFlanks(); renderTabs(); }

  // --- movement -----------------------------------------------------------

  // Nothing is allowed to paint before its picture is ready.
  //
  // The old swap replaced the centre's markup and let the browser fetch: for a
  // frame or two that left an empty panel, then a picture appearing inside it.
  // The incoming image is already on screen in the flank, so it is normally in
  // cache and this resolves immediately; the timeout is for the case where it
  // is not, and a late slide is better than a blank one.
  function ready(src) {
    if (!src) return Promise.resolve();
    return new Promise((resolve) => {
      const img = new Image();
      const done = () => resolve();
      img.onload = () => (img.decode ? img.decode().then(done, done) : done());
      img.onerror = done;
      img.src = src;
      setTimeout(done, 600);
    });
  }

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
  function shuffle(delta) {
    if (busy) return;
    const incoming = at(axis, pos + delta);
    const inSide = delta > 0 ? "next" : "prev";
    const outSide = delta > 0 ? "prev" : "next";

    const centre = region("center");
    const inRow = ride.querySelector(`.mod-flank-col--${inSide} .mod-sortrow.is-current`);
    const outRow = ride.querySelector(`.mod-flank-col--${outSide} .mod-sortrow.is-current`);

    // No flank to move from (a single-slide axis): fall back to a plain swap.
    if (!inRow || !centre) { pos += delta; renderAll(); return; }

    busy = true;

    ready(incoming && incoming.src).then(() => {
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
        // Land: adopt the new position, redraw canonically, and drop the
        // journey transforms in the same frame so nothing animates back.
        pos += delta;
        centre.style.transition = "none";
        centre.style.transform = "";
        centre.style.opacity = "";
        renderAll();
        ride.classList.remove("is-shuffling");

        requestAnimationFrame(() => requestAnimationFrame(() => {
          centre.style.transition = "";
          busy = false;
        }));
      }, SHUFFLE_MS);
    });
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

    const incoming = at(target, pos);
    const outClass = direction > 0 ? "is-axis-down" : "is-axis-up";
    const inClass = direction > 0 ? "is-enter-down" : "is-enter-up";

    // Same rule as the shuffle: never paint a panel before its picture is ready.
    ready(incoming && incoming.src).then(() => {
      ride.classList.add(outClass);
      setTimeout(() => {
        axis = target;
        ride.classList.remove(outClass);
        ride.classList.add(inClass);
        renderAll();
        requestAnimationFrame(() => requestAnimationFrame(() => {
          ride.classList.remove(inClass);
          busy = false;
        }));
      }, NAV_MS);
    });
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
