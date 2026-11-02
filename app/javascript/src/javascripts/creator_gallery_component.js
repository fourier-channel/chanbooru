import Landing from "./modulation_landing_component";
import {
  BLANK_MINI, HERO_MAX, HERO_MIN, MIN_W, MINI_EFFECTS, MINI_MAX, DIRS, ROW_H,
  adderRow, bandRule, layoutOf, miniLook, miniRole, problemsOf, rowsOf, ruleSentence, slotCount, tagsOf,
} from "./creator_gallery_model";
import { covered, harmonicModel } from "./harmonic_model";
import { bindLeave, mountTuner, tunerSection } from "./creator_tuner";
import { harmonicBuilder } from "./harmonic_builder";
import { keepTab, postDecks } from "./post_deck";
import { placed, usedMap, usedWords } from "./post_deck_model";
import {
  HANDLES, IDENTITY, move, pictureStyle, putView, resize, scaleBy, style as viewStyle, toBox, transform, viewIn,
} from "./post_view";
import Notice from "./notice";
import { captureRects, playFLIP } from "./flip";
import { clampHeight, keyHeight } from "./creator_about_model";

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

// A post's applied view on `node`, as --cg-view (post_view.js): its picture,
// or the banner's layers, compose it into their own transform.
function showView(node, view) {
  const t = transform(view);
  if (t) { node?.style.setProperty("--cg-view", t); } else { node?.style.removeProperty("--cg-view"); }
}

// A post to pick, marked for the blacklist like every other drawn post: every
// card of every post deck (post_deck.js), the harmonic builder's among them.
const thumb = (slide, attrs, ...kids) => el("button", { type: "button", class: "cg-thumb mod-blacklist-target", title: `post #${slide.id}`, ...marks(slide), ...attrs },
  el("img", { src: slide.thumb || slide.src, alt: "", loading: "lazy", draggable: "false" }), ...kids);

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
// from, then the hold. Held while the pointer is on it, while it is under 60%
// in view or the page is hidden, and nothing moves on its own for a reader
// who asked for less motion: the arrows step it. A post the blacklist marked
// is passed over.
const TRANSIT_MS = 1300;

