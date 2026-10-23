import Landing from "./modulation_landing_component";
import {
  BLANK_MINI, HERO_MAX, HERO_MIN, MIN_W, MINI_EFFECTS, MINI_MAX, DIRS, ROW_H,
  adderRow, bandRule, layoutOf, miniLook, miniRole, problemsOf, rowsOf, ruleSentence, slotCount, tagsOf,
} from "./creator_gallery_model";

// THE CREATOR GALLERY's page (CreatorGalleryComponent): the ground's parallax,
// the minibands' cycles and the panels that descend from the header, for
// every viewer; and on the edit page, the editor -- the same page with
// options on everything, working on a draft of the look and the bands' posts
// that Save sends in one PATCH. The rules it previews are
// creator_gallery_model.js, the server's own sentences.
//
// The hero band is the landing page's belt (modulation_landing_component.js);
// the editor redraws it in place through that module's destroy and init.

const label = (name) => name.replaceAll("_", " ");

// The banner's picture: the sample for an image, the preview for anything
// else (CreatorGalleryComponent#picture). A slide with no small variant has
// only its src (LandingShowcase#thumb_url).
const picture = (slide) => (slide.kind === "image" ? slide.src : slide.thumb || slide.src);

const pillClass = (category) => {
  if (["artist", "copyright", "character"].includes(category)) { return `mod-pill mod-pill--cat mod-pill--cat-${category}`; }
  return category === "meta" ? "mod-pill mod-pill--meta" : "mod-pill mod-pill--unsourced";
};

// What the blacklist matches a post on (CreatorGalleryComponent#marks), as
// attributes for el().
const marks = (slide) => ({
  "data-id": slide.id, "data-tags": slide.tags, "data-rating": slide.rating,
  "data-flags": slide.flags, "data-score": slide.score, "data-uploader-id": slide.uploader_id,
});

// An element: attributes by name (true for a bare one; false, null and
// undefined leave it off), then its children, strings as text.
function el(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  Object.entries(attrs).filter(([, v]) => v !== false && v !== null && v !== undefined)
    .forEach(([k, v]) => node.setAttribute(k, v === true ? "" : String(v)));
  node.append(...kids);
  return node;
}

const pill = (tag, ...extra) => el("span", { class: pillClass(tag.category) },
  el("span", { class: "mod-pill-dot" }), el("span", { class: "mod-pill-label" }, label(tag.name)), ...extra);

// A control is known across a redraw by what it does and to what.
const FOCUS_KEYS = ["data-cg-act", "data-cg-field", "data-i", "data-id", "data-v"];
const focusKey = (node) => (FOCUS_KEYS.some((k) => node.hasAttribute(k)) ? FOCUS_KEYS.map((k) => node.getAttribute(k)).join("|") : null);

// Every post the page draws is an element the blacklist can mark: a region
// redrawn hands the engine what arrived and what left (Blacklist#adopt). The
// control that had focus has it again in the new nodes, or a keyboard user
// is thrown back to the top of the page after every pick.
function fill(region, ...nodes) {
  const removed = Array.from(region.querySelectorAll(".mod-blacklist-target, .modland-poolitem"));
  const focused = region.contains(document.activeElement) ? focusKey(document.activeElement) : null;
  region.replaceChildren(...nodes);
  if (focused) { Array.from(region.querySelectorAll("a, button, input, select")).find((node) => focusKey(node) === focused)?.focus({ preventScroll: true }); }
  const added = Array.from(region.querySelectorAll(".mod-blacklist-target, .modland-poolitem"));
  const engine = document.querySelector("#blacklist-box")?.blacklist;
  if (engine && (added.length || removed.length)) { engine.adopt(added, removed); }
}

// The belt's rows, as CreatorGalleryComponent#hero_categories draws them:
// every post, then one row per character on at least one of them.
function heroCategories(tags, list) {
  const rows = tags.filter((t) => t.category === "character")
    .map((t) => ({ key: `c-${t.name}`, label: label(t.name), slides: list.filter((s) => tagsOf(s).includes(t.name)) }));
  return [{ key: "all", label: "All", slides: list }, ...rows].filter((row) => row.slides.length);
}

// --- one miniband's cycle ----------------------------------------------
//
// One setTimeout chain: a step, then -- once its transition is over -- the
// settle that puts the post that left back where the next arrival enters
// from, then the hold. Held while the pointer is on it or the page is hidden,
// and nothing moves on its own for a reader who asked for less motion: the
// arrows step it. A post the blacklist marked is passed over.
const TRANSIT_MS = 1300;

