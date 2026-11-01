import { captureRects, playFLIP, prefersReducedMotion } from "./flip";
import { POP_OUT_MS, enterDelay, pitch, withGhosts } from "./post_deck_model";

// THE POST DECK: every post picker of the creator gallery's editor -- the
// hero band's, a miniband's, the banner's and a harmonic's background -- is
// one of these (operator, 2026-11-01). Cards sit in rows that overlap, each
// row covering the foot of the one above, so a lip of every card shows
// (post_deck_model.js pitch); the pointer or the keyboard lifts a card whole
// into view. A click brings it closer, in an enlarged card over the page.
//
// A deck that picks many -- the hero's, a miniband's -- has a staging strip:
// a card dragged onto it is picked at the place it is let go, a staged card
// dragged off it is taken off, and a card let go anywhere else settles back.
// A deck that chooses one -- the banner, a background -- chooses on a click
// and enlarges from the corner of the card, or from the keyboard on "+".
//
// Every card, the enlarged one and the dragged one are the editor's one
// thumb() and go through its fill(), so the blacklist hides a post in each of
// them (Blacklist#adopt).
//
// The drag's feel is Technetium's src/ui/threadDrag.ts (its constants, the
// follow's lerp and the settle back); the strip's motion is src/ui/flip.ts
// (flip.js), src/client/useTagDiff.ts and src/ui/pop.ts (post_deck_model.js).

const THRESHOLD_PX = 5;
const LERP = 0.25;
const LIFT_SCALE = 1.03;
const TILT_DEG = 1;
const CANCEL_MS = 220;
const CANCEL_EASE = "cubic-bezier(0.34, 1.4, 0.64, 1)";
const CLICK_SUPPRESS_MS = 400;
const LIFT_SHADOW = "0 8px 20px rgba(0,0,0,0.45)";
// A finger held still this long picks the card up; one that moves first is
// scrolling the deck.
const LONG_PRESS_MS = 300;
const POP_MS = 240;
const POP_EASE = "cubic-bezier(0.2, 0, 0, 1)";

function el(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  Object.entries(attrs).filter(([, v]) => v !== false && v !== null && v !== undefined)
    .forEach(([k, v]) => node.setAttribute(k, v === true ? "" : String(v)));
  node.append(...kids);
  return node;
}

const inside = (rect, x, y) => x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;

const STOPS = "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])";

// Tab and Shift+Tab go round `box` while it is open over the page (a modal
// window: the enlarged card, a miniband's window) and never out to the page
// behind it, which the window keeps from the pointer as well.
export function keepTab(e, box) {
  if (e.key !== "Tab") { return; }
  // A tabindex of -1 (the enlarged card's picture, a roving deck's other
  // cards) is no stop, though a button: Tab passes it by.
  const stops = [...box.querySelectorAll(STOPS)].filter((node) => node.tabIndex >= 0 && node.getClientRects().length && !node.closest("[inert]"));
  const at = document.activeElement;
  const edge = e.shiftKey ? stops[0] : stops.at(-1);
  if (box.contains(at) && at !== edge && !(e.shiftKey && at === box)) { return; }
  e.preventDefault();
  (e.shiftKey ? stops.at(-1) : stops[0])?.focus({ preventScroll: true });
}

