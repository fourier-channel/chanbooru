// The gallery hover tag panel: rest the pointer on a card and that post's
// tag panel pops up beside it, grouped and coloured by category. Auto-loaded
// by the src/javascripts require.context glob; boots only where the grid is.
//
// Display comes from data-tags INTERSECTED with the server's category map
// (data-tag-categories on the grid). The map is the display gate: a tag the
// server left out of it -- a banished name -- is matching data for the
// blacklist and nothing else, so the client skips it rather than defaulting
// it into view.

const ORDER = ["artist", "copyright", "character", "general", "meta"];
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function boot() {
  const grid = document.querySelector(".modgal-grid[data-tag-categories]");
  if (!grid || grid.dataset.tagpopBooted) {
    return;
  }
  grid.dataset.tagpopBooted = "1";

  let cats = {};
  let counts = {};
  try {
    cats = JSON.parse(grid.dataset.tagCategories || "{}");
    // Counts are OPTIONAL: an older cached page has no data-tag-counts, and a
    // pill with no number is better than no panel at all.
    counts = JSON.parse(grid.dataset.tagCounts || "{}");
  } catch {
    return;
  }

  // " 1234" -- a space then the number, inside the pill, to the right of the
  // name (operator ruling 2026-09-07). Rendered as its own span so it can be
  // dimmed without touching the name, and omitted entirely when the count is
  // unknown rather than printed as a zero that would read as "no posts".
  const countOf = (tag) => {
    const n = counts[tag];
    return typeof n === "number" && n > 0 ? ` <span class="mod-pill-count">${n.toLocaleString()}</span>` : "";
  };

  const pop = document.createElement("div");
  pop.className = "modgal-tagpop";
  pop.hidden = true;
  // Inside .modgal, not <body>: the category pill classes are scoped there.
  (grid.closest(".modgal") || document.body).appendChild(pop);

  let timer = null;
  let current = null;
  let raf = null;

  // How long the pointer must REST on one card before its tags appear
  // (operator ruling 2026-09-07). Long enough that sweeping across the grid
  // shows nothing at all, which is the point: the panel used to flash open
  // after 180ms on every card the cursor crossed.
  const DWELL_MS = 2000;

  // The bar that fills while you wait. It is driven by the CLOCK, from
  // requestAnimationFrame, not by a CSS animation -- so it shows the real
  // progress of the real wait. If the tab is throttled and the wait actually
  // takes longer, the bar is slower too, because it is reading the same
  // elapsed time the decision reads. A bar that always takes two seconds to
  // fill regardless would be a picture of a wait rather than the wait.
  const meter = document.createElement("div");
  meter.className = "modgal-tagpop-meter";
  meter.hidden = true;
  meter.innerHTML = '<i></i>';
  (grid.closest(".modgal") || document.body).appendChild(meter);

  function stopMeter() {
    if (raf) {
      cancelAnimationFrame(raf);
      raf = null;
    }
    meter.hidden = true;
  }

  // Sit the meter along the bottom edge of the card being waited on, so the
  // progress belongs visibly to THAT card rather than floating near the
  // cursor.
  function startMeter(card) {
    const r = card.getBoundingClientRect();
    meter.style.left = `${Math.round(r.left)}px`;
    meter.style.top = `${Math.round(r.bottom - 3)}px`;
    meter.style.width = `${Math.round(r.width)}px`;
    meter.hidden = false;
    const fill = meter.firstElementChild;
    fill.style.width = "0%";
    const started = performance.now();
    const step = (now) => {
      const p = Math.min(1, (now - started) / DWELL_MS);
      fill.style.width = `${(p * 100).toFixed(1)}%`;
      if (p < 1) {
        raf = requestAnimationFrame(step);
        return;
      }
      raf = null;
      stopMeter();
      show(card);
    };
    raf = requestAnimationFrame(step);
  }

  function show(card) {
    const groups = {};
    (card.getAttribute("data-tags") || "").split(/\s+/).forEach((tag) => {
      const key = cats[tag];
      if (!key) {
        return;
      }
      (groups[key] ||= []).push(tag);
    });
    const html = ORDER.filter((key) => groups[key]).map((key) =>
      `<div class="modgal-tagpop-group"><span class="modgal-tagpop-label">${key}</span><div class="modgal-tagpop-pills">` +
      groups[key].map((tag) => `<span class="mod-pill mod-pill--cat-${key}"><span class="mod-pill-dot"></span>${esc(tag.replace(/_/g, " "))}${countOf(tag)}</span>`).join("") +
      "</div></div>").join("");
    if (!html) {
      return;
    }

    pop.innerHTML = html;
    pop.hidden = false;
    const rect = card.getBoundingClientRect();
    const pw = pop.offsetWidth;
    const ph = pop.offsetHeight;
    let x = rect.right + 10;
    let y = rect.top;
    if (x + pw > window.innerWidth - 8) {
      x = rect.left - pw - 10;
    }
    if (x < 8) {
      x = Math.min(rect.left, window.innerWidth - pw - 8);
      y = rect.bottom + 10;
    }
    y = Math.max(8, Math.min(y, window.innerHeight - ph - 8));
    pop.style.left = `${Math.round(x)}px`;
    pop.style.top = `${Math.round(y)}px`;
  }

  function hide() {
    clearTimeout(timer);
    stopMeter();
    current = null;
    pop.hidden = true;
  }

  grid.addEventListener("mouseover", (e) => {
    const card = e.target.closest(".modgal-card");
    if (!card || card === current) {
      return;
    }
    // Moving to a different card abandons the previous wait entirely: the
    // dwell has to be spent on ONE card, not accumulated across the grid.
    current = card;
    clearTimeout(timer);
    stopMeter();
    pop.hidden = true;
    startMeter(card);
  });

  grid.addEventListener("mouseout", (e) => {
    const card = e.target.closest(".modgal-card");
    if (!card || (e.relatedTarget && card.contains(e.relatedTarget))) {
      return;
    }
    hide();
  });

  window.addEventListener("scroll", hide, { passive: true });
}

$(document).ready(boot);

export default { boot };
