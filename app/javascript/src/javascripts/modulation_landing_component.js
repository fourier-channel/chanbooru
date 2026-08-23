// The landing carousel.
//
// Auto-advances within a category, then moves on to the next one, so a visitor
// who does nothing still sees all three. Any manual interaction stops it -- the
// point of touching the arrows is to look at something, and a carousel that
// slides out from under you while you are reading is worse than one that never
// moved. Stopping is therefore permanent until the reader asks for it back,
// which is what the resume control is for.

function initLanding(root) {
  if (root.dataset.modlandBooted) return;
  root.dataset.modlandBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const region = (name) => root.querySelector(`[data-region="${name}"]`);
  const slidesEl = region("slides");
  if (!slidesEl) return;

  const cats = (cfg.categories || []).map((c) => c.key);
  let catIndex = 0;
  let index = 0;
  let advanceTimer = null;
  let resumeTimer = null;
  let paused = false;

  const inCategory = () =>
    Array.from(slidesEl.querySelectorAll(`[data-slide][data-cat="${cats[catIndex]}"]`));

  // A blacklisted slide is skipped rather than shown-and-hidden: the blacklist
  // hides by removing from layout, which in a fixed-height stage is a blank
  // frame holding for six seconds with no explanation.
  const visible = () => inCategory().filter((el) => !el.classList.contains("blacklisted-active"));

  function paintCredit(slide) {
    const el = region("credit");
    if (!el) return;

    const creator = slide && slide.dataset.creator;
    const platform = slide && slide.dataset.platform;
    if (!creator && !platform) { el.innerHTML = ""; el.hidden = true; return; }

    el.hidden = false;
    const parts = [];
    if (creator) parts.push(`Created by <span class="modland-credit-creator">${creator}</span>`);
    // The platform slug rides on a data attribute so a per-site logo can be
    // hung off it in CSS later without this string becoming an identifier.
    if (platform) {
      const key = slide.dataset.platformKey || "";
      parts.push(`posted on <span class="modland-credit-platform" data-platform="${key}">${platform}</span>`);
    }
    el.innerHTML = `${parts.join(" and ")}.`;
  }

  function paint() {
    const slides = visible();
    if (!slides.length) return;
    index = ((index % slides.length) + slides.length) % slides.length;

    slidesEl.querySelectorAll("[data-slide]").forEach((el) => el.classList.remove("is-active"));
    slides[index].classList.add("is-active");
    paintCredit(slides[index]);

    root.querySelectorAll("[data-act='tab']").forEach((tab) => {
      const on = tab.dataset.cat === cats[catIndex];
      tab.classList.toggle("is-active", on);
      tab.setAttribute("aria-selected", String(on));
    });
    positionThumb();
  }

  // The sliding highlight behind the active segment.
  function positionThumb() {
    const thumb = region("thumb");
    const active = root.querySelector("[data-act='tab'].is-active");
    if (!thumb || !active) return;
    thumb.style.width = `${active.offsetWidth}px`;
    thumb.style.transform = `translateX(${active.offsetLeft}px)`;
  }

  // Forward one slide; at the end of a category, move to the next one. This is
  // the only place categories advance on their own.
  function advance() {
    const slides = visible();
    if (index + 1 < slides.length) {
      index += 1;
    } else {
      catIndex = (catIndex + 1) % Math.max(cats.length, 1);
      index = 0;
    }
    paint();
  }

  function startTimer() {
    stopTimer();
    advanceTimer = setInterval(advance, cfg.advanceMs || 6000);
  }

  function stopTimer() {
    if (advanceTimer) { clearInterval(advanceTimer); advanceTimer = null; }
  }

  // --- pausing and resuming ----------------------------------------------

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
    // Restart the fill animation from zero. Removing the class and forcing a
    // reflow is what makes it replay when the reader interacts again mid-fill;
    // without the reflow the browser coalesces the change and nothing happens.
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

  // A lurch backwards, then forward into the next slide. The backward nudge is
  // what makes the restart feel deliberate rather than like the page twitching:
  // it signals "picking up where we left off" before it moves on.
  function resume() {
    hideResume();
    paused = false;

    const stage = region("stage");
    if (stage) {
      stage.classList.add("is-lurching");
      setTimeout(() => {
        stage.classList.remove("is-lurching");
        advance();
        startTimer();
      }, 260);
    } else {
      advance();
      startTimer();
    }
  }

  // --- interaction --------------------------------------------------------

  function step(delta) {
    const slides = visible();
    if (!slides.length) return;
    index += delta;
    if (index >= slides.length) { catIndex = (catIndex + 1) % cats.length; index = 0; }
    if (index < 0) { catIndex = (catIndex - 1 + cats.length) % cats.length; index = Math.max(visible().length - 1, 0); }
    paint();
  }

  root.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]");
    if (!act) return;

    if (act.dataset.act === "resume") { e.preventDefault(); resume(); return; }

    // Everything else here is the reader taking over.
    if (act.dataset.act === "next") { e.preventDefault(); step(1); pause(); }
    else if (act.dataset.act === "prev") { e.preventDefault(); step(-1); pause(); }
    else if (act.dataset.act === "tab") {
      e.preventDefault();
      const i = cats.indexOf(act.dataset.cat);
      if (i >= 0) { catIndex = i; index = 0; paint(); pause(); }
    }
  });

  // Left/right move the carousel, the same keys that move post-to-post in the
  // Modulation post view. Same guard as there: a key pressed while typing
  // belongs to the field, not to the page.
  //
  // Only left and right. Up and down scroll the page here -- the post view
  // binds them because it has a second axis to move along, and this does not.
  //
  // Counts as taking over, exactly as clicking an arrow does. Reaching for the
  // keyboard is the same intent as reaching for the arrow, and it would be
  // strange for one to stop the ride and the other not to.
  window.addEventListener("keydown", (e) => {
    if (e.target.closest("input, textarea, select, [contenteditable]")) return;
    if (e.key === "ArrowLeft") { step(-1); pause(); }
    else if (e.key === "ArrowRight") { step(1); pause(); }
  });

  // Keep the segment highlight aligned when the row reflows.
  window.addEventListener("resize", positionThumb);

  paint();
  startTimer();
}

function initAll() {
  document.querySelectorAll("[data-modland]").forEach(initLanding);
}

$(document).ready(initAll);

export default { initAll };