function cycleMini(mini, reduced) {
  const life = new AbortController();
  const all = () => Array.from(mini.querySelectorAll(".modcreator-mini-item"));
  const shown = () => all().filter((item) => !item.classList.contains("blacklisted-active"));
  let pos = 0;
  let settled = true;
  let hovered = false;
  let seen = false;
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
    if (hovered || !seen || document.hidden || shown().length < 2) { return; }
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
  const view = new IntersectionObserver((entries) => {
    seen = entries.at(-1).intersectionRatio >= 0.6;
    if (seen) { resume(); }
  }, { threshold: [0, 0.6, 1] });
  view.observe(mini);
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
  return () => { life.abort(); view.disconnect(); clearTimeout(timer); };
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

  // The views of the posts the draft puts where views are drawn -- the
  // banner, the harmonics' backgrounds, the layout's minibands -- which are
  // the views a Save sends (CreatorGalleryLayout#save's `placed`). A post off
  // the page keeps the view it has, to bring back when it is chosen again.
  const viewsOnPage = (d) => {
    const ids = new Set([d.banner.post_id, ...d.harmonics.map((h) => h.background_post_id), ...d.minis.slice(0, slotCount(d.layout)).flatMap((m) => m.posts)]);
    return d.views.filter((v) => ids.has(v.post_id));
  };
  // What Save compares and sends: the minibands past the layout's count are
  // kept while editing, so a layout switched back keeps them, and are not
  // the page's.
  const payload = (d) => JSON.stringify({ ...d, minis: d.minis.slice(0, slotCount(d.layout)), views: viewsOnPage(d) });
  const draft = structuredClone(data.draft);
  // Each harmonic of the draft carries a key of its own, which undo's copies
  // keep, so a Save's answer finds the entries it was about. It is not sent.
  let keys = 0;
  const keyed = (h) => Object.assign(h, { draftKey: (keys += 1) });
  draft.harmonics.forEach(keyed);
  let savedPayload = payload(draft);
  // A post's applied view is the draft's, by post: choosing a post again
  // brings back the view it was given.
  const viewOf = (id) => viewIn(draft.views, id);
  // Each miniband's posts as last saved: a post already in the band is the
  // creator's to keep, whatever the dedupe rule says of a post added now.
  let savedMinis = data.draft.minis.map((m) => m.posts);
  let serverProblems = [];
  let saving = false;
  let leaving = false;
  let openMini = -1;
  let toastTimer = 0;

  // The Tuner's harmonics (CREATOR_TUNER.md rev 3): the list's own checks,
  // Save's sentences (harmonic_model.js), against the rows as saved.
  const model = harmonicModel(data.registry);
  const limits = data.registry.limits;
  const sites = new Map(model.sites.map((site) => [site.key, site]));
  const ctaLabels = new Map(data.registry.ctas);
  let serverCards = new Map(data.cards.map((card) => [card.id, card]));
  let savedBackground = new Map(data.draft.harmonics.map((h) => [h.id, h.background_post_id]));
  // The removals' fingerprints (CreatorHarmonicRemoval.fingerprint).
  const removed = new Set(data.removed);
  let stored = new Map(data.draft.harmonics.map((h) => [h.id, {
    url: h.url, host: serverCards.get(h.id)?.host, site: serverCards.get(h.id)?.site, staff_hidden: h.staff_hidden,
  }]));
  // A background the server found no longer showable, while it is the one saved.
  const stale = (h) => Boolean(h.id && h.background_post_id === savedBackground.get(h.id) && serverCards.get(h.id)?.stale);
  let harmonicProblems = [];
  let stopTuner = null;

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
    harmonicProblems = model.problems(draft.harmonics, { stored, removed, stale, cap: data.harmonicCap });
    const problems = [...new Set([...serverProblems, ...problemsOf(draft, slideOf, savedMinis), ...harmonicProblems.map((p) => p.text)])];
    const dirty = payload(draft) !== savedPayload;
    const button = region("problems-btn");
    button.hidden = !problems.length;
    button.textContent = `${problems.length} to fix`;
    if (!problems.length) { region("problems").hidden = true; }
    button.setAttribute("aria-expanded", String(!region("problems").hidden));
    region("problems-list").replaceChildren(el("ul", {}, ...problems.map((p) => el("li", {}, p))));
    region("dirty").textContent = saving ? "saving" : dirty ? "unsaved changes" : "saved";
    // The bar's Save and the builder's are one.
    root.querySelectorAll("[data-cg-act='save']").forEach((b) => { b.disabled = saving || !dirty || problems.length > 0; });
    root.querySelector("[data-cg-act='discard']").disabled = saving || !dirty;
  }

  function changed() {
    serverProblems = [];
    report();
  }

  // --- the Tuner, drawn from the draft ---
  // A harmonic of the draft as the page would draw it (CreatorGalleryLayout#card):
  // what the server drew while it is unchanged, the link model's reading of
  // what was typed since. A staff-hidden one is the server's, as it was.
  function draftCard(h, i) {
    const number = i + 1;
    const server = serverCards.get(h.id);
    if (h.staff_hidden) { return { ...server, number }; }
    const unchanged = server && h.url === server.url;
    const found = unchanged ? server : model.link(h.url);
    const site = sites.get(found.site);
    const host = found.host ?? found.vars?.host ?? "";
    const settings = Object.fromEntries(["focus_x", "focus_y", "zoom", "shade"].map((key) => [key, h[key] ?? data.registry.defaults[key]]));
    const slide = h.background_post_id && slideOf(h.background_post_id);
    let drawn = null;
    if (server?.picture && h.background_post_id === savedBackground.get(h.id)) {
      drawn = { ...server.picture, ...settings, view: viewOf(h.background_post_id) };
    } else if (slide) {
      drawn = {
        id: slide.id, tags: slide.tags, rating: slide.rating, flags: slide.flags, score: slide.score, uploader_id: slide.uploader_id, src: picture(slide),
        ...settings, view: viewOf(slide.id),
      };
    }
    return {
      id: h.id,
      number,
      shown: h.shown !== false,
      counts: Boolean(h.shown !== false && site && !(found.url && covered(found.url, removed))),
      url: found.url ?? null,
      host,
      site: found.site ?? null,
      name: site?.name ?? (unchanged ? server.name : null) ?? (host || "No site"),
      logo: site ? site.logo : (unchanged && server.logo) || null,
      support: Boolean(site?.support),
      adult: Boolean(site ? site.adult : unchanged && server.adult),
      title: h.title,
      subtitle: h.subtitle,
      cta: h.cta,
      cta_label: ctaLabels.get(h.cta) ?? null,
      places: h.places ?? {},
      gradient: h.background_gradient,
      picture: drawn,
      notice: harmonicProblems.find((p) => p.n === number)?.text ?? null,
    };
  }

  const counting = () => draft.harmonics.filter((h, i) => draftCard(h, i).counts).length;

  // The Tuner where the draft puts it, the harmonic in hand ringed and shown
  // first, and the add tile while there is room. It holds still: its cards
  // open the builder, they do not lead away.
  function drawTuner() {
    const { enabled, placement } = draft.tuner;
    const head = region("head");
    const old = Array.from(head.querySelectorAll("[data-cg-tuner]"));
    // Focus on the Tuner stays on it through a redraw, on the card it shows.
    const held = old.some((section) => section.contains(document.activeElement));
    const gone = old.flatMap((section) => Array.from(section.querySelectorAll(".mod-blacklist-target")));
    stopTuner?.();
    stopTuner = null;
    old.forEach((section) => section.remove());
    head.classList.toggle("modcreator-head--dial", enabled && placement === "A");
    head.classList.toggle("modcreator-head--sky", enabled && placement === "B");
    region("id").classList.toggle("modcreator-id--tuned", enabled && placement === "A");
    const cards = enabled ? draft.harmonics.map(draftCard) : [];
    const add = enabled && draft.harmonics.length < limits.rows && counting() < data.harmonicCap;
    let arrived = [];
    if (cards.length || add) {
      // eslint-disable-next-line no-use-before-define -- the builder redraws the Tuner, and the Tuner rings the builder's harmonic
      const ring = builder.index >= 0 ? builder.index : null;
      const section = tunerSection(placement, cards, { logos: data.logos, shadeFloor: limits.shade_floor, add, ring });
      section.dataset.cgBuild = "";
      if (placement === "B") { head.querySelector(".modcreator-banner").after(section); } else { region("id").append(section); }
      stopTuner = mountTuner(section, { hold: true });
      arrived = Array.from(section.querySelectorAll(".mod-blacklist-target"));
      if (held) { section.querySelector(".cg-hm:not([hidden])")?.focus(); }
    }
    const engine = document.querySelector("#blacklist-box")?.blacklist;
    if (engine && (arrived.length || gone.length)) { engine.adopt(arrived, gone); }
  }

  // Every post picker is a deck, its enlarged card and dragged card hung from
  // the page, over everything.
  const decks = postDecks(root, { thumb, picture, fill });

  const builder = harmonicBuilder(region("builder"), {
    registry: data.registry,
    logos: data.logos,
    cap: data.harmonicCap,
    isAdmin: data.isAdmin,
    saveUrl: data.saveUrl,
    entries: () => draft.harmonics,
    card: (i) => draftCard(draft.harmonics[i], i),
    problems: () => harmonicProblems,
    counting,
    placement: () => draft.tuner.placement,
    // eslint-disable-next-line no-use-before-define -- the Layout sheet's Tuner switch and the builder's are one
    setPlacement: (placement) => setTuner(true, placement),
    // The creator's own posts, asked as the banner's are.
    posts: () => candidates([]),
    // The background's view, set on the builder's card (`frame`); `painted`
    // draws the builder again once the draft has it.
    view: (i, frame, painted) => {
      const h = draft.harmonics[i];
      // eslint-disable-next-line no-use-before-define -- the builder is drawn before the view editor is defined
      editView(h.background_post_id, {
        what: "The harmonic's picture",
        frame,
        paint: (view) => frame()?.querySelector(".cg-hm-img")?.setAttribute("style", pictureStyle({ ...draftCard(h, i).picture, view })),
        kept: () => {
          drawTuner();
          painted();
        },
      });
    },
    slideOf,
    fill,
    deck: decks.deck,
    toast,
    dirty: () => payload(draft) !== savedPayload,
    changed: () => {
      changed();
      drawTuner();
    },
    moved: () => {
      drawTuner();
      report();
    },
  });

  function setTuner(enabled, placement) {
    draft.tuner = { enabled, placement };
    root.querySelectorAll("[data-cg-act='tuner-mode']").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.v === (enabled ? placement : "off"))));
    region("tuner-note").hidden = enabled;
    if (!enabled) { builder.close(); }
    changed();
    drawTuner();
    builder.paint();
  }

  // A new harmonic: a link to fill in, words in the corner, the ground behind.
  const blankHarmonic = () => keyed({
    id: null, shown: true, url: "", title: "", subtitle: "", cta: null,
    places: { ...data.registry.presets.find(([key]) => key === "corner")[2] },
    background_post_id: null, background_gradient: null, focus_x: null, focus_y: null, zoom: null, shade: null, staff_hidden: false,
  });

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

  // A redraw keeps each list where it was scrolled, so a pick does not jump
  // the deck back to its top, and moves the staging strips in it from what
  // they were to what they are (post_deck.js restage).
  function keepScroll(box, draw) {
    // Keyed by the miniband too: every miniband's list has the same class.
    const key = (list) => `${list.closest("[data-cg-mini]")?.dataset.cgMini ?? ""} ${list.className}`;
    const at = new Map([...box.querySelectorAll(".cg-scroll")].map((list) => [key(list), [list.scrollTop, list.scrollLeft]]));
    decks.restage(box, draw);
    box.querySelectorAll(".cg-scroll").forEach((list) => {
      [list.scrollTop, list.scrollLeft] = at.get(key(list)) || [0, 0];
    });
  }

  // `total` counts every eligible post; `slides` are the newest of them,
  // up to `cap`, that the curator may see (CreatorGalleryLayout#candidates).
  const capNote = (answer) => (cappedOf(answer)
    ? [el("p", { class: "cg-note" }, `${answer.slides.length} of ${answer.total} posts are shown: the newest ${answer.cap} at most, and only those you may see.`)] : []);

  // A post on a staging strip: its card, numbered, and the keys that move it
  // along or take it off; on a miniband, also its View, set on the miniband
  // itself. `band` is hero or mini; `attrs` say which miniband.
  const stripItem = (band, id, i, n, attrs) => {
    const slide = slideOf(id);
    const where = band === "hero" ? "the band" : "the miniband";
    return el("div", { class: "modcreator-strip-item", role: "listitem", "data-flip-id": id },
      slide ? thumb(slide, { tabindex: "-1" }, el("span", { class: "cg-thumb-num" }, String(i + 1))) : el("span", { class: "cg-thumb" }, el("span", { class: "cg-thumb-cap" }, `#${id}`)),
      el("div", { class: "modcreator-strip-moves" },
        el("button", { type: "button", "data-cg-act": `${band}-move`, ...attrs, "data-id": id, "data-v": -1, disabled: i === 0, "aria-label": `Move post #${id} earlier` }, "\u2039"),
        el("button", { type: "button", "data-cg-act": `${band}-pick`, ...attrs, "data-id": id, "aria-label": `Take post #${id} off ${where}` }, "\u00d7"),
        el("button", { type: "button", "data-cg-act": `${band}-move`, ...attrs, "data-id": id, "data-v": 1, disabled: i === n - 1, "aria-label": `Move post #${id} later` }, "\u203a")),
      ...(band === "mini" ? [el("button", {
        type: "button", class: "modcreator-strip-view", "data-cg-act": "mini-view", ...attrs, "data-id": id, disabled: !slide, "aria-label": `Move, scale or flip post #${id} on the miniband`,
      }, "View")] : []));
  };

  function renderHeroPicker() {
    const box = region("hero-picker");
    const posts = draft.hero.posts;
    region("hero-posts").textContent = `Posts (${posts.length}/${HERO_MAX})`;
    region("hero-posts").setAttribute("aria-expanded", String(!box.hidden));
    if (box.hidden) { return; }
    const rule = bandRule(draft.hero.tags);
    const base = heroBase();
    const full = posts.length >= HERO_MAX;
    const stageAs = (list) => {
      draft.hero.posts = list;
      renderHeroPicker(); renderChips(); rebuildBelt(); changed();
    };
    let deck = [el("p", { class: "cg-note" }, "Add tags to the band first. Its candidates are every post that fits them.")];
    if (draft.hero.tags.length && !base) {
      deck = [el("p", { class: "cg-note" }, "Finding the band's candidates...")];
    } else if (draft.hero.tags.length) {
      deck = [...capNote(base), decks.deck(base.slides.filter(rule.ok), {
        size: 112,
        label: "The band's candidates",
        card: (s) => {
          const at = posts.indexOf(s.id);
          const chars = rule.c.filter((c) => tagsOf(s).includes(c)).map(label).join(", ");
          return [{ "aria-pressed": String(at >= 0) },
            ...(at >= 0 ? [el("span", { class: "cg-thumb-num" }, String(at + 1))] : []),
            el("span", { class: "cg-thumb-cap" }, `#${s.id}`, ...(chars ? [el("br", {}), el("span", { class: "cg-thumb-chars" }, chars)] : []))];
        },
        blocked: (s) => full && !posts.includes(s.id),
        act: (s) => {
          const on = posts.includes(s.id);
          return {
            attrs: { "data-cg-act": "hero-pick", "data-id": s.id },
            text: on ? "Take off the band" : "Pick",
            disabled: full && !on,
            why: full && !on ? `The band holds ${HERO_MAX} posts, the most. Take one off first` : null,
          };
        },
        strip: "hero",
        drop: (id, index) => stageAs(placed(posts, id, index)),
      })];
    }
    keepScroll(box, () => fill(box,
      el("div", { class: "modcreator-picker-head" },
        el("span", { class: "cg-label modcreator-picker-title" }, `The band's posts: ${posts.length}, from ${HERO_MIN} to ${HERO_MAX}, in this order`),
        el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hero-picker" }, "Done")),
      decks.stage("hero", posts.map((id, i) => stripItem("hero", id, i, posts.length, {})), {
        label: "The band's posts, in order",
        empty: "Drag a post here to put it on the band, or open one and Pick it.",
        slideOf,
        drop: (id, index) => stageAs(placed(posts, id, index)),
        off: (id) => stageAs(posts.filter((p) => p !== id)),
      }),
      ...deck));
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
    const options = mini.tag && !palette.has(mini.tag) ? [{ name: mini.tag, count: mini.posts.length }, ...data.palette] : data.palette;
    return el("div", {
      class: "modcreator-mini", "data-cg-mini": i, "data-effect": mini.effect, "data-dir": mini.dir, "data-hold": mini.hold,
      style: `--mini-h: ${ROW_H[n]}px; --mini-w: ${MIN_W[n]}px`,
    },
    ...list.map((s) => el("a", { class: "modcreator-mini-item modcreator-card mod-blacklist-target", href: s.url, title: `post #${s.id}`, ...marks(s) },
      el("img", { class: "modcreator-mini-img", src: picture(s), alt: "", loading: "lazy", draggable: "false", style: viewStyle(viewOf(s.id)) || null }))),
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
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "mini-picker", "data-i": i, "aria-expanded": String(openMini === i) }, `Posts (${mini.posts.length}/${MINI_MAX})`)));
  }

  function renderMinis() {
    keepScroll(region("minis"), () => fill(region("minis"), ...rowsOf(draft.layout).map((row) => el("div", { class: "modcreator-minis-row" }, ...row.map((i) => miniSlot(i, row.length))))));
    region("layout-name").textContent = layoutOf(draft.layout).label;
    // eslint-disable-next-line no-use-before-define -- the window redraws the minibands it picks for
    renderMiniWindow();
    bindMinis();
  }

  // The open miniband's posts, in a window over the page: its staging strip,
  // then its deck. A post another miniband shows is marked with where it is,
  // and may not be picked here (the dedupe rule, problemsOf); one this
  // miniband already has stays to take off.
  function renderMiniWindow() {
    const old = root.querySelector(".modcreator-mini-window");
    const i = openMini < slotCount(draft.layout) ? openMini : -1;
    // Another miniband's window is a new one: its lists start at their tops.
    if (old && Number(old.dataset.i) !== i) {
      fill(old);
      old.remove();
    }
    if (i < 0) { return; }
    const win = root.querySelector(".modcreator-mini-window") || root.appendChild(el("div", {
      class: "modcreator-mini-window modcreator-edit-ui", role: "dialog", "aria-modal": "true", "aria-label": `Miniband ${i + 1}'s posts`, "data-i": i, tabindex: "-1",
    }));
    const mini = draft.minis[i];
    const answer = loaded.get(mini.tag);
    const used = usedMap(draft.minis.slice(0, slotCount(draft.layout)), i);
    const full = mini.posts.length >= MINI_MAX;
    const here = (id) => mini.posts.includes(id);
    const stageAs = (list) => {
      mini.posts = list;
      renderMinis(); changed();
    };
    let deck = [el("p", { class: "cg-note" }, mini.tag ? "Finding the posts..." : "This miniband shows one tag. Pick it on the miniband.")];
    if (mini.tag && answer) {
      deck = [...capNote(answer), decks.deck(answer.slides, {
        size: 112,
        label: `Miniband ${i + 1}'s candidates`,
        card: (s) => {
          const at = mini.posts.indexOf(s.id);
          return [{ "aria-pressed": String(at >= 0) }, ...(at >= 0 ? [el("span", { class: "cg-thumb-num" }, String(at + 1))] : [])];
        },
        note: (s) => (used.has(s.id) ? `${here(s.id) ? "Also in" : "Used in"} ${usedWords(used.get(s.id))}` : null),
        blocked: (s) => !here(s.id) && (used.has(s.id) || full),
        act: (s) => {
          const why = (used.has(s.id) && "A post shows on one miniband only. Take it off the other first") || (full && `A miniband holds ${MINI_MAX} posts, the most. Take one off first`);
          return {
            attrs: { "data-cg-act": "mini-pick", "data-i": i, "data-id": s.id },
            text: here(s.id) ? "Take off the miniband" : "Pick",
            disabled: !here(s.id) && Boolean(why),
            why: here(s.id) ? null : why || null,
          };
        },
        strip: `mini-${i}`,
        drop: (id, index) => stageAs(placed(mini.posts, id, index)),
      })];
    }
    keepScroll(win, () => fill(win,
      el("div", { class: "modcreator-mini-window-head" },
        el("span", { class: "modcreator-mini-num" }, String(i + 1)),
        el("span", { class: "cg-label" }, mini.tag ? `${label(mini.tag)}: ${mini.posts.length} of ${MINI_MAX}, in this order` : "Pick a tag first"),
        el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "mini-picker", "data-i": i }, "Done")),
      decks.stage(`mini-${i}`, mini.posts.map((id, k) => stripItem("mini", id, k, mini.posts.length, { "data-i": i })), {
        label: `Miniband ${i + 1}'s posts, in order`,
        empty: "Drag a post here to put it on the miniband, or open one and Pick it.",
        slideOf,
        drop: (id, index) => stageAs(placed(mini.posts, id, index)),
        off: (id) => stageAs(mini.posts.filter((p) => p !== id)),
      }),
      ...deck));
  }

  // The window closes, and the keyboard is back on the miniband's Posts.
  function closeMini(refocus) {
    const i = openMini;
    openMini = -1;
    renderMinis();
    if (refocus) { root.querySelector(`[data-cg-act='mini-picker'][data-i='${i}']`)?.focus({ preventScroll: true }); }
  }

  function loadMini(i) {
    const tag = draft.minis[i].tag;
    return tag ? candidates([tag]) : Promise.resolve(null);
  }

  // --- the look: banner, depth, layout ---
  function renderBanners() {
    const all = loaded.get("");
    keepScroll(region("banners"), () => fill(region("banners"),
      ...(all ? capNote(all) : []),
      el("button", { type: "button", class: "modcreator-banner-none", "data-cg-act": "banner", "aria-pressed": String(!draft.banner.post_id) }, "None"),
      ...(all ? [decks.deck(all.slides, {
        size: 80,
        label: "Your posts",
        card: (s) => [{ "data-cg-act": "banner", "aria-pressed": String(s.id === draft.banner.post_id) }],
      })] : [el("span", { class: "cg-note" }, "Finding your posts...")])));
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

  // The look as the layers' CSS variables (CreatorGalleryComponent#depth_style),
  // the banner post's view among them.
  function paintDepth() {
    const { blur, dim, parallax: strength } = draft.depth;
    layers.forEach((layer) => {
      layer.style.setProperty("--cg-blur", `${blur}px`);
      layer.style.setProperty("--cg-dim", String(dim / 100));
      layer.style.setProperty("--cg-par", String(strength / 100));
      layer.style.setProperty("--cg-y", `${draft.banner.y}%`);
      showView(layer, viewOf(draft.banner.post_id));
    });
    root.querySelector("[data-cg-act='view-banner']").disabled = !draft.banner.post_id;
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

  // --- a post's applied view, set on the page itself (item 8) ---
  //
  // A box over the picture in `frame()`: a drag moves the picture, the wheel
  // scales it, a corner scales it evenly and an edge stretches it (Distort);
  // Flip, Reset and Done are in a bar by it. Each gesture is worked from the
  // view it started from (post_view.js). `paint` draws the view on the page
  // as it goes; the draft takes it when the gesture ends, and then `kept`
  // runs. One picture at a time: Done, Escape or a press anywhere else ends it.
  let viewing = null;
  function editView(id, { what, frame, paint, kept }) {
    viewing?.();
    if (!id || !frame()) { return; }
    const opener = document.activeElement;
    const life = new AbortController();
    const on = { signal: life.signal };
    let view = viewOf(id);
    let over = false;
    let settle = 0;
    let wheel = null;
    let queued = 0;
    const box = el("div", {
      class: "modcreator-viewer-box", tabindex: "0",
      "aria-label": `${what}. Drag it, or use the arrow keys, to move it; the wheel, or + and -, scales it; a corner scales it, an edge stretches it.`,
    }, ...HANDLES.map((handle) => el("span", { class: `modcreator-viewer-handle modcreator-viewer-handle--${handle}`, "data-handle": handle, "aria-hidden": "true" })));
    const bar = el("div", { class: "modcreator-viewer-bar cg-glass" },
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-view": "flip_h", "aria-pressed": "false", title: "Mirror it left to right" }, "Flip H"),
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-view": "flip_v", "aria-pressed": "false", title: "Mirror it top to bottom" }, "Flip V"),
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-view": "reset", title: "Back to the picture as posted" }, "Reset"),
      el("button", { type: "button", class: "cg-btn cg-btn--sm cg-btn--go", "data-view": "done" }, "Done"));
    const layer = el("div", { class: "modcreator-viewer", role: "group", "aria-label": `${what}: its view` }, box, bar);

    function commit() {
      settle = 0;
      draft.views = putView(draft.views, id, view);
      changed();
      kept?.();
    }

    function end() {
      if (over) { return; }
      over = true;
      if (settle) {
        clearTimeout(settle);
        commit();
      }
      const held = layer.contains(document.activeElement);
      life.abort();
      layer.remove();
      root.classList.remove("is-viewing");
      root.querySelectorAll(".is-view-target").forEach((node) => node.classList.remove("is-view-target"));
      viewing = null;
      if (held && opener?.isConnected) { opener.focus({ preventScroll: true }); }
    }

    // The box over the frame, where the view draws the picture before its flips.
    function place() {
      queued = 0;
      const node = frame();
      if (!node) {
        end();
        return;
      }
      const r = node.getBoundingClientRect();
      const b = toBox(view, r);
      Object.assign(layer.style, { left: `${r.left}px`, top: `${r.top}px`, width: `${r.width}px`, height: `${r.height}px` });
      Object.assign(box.style, { left: `${b.left}px`, top: `${b.top}px`, width: `${b.width}px`, height: `${b.height}px` });
      // Under the frame, or over it where the window ends first.
      bar.classList.toggle("is-above", r.bottom + 56 > window.innerHeight);
      ["flip_h", "flip_v"].forEach((flip) => bar.querySelector(`[data-view="${flip}"]`).setAttribute("aria-pressed", String(view[flip])));
    }

    function show(next) {
      view = next;
      paint(view);
      place();
    }

    function keep(next) {
      show(next);
      commit();
    }

    layer.addEventListener("pointerdown", (e) => {
      if (e.button !== 0 || e.target.closest(".modcreator-viewer-bar")) { return; }
      e.preventDefault();
      box.focus({ preventScroll: true });
      const r = frame().getBoundingClientRect();
      const from = view;
      const grip = e.target;
      const { handle } = grip.dataset;
      const drag = new AbortController();
      grip.setPointerCapture(e.pointerId);
      grip.addEventListener("pointermove", (m) => show(handle
        ? resize(from, handle, m.clientX - r.left, m.clientY - r.top, r)
        : move(from, m.clientX - e.clientX, m.clientY - e.clientY, r)), { signal: drag.signal });
      const drop = () => {
        drag.abort();
        if (view !== from) { commit(); }
      };
      grip.addEventListener("pointerup", drop, { signal: drag.signal });
      grip.addEventListener("pointercancel", drop, { signal: drag.signal });
    }, on);

    // A run of wheel steps is one gesture from the view it began on, its
    // factor held to the scale's range so a turn back answers at once.
    layer.addEventListener("wheel", (e) => {
      if (e.ctrlKey) { return; }
      e.preventDefault();
      const dy = e.deltaMode === WheelEvent.DOM_DELTA_LINE ? e.deltaY * 16 : e.deltaY;
      wheel = settle ? wheel : { from: view, factor: 1 };
      wheel.factor = Math.min(4000 / wheel.from.scale, Math.max(200 / wheel.from.scale, wheel.factor * Math.exp(-dy / 600)));
      show(scaleBy(wheel.from, wheel.factor));
      clearTimeout(settle);
      settle = setTimeout(commit, 250);
    }, { ...on, passive: false });

    box.addEventListener("keydown", (e) => {
      const r = frame().getBoundingClientRect();
      const step = e.shiftKey ? 0.1 : 0.01;
      const nudge = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key];
      const factor = { "+": 1.05, "=": 1.05, "-": 1 / 1.05 }[e.key];
      if (nudge) {
        keep(move(view, nudge[0] * r.width, nudge[1] * r.height, r));
      } else if (factor) {
        keep(scaleBy(view, factor));
      } else {
        return;
      }
      e.preventDefault();
    }, on);

    bar.addEventListener("click", (e) => {
      const act = e.target.closest("[data-view]")?.dataset.view;
      if (act === "flip_h" || act === "flip_v") {
        keep({ ...view, [act]: !view[act] });
      } else if (act === "reset") {
        keep(IDENTITY);
      } else if (act === "done") {
        end();
      }
    }, on);

    // Escape is Done here before it closes anything under the box.
    window.addEventListener("keydown", (e) => {
      if (e.key !== "Escape") { return; }
      e.preventDefault();
      e.stopPropagation();
      end();
    }, { ...on, capture: true });
    document.addEventListener("pointerdown", (e) => { if (!layer.contains(e.target)) { end(); } }, { ...on, capture: true });
    const requeue = () => { queued ||= requestAnimationFrame(place); };
    window.addEventListener("scroll", requeue, { ...on, capture: true, passive: true });
    window.addEventListener("resize", requeue, on);
    life.signal.addEventListener("abort", () => cancelAnimationFrame(queued));

    viewing = end;
    // In place first: a miniband post its cycle has moved out of the band
    // would otherwise be scrolled to inside the band's clip.
    frame().classList.add("is-view-target");
    root.classList.add("is-viewing");
    frame().scrollIntoView({ block: "nearest", inline: "nearest" });
    root.append(layer);
    place();
    box.focus({ preventScroll: true });
  }

  // --- Save and Discard ---
  async function save() {
    saving = true;
    report();
    // What was sent is what is saved: the draft can change while Save waits.
    const sent = payload(draft);
    const hero = { ...draft.hero, tags: draft.hero.tags.map((t) => t.name) };
    const body = {
      creator_gallery: {
        title: draft.title, bio: draft.bio, matrix_contact: draft.matrix_contact, page_private: draft.page_private, show_contact: draft.show_contact,
      },
      layout: {
        headline: draft.headline, subline: draft.subline, banner: draft.banner, depth: draft.depth,
        hero, layout: draft.layout, minis: draft.minis.slice(0, slotCount(draft.layout)),
        tuner: draft.tuner,
        // A staff-hidden harmonic is sent by its id alone to keep its place.
        harmonics: draft.harmonics.map((h) => Object.fromEntries(Object.entries(h).filter(([key]) => key !== "staff_hidden" && key !== "draftKey"))),
        views: viewsOnPage(draft),
      },
    };
    // The entries as sent: the draft can change, and undo copy its entries,
    // while Save waits.
    const sentHarmonics = structuredClone(draft.harmonics);
    try {
      const r = await fetch(data.saveUrl, {
        method: "PATCH",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" },
        body: JSON.stringify(body),
      });
      if (r.ok) {
        const ids = (await r.json()).harmonic_ids;
        const unchanged = payload(draft) === sent;
        // A new entry learns its id from the answer, wherever undo has put it.
        // One undo brought back after Save went without it is new again: its
        // row is gone, unless staff hid it, and the server keeps those.
        const idOf = new Map(sentHarmonics.map((h, i) => [h.draftKey, ids[i]]));
        draft.harmonics.forEach((h) => { h.id = idOf.has(h.draftKey) ? idOf.get(h.draftKey) : (h.staff_hidden ? h.id : null); });
        // The draft takes the links in the server's spelling while it is what was sent.
        if (unchanged) { draft.harmonics.forEach((h) => { h.url = model.link(h.url).url ?? h.url; }); }
        // The rows as saved are the entries as sent, whatever the draft has
        // become: the server's cards stand for a background it drew.
        const saved = sentHarmonics.map((h, i) => ({ ...h, id: ids[i] }));
        serverCards = new Map(saved.filter((h) => serverCards.has(h.id) && savedBackground.get(h.id) === h.background_post_id)
          .map((h) => [h.id, serverCards.get(h.id)]));
        savedBackground = new Map(saved.map((h) => [h.id, h.background_post_id]));
        stored = new Map(saved.map((h) => {
          const found = model.link(h.url);
          return [h.id, found.url ? { url: found.url, host: found.host, site: found.site, staff_hidden: h.staff_hidden } : stored.get(h.id)];
        }));
        savedPayload = unchanged ? payload(draft) : payload({ ...JSON.parse(sent), harmonics: saved });
        savedMinis = JSON.parse(sent).minis.map((m) => m.posts);
        // The steps back lead to entries without their ids.
        builder.forget();
        report();
        drawTuner();
        // A builder typed into while Save waited is left as it is.
        if (unchanged) { builder.paint(); }
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
    case "tuner-mode": setTuner(v !== "off", v === "off" ? draft.tuner.placement : v); break;
    // About and the builder never show together (the gallery's own listener opened it).
    case "about": if (act.getAttribute("aria-expanded") === "true") { builder.close(); } break;
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
      if (openMini === i) {
        closeMini(true);
        break;
      }
      openMini = i;
      renderMinis();
      root.querySelector(".modcreator-mini-window")?.focus({ preventScroll: true });
      // Drawn only into the window it was asked for: one closed meanwhile (a
      // View begun on its strip) keeps the minibands it left, view and all.
      loadMini(i).then(() => { if (openMini === i) { renderMinis(); } });
      break;
    case "mini-pick":
      mini.posts = mini.posts.includes(id) ? mini.posts.filter((p) => p !== id) : [...mini.posts, id];
      renderMinis(); changed();
      break;
    case "mini-move": {
      const from = mini.posts.indexOf(id);
      const to = from + Number(v);
      [mini.posts[from], mini.posts[to]] = [mini.posts[to], mini.posts[from]];
      renderMinis(); changed();
      break;
    }
    case "banner":
      draft.banner.post_id = act.dataset.id ? id : null;
      renderBanners(); paintBanner(); paintDepth(); changed();
      break;
    case "view-banner": {
      const frame = () => root.querySelector(".modcreator-banner");
      editView(draft.banner.post_id, { what: "The banner", frame, paint: (view) => layers.forEach((layer) => showView(layer, view)) });
      break;
    }
    case "mini-view": {
      // The miniband shows the post alone while its view is set, its window
      // out of the way.
      closeMini(false);
      const frame = () => root.querySelector(`[data-cg-mini="${i}"] .modcreator-mini-item[data-id="${id}"]`);
      editView(id, { what: `Post #${id} on miniband ${i + 1}`, frame, paint: (view) => showView(frame()?.querySelector(".modcreator-mini-img"), view) });
      break;
    }
    case "layout":
      draft.layout = v;
      draft.minis = [...draft.minis, ...Array.from({ length: Math.max(0, slotCount(v) - draft.minis.length) }, () => structuredClone(BLANK_MINI))];
      press("layout", v);
      renderMinis(); changed();
      break;
    default: break;
    }
  });

  // The Tuner the editor draws holds still: a card opens the builder on its
  // harmonic, the add tile opens it on a new one.
  root.addEventListener("click", (e) => {
    const tuner = e.target.closest("[data-cg-tuner]");
    if (!tuner) { return; }
    if (e.target.closest("[data-cg-add]")) {
      builder.add(blankHarmonic());
      return;
    }
    const card = e.target.closest("a.cg-hm");
    if (!card) { return; }
    e.preventDefault();
    builder.open(Array.from(tuner.querySelectorAll("a.cg-hm")).indexOf(card));
  });
  root.addEventListener("auxclick", (e) => {
    if (e.target.closest("[data-cg-tuner] a.cg-hm")) { e.preventDefault(); }
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
    } else if (field === "page_private" || field === "show_contact") {
      draft[field] = e.target.checked;
      // The contact previews here; a private page is still the whole page to its creator.
      if (field === "show_contact") {
        root.querySelectorAll("[data-cg-contact]").forEach((shown) => { shown.hidden = !e.target.checked; });
        root.querySelectorAll("[data-cg-contact-off]").forEach((shown) => { shown.hidden = e.target.checked; });
      }
      changed();
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
  // The miniband's window closes on a press outside it, once any enlarged
  // card over it has closed.
  document.addEventListener("pointerdown", (e) => {
    const win = root.querySelector(".modcreator-mini-window");
    if (!win || decks.popOpen || win.contains(e.target) || e.target.closest?.("[data-cg-act='mini-picker']")) { return; }
    closeMini(false);
  }, true);
  document.addEventListener("keydown", (e) => {
    const win = root.querySelector(".modcreator-mini-window");
    // An enlarged card over the window keeps the keyboard itself.
    if (win && !decks.popOpen) { keepTab(e, win); }
    if (e.key !== "Escape") { return; }
    if (openMini >= 0) { closeMini(true); }
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
  drawTuner();
  report();
}

// --- every viewer ----------------------------------------------------------

// The PATCH modulation_landing_component.js saveSetting makes: About's own
// choices, remembered per viewer (ModulationSetting). One at a time, in the
// order made: each merges into what the one before it wrote, so two boxes
// set within one round trip both stay -- two at once would each write back
// what they read, and a signed-out viewer's settings are a cookie, whose
// last Set-Cookie wins.
let saving = Promise.resolve();
function saveSetting(body, failure) {
  saving = saving.then(() => fetch("/modulation/settings", {
    method: "PATCH",
    headers: {
      "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') || {}).content || "",
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    credentials: "same-origin",
    body: JSON.stringify(body),
  })).then((r) => {
    if (!r.ok) { throw new Error(`HTTP ${r.status}`); }
  }).catch(() => Notice.error(failure));
}

const saveBox = (kind, box) => saveSetting({ creator_about_boxes: { [kind]: box } },
  "Could not save how this About box is set; it will not be remembered. Reload the page and set it again.");

// The boxes' pop: up from a little below, a touch small, settling with the
// formant's tag-pop ease (_tokens.scss --mod-tag-pop-ease).
const POP_EASE = "cubic-bezier(0.2, 1.4, 0.4, 1)";
const POP_IN = [{ opacity: 0, transform: "translateY(10px) scale(0.96)" }, { opacity: 1, transform: "none" }];
const POP_OUT = [{ opacity: 1, transform: "none" }, { opacity: 0, transform: "translateY(6px) scale(0.96)" }];
// The region's own grow, as the stylesheet's .modcreator-about transition.
const ABOUT_MS = 280;

// About: its button in the band panel's corner opens the region over the
// panel, which grows from nothing and pushes the panel down, its open boxes
// popping up one after another; closing runs it backwards. Each box opens
// and closes on its chip or its x, the others sliding to share the row, and
// is as tall as its viewer drags or keys its grip. Every choice is the
// viewer's, remembered; the builder and a link to a section open About
// without asking, and are not.
function bindAbout(root, reduced) {
  const about = root.querySelector("#modcreator-about");
  if (!about) { return null; }
  const button = root.querySelector("[data-cg-act='about']");
  const boxes = about.querySelector("[data-cg-region='boxes']");
  const chipOf = (kind) => about.querySelector(`.modcreator-about-chip[data-v="${kind}"]`);
  const boxOf = (kind) => about.querySelector(`[data-cg-box="${kind}"]`);

  // A box's height is its body's (the head and grip are drawn around it): as
  // tall as its content until its viewer sets it. Its grip always says it,
  // set or measured, once the box is drawn.
  const bodyOf = (box) => box.querySelector(".modcreator-box-body");
  const heightOf = (box) => bodyOf(box).offsetHeight;
  function setHeight(box, h) {
    bodyOf(box).style.height = h === null ? "" : `${h}px`;
    box.querySelector(".modcreator-box-grip").setAttribute("aria-valuenow", String(h ?? heightOf(box)));
  }
  const sayHeights = () => [...boxes.children].filter((box) => !box.hidden && !bodyOf(box).style.height).forEach((box) => setHeight(box, null));

  // A turn of About's motion: a later click takes over from an earlier one
  // mid-way, and the earlier one's timers do nothing.
  let turn = 0;
  let pops = [];
  const page = document.scrollingElement;
  const hero = button.closest(".modcreator-hero");
  function setAbout(open, animate) {
    turn += 1;
    const mine = turn;
    const later = (ms, fn) => setTimeout(() => { if (turn === mine) { fn(); } }, ms);
    pops.forEach((pop) => pop.cancel());
    pops = [];
    page.style.overflowAnchor = "";
    button.setAttribute("aria-expanded", String(open));
    const shown = [...boxes.children].filter((box) => !box.hidden);
    if (open) {
      // Opening pushes the panel down where its viewer sees it: the browser's
      // scroll anchoring would hold the panel still on screen and grow the
      // region up out of sight, so it is off until the region is open. A
      // region whose place is above the screen is scrolled to first.
      page.style.overflowAnchor = "none";
      const top = about.hidden ? hero.getBoundingClientRect().top : about.getBoundingClientRect().top;
      if (top < 0) { window.scrollBy({ top: top - 16, behavior: animate ? "smooth" : "instant" }); }
    }
    if (!animate) {
      about.hidden = !open;
      about.inert = false;
      about.classList.remove("is-shut", "is-moving");
      if (open) { sayHeights(); }
      later(ABOUT_MS, () => { page.style.overflowAnchor = ""; });
      return;
    }
    if (open) {
      about.inert = false;
      if (about.hidden) {
        about.hidden = false;
        about.classList.add("is-shut");
      }
      about.classList.add("is-moving");
      // One forced reflow commits the shut row, so the grow runs from it.
      void about.offsetHeight;
      about.classList.remove("is-shut");
      sayHeights();
      pops = shown.map((box, i) => box.animate(POP_IN, { duration: 240, delay: 80 + (i * 50), easing: POP_EASE, fill: "backwards" }));
      later(Math.max(ABOUT_MS, 80 + (50 * (shown.length - 1)) + 240), () => {
        about.classList.remove("is-moving");
        page.style.overflowAnchor = "";
      });
    } else {
      about.inert = true;
      about.classList.add("is-moving");
      pops = shown.reverse().map((box, i) => box.animate(POP_OUT, { duration: 140, delay: i * 30, easing: "ease-in", fill: "forwards" }));
      later(100, () => about.classList.add("is-shut"));
      later(100 + ABOUT_MS, () => {
        about.hidden = true;
        about.inert = false;
        about.classList.remove("is-shut", "is-moving");
        pops.forEach((pop) => pop.cancel());
        pops = [];
      });
    }
  }

  // A box closing pops out first, then the rest slide into its room; a click
  // on its chip mid-way keeps it.
  const leaving = new Map();
  function setBox(kind, open) {
    const box = boxOf(kind);
    chipOf(kind).setAttribute("aria-pressed", String(open));
    leaving.get(kind)?.cancel();
    leaving.delete(kind);
    if (open) {
      if (!box.hidden) { return; }
      const prev = captureRects(boxes);
      box.hidden = false;
      // A box that was hidden measured nowhere: it pops, the rest slide.
      prev.delete(kind);
      playFLIP(boxes, prev);
      // The row's widths changed, and with them every content height.
      sayHeights();
      if (!reduced) { box.animate(POP_IN, { duration: 220, easing: POP_EASE }); }
      return;
    }
    const shut = () => {
      const prev = captureRects(boxes);
      box.hidden = true;
      box.getAnimations().forEach((a) => a.cancel());
      playFLIP(boxes, prev);
      sayHeights();
    };
    if (reduced) { shut(); return; }
    const pop = box.animate(POP_OUT, { duration: 140, easing: "ease-in", fill: "forwards" });
    leaving.set(kind, pop);
    // A cancelled pop (the chip clicked again) rejects: the box stays.
    pop.finished.then(() => { leaving.delete(kind); shut(); }, () => null);
  }

  root.addEventListener("click", (e) => {
    const act = e.target.closest("[data-cg-act='about'], [data-cg-act='box']");
    if (!act || !root.contains(act)) { return; }
    if (act.dataset.cgAct === "about") {
      const open = act.getAttribute("aria-expanded") !== "true";
      setAbout(open, !reduced);
      // Opened by key (a click with no clicks counted), the focus goes on to
      // what it opened: the region is above its button, and Tab from the
      // button would carry on down the page past it.
      if (open && e.detail === 0) { about.querySelector(".modcreator-about-chip").focus({ preventScroll: true }); }
      saveSetting({ creator_about_open: open },
        "Could not save whether About is open; it will not be remembered. Reload the page and set it again.");
      return;
    }
    const kind = act.dataset.v;
    const open = chipOf(kind).getAttribute("aria-pressed") !== "true";
    setBox(kind, open);
    // A box closed by its own x hands the focus to its chip, to open it again.
    if (!open && act.classList.contains("modcreator-box-x")) { chipOf(kind).focus(); }
    saveBox(kind, { open });
  });

  // The grip. Keys step a box and its height is saved once they stop; a drag
  // or a reset after a key drops the key's pending save, which would write
  // the stepped height back over it.
  const keyed = new Map();
  const unkey = (kind) => {
    clearTimeout(keyed.get(kind));
    keyed.delete(kind);
  };

  boxes.addEventListener("pointerdown", (e) => {
    const grip = e.target.closest(".modcreator-box-grip");
    if (!grip || e.button !== 0) { return; }
    const box = grip.closest("[data-cg-box]");
    unkey(box.dataset.cgBox);
    const startY = e.clientY;
    const startH = heightOf(box);
    const before = bodyOf(box).style.height;
    grip.setPointerCapture(e.pointerId);
    box.classList.add("is-sizing");
    const drag = (ev) => setHeight(box, clampHeight(startH + ev.clientY - startY));
    const end = () => {
      grip.removeEventListener("pointermove", drag);
      grip.removeEventListener("pointerup", end);
      grip.removeEventListener("pointercancel", end);
      box.classList.remove("is-sizing");
      if (bodyOf(box).style.height !== before) { saveBox(box.dataset.cgBox, { h: parseInt(bodyOf(box).style.height, 10) }); }
    };
    grip.addEventListener("pointermove", drag);
    grip.addEventListener("pointerup", end);
    grip.addEventListener("pointercancel", end);
  });

  boxes.addEventListener("dblclick", (e) => {
    const box = e.target.closest(".modcreator-box-grip")?.closest("[data-cg-box]");
    if (!box) { return; }
    unkey(box.dataset.cgBox);
    setHeight(box, null);
    saveBox(box.dataset.cgBox, { h: null });
  });

  boxes.addEventListener("keydown", (e) => {
    const box = e.target.closest(".modcreator-box-grip")?.closest("[data-cg-box]");
    if (!box) { return; }
    const h = keyHeight(e.key, e.shiftKey, heightOf(box));
    if (h === undefined) { return; }
    e.preventDefault();
    setHeight(box, h);
    const kind = box.dataset.cgBox;
    unkey(kind);
    keyed.set(kind, setTimeout(() => {
      keyed.delete(kind);
      saveBox(kind, { h });
    }, 400));
  });

  // A box at its content's height grows and shrinks with it (an edit form
  // opening, an image arriving): its grip says the height it has when reached.
  boxes.addEventListener("focusin", (e) => {
    const box = e.target.closest(".modcreator-box-grip")?.closest("[data-cg-box]");
    if (box && !bodyOf(box).style.height) { setHeight(box, null); }
  });
  if (!about.hidden) { sayHeights(); }

  return { about, setAbout, setBox: (kind) => { boxOf(kind).hidden = false; chipOf(kind).setAttribute("aria-pressed", "true"); } };
}

function initGallery(root) {
  if (root.dataset.cgBooted) { return; }
  root.dataset.cgBooted = "1";
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  let stops = [];
  const bindMinis = () => {
    stops.forEach((stop) => stop());
    stops = Array.from(root.querySelectorAll("[data-cg-mini]"), (mini) => cycleMini(mini, reduced));
  };

  // A private page closed to this viewer has no About.
  const about = bindAbout(root, reduced);

  // A form in a box redirects back to its own section (edit#creator-characters):
  // About and the box open on it, at once.
  // The sections' ids are plain words: the hash is read as written, and a
  // malformed escape in a link names no section rather than stopping the page.
  const anchor = window.location.hash.length > 1 ? document.getElementById(window.location.hash.slice(1)) : null;
  // A link to About itself (its button's aria-controls) opens it alone.
  if (anchor && about?.about.contains(anchor)) {
    const box = anchor.closest("[data-cg-box]");
    if (box) { about.setBox(box.dataset.cgBox); }
    about.setAbout(true, false);
    anchor.scrollIntoView();
  }

  if (!reduced) { parallax(root); }
  // A harmonic leaves the booru through the leaving notice; the editor's own
  // Tuner opens the builder instead.
  bindLeave(root);
  if (root.dataset.editor) {
    editor(root, JSON.parse(root.dataset.editor), bindMinis);
  } else {
    bindMinis();
    root.querySelectorAll("[data-cg-tuner]").forEach((section) => mountTuner(section));
  }
}

function initAll() {
  document.querySelectorAll("[data-creator-gallery]").forEach(initGallery);
}

$(document).ready(initAll);

export default { initAll };