function cycleMini(mini, reduced) {
  const life = new AbortController();
  const all = () => Array.from(mini.querySelectorAll(".modcreator-mini-item"));
  const shown = () => all().filter((item) => !item.classList.contains("blacklisted-active"));
  let pos = 0;
  let settled = true;
  let hovered = false;
  let timer = null;

  function paint() {
    const list = shown();
    const { effect, dir } = mini.dataset;
    const hold = Number(mini.dataset.hold);
    list.forEach((item, j) => {
      const look = miniLook(effect, dir, miniRole(j, list.length, pos, settled), hold);
      item.style.transform = look.tf;
      item.style.opacity = String(look.op);
      item.style.transition = reduced ? "none" : look.tr;
      item.style.zIndex = String(look.z);
    });
    const cur = list.length ? all().indexOf(list[((pos % list.length) + list.length) % list.length]) : -1;
    mini.querySelectorAll(".modcreator-mini-dot").forEach((dot, j) => dot.classList.toggle("is-on", j === cur));
  }

  function tick() {
    timer = null;
    if (!settled) {
      settled = true;
      paint();
      timer = setTimeout(tick, Math.max(0, (Number(mini.dataset.hold) * 1000) - TRANSIT_MS));
      return;
    }
    // Held: the mouse leaving or the page coming back starts it again.
    if (hovered || document.hidden || shown().length < 2) { return; }
    pos += 1;
    settled = false;
    paint();
    timer = setTimeout(tick, TRANSIT_MS);
  }

  function resume() {
    if (!reduced && !timer) { timer = setTimeout(tick, Number(mini.dataset.hold) * 1000); }
  }

  // A mouse only: a tap is a pointerenter with no leave until the next tap
  // elsewhere, and would hold the band that long.
  mini.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") { hovered = true; } }, { signal: life.signal });
  mini.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") { hovered = false; resume(); } }, { signal: life.signal });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { resume(); } }, { signal: life.signal });
  // The blacklist can bring back a second post to a band that had stopped.
  document.addEventListener("danbooru:blacklist-applied", () => { paint(); resume(); }, { signal: life.signal });
  mini.addEventListener("click", (e) => {
    const act = e.target.closest("[data-cg-act='mini-step']");
    if (!act) { return; }
    pos += Number(act.dataset.v);
    settled = true;
    paint();
  }, { signal: life.signal });

  paint();
  resume();
  return () => { life.abort(); clearTimeout(timer); };
}

// --- the ground's parallax -----------------------------------------------
//
// One pointer listener for the page, its writes one per frame, and only to
// the layers that move ([data-cg-depth], each clipped): --px/--py from -1 to
// 1, scaled in the stylesheet by the creator's --cg-par.
function parallax(root) {
  const layers = root.querySelectorAll("[data-cg-depth]");
  let frame = 0;
  let x = 0;
  let y = 0;
  window.addEventListener("pointermove", (e) => {
    x = ((e.clientX / window.innerWidth) * 2) - 1;
    y = ((e.clientY / window.innerHeight) * 2) - 1;
    if (frame) { return; }
    frame = requestAnimationFrame(() => {
      frame = 0;
      layers.forEach((layer) => {
        layer.style.setProperty("--px", x.toFixed(3));
        layer.style.setProperty("--py", y.toFixed(3));
      });
    });
  }, { passive: true });
}

// --- the editor ----------------------------------------------------------