// @param root the editor's page: the enlarged card and the dragged one hang
//   from it, over everything, so no clipped box cuts them off
// @param kit the editor's thumb(slide, attrs, ...kids), picture(slide) (the
//   larger picture) and fill(region, ...nodes)
// @return { deck(slides, opts), stage(name, items, opts), restage(box, draw),
//   closePop(), popOpen }
export function postDecks(root, { thumb, picture, fill }) {
  let pop = null;
  let quietUntil = 0;

  // --- the enlarged card -------------------------------------------------
  // The transform that puts the enlarged card over the thumb it came from.
  function towards(box, card) {
    const to = box.getBoundingClientRect();
    const from = card.getBoundingClientRect();
    return `translate(${from.left - to.left}px, ${from.top - to.top}px) scale(${from.width / to.width})`;
  }

  function closePop() {
    if (!pop) { return; }
    const { box, card, life } = pop;
    pop = null;
    life.abort();
    const gone = () => {
      fill(box);
      box.remove();
    };
    if (card.isConnected && document.activeElement && box.contains(document.activeElement)) { card.focus({ preventScroll: true }); }
    if (!card.isConnected || prefersReducedMotion()) {
      box.animate([{ opacity: 1 }, { opacity: 0 }], { duration: prefersReducedMotion() ? 120 : 1, easing: "ease-out" }).onfinish = gone;
      return;
    }
    box.animate([{ transform: "none", opacity: 1 }, { transform: towards(box, card), opacity: 0.4 }], { duration: POP_MS * 0.8, easing: POP_EASE }).onfinish = gone;
  }

  function openPop(card, slide, { act, note }) {
    closePop();
    const art = thumb(slide, { tabindex: "-1", "aria-hidden": "true" });
    art.querySelector("img").src = picture(slide);
    const button = act
      ? el("button", { type: "button", class: "cg-btn cg-btn--go", ...act.attrs, disabled: act.disabled }, act.text)
      // One choice: the card's own click chooses it.
      : el("button", { type: "button", class: "cg-btn cg-btn--go", disabled: card.getAttribute("aria-checked") === "true" || card.getAttribute("aria-pressed") === "true" }, "Choose");
    const box = el("div", { class: "cg-deck-pop", role: "dialog", "aria-modal": "true", "aria-label": `Post #${slide.id}` });
    root.append(box);
    fill(box, art, el("div", { class: "cg-deck-pop-foot" },
      el("span", { class: "cg-deck-pop-id" }, `#${slide.id}`),
      ...(note ? [el("span", { class: "cg-deck-pop-note" }, note)] : []),
      button));
    const life = new AbortController();
    pop = { box, card, life };
    // The action is the editor's (its own listener on the page): the card
    // closes once it is done.
    button.addEventListener("click", () => {
      if (!act) { card.click(); }
      closePop();
    });
    const on = (type, fn) => document.addEventListener(type, fn, { capture: true, signal: life.signal });
    // A press outside closes it, and does nothing else to an open window
    // under it: the window waits for the next one (popOpen).
    on("pointerdown", (e) => { if (!box.contains(e.target)) { closePop(); } });
    // Escape closes the card alone, not the sheet or window under it; Tab
    // stays in it.
    on("keydown", (e) => {
      if (e.key !== "Escape") {
        keepTab(e, box);
        return;
      }
      e.stopPropagation();
      closePop();
    });
    on("scroll", (e) => { if (!box.contains(e.target)) { closePop(); } });
    if (prefersReducedMotion()) {
      box.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 160, easing: "ease-out" });
    } else {
      box.animate([{ transform: towards(box, card), opacity: 0.4 }, { transform: "none", opacity: 1 }], { duration: POP_MS, easing: POP_EASE });
    }
    button.focus({ preventScroll: true });
  }

  // --- dragging ----------------------------------------------------------
  //
  // From a press on `card` to its release: past THRESHOLD_PX (a mouse) or a
  // long press (a finger), a copy of the card follows the pointer. `strip`
  // names the staging strip it may be let go on; `drop(index)` is that, `off()`
  // is a staged card let go outside it, and anything else settles back.
  function press(e, card, slide, { strip, drop, off }) {
    const start = { x: e.clientX, y: e.clientY };
    const touch = e.pointerType === "touch";
    const life = new AbortController();
    const on = (target, type, fn, opts = {}) => target.addEventListener(type, fn, { ...opts, signal: life.signal });
    let armed = !touch;
    let ghost = null;
    let frame = 0;
    let at = null;
    let to = null;
    let grip = null;
    let tilt = 0;
    const timer = touch ? setTimeout(() => { armed = true; card.classList.add("is-armed"); }, LONG_PRESS_MS) : 0;
    const stripNow = () => root.querySelector(`.cg-stage[data-stage="${strip}"]`);

    const end = () => {
      clearTimeout(timer);
      cancelAnimationFrame(frame);
      life.abort();
      card.classList.remove("is-armed", "is-lifted");
      stripNow()?.classList.remove("is-over");
    };
    const unghost = () => {
      if (!ghost) { return; }
      fill(ghost);
      ghost.remove();
    };

    function follow() {
      const reduced = prefersReducedMotion();
      at = reduced ? { ...to } : { x: at.x + ((to.x - at.x) * LERP), y: at.y + ((to.y - at.y) * LERP) };
      ghost.style.transform = `translate(${at.x}px, ${at.y}px)${reduced ? "" : ` rotate(${tilt}deg) scale(${LIFT_SCALE})`}`;
      if (Math.abs(to.x - at.x) > 0.5 || Math.abs(to.y - at.y) > 0.5) { frame = requestAnimationFrame(follow); } else { frame = 0; }
    }

    function lift() {
      const rect = card.getBoundingClientRect();
      grip = { x: start.x - rect.left, y: start.y - rect.top };
      at = { x: rect.left, y: rect.top };
      to = { ...at };
      ghost = el("div", { class: "cg-deck-ghost", "aria-hidden": "true", style: `width: ${rect.width}px; height: ${rect.height}px; transform: translate(${rect.left}px, ${rect.top}px); box-shadow: ${LIFT_SHADOW}` });
      root.append(ghost);
      fill(ghost, thumb(slide, { tabindex: "-1" }));
      card.classList.add("is-lifted");
      card.setPointerCapture(e.pointerId);
    }

    // Let go anywhere else: back to its place.
    function settle() {
      const rect = card.getBoundingClientRect();
      const home = `translate(${rect.left}px, ${rect.top}px)`;
      card.classList.add("is-settling");
      const done = () => {
        card.classList.remove("is-settling");
        unghost();
      };
      if (!card.isConnected) {
        done();
        return;
      }
      ghost.animate([{ transform: ghost.style.transform }, { transform: home }], { duration: prefersReducedMotion() ? 1 : CANCEL_MS, easing: CANCEL_EASE, fill: "forwards" }).onfinish = done;
    }

    // Held still, a finger owns the card: the page neither scrolls under it
    // nor offers the picture's own menu.
    on(card, "touchmove", (m) => { if (armed) { m.preventDefault(); } }, { passive: false });
    on(card, "contextmenu", (m) => { if (armed) { m.preventDefault(); } });
    on(document, "pointermove", (m) => {
      if (m.pointerId !== e.pointerId) { return; }
      const far = Math.hypot(m.clientX - start.x, m.clientY - start.y) > THRESHOLD_PX;
      if (!ghost) {
        // A finger that moves before the long press is scrolling.
        if (far && !armed) { end(); }
        if (!far || !armed) { return; }
        lift();
      }
      const x = m.clientX - grip.x;
      tilt = Math.sign(x - to.x) * TILT_DEG;
      to = { x, y: m.clientY - grip.y };
      stripNow()?.classList.toggle("is-over", inside(stripNow().getBoundingClientRect(), m.clientX, m.clientY));
      if (!frame) { frame = requestAnimationFrame(follow); }
    });
    // Up anywhere: the capture is the card's only once the drag began.
    on(document, "pointerup", (u) => {
      if (u.pointerId !== e.pointerId) { return; }
      const target = stripNow();
      end();
      if (!ghost) { return; }
      quietUntil = performance.now() + CLICK_SUPPRESS_MS;
      if (target && inside(target.getBoundingClientRect(), u.clientX, u.clientY) && drop) {
        // Before the cards that start right of the pointer, the dragged one aside.
        const index = [...target.querySelectorAll("[data-flip-id]")]
          .filter((item) => item.dataset.flipId !== String(slide.id))
          .filter((item) => { const r = item.getBoundingClientRect(); return r.left + (r.width / 2) < u.clientX; }).length;
        unghost();
        drop(index);
      } else if (off) {
        unghost();
        off();
      } else {
        settle();
      }
    });
    on(document, "pointercancel", (u) => {
      if (u.pointerId !== e.pointerId) { return; }
      end();
      if (ghost) { settle(); }
    });
  }

  // --- the deck ------------------------------------------------------------
  //
  // @param slides the posts to offer
  // @param opts size (a card's width, px); label (the list's name);
  //   card(slide) -> [attrs, ...kids] for the card (thumb's own);
  //   note(slide) -> a sentence the card and the enlarged card show, or null;
  //   blocked(slide) -> true when it may not be picked now;
  //   act(slide) -> { attrs, text, disabled, why } for the enlarged card's button,
  //     which the editor's own listener acts on -- a deck that picks many;
  //     without it, the deck chooses one, on the card's own click;
  //   strip (the staging strip's name) and drop(id, index) -- the drag
  // @return the deck's element, for fill()
  function deck(slides, opts) {
    const h = Math.round(opts.size * 1.25);
    const box = el("div", {
      class: `cg-deck cg-scroll${opts.act ? "" : " cg-deck--one"}`, role: opts.act ? "group" : null, "aria-label": opts.label,
      style: `--deck-w: ${opts.size}px; --deck-h: ${h}px; --deck-pitch: ${pitch(h)}px; --deck-foot: ${h - pitch(h)}px`,
    });
    const byId = new Map(slides.map((s) => [String(s.id), s]));
    box.append(...slides.map((slide) => {
      const [attrs, ...kids] = opts.card(slide);
      const note = opts.note?.(slide);
      const blocked = opts.blocked?.(slide);
      return thumb(slide, {
        ...attrs, class: `cg-thumb mod-blacklist-target cg-deck-card${blocked ? " is-blocked" : ""}`,
        "aria-haspopup": opts.act ? "dialog" : null, "aria-disabled": blocked ? "true" : null, "aria-keyshortcuts": opts.act ? null : "+",
      }, ...kids,
      ...(note ? [el("span", { class: "cg-deck-note" }, note)] : []),
      ...(opts.act ? [] : [el("span", { class: "cg-deck-zoom", "aria-hidden": "true", title: "Bring it closer (+)" }, "+")]));
    }));
    const slideOf = (card) => byId.get(card.dataset.id);
    // The enlarged card says why a post may not be picked, as well as where else it is.
    const popOf = (card) => {
      const act = opts.act?.(slideOf(card));
      return { act, note: [opts.note?.(slideOf(card)), act?.why].filter(Boolean).join(". ") || null };
    };

    // A touch has no hover: the first tap lifts the card, the next opens it.
    let lastTouch = false;
    box.addEventListener("pointerdown", (e) => {
      const card = e.target.closest(".cg-deck-card");
      lastTouch = e.pointerType === "touch";
      if (!card || e.button !== 0 || !opts.strip) { return; }
      const slide = slideOf(card);
      press(e, card, slide, { strip: opts.strip, drop: opts.blocked?.(slide) ? null : (index) => opts.drop(slide.id, index) });
    });
    box.addEventListener("click", (e) => {
      const card = e.target.closest(".cg-deck-card");
      if (!card) { return; }
      const zoom = e.target.closest(".cg-deck-zoom");
      // The click a drag ends with is not a click.
      if (performance.now() < quietUntil) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      if (lastTouch && opts.act && !card.classList.contains("is-touched")) {
        e.preventDefault();
        box.querySelectorAll(".is-touched").forEach((other) => other.classList.remove("is-touched"));
        card.classList.add("is-touched");
        return;
      }
      if (!opts.act && !zoom) { return; }
      e.preventDefault();
      e.stopPropagation();
      openPop(card, slideOf(card), popOf(card));
    });
    // The corner's "+" is the pointer's; the keyboard's is the key itself.
    box.addEventListener("keydown", (e) => {
      const card = e.target.closest(".cg-deck-card");
      if (opts.act || !card || e.key !== "+") { return; }
      e.preventDefault();
      openPop(card, slideOf(card), popOf(card));
    });
    return box;
  }

  // --- the staging strip -------------------------------------------------
  //
  // @param name the strip's name, which its deck's `strip` names
  // @param items the staged posts, in order, each an element with
  //   data-flip-id (the post's id) holding its card
  // @param opts empty (the sentence an empty strip shows), slideOf(id),
  //   drop(id, index) (moved along it) and off(id) (dragged off it)
  function stage(name, items, opts) {
    const strip = el("div", { class: "cg-stage cg-scroll", "data-stage": name, role: "list", "aria-label": opts.label },
      ...(items.length ? items : [el("p", { class: "cg-stage-empty cg-note" }, opts.empty)]));
    strip.addEventListener("pointerdown", (e) => {
      const card = e.target.closest(".cg-thumb");
      const item = card?.closest("[data-flip-id]");
      const slide = item && opts.slideOf(Number(item.dataset.flipId));
      if (!slide || e.button !== 0) { return; }
      press(e, card, slide, { strip: name, drop: (index) => opts.drop(slide.id, index), off: () => opts.off(slide.id) });
    });
    strip.addEventListener("click", (e) => {
      if (performance.now() < quietUntil) {
        e.preventDefault();
        e.stopPropagation();
      }
    }, true);
    return strip;
  }

  // Redraw `box` with `draw`, and move each staging strip in it from what it
  // was to what it is: a card that stayed slides to its new place, a new one
  // pops in, one taken off pops out where it was. A strip drawn for the first
  // time only sets the baseline.
  function restage(box, draw) {
    const before = new Map([...box.querySelectorAll(".cg-stage")].map((strip) => [strip.dataset.stage, {
      rects: captureRects(strip),
      nodes: new Map([...strip.querySelectorAll("[data-flip-id]")].map((item) => [item.dataset.flipId, item])),
    }]));
    draw();
    box.querySelectorAll(".cg-stage").forEach((strip) => {
      const old = before.get(strip.dataset.stage);
      if (!old) { return; }
      const items = [...strip.querySelectorAll("[data-flip-id]")];
      const ids = items.map((item) => item.dataset.flipId);
      const was = [...old.nodes.keys()];
      const entering = new Set(ids.filter((id) => !old.nodes.has(id)));
      const gone = was.filter((id) => !ids.includes(id));
      // A leaving card is the old one, put back where it was, out of reach.
      const ghosts = withGhosts(ids, was, entering, gone).map(({ id, phase }) => {
        if (phase !== "leaving") { return strip.querySelector(`[data-flip-id="${id}"]`); }
        const ghost = old.nodes.get(id);
        delete ghost.dataset.flipId;
        ghost.classList.add("cg-deck-out");
        ghost.setAttribute("aria-hidden", "true");
        ghost.inert = true;
        return ghost;
      });
      if (gone.length) { strip.append(...ghosts); }
      [...entering].forEach((id, n) => {
        const item = strip.querySelector(`[data-flip-id="${id}"]`);
        item.classList.add("cg-deck-in");
        item.style.animationDelay = `${enterDelay(n)}ms`;
      });
      playFLIP(strip, old.rects);
      if (!gone.length) { return; }
      // The ghosts go once they have popped out; whoever was beside them
      // slides into the room they leave.
      setTimeout(() => {
        if (!strip.isConnected) { return; }
        const prev = captureRects(strip);
        strip.querySelectorAll(".cg-deck-out").forEach((ghost) => ghost.remove());
        playFLIP(strip, prev);
      }, POP_OUT_MS);
    });
  }

  return {
    deck,
    stage,
    restage,
    closePop,
    get popOpen() { return Boolean(pop); },
  };
}
