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
  try {
    cats = JSON.parse(grid.dataset.tagCategories || "{}");
  } catch {
    return;
  }

  const pop = document.createElement("div");
  pop.className = "modgal-tagpop";
  pop.hidden = true;
  // Inside .modgal, not <body>: the category pill classes are scoped there.
  (grid.closest(".modgal") || document.body).appendChild(pop);

  let timer = null;
  let current = null;

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
      groups[key].map((tag) => `<span class="mod-pill mod-pill--cat-${key}"><span class="mod-pill-dot"></span>${esc(tag.replace(/_/g, " "))}</span>`).join("") +
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
    current = null;
    pop.hidden = true;
  }

  grid.addEventListener("mouseover", (e) => {
    const card = e.target.closest(".modgal-card");
    if (!card || card === current) {
      return;
    }
    current = card;
    clearTimeout(timer);
    timer = setTimeout(() => show(card), 180);
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