function editor(root, data, bindMinis) {
  const region = (name) => root.querySelector(`[data-cg-region="${name}"]`);
  const modland = root.querySelector("[data-modland]");
  const beltConfig = JSON.parse(modland.dataset.config);
  const layers = Array.from(root.querySelectorAll("[data-cg-depth]"));

  const known = new Map(data.slides.map((s) => [s.id, s]));
  const slideOf = (id) => known.get(id);
  const palette = new Map(data.palette.map((t) => [t.name, t]));
  const categoryOf = (name) => palette.get(name)?.category || "general";

  // What Save compares and sends: the minibands past the layout's count are
  // kept while editing, so a layout switched back keeps them, and are not
  // the page's.
  const payload = (d) => JSON.stringify({ ...d, minis: d.minis.slice(0, slotCount(d.layout)) });
  const draft = structuredClone(data.draft);
  let savedPayload = payload(draft);
  let serverProblems = [];
  let saving = false;
  let leaving = false;
  let openMini = -1;
  let toastTimer = 0;

  function toast(text) {
    const box = region("toast");
    box.textContent = text;
    box.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { box.hidden = true; }, 6000);
  }

  // The candidates for a band's tags (edit.json, CreatorGalleryLayout#candidates),
  // asked once per set of tags; `loaded` holds the answers by their key.
  const loaded = new Map();
  const asked = new Map();
  function candidates(tags) {
    const key = tags.join(" ");
    if (!asked.has(key)) {
      asked.set(key, fetch(`${data.candidatesUrl}?tags=${encodeURIComponent(key)}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
        .then((r) => {
          if (!r.ok) { throw new Error(`HTTP ${r.status}`); }
          return r.json();
        })
        .then((answer) => {
          answer.slides.forEach((s) => known.set(s.id, s));
          loaded.set(key, answer);
          return answer;
        })
        .catch((e) => {
          asked.delete(key);
          toast(`Could not load the posts ${key ? `tagged ${label(key)}` : "for the banner"} (${e.message}). Open the picker again to retry.`);
          return null;
        }));
    }
    return asked.get(key);
  }

  // The hero's candidates are asked for its generals alone (with none, for
  // its characters), so adderRow can say exactly what a new tag would do;
  // the band's own are those that fit all its tags.
  const heroKey = () => {
    const { g, c } = bandRule(draft.hero.tags);
    return g.length ? g : c;
  };
  const heroBase = () => loaded.get(heroKey().join(" "));
  // The answer is the newest posts only, or leaves out some the curator may not see.
  const cappedOf = (answer) => answer.total > answer.slides.length;
  const chosenSlides = (posts) => posts.map(slideOf).filter(Boolean);

  // --- what Save waits on ---
  function report() {
    const problems = [...new Set([...serverProblems, ...problemsOf(draft, slideOf)])];
    const dirty = payload(draft) !== savedPayload;
    const button = region("problems-btn");
    button.hidden = !problems.length;
    button.textContent = `${problems.length} to fix`;
    if (!problems.length) { region("problems").hidden = true; }
    button.setAttribute("aria-expanded", String(!region("problems").hidden));
    region("problems-list").replaceChildren(el("ul", {}, ...problems.map((p) => el("li", {}, p))));
    region("dirty").textContent = saving ? "saving" : dirty ? "unsaved changes" : "saved";
    root.querySelector("[data-cg-act='save']").disabled = saving || !dirty || problems.length > 0;
    root.querySelector("[data-cg-act='discard']").disabled = saving || !dirty;
  }

  function changed() {
    serverProblems = [];
    report();
  }

  // --- the hero band ---
  function rebuildBelt() {
    const hero = draft.hero;
    const list = chosenSlides(hero.posts);
    const categories = heroCategories(hero.tags, list);
    Landing.destroy(modland);
    modland.dataset.config = JSON.stringify({
      ...beltConfig, categories, advanceMs: hero.hold * 1000, direction: hero.dir === "left" ? 1 : -1, cells: hero.cells, effect: hero.effect,
    });
    const tabs = modland.querySelector(".modland-tabs");
    tabs.replaceChildren(tabs.querySelector("[data-region='thumb']"), ...categories.map((c, i) => el("button", {
      type: "button", role: "tab", class: i ? "modland-tab" : "modland-tab is-active", "data-act": "axis", "data-cat": c.key, "aria-selected": String(!i),
    }, c.label)));
    // The pool is marked before the belt boots, so its first draw skips what
    // the blacklist hides.
    fill(modland.querySelector(".modland-pool"), ...list.map((s) => el("span", { class: "modland-poolitem", "data-slide": true, "data-cat": "all", ...marks(s) })));
    modland.hidden = !categories.length;
    region("hero-empty").hidden = categories.length > 0;
    region("hero-empty").textContent = hero.tags.length ?
      "No posts in the band yet. Open Posts below and pick from the candidates." :
      "Start with the tags. Add them above and the band's candidates appear.";
    Landing.init(modland);
  }

  function renderChips() {
    const chosen = chosenSlides(draft.hero.posts);
    const adderOpen = !region("adder").hidden;
    fill(region("chips"), ...draft.hero.tags.map((t) => {
      const n = chosen.filter((s) => tagsOf(s).includes(t.name)).length;
      return pill(t,
        el("span", { class: n ? "modcreator-chip-count" : "modcreator-chip-count is-none", title: `On ${n} of the band's posts` }, String(n)),
        el("button", { type: "button", class: "modcreator-chip-x", "data-cg-act": "untag", "data-v": t.name, "aria-label": `Take ${label(t.name)} off the band` }, "\u00d7"));
    }), el("button", { type: "button", class: "modcreator-add-tag", "data-cg-act": "adder", "aria-expanded": String(adderOpen) }, "+ Tag"));
    region("chips").querySelectorAll(".mod-pill").forEach((chip) => chip.classList.add("modcreator-chip"));
    root.querySelector(".modcreator-pills-row.modcreator-static").replaceChildren(...draft.hero.tags.map((t) => pill(t)));
  }

  function renderAdder() {
    if (region("adder").hidden) { return; }
    const base = heroBase();
    if (!base) {
      fill(region("adder-rows"), el("p", { class: "cg-note" }, "Finding your posts..."));
      return;
    }
    const query = root.querySelector("[data-cg-field='tag-query']").value.trim().toLowerCase().replaceAll(" ", "_");
    const on = new Set(draft.hero.tags.map((t) => t.name));
    const offered = data.palette.filter((t) => !on.has(t.name) && t.name.includes(query)).slice(0, 40);
    const chosen = chosenSlides(draft.hero.posts);
    fill(region("adder-rows"), ...offered.map((t) => {
      const row = adderRow(draft.hero.tags, t, { base: base.slides, count: t.count, chosen, capped: cappedOf(base) });
      return el("button", { type: "button", class: "modcreator-adder-row", "data-cg-act": "tag", "data-v": t.name, disabled: row.disabled },
        pill(t), el("span", { class: "modcreator-adder-kind" }, row.kind),
        el("span", { class: row.drops ? "modcreator-adder-note is-leaving" : "modcreator-adder-note" }, row.note));
    }), ...(offered.length ? [] : [el("p", { class: "cg-note" }, query ? `No tag on your posts matches ${query}.` : "Every tag on your posts is on the band.")]));
  }

  function renderRule() {
    const base = heroBase();
    const all = loaded.get("");
    const fitting = base ? base.slides.filter(bandRule(draft.hero.tags).ok).length : 0;
    region("rule").textContent = base && all ? ruleSentence(draft.hero.tags, fitting, all.total, cappedOf(base)) : ruleSentence(draft.hero.tags, "...", "...");
  }

  // A post to pick, marked for the blacklist like every other drawn post.
  const thumb = (slide, attrs, ...kids) => el("button", { type: "button", class: "cg-thumb mod-blacklist-target", title: `post #${slide.id}`, ...marks(slide), ...attrs },
    el("img", { src: slide.thumb || slide.src, alt: "", loading: "lazy", draggable: "false" }), ...kids);

  // A redraw keeps each list where it was scrolled, so a pick does not jump
  // the grid back to its top.
  function keepScroll(box, draw) {
    // Keyed by the miniband too: every miniband's list has the same class.
    const key = (list) => `${list.closest("[data-cg-mini]")?.dataset.cgMini ?? ""} ${list.className}`;
    const at = new Map([...box.querySelectorAll(".cg-scroll")].map((list) => [key(list), [list.scrollTop, list.scrollLeft]]));
    draw();
    box.querySelectorAll(".cg-scroll").forEach((list) => {
      [list.scrollTop, list.scrollLeft] = at.get(key(list)) || [0, 0];
    });
  }

  // `total` counts every eligible post; `slides` are the newest of them,
  // up to `cap`, that the curator may see (CreatorGalleryLayout#candidates).
  const capNote = (answer) => (cappedOf(answer)
    ? [el("p", { class: "cg-note" }, `${answer.slides.length} of ${answer.total} posts are shown: the newest ${answer.cap} at most, and only those you may see.`)] : []);

  function renderHeroPicker() {
    const box = region("hero-picker");
    const posts = draft.hero.posts;
    region("hero-posts").textContent = `Posts (${posts.length}/${HERO_MAX})`;
    region("hero-posts").setAttribute("aria-expanded", String(!box.hidden));
    if (box.hidden) { return; }
    const rule = bandRule(draft.hero.tags);
    const base = heroBase();
    const full = posts.length >= HERO_MAX;
    const strip = posts.map((id, i) => {
      const slide = slideOf(id);
      return el("div", { class: "modcreator-strip-item" },
        slide ? thumb(slide, { tabindex: "-1" }, el("span", { class: "cg-thumb-num" }, String(i + 1))) : el("span", { class: "cg-thumb" }, el("span", { class: "cg-thumb-cap" }, `#${id}`)),
        el("div", { class: "modcreator-strip-moves" },
          el("button", { type: "button", "data-cg-act": "hero-move", "data-id": id, "data-v": -1, disabled: i === 0, "aria-label": `Move post #${id} earlier` }, "\u2039"),
          el("button", { type: "button", "data-cg-act": "hero-pick", "data-id": id, "aria-label": `Take post #${id} off the band` }, "\u00d7"),
          el("button", { type: "button", "data-cg-act": "hero-move", "data-id": id, "data-v": 1, disabled: i === posts.length - 1, "aria-label": `Move post #${id} later` }, "\u203a")));
    });
    let grid = [el("p", { class: "cg-note" }, "Add tags to the band first. Its candidates are every post that fits them.")];
    if (draft.hero.tags.length && !base) {
      grid = [el("p", { class: "cg-note" }, "Finding the band's candidates...")];
    } else if (draft.hero.tags.length) {
      grid = [...capNote(base), el("div", { class: "modcreator-picker-grid cg-scroll" }, ...base.slides.filter(rule.ok).map((s) => {
        const at = posts.indexOf(s.id);
        const chars = rule.c.filter((c) => tagsOf(s).includes(c)).map(label).join(", ");
        return thumb(s, { "data-cg-act": "hero-pick", "aria-pressed": String(at >= 0), disabled: full && at < 0 },
          ...(at >= 0 ? [el("span", { class: "cg-thumb-num" }, String(at + 1))] : []),
          el("span", { class: "cg-thumb-cap" }, `#${s.id}`, ...(chars ? [el("br", {}), el("span", { class: "cg-thumb-chars" }, chars)] : [])));
      }))];
    }
    keepScroll(box, () => fill(box,
      el("div", { class: "modcreator-picker-head" },
        el("span", { class: "cg-label modcreator-picker-title" }, `The band's posts: ${posts.length}, from ${HERO_MIN} to ${HERO_MAX}, in this order`),
        el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hero-picker" }, "Done")),
      ...(posts.length ? [el("div", { class: "modcreator-picker-strip cg-scroll" }, ...strip)] : []),
      ...grid));
  }

  function loadHero() {
    renderAdder();
    renderHeroPicker();
    renderRule();
    candidates(heroKey()).then(() => {
      renderAdder();
      renderHeroPicker();
      renderRule();
    });
  }

  // Tags changed: the chosen posts that no longer fit leave, and say so.
  function retag(tags) {
    const rule = bandRule(tags);
    const gone = draft.hero.posts.filter((id) => slideOf(id) && !rule.ok(slideOf(id)));
    draft.hero.tags = tags;
    draft.hero.posts = draft.hero.posts.filter((id) => !gone.includes(id));
    if (gone.length) { toast(`${gone.length === 1 ? "1 post left" : `${gone.length} posts left`} the band: ${gone.map((id) => `#${id}`).join(", ")} no longer fit its tags.`); }
    renderChips();
    rebuildBelt();
    loadHero();
    changed();
  }

  // --- the minibands, drawn from the draft ---
  function miniSlot(i, n) {
    const mini = draft.minis[i];
    const list = chosenSlides(mini.posts);
    const tag = mini.tag ? { name: mini.tag, category: categoryOf(mini.tag) } : null;
    const answer = loaded.get(mini.tag);
    const options = mini.tag && !palette.has(mini.tag) ? [{ name: mini.tag, count: mini.posts.length }, ...data.palette] : data.palette;
    const picker = openMini === i && el("div", { class: "modcreator-mini-picker modcreator-edit-ui" },
      el("div", { class: "modcreator-mini-picker-head" },
        el("span", { class: "cg-label" }, tag ? `${label(tag.name)}: ${mini.posts.length} of ${MINI_MAX}` : "Pick a tag first"),
        el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "mini-picker", "data-i": i }, "Done")),
      ...(tag && answer ? capNote(answer) : []),
      el("div", { class: "modcreator-mini-picker-grid cg-scroll" }, ...(tag && answer ? [
        // A chosen post not among the candidates shown -- hidden from the
        // curator, or no longer a valid choice -- is its number, to take off.
        ...mini.posts.filter((id) => !answer.slides.some((s) => s.id === id)).map((id) => el("button", {
          type: "button", class: "cg-thumb", "data-cg-act": "mini-pick", "data-i": i, "data-id": id, "aria-pressed": "true", "aria-label": `Take post #${id} off the miniband`,
        }, el("span", { class: "cg-thumb-num" }, String(mini.posts.indexOf(id) + 1)), el("span", { class: "cg-thumb-cap" }, `#${id}`))),
        ...answer.slides.map((s) => {
          const at = mini.posts.indexOf(s.id);
          return thumb(s, { "data-cg-act": "mini-pick", "data-i": i, "aria-pressed": String(at >= 0), disabled: mini.posts.length >= MINI_MAX && at < 0 },
            ...(at >= 0 ? [el("span", { class: "cg-thumb-num" }, String(at + 1))] : []));
        }),
      ] : [el("p", { class: "cg-note" }, tag ? "Finding the posts..." : "This miniband shows one tag. Pick it above.")])));

    return el("div", {
      class: "modcreator-mini", "data-cg-mini": i, "data-effect": mini.effect, "data-dir": mini.dir, "data-hold": mini.hold,
      style: `--mini-h: ${ROW_H[n]}px; --mini-w: ${MIN_W[n]}px`,
    },
    ...list.map((s) => el("a", { class: "modcreator-mini-item modcreator-card mod-blacklist-target", href: s.url, title: `post #${s.id}`, ...marks(s) },
      el("img", { class: "modcreator-mini-img", src: picture(s), alt: "", loading: "lazy", draggable: "false" }))),
    ...(list.length ? [
      el("div", { class: "modcreator-mini-shade", "aria-hidden": "true" }),
      el("button", { type: "button", class: "modcreator-mini-arrow modcreator-mini-arrow--prev", "data-cg-act": "mini-step", "data-v": -1, "aria-label": "Previous post" }, "\u2039"),
      el("button", { type: "button", class: "modcreator-mini-arrow modcreator-mini-arrow--next", "data-cg-act": "mini-step", "data-v": 1, "aria-label": "Next post" }, "\u203a"),
    ] : [el("div", { class: "modcreator-mini-empty" }, tag ? "No posts yet. Open Posts below." : "Nothing here yet")]),
    ...(tag && list.length ? [el("div", { class: "modcreator-mini-label modcreator-static" }, pill(tag),
      el("span", { class: "modcreator-mini-dots", "aria-hidden": "true" }, ...list.map((_, j) => el("span", { class: j ? "modcreator-mini-dot" : "modcreator-mini-dot is-on" }))))] : []),
    el("div", { class: "modcreator-mini-top modcreator-edit-ui" },
      el("span", { class: "modcreator-mini-num" }, String(i + 1)),
      el("select", { class: "cg-select modcreator-mini-tag", "data-cg-field": "mini-tag", "data-i": i, "aria-label": `Miniband ${i + 1}'s tag` },
        el("option", { value: "" }, "Pick a tag"),
        ...options.map((t) => el("option", { value: t.name, selected: t.name === mini.tag }, `${label(t.name)} (${t.count})`))),
      el("select", { class: "cg-select", "data-cg-field": "mini-effect", "data-i": i, "aria-label": `Miniband ${i + 1}'s effect` },
        ...MINI_EFFECTS.map((fx) => el("option", { value: fx.v, selected: fx.v === mini.effect }, fx.label)))),
    el("div", { class: "modcreator-mini-bottom modcreator-edit-ui" },
      el("div", { class: "cg-seg", role: "group", "aria-label": "Direction" }, ...DIRS.map((d) => {
        const button = el("button", { type: "button", "data-cg-act": "mini-dir", "data-i": i, "data-v": d.v, "aria-pressed": String(d.v === mini.dir), "aria-label": d.label });
        // A constant glyph, the one the hero's direction buttons use.
        button.innerHTML = `<svg class="modcreator-arrow-${d.v}" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14M13 6l6 6-6 6"></path></svg>`;
        return button;
      })),
      el("label", { class: "modcreator-mini-hold" }, "Hold",
        el("input", { type: "range", min: 2, max: 12, value: mini.hold, "data-cg-field": "mini-hold", "data-i": i }),
        el("span", {}, `${mini.hold}s`)),
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "mini-picker", "data-i": i, "aria-expanded": String(openMini === i) }, `Posts (${mini.posts.length}/${MINI_MAX})`)),
    ...(picker ? [picker] : []));
  }

  function renderMinis() {
    keepScroll(region("minis"), () => fill(region("minis"), ...rowsOf(draft.layout).map((row) => el("div", { class: "modcreator-minis-row" }, ...row.map((i) => miniSlot(i, row.length))))));
    region("layout-name").textContent = layoutOf(draft.layout).label;
    bindMinis();
  }

  function loadMini(i) {
    const tag = draft.minis[i].tag;
    return tag ? candidates([tag]) : Promise.resolve(null);
  }

  // --- the look: banner, depth, layout ---
  function renderBanners() {
    const all = loaded.get("");
    fill(region("banners"),
      ...(all ? capNote(all) : []),
      el("button", { type: "button", class: "modcreator-banner-none", "data-cg-act": "banner", "aria-pressed": String(!draft.banner.post_id) }, "None"),
      ...(all ? all.slides.map((s) => thumb(s, { "data-cg-act": "banner", "aria-pressed": String(s.id === draft.banner.post_id) })) : [el("span", { class: "cg-note" }, "Finding your posts...")]));
  }

  function paintBanner() {
    const slide = draft.banner.post_id && slideOf(draft.banner.post_id);
    layers.forEach((layer) => {
      const kind = layer.classList.contains("modcreator-ground") ? "ground" : "banner";
      layer.querySelector(`.modcreator-${kind}-art`).replaceWith(slide ?
        el("img", { class: `modcreator-${kind}-art`, src: picture(slide), alt: "" }) :
        el("span", { class: `modcreator-${kind}-art modcreator-${kind}-art--none` }));
      Object.keys(marks({})).forEach((name) => layer.removeAttribute(name));
      layer.classList.remove("mod-blacklist-target", "blacklisted-active", "blacklisted-hidden");
      if (slide) {
        Object.entries(marks(slide)).forEach(([name, v]) => layer.setAttribute(name, String(v)));
        layer.classList.add("mod-blacklist-target");
      }
    });
    const engine = document.querySelector("#blacklist-box")?.blacklist;
    if (engine) { engine.adopt(slide ? layers : [], layers); }
  }

  // The look as the layers' CSS variables (CreatorGalleryComponent#depth_style).
  function paintDepth() {
    const { blur, dim, parallax: strength } = draft.depth;
    layers.forEach((layer) => {
      layer.style.setProperty("--cg-blur", `${blur}px`);
      layer.style.setProperty("--cg-dim", String(dim / 100));
      layer.style.setProperty("--cg-par", String(strength / 100));
      layer.style.setProperty("--cg-y", `${draft.banner.y}%`);
    });
  }

  const press = (act, v) => root.querySelectorAll(`[data-cg-act="${act}"]`).forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === String(v))));

  function toggleSheet(name) {
    root.querySelectorAll("[data-cg-sheet]").forEach((sheet) => { sheet.hidden = sheet.dataset.cgSheet !== name || !sheet.hidden; });
    root.querySelectorAll(".cg-seg [data-cg-act='sheet']").forEach((b) => {
      b.setAttribute("aria-pressed", String(!root.querySelector(`[data-cg-sheet="${b.dataset.v}"]`).hidden));
    });
    if (name === "page" && !root.querySelector("[data-cg-sheet='page']").hidden) { candidates([]).then(renderBanners); }
  }

  function toggleAdder(open) {
    region("adder").hidden = !open;
    root.querySelector(".modcreator-add-tag")?.setAttribute("aria-expanded", String(open));
    if (open) {
      loadHero();
      root.querySelector("[data-cg-field='tag-query']").focus();
    }
  }

  // --- Save and Discard ---
  async function save() {
    saving = true;
    report();
    // What was sent is what is saved: the draft can change while Save waits.
    const sent = payload(draft);
    const hero = { ...draft.hero, tags: draft.hero.tags.map((t) => t.name) };
    const body = {
      creator_gallery: { title: draft.title, bio: draft.bio, matrix_contact: draft.matrix_contact },
      layout: {
        headline: draft.headline, subline: draft.subline, banner: draft.banner, depth: draft.depth,
        hero, layout: draft.layout, minis: draft.minis.slice(0, slotCount(draft.layout)),
      },
    };
    try {
      const r = await fetch(data.saveUrl, {
        method: "PATCH",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" },
        body: JSON.stringify(body),
      });
      if (r.ok) {
        savedPayload = sent;
        toast("Saved. This is the page everyone sees from their next visit.");
      } else if (r.status === 422 && payload(draft) !== sent) {
        // The problems are the sent draft's, and it has changed since.
        toast("Nothing was saved, and the page has changed since. Save again to check it.");
      } else if (r.status === 422) {
        serverProblems = (await r.json()).problems;
        region("problems").hidden = false;
      } else {
        toast(`Save failed (HTTP ${r.status}); nothing was saved. Save again, and reload the page if it keeps failing.`);
      }
    } catch (e) {
      toast(`Save failed (${e.message}); nothing was saved. Check the connection and Save again.`);
    }
    saving = false;
    report();
  }

  // --- what the controls do ---
  root.addEventListener("click", (e) => {
    const act = e.target.closest("[data-cg-act]");
    if (!act || !root.contains(act)) { return; }
    const v = act.dataset.v;
    const id = Number(act.dataset.id);
    const i = Number(act.dataset.i);
    const mini = draft.minis[i];
    switch (act.dataset.cgAct) {
    case "sheet": toggleSheet(v); break;
    case "preview": {
      const on = root.classList.toggle("is-preview");
      act.setAttribute("aria-pressed", String(on));
      region("preview-label").textContent = on ? "Show controls" : "Hide controls";
      break;
    }
    case "problems": {
      region("problems").hidden = !region("problems").hidden;
      act.setAttribute("aria-expanded", String(!region("problems").hidden));
      break;
    }
    case "save": save(); break;
    case "discard":
      leaving = true;
      window.location.reload();
      break;
    case "adder": toggleAdder(region("adder").hidden); break;
    case "tag": retag([...draft.hero.tags, { name: v, category: categoryOf(v) }]); break;
    case "untag": retag(draft.hero.tags.filter((t) => t.name !== v)); break;
    case "hero-effect": draft.hero.effect = v; press("hero-effect", v); rebuildBelt(); changed(); break;
    case "hero-dir": draft.hero.dir = v; press("hero-dir", v); rebuildBelt(); changed(); break;
    case "hero-cells": draft.hero.cells = Number(v); press("hero-cells", v); rebuildBelt(); changed(); break;
    case "hero-picker":
      region("hero-picker").hidden = !region("hero-picker").hidden;
      if (region("hero-picker").hidden) { renderHeroPicker(); } else { loadHero(); }
      break;
    case "hero-pick":
      draft.hero.posts = draft.hero.posts.includes(id) ? draft.hero.posts.filter((p) => p !== id) : [...draft.hero.posts, id];
      renderHeroPicker(); renderChips(); rebuildBelt(); changed();
      break;
    case "hero-move": {
      const posts = draft.hero.posts;
      const from = posts.indexOf(id);
      const to = from + Number(v);
      [posts[from], posts[to]] = [posts[to], posts[from]];
      renderHeroPicker(); rebuildBelt(); changed();
      break;
    }
    case "mini-dir": mini.dir = v; renderMinis(); changed(); break;
    case "mini-picker":
      openMini = openMini === i ? -1 : i;
      renderMinis();
      if (openMini === i) { loadMini(i).then(renderMinis); }
      break;
    case "mini-pick":
      mini.posts = mini.posts.includes(id) ? mini.posts.filter((p) => p !== id) : [...mini.posts, id];
      renderMinis(); changed();
      break;
    case "banner":
      draft.banner.post_id = act.dataset.id ? id : null;
      renderBanners(); paintBanner(); changed();
      break;
    case "layout":
      draft.layout = v;
      draft.minis = [...draft.minis, ...Array.from({ length: Math.max(0, slotCount(v) - draft.minis.length) }, () => structuredClone(BLANK_MINI))];
      press("layout", v);
      renderMinis(); changed();
      break;
    default: break;
    }
  });

  // Typing previews at once; a slider redraws its band once it is let go.
  root.addEventListener("input", (e) => {
    const field = e.target.dataset.cgField;
    const v = e.target.value;
    const statics = { title: v || data.slug, bio: v || "Nothing here yet.", headline: v, subline: v };
    if (["title", "bio", "matrix_contact", "headline", "subline"].includes(field)) {
      draft[field] = v;
      const shown = root.querySelector(`[data-cg-static="${field}"]`);
      if (shown) { shown.textContent = statics[field]; }
    } else if (field === "tag-query") {
      renderAdder();
      return;
    } else if (field === "hero.hold") {
      draft.hero.hold = Number(v);
      region("hero-hold").textContent = v;
    } else if (field === "mini-hold") {
      const i = Number(e.target.dataset.i);
      draft.minis[i].hold = Number(v);
      e.target.nextElementSibling.textContent = `${v}s`;
      root.querySelector(`[data-cg-mini="${i}"]`).dataset.hold = v;
    } else if (field === "banner.y") {
      draft.banner.y = Number(v);
      region("banner-y").textContent = v;
      paintDepth();
    } else if (field?.startsWith("depth.")) {
      const key = field.slice("depth.".length);
      draft.depth[key] = Number(v);
      region(`depth-${key}`).textContent = v;
      paintDepth();
    } else {
      return;
    }
    changed();
  });

  root.addEventListener("change", (e) => {
    const field = e.target.dataset.cgField;
    const i = Number(e.target.dataset.i);
    if (field === "hero.hold") {
      rebuildBelt();
    } else if (field === "mini-effect") {
      draft.minis[i].effect = e.target.value;
      renderMinis();
      changed();
    } else if (field === "mini-tag") {
      // A new tag starts the miniband over: its first four posts.
      const tag = e.target.value;
      draft.minis[i] = { ...draft.minis[i], tag, posts: [] };
      renderMinis();
      changed();
      loadMini(i).then((answer) => {
        if (!answer || draft.minis[i].tag !== tag) { return; }
        draft.minis[i].posts = answer.slides.slice(0, 4).map((s) => s.id);
        renderMinis();
        changed();
      });
    }
  });

  // The adder closes on a click elsewhere and on Escape, like the sheets. The
  // click's path is read as it was dispatched: the row it picked has been
  // redrawn away by now, and is no longer in the adder.
  document.addEventListener("click", (e) => {
    const inside = e.composedPath().some((node) => node instanceof Element && node.matches("[data-cg-region='adder'], .modcreator-add-tag"));
    if (!region("adder").hidden && !inside) { toggleAdder(false); }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") { return; }
    toggleAdder(false);
    root.querySelectorAll("[data-cg-sheet]").forEach((sheet) => { sheet.hidden = true; });
    root.querySelectorAll(".cg-seg [data-cg-act='sheet']").forEach((b) => b.setAttribute("aria-pressed", "false"));
  });

  // A problem Save was answered with can be fixed outside the draft (a post's
  // audience, on Who sees your posts): coming back to the page lets Save ask
  // the server again.
  const askAgain = () => {
    if (document.hidden || !serverProblems.length) { return; }
    serverProblems = [];
    report();
  };
  document.addEventListener("visibilitychange", askAgain);
  window.addEventListener("focus", askAgain);

  // The page's own sections (About) post their forms and reload: what is not
  // saved would be lost, so leaving asks first.
  window.addEventListener("beforeunload", (e) => {
    if (leaving || payload(draft) === savedPayload) { return; }
    e.preventDefault();
    e.returnValue = "";
  });

  root.querySelectorAll("[data-cg-layout-label]").forEach((span) => { span.textContent = layoutOf(span.dataset.cgLayoutLabel).label; });
  renderChips();
  renderMinis();
  loadHero();
  candidates([]).then(renderRule);
  report();
}

