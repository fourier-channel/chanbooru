// The landing showcase: advances slides on a timer, and periodically replaces
// the whole set with a fresh shuffle so a page left open does not settle into a
// fixed poster.

function initLanding(root) {
  if (root.dataset.modlandBooted) return;
  root.dataset.modlandBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const slidesEl = root.querySelector('[data-region="slides"]');
  const dotsEl = root.querySelector('[data-region="dots"]');
  if (!slidesEl) return;

  let index = 0;
  let advanceTimer = null;

  const allSlides = () => Array.from(slidesEl.querySelectorAll("[data-slide]"));

  // A blacklisted slide is skipped rather than shown-and-hidden: the blacklist
  // hides by removing from layout, which in a fixed-height stage would be a
  // blank frame with no explanation for the several seconds it holds.
  const visibleSlides = () =>
    allSlides().filter((el) => !el.classList.contains("blacklisted-active"));

  function paint() {
    const slides = visibleSlides();
    if (!slides.length) return;
    index = ((index % slides.length) + slides.length) % slides.length;

    allSlides().forEach((el) => el.classList.remove("is-active"));
    slides[index].classList.add("is-active");

    if (dotsEl) {
      dotsEl.innerHTML = slides
        .map((_, i) => `<span class="modland-dot${i === index ? " is-active" : ""}"></span>`)
        .join("");
    }
  }

  function advance() {
    index += 1;
    paint();
  }

  function restartTimer() {
    if (advanceTimer) clearInterval(advanceTimer);
    advanceTimer = setInterval(advance, cfg.advanceMs || 6000);
  }

  function slideMarkup(s) {
    const el = document.createElement("a");
    el.className = "modland-slide";
    el.href = s.url;
    el.setAttribute("data-slide", "");
    // Same blacklist contract as the gallery cards, so the viewer's own rules
    // apply to a freshly fetched set exactly as they did to the first one.
    el.setAttribute("data-id", s.id);
    el.setAttribute("data-tags", s.tags || "");
    el.setAttribute("data-rating", s.rating || "");
    el.setAttribute("data-flags", s.flags || "");
    el.setAttribute("data-score", s.score == null ? "" : s.score);
    el.setAttribute("data-uploader-id", s.uploader_id == null ? "" : s.uploader_id);

    const img = document.createElement("img");
    img.className = "modland-slide-img";
    img.src = s.src;
    img.alt = "";
    img.loading = "lazy";

    const tag = document.createElement("span");
    tag.className = "modland-slide-tag";
    tag.textContent = s.label || "";

    el.appendChild(img);
    el.appendChild(tag);
    return el;
  }

  function refresh() {
    fetch(cfg.slidesUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (!data || !Array.isArray(data.slides) || !data.slides.length) return;
        slidesEl.innerHTML = "";
        data.slides.forEach((s) => slidesEl.appendChild(slideMarkup(s)));
        // Re-run the blacklist over the new markup. Without this a freshly
        // fetched set arrives unfiltered, which is the one outcome a blacklist
        // must never have. Re-initialising with the rules it already holds is
        // how it rebuilds its element list from the selector; per-rule toggles
        // live in localStorage, so they survive.
        const box = document.querySelector("#blacklist-box");
        if (box && box.blacklist) {
          box.blacklist.initialize(box.blacklist.rules.map((rule) => rule.string));
        }
        index = 0;
        paint();
        restartTimer();
      })
      // A failed refresh leaves the set that is already on screen.
      .catch(() => {});
  }

  paint();
  restartTimer();
  if (cfg.refreshMs) setInterval(refresh, cfg.refreshMs);
}

function initAll() {
  document.querySelectorAll("[data-modland]").forEach(initLanding);
}

$(document).ready(initAll);

export default { initAll };
