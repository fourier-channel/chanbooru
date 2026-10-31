import { harmonicCard } from "./creator_tuner";
import { strip } from "./harmonic_model";

// THE HARMONIC BUILDER (CREATOR_TUNER.md rev 3, sec 3): one harmonic of the
// draft at a time, in a glass sheet under the Tuner and over the page. It
// works on the editor's draft in place -- the editor draws the Tuner, checks
// the list (harmonic_model.js) and saves -- and keeps its own undo.
//
// The card in hand is the only thing ringed; every other control here is
// neutral or the accent. Its elements are placed by dragging them on the
// card, or by an element and a place on the grid, which is the same choice
// for a keyboard.

function el(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  Object.entries(attrs).filter(([, v]) => v !== false && v !== null && v !== undefined)
    .forEach(([k, v]) => node.setAttribute(k, v === true ? "" : String(v)));
  node.append(...kids.filter((kid) => kid !== null && kid !== false));
  return node;
}

const clamp = (lo, x, hi) => Math.min(hi, Math.max(lo, x));
const length = (text) => [...strip(text)].length;

// What the blacklist matches a post on (CreatorGalleryComponent#marks).
const marks = (slide) => ({
  "data-id": slide.id, "data-tags": slide.tags, "data-rating": slide.rating,
  "data-flags": slide.flags, "data-score": slide.score, "data-uploader-id": slide.uploader_id,
});

// The card's elements: key, name, and the class harmonicCard draws it with.
const ELEMENTS = [["mark", "Mark", "cg-hm-mark"], ["title", "Title", "cg-hm-title"], ["subtitle", "Subtitle", "cg-hm-sub"], ["button", "Button", "cg-hm-cta"], ["host", "Host", "cg-hm-host"]];
const ELEMENT_OF = Object.fromEntries(ELEMENTS.map(([key, , name]) => [name, key]));
const GRABBED = ELEMENTS.map(([, , name]) => `.${name}`).join(", ");
const SETTINGS = [["focus_x", "Focus across", "focus"], ["focus_y", "Focus down", "focus"], ["zoom", "Zoom", "zoom"], ["shade", "Shade", "shade"]];
const PREVIEWS = { A: ["Masthead (A)", 320], B: ["Skywave (B)", 285] };
const SMALLEST = 160;
const INTAKE = "https://41chan.net/horizon/#intake";
const UNDO_MAX = 100;
const TYPING = new Set(["INPUT", "SELECT", "TEXTAREA"]);

// The control a redraw put in place of `node`: the same act on the same thing.
const sameAs = (node) => `[data-cg-act="${node.dataset.cgAct}"]${node.dataset.v === undefined ? `[data-id="${node.dataset.id}"]` : `[data-v="${node.dataset.v}"]`}`;