// --- every viewer ----------------------------------------------------------

function initGallery(root) {
  if (root.dataset.cgBooted) { return; }
  root.dataset.cgBooted = "1";
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  let stops = [];
  const bindMinis = () => {
    stops.forEach((stop) => stop());
    stops = Array.from(root.querySelectorAll("[data-cg-mini]"), (mini) => cycleMini(mini, reduced));
  };

  // The panels descend from the header on About; one put away is listed
  // above the rest, to bring back.
  function listHidden() {
    const away = Array.from(root.querySelectorAll("[data-cg-panel]")).filter((box) => box.hidden);
    const strip = root.querySelector("[data-cg-region='hidden-panels']");
    strip.hidden = !away.length;
    strip.replaceChildren(...away.map((box) => el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "show-panel", "data-v": box.dataset.cgPanel }, `Show ${box.dataset.cgTitle}`)));
  }

  root.addEventListener("click", (e) => {
    const act = e.target.closest("[data-cg-act]");
    if (!act || !root.contains(act)) { return; }
    if (act.dataset.cgAct === "about") {
      const about = root.querySelector("#modcreator-about");
      about.hidden = !about.hidden;
      act.setAttribute("aria-expanded", String(!about.hidden));
    } else if (act.dataset.cgAct === "hide-panel") {
      act.closest("[data-cg-panel]").hidden = true;
      listHidden();
    } else if (act.dataset.cgAct === "show-panel") {
      root.querySelector(`[data-cg-panel="${act.dataset.v}"]`).hidden = false;
      listHidden();
    }
  });

  // A form in a panel redirects back to its own section (edit#creator-characters):
  // the panels open on it.
  const about = root.querySelector("#modcreator-about");
  // The sections' ids are plain words: the hash is read as written, and a
  // malformed escape in a link names no section rather than stopping the page.
  const anchor = window.location.hash.length > 1 ? document.getElementById(window.location.hash.slice(1)) : null;
  if (anchor && about.contains(anchor)) {
    about.hidden = false;
    root.querySelector("[data-cg-act='about']").setAttribute("aria-expanded", "true");
    anchor.scrollIntoView();
  }

  if (!reduced) { parallax(root); }
  if (root.dataset.editor) {
    editor(root, JSON.parse(root.dataset.editor), bindMinis);
  } else {
    bindMinis();
  }
}

function initAll() {
  document.querySelectorAll("[data-creator-gallery]").forEach(initGallery);
}

$(document).ready(initAll);

export default { initAll };