// @param anchor the element the builder is drawn into
// @param ctx the editor: registry, logos, cap, isAdmin, saveUrl, entries()
//   (the draft's list, edited in place), card(i), problems(), counting(),
//   placement(), setPlacement(p), posts() (a promise of the creator's own
//   posts), slideOf(id), dirty(), changed() (after an edit), moved() (after
//   the builder opened, closed or moved to another harmonic), fill, toast
// @return { open(i), close(), paint(), add(blank), forget(), index }
export function harmonicBuilder(anchor, ctx) {
  const { registry, logos } = ctx;
  const limits = registry.limits;
  const shadeFloor = limits.shade_floor;
  const presets = new Map(registry.presets.map(([key, , places]) => [key, places]));
  const root = anchor.closest("[data-creator-gallery]");
  const phone = window.matchMedia("(width <= 640px)");

  let index = -1;
  let pick = "title";
  let undo = [];
  let redo = [];
  let lastKey = null;
  // The creator's posts: null until asked for, undefined while asked, false
  // when they did not come.
  let posts = null;
  let live = {};

  // Save is the bar's own Save, kept across redraws so it keeps the state
  // the editor gave it.
  const saveButton = el("button", { type: "button", class: "cg-btn cg-btn--sm cg-btn--go", "data-cg-act": "save" }, "Save");

  const entry = () => ctx.entries()[index];

  // --- the parts that follow every keystroke ---
  function capLine() {
    const counting = ctx.counting();
    return `${counting} of ${ctx.cap} places used.${counting >= ctx.cap ? " More places come with add-ons." : ""}`;
  }

  function previews(card) {
    const [name, width] = PREVIEWS[ctx.placement()];
    return [[`${name}, ${width}`, width], [`Smallest, ${SMALLEST}`, SMALLEST]].map(([caption, w]) => {
      const shown = harmonicCard(card, { logos, shadeFloor });
      shown.style.width = `${w}px`;
      shown.tabIndex = -1;
      return el("figure", { class: "cg-hb-preview" }, shown, el("figcaption", { class: "cg-note" }, caption));
    });
  }

  function askBox(host) {
    const line = `Please add ${host} to the Creator Tuner's list.`;
    return [
      el("p", { class: "cg-hb-ask-line" }, line),
      el("div", { class: "cg-hb-ask-acts" },
        el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-copy", "data-v": line }, "Copy"),
        el("a", { class: "cg-btn cg-btn--sm", href: INTAKE, target: "_blank", rel: "noopener" }, `Ask for ${host}`)),
      el("p", { class: "cg-note" }, "Or ask Fourier in the Matrix help room with !request and the same line."),
    ];
  }

  function refresh() {
    const current = entry();
    const card = ctx.card(index);
    const mine = ctx.problems().filter((problem) => problem.n === index + 1 || problem.n === null);
    const stage = harmonicCard(card, { ring: true, logos, shadeFloor });
    stage.tabIndex = -1;
    ctx.fill(live.stage, stage);
    ctx.fill(live.previews, ...previews(card));
    live.cap.textContent = capLine();
    live.pill.replaceChildren(...(card.site
      ? [el("b", {}, "Detected"), ` ${card.name}${card.support ? " (support)" : ""} `, el("bdi", { class: "cg-hb-host" }, card.host)]
      : ["No site detected"]));
    const ask = mine.find((problem) => problem.ask)?.ask;
    live.ask.hidden = !ask;
    ctx.fill(live.ask, ...(ask ? askBox(ask) : []));
    live.problems.replaceChildren(mine.length
      ? el("ul", {}, ...mine.map((problem) => el("li", {}, problem.text)))
      : el("p", { class: "cg-note" }, "No problems. Save would accept this harmonic."));
    [["title", live.titleCount], ["subtitle", live.subtitleCount]].forEach(([key, node]) => {
      const n = length(current[key]);
      node.textContent = `${n} / ${limits[key]}`;
      node.classList.toggle("is-over", n > limits[key]);
    });
    live.undo.disabled = !undo.length;
    live.redo.disabled = !redo.length;
    // A hide reloads the page, so it waits on a draft that is saved.
    const blocked = ctx.dirty() || !current.id;
    live.mod?.querySelectorAll("input:not([type='hidden']), button").forEach((node) => { node.disabled = blocked; });
    if (live.modNote) { live.modNote.hidden = !blocked; }
  }

  // --- the sheet ---
  function head(list) {
    const placement = ctx.placement();
    live.cap = el("p", { class: "cg-note cg-hb-cap" });
    live.undo = el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-undo", title: "Undo (Ctrl-Z)" }, "Undo");
    live.redo = el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-redo", title: "Redo (Ctrl-Shift-Z)" }, "Redo");
    return el("div", { class: "cg-hb-head" },
      el("div", { class: "cg-hb-heading" },
        el("h3", { tabindex: -1 }, `Building harmonic ${index + 1} of ${list.length}`),
        el("div", { class: "cg-seg", role: "group", "aria-label": "Where the Tuner sits" }, ...Object.entries(PREVIEWS).map(([v, [name]]) => el("button", {
          type: "button", "data-cg-act": "hb-placement", "data-v": v, "aria-pressed": String(placement === v), "aria-label": name, title: name,
        }, v))),
        live.cap),
      el("div", { class: "cg-hb-acts" }, live.undo, live.redo, saveButton,
        el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-done" }, "Done")));
  }

  function stageColumn() {
    live.stage = el("div", { class: "cg-hb-stage-card", title: "Drag the words to place them" });
    live.previews = el("div", { class: "cg-hb-previews cg-scroll" });
    return el("div", { class: "cg-hb-stage" }, live.stage, live.previews);
  }

  function linkSection(current) {
    live.pill = el("p", { class: "cg-hb-pill" });
    live.ask = el("div", { class: "cg-hb-ask" });
    return el("div", { class: "cg-hb-sec" },
      el("label", { class: "cg-field" }, el("span", { class: "cg-label" }, "Address"),
        el("input", {
          type: "text", class: "cg-input cg-hb-mono", "data-cg-field": "hb-url", value: current.url ?? "",
          inputmode: "url", spellcheck: "false", autocomplete: "off", autocapitalize: "off", placeholder: "https://",
        })),
      live.pill,
      live.ask,
      el("details", { class: "cg-hb-sites" }, el("summary", {}, "Sites the Tuner carries"),
        ...registry.groups.map((group) => el("p", { class: "cg-note" }, el("b", {}, `${group}:`), ` ${registry.sites.filter((site) => site.group === group).map((site) => site.name).join(", ")}`)),
        el("p", { class: "cg-note" }, "Missing one? Type its address and ask for it.")));
  }

  function wordsSection(current) {
    live.titleCount = el("span", { class: "cg-hb-count" });
    live.subtitleCount = el("span", { class: "cg-hb-count" });
    const field = (key, name, count) => el("label", { class: "cg-field" },
      el("span", { class: "cg-hb-fieldhead" }, el("span", { class: "cg-label" }, name), count),
      el("input", { type: "text", class: "cg-input", "data-cg-field": `hb-${key}`, value: current[key] ?? "", autocomplete: "off" }));
    return el("div", { class: "cg-hb-sec" },
      field("title", "Title", live.titleCount),
      field("subtitle", "Subtitle", live.subtitleCount),
      el("label", { class: "cg-field" }, el("span", { class: "cg-label" }, "Button word"),
        el("select", { class: "cg-select", "data-cg-field": "hb-cta" },
          el("option", { value: "", selected: !current.cta }, "No button"),
          ...registry.ctas.map(([key, name]) => el("option", { value: key, selected: current.cta === key }, name)))));
  }

  function backgroundSection(current) {
    const post = current.background_post_id ?? null;
    const radio = (attrs, checked, ...kids) => el("button", { type: "button", role: "radio", "aria-checked": String(checked), tabindex: checked ? 0 : -1, ...attrs }, ...kids);
    const thumb = (slide) => radio({ class: "cg-thumb mod-blacklist-target", "data-cg-act": "hb-bg", title: `post #${slide.id}`, ...marks(slide) }, slide.id === post,
      el("img", { src: slide.thumb || slide.src, alt: "", loading: "lazy", draggable: "false" }));
    const slides = posts ? posts.slides : [];
    // The post in place that is not among those offered: hidden from the
    // creator now, or no longer theirs. It stays, by its number.
    const missing = post && !slides.some((slide) => slide.id === post)
      ? [ctx.slideOf(post) ? thumb(ctx.slideOf(post)) : radio({ class: "cg-thumb", "data-cg-act": "hb-bg", "data-id": post }, true, el("span", { class: "cg-thumb-cap" }, `#${post}`))]
      : [];
    let offered = [el("p", { class: "cg-note" }, "Finding your posts...")];
    if (posts === false) {
      offered = [el("p", { class: "cg-note" }, "Your posts did not load. Close the builder and open it again to retry.")];
    } else if (posts) {
      offered = [
        ...(posts.total > posts.slides.length ? [el("p", { class: "cg-note" }, `${posts.slides.length} of ${posts.total} posts are shown: the newest ${posts.cap} at most, and only those you may see.`)] : []),
        el("div", { class: "cg-hb-posts cg-scroll" }, ...missing, ...slides.map(thumb)),
      ];
    } else if (missing.length) {
      offered = [el("div", { class: "cg-hb-posts cg-scroll" }, ...missing)];
    }
    const gradient = post ? undefined : (current.background_gradient ?? null);
    const ranges = SETTINGS.map(([key, name, range]) => {
      const [low, max] = limits[range];
      const min = key === "shade" ? shadeFloor : low;
      const value = current[key] ?? registry.defaults[key];
      return el("label", { class: "cg-hb-range" }, el("span", { class: "cg-label" }, name),
        el("input", { type: "range", min, max, value, "data-cg-field": `hb-${key}`, disabled: !post }),
        el("output", {}, `${value}%`));
    });
    return el("div", { class: "cg-hb-sec" },
      el("div", { class: "cg-hb-bgs", role: "radiogroup", "aria-label": "Background" },
        el("span", { class: "cg-label" }, "Your posts"),
        ...offered,
        el("span", { class: "cg-label" }, "Gradients"),
        el("div", { class: "cg-hb-grads" }, ...[[null, "Ground"], ...registry.gradients].map(([key, name]) => radio(
          { class: "cg-hb-swatch", "data-cg-act": "hb-grad", "data-v": key ?? "" }, gradient === key,
          el("span", { class: `cg-hm-grad cg-hm-grad--${key ?? 0}` }), el("span", { class: "cg-hb-swatch-name" }, name))))),
      el("div", { class: "cg-hb-ranges" }, ...ranges),
      el("p", { class: "cg-note" }, post
        ? `Words sit on the picture, so the shade has a floor of ${shadeFloor}%.`
        : "A gradient is drawn dark enough for words, so it takes no focus, zoom or shade."));
  }

  function placesSection(current) {
    const places = current.places ?? {};
    const [, pickName] = ELEMENTS.find(([key]) => key === pick);
    const preset = registry.presets.find(([, , set]) => ELEMENTS.every(([key]) => (set[key] ?? "") === (places[key] ?? "")))?.[0];
    const cells = registry.places.map((code) => {
      const here = ELEMENTS.filter(([key]) => places[key] === code).map(([, name]) => name);
      return el("button", {
        type: "button", class: "cg-hb-place", role: "radio", "aria-checked": String(places[pick] === code), "data-cg-act": "hb-place", "data-v": code,
        "aria-label": here.length ? `${code}: ${here.join(", ")}` : code,
      }, el("b", {}, code), el("span", {}, here.join(", ")));
    });
    // One place in the grid is in the tab order: the one picked, or the first.
    const tabbed = cells.find((cell) => cell.getAttribute("aria-checked") === "true") ?? cells[0];
    cells.forEach((cell) => cell.setAttribute("tabindex", cell === tabbed ? "0" : "-1"));
    return el("div", { class: "cg-hb-sec" },
      el("span", { class: "cg-label" }, "Places"),
      el("div", { class: "cg-seg", role: "group", "aria-label": "Presets" }, ...registry.presets.map(([key, name]) => el("button", {
        type: "button", "data-cg-act": "hb-preset", "data-v": key, "aria-pressed": String(key === preset),
      }, name))),
      el("div", { class: "cg-hb-chips", role: "radiogroup", "aria-label": "Element to place" }, ...ELEMENTS.map(([key, name]) => el("button", {
        type: "button", class: "cg-hb-chip", role: "radio", "aria-checked": String(key === pick), tabindex: key === pick ? 0 : -1, "data-cg-act": "hb-pick", "data-v": key,
      }, name))),
      el("div", { class: "cg-hb-places", role: "radiogroup", "aria-label": `Place for the ${pickName.toLowerCase()}` }, ...cells),
      pick === "mark" && el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-place", "data-v": "", "aria-pressed": String(!places.mark) }, "No mark"),
      el("p", { class: "cg-note" }, "Drag a word on the card, or pick it here and then its place."));
  }

  function moderation(current, locked) {
    const token = document.querySelector("meta[name='csrf-token']")?.content ?? "";
    live.modNote = el("p", { class: "cg-note" }, current.id ? "Save or discard first: hiding reloads the page." : "Save it first: only a saved harmonic can be hidden.");
    live.mod = el("form", { method: "post", action: ctx.saveUrl, class: "cg-hb-mod" },
      el("input", { type: "hidden", name: "_method", value: "patch" }),
      el("input", { type: "hidden", name: "authenticity_token", value: token }),
      el("input", { type: "hidden", name: locked ? "harmonic_unhide" : "harmonic_hide", value: current.id ?? "" }),
      el("span", { class: "cg-label" }, "Staff"),
      !locked && el("input", { type: "text", name: "reason", class: "cg-input", "data-cg-field": "hb-reason", placeholder: "Reason, shown to the owner", autocomplete: "off" }),
      el("button", { type: "submit", class: "cg-btn cg-btn--sm" }, locked ? "Show again" : "Hide from the page"),
      live.modNote);
    return live.mod;
  }

  function foot(current, list, locked) {
    return el("div", { class: "cg-hb-foot" },
      el("label", { class: "cg-check" }, el("input", { type: "checkbox", "data-cg-field": "hb-shown", checked: current.shown !== false, disabled: locked }), "Shown"),
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-move", "data-v": -1, disabled: index === 0 }, "Move earlier"),
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-move", "data-v": 1, disabled: index === list.length - 1 }, "Move later"),
      el("button", { type: "button", class: "cg-btn cg-btn--sm", "data-cg-act": "hb-remove", disabled: locked }, "Remove"));
  }

  function paint() {
    if (index < 0) { return; }
    const list = ctx.entries();
    const current = entry();
    // A staff-hidden harmonic is not its owner's to change: it only moves.
    const locked = Boolean(current.staff_hidden);
    // A redraw keeps the focus in the sheet: fill() puts it back on the same
    // control, and the heading takes it when that is gone or disabled.
    const held = anchor.contains(document.activeElement);
    live = {};
    ctx.fill(anchor, el("section", { class: "cg-hb cg-glass", "data-cg-build": true, "aria-label": "Harmonic builder" },
      head(list),
      el("div", { class: "cg-hb-grid" },
        stageColumn(),
        el("div", { class: "cg-hb-form" },
          locked && el("p", { class: "cg-hb-locked" }, ctx.card(index).notice),
          el("fieldset", { disabled: locked },
            linkSection(current),
            wordsSection(current),
            live.background = backgroundSection(current),
            live.places = placesSection(current)),
          el("div", { class: "cg-hb-sec", "aria-live": "polite" }, el("span", { class: "cg-label" }, "Problems"), live.problems = el("div", { class: "cg-hb-problems" })),
          foot(current, list, locked),
          ctx.isAdmin && moderation(current, locked)))));
    refresh();
    if (held && !anchor.contains(document.activeElement)) { anchor.querySelector(".cg-hb-heading h3").focus(); }
  }

  // --- opening and closing ---
  function open(i) {
    if (i !== index) { lastKey = null; }
    index = i;
    // The builder and About never show together.
    const about = root.querySelector("#modcreator-about");
    if (about) { about.hidden = true; }
    root.querySelector("[data-cg-act='about']")?.setAttribute("aria-expanded", "false");
    if (posts === null || posts === false) {
      posts = undefined;
      ctx.posts().then((answer) => {
        posts = answer ?? false;
        // Only the posts are drawn again: a field being typed in is left as it is.
        if (index >= 0) {
          ctx.fill(live.background, ...backgroundSection(entry()).childNodes);
          refresh();
        }
      });
    }
    paint();
    ctx.moved();
    // The sheet takes the focus from the card that opened it.
    anchor.querySelector(".cg-hb-heading h3").focus();
    // On a phone the builder is a sheet over the bottom of the screen: the
    // Tuner it edits goes above it.
    if (phone.matches) { root.querySelector("[data-cg-tuner]")?.scrollIntoView({ block: "start" }); }
  }

  function close() {
    // The focus goes back to the Tuner when it was in the sheet.
    const held = anchor.contains(document.activeElement) || document.activeElement === document.body;
    index = -1;
    ctx.fill(anchor);
    ctx.moved();
    if (held) { root.querySelector("[data-cg-tuner] .cg-hm:not([hidden])")?.focus(); }
  }

  // --- undo ---
  // A step is the whole list as it was, and which harmonic was in hand.
  // Typing into one field is one step until the field is left.
  const snapshot = () => ({ list: structuredClone(ctx.entries()), index });

  function record(key) {
    if (key === null || key !== lastKey) {
      undo = [...undo, snapshot()].slice(-UNDO_MAX);
      redo = [];
    }
    lastKey = key;
  }

  function restore(snap) {
    const list = ctx.entries();
    list.splice(0, Infinity, ...structuredClone(snap.list));
    lastKey = null;
    if (!list.length) {
      close();
      ctx.changed();
      return;
    }
    index = clamp(0, snap.index, list.length - 1);
    ctx.changed();
    paint();
    ctx.moved();
  }

  function back() {
    if (!undo.length) { return; }
    redo = [...redo, snapshot()];
    const snap = undo.at(-1);
    undo = undo.slice(0, -1);
    restore(snap);
  }

  function forward() {
    if (!redo.length) { return; }
    undo = [...undo, snapshot()];
    const snap = redo.at(-1);
    redo = redo.slice(0, -1);
    restore(snap);
  }

  function edit(key, change) {
    record(key);
    change(entry());
    ctx.changed();
  }

  // --- placing by drag: the word under the pointer goes to the nearest of
  // the nine places, the whole drag one step of undo ---
  function grab(e) {
    const hit = e.target.closest(`.cg-hb-stage-card :is(${GRABBED})`);
    if (!hit || e.button !== 0 || index < 0 || entry().staff_hidden) { return; }
    e.preventDefault();
    const stage = e.target.closest(".cg-hb-stage-card");
    const element = ELEMENT_OF[[...hit.classList].find((name) => name in ELEMENT_OF)];
    const life = new AbortController();
    let moved = false;
    pick = element;
    stage.setPointerCapture(e.pointerId);
    stage.addEventListener("pointermove", (m) => {
      const box = stage.querySelector(".cg-hm-safe--full").getBoundingClientRect();
      const column = clamp(0, Math.floor(((m.clientX - box.left) / box.width) * 3), 2);
      const row = clamp(0, Math.floor(((m.clientY - box.top) / box.height) * 3), 2);
      const place = `${"tmb"[row]}${"lcr"[column]}`;
      if (entry().places?.[element] === place) { return; }
      if (!moved) { record(null); }
      moved = true;
      entry().places = { ...entry().places, [element]: place };
      ctx.changed();
      refresh();
    }, { signal: life.signal });
    // The places are drawn again, and nothing else: a field being typed in
    // kept the focus through the drag, and keeps its caret.
    const drop = () => {
      life.abort();
      ctx.fill(live.places, ...placesSection(entry()).childNodes);
    };
    stage.addEventListener("pointerup", drop, { signal: life.signal });
    stage.addEventListener("pointercancel", drop, { signal: life.signal });
  }

  // --- what the controls do ---
  function choosePost(id) {
    edit(null, (harmonic) => Object.assign(harmonic, {
      background_post_id: id, background_gradient: null,
      ...Object.fromEntries(SETTINGS.map(([key]) => [key, harmonic[key] ?? registry.defaults[key]])),
    }));
    paint();
  }

  function chooseGradient(key) {
    edit(null, (harmonic) => Object.assign(harmonic, {
      background_post_id: null, background_gradient: key, ...Object.fromEntries(SETTINGS.map(([setting]) => [setting, null])),
    }));
    paint();
  }

  function move(step) {
    record(null);
    const list = ctx.entries();
    [list[index], list[index + step]] = [list[index + step], list[index]];
    index += step;
    ctx.changed();
    paint();
  }

  function remove() {
    record(null);
    const list = ctx.entries();
    list.splice(index, 1);
    if (!list.length) {
      // Nothing left to build: the Tuner's add tile is next.
      close();
      ctx.changed();
      return;
    }
    index = Math.min(index, list.length - 1);
    ctx.changed();
    paint();
  }

  function copy(line) {
    Promise.resolve().then(() => navigator.clipboard.writeText(line)).then(
      () => ctx.toast("Copied. Paste it on the intake page, or to Fourier."),
      () => ctx.toast("Could not copy. Select the line and copy it by hand."),
    );
  }

  anchor.addEventListener("click", (e) => {
    // A card here is being set, not followed.
    if (e.target.closest("a.cg-hm")) {
      e.preventDefault();
      return;
    }
    const act = e.target.closest("[data-cg-act]");
    if (!act || index < 0) { return; }
    const v = act.dataset.v;
    switch (act.dataset.cgAct) {
    case "hb-undo": back(); break;
    case "hb-redo": forward(); break;
    case "hb-done": close(); break;
    case "hb-placement": ctx.setPlacement(v); break;
    case "hb-preset":
      edit(null, (harmonic) => { harmonic.places = { ...presets.get(v) }; });
      paint();
      break;
    case "hb-pick": pick = v; paint(); break;
    case "hb-place":
      edit(null, (harmonic) => { harmonic.places = { ...harmonic.places, [pick]: v }; });
      paint();
      break;
    case "hb-bg": choosePost(Number(act.dataset.id)); break;
    case "hb-grad": chooseGradient(v === "" ? null : Number(v)); break;
    case "hb-move": move(Number(v)); break;
    case "hb-remove": remove(); break;
    case "hb-copy": copy(v); break;
    default: break;
    }
  });
  anchor.addEventListener("auxclick", (e) => { if (e.target.closest("a.cg-hm")) { e.preventDefault(); } });
  anchor.addEventListener("dragstart", (e) => e.preventDefault());
  anchor.addEventListener("pointerdown", grab);

  // Typing previews at once; the field's own text is left alone.
  anchor.addEventListener("input", (e) => {
    const field = e.target.dataset.cgField;
    if (index < 0 || !field) { return; }
    const key = field.slice("hb-".length);
    if (["url", "title", "subtitle"].includes(key)) {
      edit(`${field}:${index}`, (harmonic) => { harmonic[key] = e.target.value; });
    } else if (SETTINGS.some(([setting]) => setting === key)) {
      edit(`${field}:${index}`, (harmonic) => { harmonic[key] = Number(e.target.value); });
      e.target.nextElementSibling.textContent = `${e.target.value}%`;
    } else {
      return;
    }
    refresh();
  });

  anchor.addEventListener("change", (e) => {
    const field = e.target.dataset.cgField;
    lastKey = null;
    if (index < 0) { return; }
    if (field === "hb-cta") {
      edit(null, (harmonic) => { harmonic.cta = e.target.value || null; });
      refresh();
    } else if (field === "hb-shown") {
      edit(null, (harmonic) => { harmonic.shown = e.target.checked; });
      refresh();
    }
  });

  // Arrow keys move through a set of choices and choose as they go, without
  // wrapping; the grid of places moves by rows too.
  anchor.addEventListener("keydown", (e) => {
    const radio = e.target.closest("[role='radio']");
    const group = radio?.closest("[role='radiogroup']");
    if (!group) { return; }
    const across = group.classList.contains("cg-hb-places") ? 3 : 1;
    const step = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -across, ArrowDown: across }[e.key];
    if (step === undefined) { return; }
    e.preventDefault();
    const radios = Array.from(group.querySelectorAll("[role='radio']"));
    const at = radios.indexOf(radio);
    const target = radios[at + step];
    const leavesRow = across === 3 && Math.abs(step) === 1 && Math.floor((at + step) / 3) !== Math.floor(at / 3);
    if (!target || leavesRow) { return; }
    const selector = sameAs(target);
    target.click();
    anchor.querySelector(selector)?.focus();
  });

  document.addEventListener("keydown", (e) => {
    const inHand = anchor.contains(e.target) || e.target === document.body;
    if (index < 0 || !inHand) { return; }
    if (e.key === "Escape") {
      close();
      return;
    }
    if (!(e.ctrlKey || e.metaKey) || TYPING.has(e.target.tagName)) { return; }
    const key = e.key.toLowerCase();
    if (key === "z" && !e.shiftKey) {
      back();
    } else if ((key === "z" && e.shiftKey) || key === "y") {
      forward();
    } else {
      return;
    }
    e.preventDefault();
  });

  return {
    open,
    close,
    paint,
    // A new harmonic, one step of undo, in hand at once.
    add: (blank) => {
      record(null);
      ctx.entries().push(blank);
      ctx.changed();
      open(ctx.entries().length - 1);
    },
    // After a save the steps back lead to rows that may be gone.
    forget: () => {
      undo = [];
      redo = [];
      lastKey = null;
    },
    get index() { return index; },
  };
}
