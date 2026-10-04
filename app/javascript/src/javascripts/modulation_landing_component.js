import Notice from "./notice";
import { WHEEL_IDLE, wheelStep } from "./fourier_wheel_step";
import CreatorLamps from "./creator_lamps";

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
  if (root.dataset.modlandBooted) { return; }
  root.dataset.modlandBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const region = (name) => root.querySelector(`[data-region="${name}"]`);
  const ride = region("ride");
  if (!ride) { return; }

  const cats = cfg.categories || [];
  if (!cats.length) { return; }

  let axis = 0;
  let pos = 0;
  let runLeft = 0;
  let advanceTimer = null;
  let resumeTimer = null;
  let busy = false;
  let started = false; // see start(): nothing is drawn before the blacklist has applied

  const esc = (s) => String(s === null || s === undefined ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  // A slide the viewer's blacklist has marked is skipped. The marks live on the
  // hidden pool elements, because that is what the blacklist can see.
  //
  // Read live, in ONE query per list: a rule toggled on is honoured by the very
  // next draw, and nothing has to be told. This asked the pool once PER SLIDE --
  // 213 queries per call, dozens of calls per step (at() and usable() both
  // filter the whole row) -- and was a quarter of each step's main thread in
  // Firefox (2026-10-03).
  const blockedIds = () => new Set(Array.from(root.querySelectorAll(".modland-poolitem.blacklisted-active"), (el) => el.dataset.id));

  // THE CREATOR, AS THEIR ARTIST PILL. The name under a card and in the credit
  // line is the creator's artist tag drawn as it is everywhere else on the
  // site -- the category pill with its activity lamp (operator, 2026-10-01) --
  // linking to their posts. One watcher for the page: lit at render from the
  // payload, re-read while the page is visible, for every artist the rows
  // credit, so a pill built after the last poll is painted from the same answer.
  const lamps = new CreatorLamps(root, {
    live: cfg.liveCreators || [],
    windowSeconds: cfg.liveWindow || 300,
    names: () => Array.from(new Set(cats.flatMap((c) => (c.slides || []).map((s) => s.creator && s.creator.tag).filter(Boolean)))),
  });
  function artistPill(creator) {
    const pill = document.createElement("a");
    pill.className = "mod-pill mod-pill--cat mod-pill--cat-artist";
    pill.href = creator.url;
    pill.dataset.tag = creator.tag;
    const dot = document.createElement("span");
    dot.className = "mod-pill-dot";
    const label = document.createElement("span");
    label.className = "mod-pill-label";
    label.textContent = creator.name;
    pill.append(dot, label);
    lamps.paint(pill);
    return pill;
  }

  const slidesOf = (a) => {
    const ids = blockedIds();
    return (cats[a] && cats[a].slides ? cats[a].slides : []).filter((s) => !ids.has(String(s.id)));
  };

  // A row with nothing left once the blacklist has had its say is not a row:
  // its tab hides, and moving between rows passes over it. The server drops
  // rows that are empty for EVERYONE; this is the same rule for the rows a
  // viewer's own blacklist empties.
  const usable = (a) => slidesOf(a).length > 0;
  function nextUsable(from, direction) {
    for (let i = 1; i <= cats.length; i++) {
      const a = (((from + (direction * i)) % cats.length) + cats.length) % cats.length;
      if (usable(a)) { return a; }
    }
    return -1;
  }

  // Each axis wraps at its own length, which is what lets categories of
  // different sizes stay lined up under one shared position.
  function at(a, p) {
    const list = slidesOf(a);
    if (!list.length) { return null; }
    return list[((p % list.length) + list.length) % list.length];
  }

  // --- the belt -----------------------------------------------------------
  //
  // One run of cells along the current axis, magnified in the middle. Every
  // cell is built ONCE per slide and thereafter only moved: its position, size
  // and opacity are custom properties derived from its signed distance from the
  // centre, and advancing the position rewrites all of them in the same frame.
  //
  // That is the whole mechanism, and it is why the run now moves as one object.
  // The version this replaces animated exactly two cells -- the incoming
  // neighbour and the outgoing centre -- by measuring their rects and
  // transforming them, then re-rendered everything else at the destination. Two
  // things sliding while the rest cut is not a conveyor; it reads as a swap
  // with scenery. Nothing here is measured, nothing is destroyed, and no cell
  // is special-cased for travelling. The belt just gets a new set of numbers.
  const RANKS = 3; // cells visible either side of the focus, by default
  // Per axis, from the payload. A row may say how many slides it wants on
  // screen (`visible`); a creators row defaults to one per creator. Halved
  // and rounded UP, because the belt is symmetric about a focus and a count
  // with no middle rounds to the wider belt rather than hiding a creator.
  // Capped by what the row actually has, so a belt is never told to show
  // more cells than it holds.
  // The outermost cell must stay a cell. FALLOFF is tuned for three a side;
  // applied to fifteen it leaves the far ones at two percent of the focus,
  // which is a paint for nothing and a run that looks like seven slides
  // whatever the setting says. For a wider run the shrink per rank is chosen
  // so the last rank is still MIN_OUTER of the first neighbour.
  const MIN_OUTER = 0.12;
  const FALLOFF = 0.72; // each further cell against the one before it
  function falloffFor(ranks) {
    if (ranks <= RANKS) { return FALLOFF; }
    return Math.pow(MIN_OUTER, 1 / (ranks - 1));
  }
  // THE HERO BAND shows more of the run, in proportion to the width it
  // gained: the band's normal width is the column's, and every extra column's
  // worth of belt is another column's worth of cards. Measured, not assumed --
  // a 1440px screen is 1.3 columns, a 2560px one is 2.3 -- so the setting's
  // count still means what the admin set on a band that has not been widened.
  const COLUMN_W = 1120;
  // THE BELT'S SIZE IS READ ONLY WHEN IT MAY HAVE CHANGED. render() wrote a
  // cell's variables and then asked the belt's size again for the next cell,
  // and a read after a write makes the browser lay the page out before it can
  // answer: 22 forced layouts and 91ms of main thread per step in Firefox
  // (2026-10-03). Read once per draw it was still one forced layout a step
  // (8ms in a held run). Now a ResizeObserver says when the belt changed size,
  // and the window and the hero band say so themselves, since they redraw in
  // the same frame, before the observer has run.
  let beltBox = { w: 800, h: 400, panel: Infinity }; // .panel: the stage wrap's width
  let beltStale = true;
  let beltWatch = null;
  function heroScale() {
    if (!root.classList.contains("is-hero-max")) { return 1; }
    return beltBox.w > COLUMN_W ? beltBox.w / COLUMN_W : 1;
  }
  function ranksFor(a) {
    const cat = cats[a];
    const want = cat && cat.visible;
    if (!want) { return RANKS; }
    // NOT capped by how many slides the row holds. `at()` wraps each axis at
    // its own length, so a belt wider than the row simply repeats -- and
    // capping here let a data value (how many posts were gathered) quietly
    // decide a presentation one. Operator ruling 2026-09-22: unlink them.
    const wanted = Math.round(want * heroScale());
    return Math.max(0, Math.ceil((wanted - 1) / 2));
  }
  const HEAD_H = 0.42; // first neighbour's height, as a fraction of the focus
  const HEAD_O = 0.55; // and the same idea for opacity
  const FALLOFF_O = 0.62;
  const THUMB_RATIO = 0.8; // w/h of a non-focus cell: fixed, so the focal
  // cell's true aspect is what makes the border
  // morph as it arrives
  const GAP = 18; // px between focus and first neighbour
  const GAP_FALLOFF = 0.78;

  // ONE CLOCK FOR THE WHOLE MOVE. At 430ms, with the size on its own curve and
  // the border's colour on a 900ms one, a step read as a pop: the cell jumped,
  // then grew, then changed colour (operator, 2026-09-25: "it kind of pops from
  // one place to the other. disjointed" -- slow it so the resize happens as the
  // border changes colour). Position, size and border now share this duration
  // (fly() gives every animation of a move the same one), so they arrive
  // together. A held arrow still speeds the run up; see step().
  const BASE_MS = 850;
  const MIN_MS = 200; // floor for a held-down arrow
  const SETTLE_MS = 180; // quiet time that counts as "the run stopped"
  // Overshoot is part of the travel, not a twitch after it. A back-out curve
  // carries a cell past its slot and brings it back inside one continuous
  // movement -- which is what the ask was: the cell arrives at speed, goes too
  // far, and settles. What this replaces played a separate keyframe animation
  // on the whole belt AFTER the move had finished, so the picture visibly came
  // to a stop and only then jerked, which reads as a glitch rather than mass.
  //
  // y1 is what sets how far past. It grows with the run so a long scroll lands
  // harder, and it is capped where the overshoot reaches roughly one cell --
  // beyond that the incoming cell crosses into its neighbour's slot and the run
  // stops reading as a run.
  // Tuned against measurement, not taste. The overshoot a back-out curve
  // produces is a fraction of the distance THAT transition covers, and during a
  // fast run the last one covers several slots -- so a curve that is a pleasant
  // nudge on a single step became 225px, or 162% of a cell, after ten. These
  // numbers keep the worst case inside one cell while leaving a single step
  // clearly springy. Softened 2026-09-25 with the longer move: at 850ms the
  // old single-step overshoot read as a bounce, not as weight.
  const EASE_Y1_BASE = 1.2;
  const EASE_Y1_STEP = 0.22;
  const EASE_Y1_MAX = 2.72;

  function easeFor(n) {
    return Number(Math.min(EASE_Y1_BASE + (n * EASE_Y1_STEP), EASE_Y1_MAX).toFixed(2));
  }
  const NAV_MS = 260;

  const failed = new Set(); // slide ids whose media will not load
  const cells = new Map(); // `${axis}:${id}` -> element

  let burst = 0; // steps since the run last came to rest
  let lastStepAt = 0; // performance.now() of the last step, for its interval
  let settleTimer = null;

  // A failure changes a cell's SHAPE, not just its contents -- a failed cell is
  // card-shaped rather than picture-shaped -- so the run has to be laid out
  // again once one arrives. Coalesced to one redraw per frame because on a
  // signed-out visit every cell fails, and each of them failing separately
  // would otherwise relayout the whole belt.
  let redrawQueued = false;

  function scheduleRender() {
    if (redrawQueued) { return; }
    redrawQueued = true;
    // render() is declared after the geometry helpers it calls, so writing it
    // above scheduleRender only moves this error onto those ten. The reference
    // lives in a frame callback and resolves long after the declaration is
    // evaluated. The disable is one line because a multi-line one does not
    // reach past its own continuation comments.
    // eslint-disable-next-line no-use-before-define
    requestAnimationFrame(() => { redrawQueued = false; render(); });
  }

  function mediaEl(slide) {
    const el = document.createElement(slide.kind === "video" ? "video" : "img");
    // Every cell's media carries .mod-image, so a failure anywhere on the belt
    // becomes an error card rather than a broken icon. That is a change from
    // the stacked flanks, where a card sized for the stage was unreadable at
    // 122px and six of them were worse than the glyph. A belt cell is far
    // larger, and a run of identical "401" cards reads as a locked archive --
    // which is exactly what it is.
    el.className = "mod-image";
    // A VIDEO PLAYS ONLY WHILE IT CAN BE SEEN. render() starts it when its
    // cell is shown AND inside the panel, and stops it otherwise; nothing here
    // starts it. It used to autoplay from the moment it was built, and a cell
    // is built two ranks before it is shown and kept two ranks after -- at
    // opacity 0, still in the viewport, so the browser kept decoding a picture
    // nobody could see: one offstage loop measured 31.7% of a core against
    // 13.0% paused, same page, headless Chromium with GPU compositing
    // (2026-09-25). "Shown" is not enough on its own: the panel clips the run,
    // and with a wide picture in focus only two ranks either side are inside
    // it (measured: 5 of the 13 shown cells at 1600px).
    // preload="auto" is what keeps the rule above: the first frame is fetched
    // and decoded while the cell waits, so it arrives as a picture, not a hole.
    if (slide.kind === "video") {
      el.muted = true;
      el.playsInline = true;
      el.loop = true;
      el.preload = "auto";
    } else {
      el.alt = "";
    }
    el.addEventListener("error", () => {
      failed.add(String(slide.id));
      const cell = el.closest(".mod-cell");
      if (cell) { cell.classList.add("is-failed"); }
      scheduleRender();
    }, { once: true });
    el.src = (slide.kind === "video" ? null : slide.thumb) || slide.src;
    return el;
  }

  function buildCell(a, slide) {
    const cell = document.createElement("a");
    cell.className = "mod-cell";
    cell.href = slide.url || "#";
    cell.title = cats[a].label;
    cell.slide = slide;

    // What the cell shows lives in its clip. The rims and corner caps around
    // it draw the border while the cell flies (see fly()); at rest they are
    // not displayed and the cell's own border is the border.
    const piece = (cls) => { const el = document.createElement("span"); el.className = cls; return el; };
    const clip = piece("mod-cell-clip");
    const ring = (cls, parts) => {
      const el = piece(cls);
      el.append(...parts.map((part) => piece(part)));
      return el;
    };
    const rim = (cls) => ring(cls, ["mod-cell-edge mod-cell-edge--h", "mod-cell-edge mod-cell-edge--v"]);
    const caps = (cls) => ring(cls, ["tl", "tr", "bl", "br"].map((c) => `mod-cell-cap mod-cell-cap--${c}`));
    cell.append(rim("mod-cell-rim"), rim("mod-cell-rim mod-cell-rim--to"), clip, caps("mod-cell-caps"), caps("mod-cell-caps mod-cell-caps--to"));

    // A BLOG CARD: the post's picture with its title, byline and blurb over
    // it, all the card there is -- it has no creator name beneath and no
    // credit line, because the words on it already say who wrote it. The
    // stylesheet decides how much of the text each rank shows.
    //
    // The picture is NOT .mod-image: a failure there would be swapped for an
    // error card under the text and would mark the cell failed. A blog
    // picture that does not load just leaves the words on a plain card.
    // LAZY, because prewarm builds cells for every other axis at page load,
    // and a blog picture is the blog's full-size original.
    // A new tab, because the post is on another site, and the booru is often
    // framed inside Technetium.
    if (slide.kind === "blog") {
      cell.classList.add("mod-cell--blog");
      cell.title = slide.title || cats[a].label;
      cell.target = "_blank";
      cell.rel = "noopener";
      if (slide.src) {
        const cover = document.createElement("img");
        cover.className = "mod-blog-cover";
        cover.alt = slide.alt || "";
        cover.loading = "lazy";
        cover.decoding = "async";
        cover.addEventListener("error", () => cover.remove(), { once: true });
        cover.src = slide.src;
        clip.appendChild(cover);
      }
      const words = document.createElement("span");
      words.className = "mod-blog-words";
      const byline = [slide.author && `by ${slide.author}`, slide.date].filter(Boolean).join(", ");
      [["mod-blog-title", slide.title], ["mod-blog-byline", byline], ["mod-blog-blurb", slide.blurb]].forEach(([cls, text]) => {
        if (!text) { return; }
        const line = document.createElement("span");
        line.className = cls;
        line.textContent = text;
        words.appendChild(line);
      });
      clip.appendChild(words);
      return cell;
    }

    if (slide.src && !failed.has(String(slide.id))) { clip.appendChild(mediaEl(slide)); } else { cell.classList.add("is-failed"); }

    // The label's text is its own box so it can keep its proportions while
    // the strip behind it stretches with the cell.
    const tag = piece("mod-cell-tag");
    const tagText = piece("mod-cell-tag-text");
    tagText.textContent = cats[a].label;
    tag.appendChild(tagText);
    clip.appendChild(tag);

    // THE CREATOR'S NAME TRAVELS WITH THE CARD, just underneath it, and
    // shrinks and dims as the card does (operator, 2026-09-19). It is a
    // SIBLING of the cell rather than a child: the cell clips to its own
    // box, and "underneath" is outside that box. It reads the cell's own
    // variables -- --cx, --ch, --co -- so it is positioned by the same
    // numbers and moved by the same flight (fly()), never measured.
    const creator = slide.creator && slide.creator.name;
    if (creator) {
      const name = document.createElement("span");
      name.className = "mod-cell-name";
      if (slide.creator.tag) { name.appendChild(artistPill(slide.creator)); } else { name.textContent = creator; }
      cell.nameEl = name;
    }
    return cell;
  }
  // The name goes wherever its cell goes, carrying the cell's variables.
  function placeName(cell, belt) {
    const name = cell.nameEl;
    if (!name) { return; }
    ["--cx", "--cw", "--ch", "--co", "--cz", "--cell-text"].forEach((v) => name.style.setProperty(v, cell.style.getPropertyValue(v)));
    name.dataset.d = cell.dataset.d;
    name.classList.toggle("is-offstage", cell.classList.contains("is-offstage"));
    name.classList.toggle("is-focus", cell.classList.contains("is-focus"));
    if (belt && name.parentNode !== belt) { belt.appendChild(name); }
  }

  // THE WINDOW IS WHAT EXISTS, not what is visible.
  //
  // render() used to walk the whole category and build a cell for every slide
  // in it, marking the far ones is-offstage -- so a row of N slides fetched N
  // images on its first frame whatever was on screen. That was survivable at a
  // row of ten and is not at a row of several hundred, which is what a row
  // holding every cached lap now is. Beyond this window a cell is not hidden,
  // it is not built; come back and it rebuilds.
  const REACH_MARGIN = 2;
  function reachFor(a) { return ranksFor(a) + REACH_MARGIN; }

  // Back to an ordinary bordered box, at rest.
  function land(cell) {
    (cell.anims || []).forEach((a) => a.cancel());
    cell.anims = [];
    cell.flight = null;
    cell.classList.remove("is-flying", "is-tinting");
    cell.style.removeProperty("--cap-r");
    cell.querySelectorAll(".mod-cell-clip > img, .mod-cell-clip > video, .mod-cell-tag-text").forEach((m) => m.removeAttribute("style"));
    if (cell.nameEl) { cell.nameEl.style.removeProperty("width"); }
  }

  // Give a cell back. `failed` is deliberately NOT cleared: it is keyed by
  // slide id, and a slide whose media would not load will not load on the next
  // lap either. Forgetting that would re-request every broken file every time
  // the belt came round.
  function dropCell(a, slide) {
    const key = `${a}:${slide.id}`;
    const cell = cells.get(key);
    if (!cell) { return; }
    land(cell);
    if (cell.nameEl) { cell.nameEl.remove(); }
    cell.remove();
    cells.delete(key);
  }

  // Promote a cell's image to the full sample. Once, and only for the focus:
  // reassigning src to the value it already holds would restart the fetch.
  // NOT ONCE IT HAS FAILED. A thumbnail that failed has already been swapped
  // for an error card (error_card.js marks it errorCarded), and promoting it
  // set src back to the full picture -- overwriting the card, and leaving a
  // blank hatched cell when that failed too, because the card is only ever
  // made once per image.
  function promoteMedia(cell, slide) {
    const el = cell.querySelector("img.mod-image");
    if (!el || !slide.thumb || cell.dataset.promoted === "1") { return; }
    if (failed.has(String(slide.id)) || el.dataset.errorCarded) { return; }
    cell.dataset.promoted = "1";
    el.src = slide.src;
  }

  let promoteSoon = null; // see render(): a focus promoted once it has stayed

  // And given back its thumbnail as it leaves the focus. A card kept at the
  // full picture was decoded again at each smaller size it shrank through on
  // later moves (13-16 decodes, ~110ms, per 30s of auto-advance; 2026-10-03).
  // The thumbnail is decoded first and swapped in only if the card has not
  // come back meanwhile; if it will not decode the card keeps the original,
  // which is correct and only dearer, and its load error is error_card's.
  function demoteMedia(cell) {
    const el = cell.querySelector("img.mod-image");
    const slide = cell.slide;
    if (!el || cell.dataset.promoted !== "1" || el.dataset.errorCarded || !slide.thumb) { return; }
    delete cell.dataset.promoted;
    const thumb = new Image();
    thumb.src = slide.thumb;
    thumb.decode().then(() => {
      if (cell.dataset.promoted === "1" || el.dataset.errorCarded) { return; }
      // Back in or bound for the focus before the thumbnail was ready: it
      // keeps the original it still shows, marked so promoteMedia does not
      // set the same address again, which would fetch it again.
      if (cell.classList.contains("is-focus") || (cell.flight && cell.flight.to.focus)) {
        if (el.getAttribute("src") === slide.src) { cell.dataset.promoted = "1"; }
        return;
      }
      el.src = slide.thumb;
    }, () => null);
  }

  function cellFor(a, slide) {
    const key = `${a}:${slide.id}`;
    if (!cells.has(key)) { cells.set(key, buildCell(a, slide)); }
    return cells.get(key);
  }

  // A cell that failed while small carries the compact card, and cells change
  // size for a living here -- one promoted to the focus would otherwise keep a
  // thumbnail's card at full size, and one demoted keeps an unreadable essay.
  // The card has to follow the box it is in.
  const CARD_RATIO = 640 / 362; // the full error card's own viewBox
  const COMPACT_CARD_RATIO = 1; // and the compact one's, 320 by 320
  // A focused blog card is landscape whatever its picture is: it holds a
  // title and a blurb, which read in lines, and the picture is cropped to fit.
  const BLOG_RATIO = 16 / 10;
  const BLOG_MIN_W = 280; // px; see cellWidth
  const CARD_SRC = /^\/errors\/(\d+)\.svg/;
  const COMPACT_BELOW = 320; // matches error_card.js

  function retuneCard(cell, width) {
    const img = cell.querySelector("img");
    if (!img) { return; }
    const src = img.getAttribute("src") || "";
    const m = src.match(CARD_SRC);
    if (!m) { return; }
    const wanted = `/errors/${m[1]}.svg${width > 0 && width < COMPACT_BELOW ? "?compact=1" : ""}`;
    if (src !== wanted) { img.setAttribute("src", wanted); }
  }

  // Shortest signed distance around the ring, so a cell at the end of a short
  // category travels IN from the near side rather than all the way around.
  function ringDelta(i, p, n) {
    let d = (i - p) % n;
    if (d > n / 2) { d -= n; }
    if (d < -n / 2) { d += n; }
    return d;
  }

  // Rank 0 is the focus, at the band's full height; each rank out is a fixed
  // fraction of the one before it, which is what makes the run recede.
  function cellHeight(k) {
    return k === 0 ? beltBox.h : beltBox.h * HEAD_H * Math.pow(falloffFor(ranksFor(axis)), k - 1);
  }

  // The focal cell is cut to its picture's own aspect; every other cell is a
  // fixed portrait thumb. That difference is what the operator asked for as the
  // border "morphing its size as it moves into place" -- a cell arriving at the
  // centre changes shape as well as growing, because the box stops being a
  // thumbnail and becomes the picture.
  function cellWidth(k, slide) {
    const h = cellHeight(k);
    if (k !== 0) { return h * THUMB_RATIO; }
    // The payload carries the picture's real dimensions, so the focal cell is
    // cut to the right shape BEFORE the picture arrives -- and stays right when
    // it never arrives at all, which is what every image on this site does for
    // a signed-out visitor. An earlier version measured naturalWidth on load
    // instead, so on production the focal cell would have kept a thumbnail's
    // proportions permanently and the border would have had nothing to morph
    // into. The server knew the answer the whole time.
    // A cell whose picture will not load has no picture's shape to keep, and
    // keeping it anyway is actively bad: a portrait slide gives a 272px focal
    // cell, the error card's explanation renders under 9px inside that, and the
    // reader is served the thumbnail-sized card on the one cell that exists to
    // be read. So a failed cell takes the CARD's shape instead. The box should
    // fit what it actually contains, and what it contains is a sentence.
    let ratio = slide.w > 0 && slide.h > 0 ? slide.w / slide.h : 0;
    if (failed.has(String(slide.id))) { ratio = CARD_RATIO; }
    if (slide.kind === "blog") { ratio = BLOG_RATIO; }
    if (!ratio) { return h * THUMB_RATIO; }
    const beltW = beltBox.w;
    let maxW = beltW * 0.62;
    // A blog card is words as well as a picture, and on a phone 62% of the
    // belt is about 150px -- a column a title cannot fit in. It may take most
    // of a narrow belt; on a wide one the 62% cap is already more than enough.
    if (slide.kind === "blog") { maxW = Math.max(maxW, Math.min(beltW * 0.86, BLOG_MIN_W)); }
    return Math.min(h * ratio, maxW);
  }

  // Walk outward from the centre, accumulating half-widths and a shrinking gap.
  // Positions are cumulative rather than a fixed pitch because the cells are
  // different sizes; a constant pitch leaves the outer ones swimming in space.
  function layout(list) {
    const focus = list.find((e) => e.d === 0);
    const xs = { 0: 0 };
    let acc = 0;
    const ranks = ranksFor(axis);
    for (let k = 1; k <= ranks + 1; k++) {
      const prevW = k === 1 ? cellWidth(0, focus ? focus.slide : {}) : cellWidth(k - 1, {});
      acc += (prevW / 2) + (GAP * Math.pow(GAP_FALLOFF, k - 1)) + (cellWidth(k, {}) / 2);
      xs[k] = acc;
    }
    return xs;
  }

  function renderCredit(slide) {
    const el = region("credit");
    if (!el) { return; }
    if (!slide) { el.innerHTML = ""; el.hidden = true; return; }

    const creator = slide.creator && slide.creator.name;
    const platform = slide.platform && slide.platform.name;
    if (!creator && !platform) { el.innerHTML = ""; el.hidden = true; return; }

    el.hidden = false;
    const parts = [];
    if (creator) {
      const who = slide.creator.tag ? artistPill(slide.creator).outerHTML : `<span class="modland-credit-creator">${esc(creator)}</span>`;
      parts.push(`Created by ${who}`);
    }
    if (platform) {
      // The slug rides on the element so a per-site logo is later a rule per
      // platform, and the display name never becomes an identifier.
      const key = esc((slide.platform && slide.platform.key) || "");
      parts.push(`posted on <span class="modland-credit-platform" data-platform="${key}">${esc(platform)}</span>`);
    }
    el.innerHTML = `${parts.join(" and ")}.`;
  }

  function positionThumb() {
    const thumb = region("thumb");
    const active = root.querySelector("[data-act='axis'].is-active");
    if (!thumb || !active) { return; }
    thumb.style.width = `${active.offsetWidth}px`;
    thumb.style.transform = `translateX(${active.offsetLeft}px)`;
    // On a narrow screen the pill scrolls sideways (see the stylesheet), so
    // the active tab is brought into the middle of it -- by setting the pill's
    // own scroll, never scrollIntoView, which would also scroll the PAGE each
    // time the ride changes row under someone reading further down.
    const tabs = thumb.parentElement;
    if (tabs.scrollWidth > tabs.clientWidth) {
      tabs.scrollTo({ left: active.offsetLeft - ((tabs.clientWidth - active.offsetWidth) / 2), behavior: "smooth" });
    }
  }

  // The thumb is placed only when the tabs change. Measuring the active tab
  // forces a layout, and render() calls this after writing every cell, so on
  // every step it laid out the whole belt a second time (2026-10-03). A
  // resize and the hero band place it themselves.
  let tabsDrawn = "";
  function renderTabs() {
    const shown = [];
    root.querySelectorAll("[data-act='axis']").forEach((tab, i) => {
      const on = i === axis;
      tab.classList.toggle("is-active", on);
      tab.setAttribute("aria-selected", String(on));
      tab.hidden = !usable(i);
      shown.push(tab.hidden ? "-" : "+");
    });
    const drawn = `${axis}:${shown.join("")}`;
    if (drawn !== tabsDrawn) { tabsDrawn = drawn; positionThumb(); }
  }

  // --- prewarm ------------------------------------------------------------
  //
  // Build what the reader is a few steps away from, off-screen but real, so a
  // cell arrives resolved -- its picture fetched, or its failure already turned
  // into an error card. Off-screen at full size rather than display:none or a
  // 1px box, because the card picks its layout from measured width.
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
    const wanted = [];
    const reach = reachFor(axis);
    for (let d = -reach; d <= reach; d++) { wanted.push([axis, at(axis, pos + d)]); }
    cats.forEach((_, a) => { if (a !== axis) { wanted.push([a, at(a, pos)], [a, at(a, pos + 1)]); } });

    wanted.forEach(([a, slide]) => {
      if (!slide) { return; }
      const cell = cellFor(a, slide);
      // Only adopt a cell that is nowhere. isConnected would be true of a cell
      // already ON the belt, but so would it be of one already in the holder --
      // see render(), where that distinction is the whole bug.
      if (!cell.parentNode) { warmHolder().appendChild(cell); }
    });
  }

  // --- the move -------------------------------------------------------------
  //
  // EVERY FRAME OF A MOVE IS TRANSFORM AND OPACITY. The belt used to transition
  // width, height, top, font-size and border-color, and each of those is a
  // style, layout and paint on the main thread every frame: ~2.5ms a frame, six
  // percent of a core at one advance per six seconds (Firefox, 2026-10-03).
  // Now a move lays the run out ONCE, at its destination, and plays each cell
  // from where it was seen to that rest with Web Animations on transform and
  // opacity, which the compositor runs without the page.
  //
  // A box that changes shape cannot simply be scaled -- its 2px border would
  // thin to a hair and its corners would turn oval, and its picture would
  // stretch. So while a cell flies it is drawn in pieces that scale without
  // distortion (the stylesheet's .is-flying): the straight edges are two bands
  // of border colour behind a clip inset by exactly 2px, the corners are
  // fixed-size caps that only translate, and the picture and the label are
  // each counter-scaled to a uniform size inside the clip. On landing the
  // cell goes back to being one ordinary bordered box, which is what a rest
  // frame is made of -- so a still carousel is drawn exactly as it always was.
  //
  // The curves are the ones the transitions used, and each property keeps its
  // own. Only position overshoots: a cell whose WIDTH overshot would bulge
  // past the size it is settling into, which reads as a wobble rather than as
  // weight -- the box arrives once and stays arrived while the run rocks into
  // place around it. Opacity and the border's colour ease, on the same clock
  // as everything else (see BASE_MS). A cell interrupted mid-flight starts its
  // next move from where the model below says it is, never from a measurement.
  const SIZE_EASE = [0.4, 0, 0.2, 1];
  const FADE_EASE = [0.25, 0.1, 0.25, 1]; // CSS `ease`
  const BORDER = 2; // px, the cell's border in the stylesheet
  let radius = 10; // px, the cell's corner (--mod-radius), read by render()
  const SAMPLES = 16; // keyframes for a counter-scale, which no single curve draws
  // Opacity 0 is not painted, and an unpainted element with a running
  // animation costs the main thread every frame: Firefox can only throttle
  // what it draws. Nothing fades all the way out while it is still moving.
  const FADE_FLOOR = 0.004;
  // When in a move its words are cut again: three steps from the width they
  // were seen at to the destination's, each a fraction of the move's time.
  const CUTS = [0.25, 0.5, 0.75];

  // WHEN A MOVE STARTS. Three clocks failed before this one (2026-10-03):
  //   - document.timeline.currentTime at the step: seconds stale in Firefox
  //     after idle, so every auto-advance began already finished and jumped;
  //   - performance.now() at the step: the click's own work was charged to the
  //     move, so its first 50-70ms were never drawn;
  //   - performance.now() in the next frame: Chromium's compositor draws a
  //     frame well after the page set its start, so the first frame drawn was
  //     already a fifth of the way through the move.
  // So a move from rest is left PENDING and the browser starts it on the
  // frame that first draws it: the opening is always seen. A move that takes
  // over from one already running starts at the timeline's time, as a
  // re-targeted transition does, so the next frame carries it on (the
  // timeline is current while anything runs). And a step that arrives while
  // a move is still pending -- up to 130ms in Chromium -- is drawn once that
  // move has started (render() waits on it): drawn at once, it read the move
  // as not yet begun and restarted from the old pose, which froze a held
  // arrow and, in Chromium, flickered between poses.
  function pendingClock() {
    for (const cell of cells.values()) {
      if (cell.flight && cell.flight.clock.pending) { return cell.flight.clock; }
    }
    return null;
  }
  let drawWhenStarted = false;
  // The border's colour is one of three, and a cell caught mid-change is a mix
  // of them: line, incoming, focus.
  const TONES = ["var(--mod-line)", "var(--mod-belt-incoming)", "var(--mod-belt-focus)"];
  const lessMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  let moveMs = BASE_MS;
  let moveY1 = easeFor(1);

  const curveCss = (c) => `cubic-bezier(${c.join(", ")})`;
  const xCurve = (y1) => [0.32, y1, 0.62, 1];

  // The browser's own cubic-bezier, so the model of where a cell is agrees
  // with where the compositor has drawn it.
  const curves = new Map();
  function curveFn(c) {
    const key = c.join(",");
    if (curves.has(key)) { return curves.get(key); }
    const [x1, y1, x2, y2] = c;
    const bez = (a, b, t) => (3 * a * (1 - t) * (1 - t) * t) + (3 * b * (1 - t) * t * t) + (t * t * t);
    const slope = (a, b, t) => (3 * a * (1 - t) * (1 - t)) + (6 * (b - a) * (1 - t) * t) + (3 * (1 - b) * t * t);
    const fn = (x) => {
      if (x <= 0) { return 0; }
      if (x >= 1) { return 1; }
      let t = x;
      for (let i = 0; i < 8; i++) {
        const d = slope(x1, x2, t);
        if (Math.abs(d) < 1e-6) { break; }
        t = Math.min(1, Math.max(0, t - ((bez(x1, x2, t) - x) / d)));
      }
      return bez(y1, y2, t);
    };
    // How far past its target this curve carries a value, for the panel test.
    fn.peak = Math.max(1, ...Array.from({ length: 65 }, (_, i) => bez(y1, y2, i / 64)));
    // And WHEN, as a fraction of the move's time: past it the value only
    // comes back. A curve that does not overshoot peaks at its end.
    const top = Array.from({ length: 65 }, (_, i) => i / 64).reduce((b, t) => (bez(y1, y2, t) > bez(y1, y2, b) ? t : b), 1);
    fn.peakAt = fn.peak > 1 ? bez(x1, x2, top) : 1;
    curves.set(key, fn);
    return fn;
  }

  // One-hot or mixed weights over TONES, as a colour.
  function toneCss(w) {
    const [l, i, f] = w;
    const li = l + i;
    const inner = li <= 0.0005 ? TONES[0] : `color-mix(in srgb, ${TONES[0]} ${((l / li) * 100).toFixed(2)}%, ${TONES[1]})`;
    if (f <= 0.0005) { return inner; }
    if (li <= 0.0005) { return TONES[2]; }
    return `color-mix(in srgb, ${inner} ${(li * 100).toFixed(2)}%, ${TONES[2]})`;
  }

  // Where a cell is drawn now: its flight's values at this moment, or its rest
  // when it is not flying. Every property on its own curve, as in fly(). The
  // moment is the flight's own clock animation, so the model reads the very
  // time the compositor draws by -- and a flight that has not started yet
  // (pending, until the next frame) is at its start.
  function seenAt(cell) {
    const f = cell.flight;
    if (!f) { return cell.rest; }
    const p = Math.min(Math.max((f.clock.currentTime || 0) / f.ms, 0), 1);
    const ex = curveFn(xCurve(f.y1))(p);
    const es = curveFn(SIZE_EASE)(p);
    const eo = curveFn(FADE_EASE)(p);
    const mix = (k, e) => f.from[k] + ((f.to[k] - f.from[k]) * e);
    return {
      x: mix("x", ex),
      w: mix("w", es), h: mix("h", es), textF: mix("textF", es), blogF: mix("blogF", es),
      o: mix("o", eo), textO: mix("textO", eo), nameO: mix("nameO", eo), wordsO: mix("wordsO", eo),
      tone: f.from.tone.map((v, i) => v + ((f.to.tone[i] - v) * eo)),
    };
  }

  const near = (a, b) => ["x", "w", "h", "o", "textF", "textO", "nameO", "blogF", "wordsO"].every((k) => Math.abs(a[k] - b[k]) < 0.01)
    && a.tone.every((v, i) => Math.abs(v - b.tone[i]) < 0.001);

  // The picture's own aspect: what it is drawn at, else what the payload says.
  // An error card is read from its address, because retuneCard may have just
  // swapped it between the full and compact layouts and the new one is not
  // decoded yet -- its natural size would still be the other card's.
  function aspectOf(media, slide, fallback) {
    const card = (media.getAttribute("src") || "").match(CARD_SRC);
    if (card) { return /[?&]compact=1/.test(media.getAttribute("src")) ? COMPACT_CARD_RATIO : CARD_RATIO; }
    if (media.naturalWidth > 0 && media.naturalHeight > 0) { return media.naturalWidth / media.naturalHeight; }
    if (media.videoWidth > 0 && media.videoHeight > 0) { return media.videoWidth / media.videoHeight; }
    if (slide.w > 0 && slide.h > 0) { return slide.w / slide.h; }
    return fallback;
  }

  // Play one cell (and its name) from `from` to its rest `to`. The cell is
  // already laid out at `to`; every keyframe is an offset from that layout.
  function fly(cell, from, to, runBegin) {
    // A label and a name keep the width they were seen cut at (see below), in
    // this move's units; one re-targeted mid-flight carries the width on from
    // the move it interrupts, so the cut does not jump at every step of a held
    // arrow.
    // Everything about the move it interrupts is read BEFORE land() cancels
    // it: cancelling clears its start, and read after, every re-target looked
    // like a move from rest -- which is what froze a held arrow (2026-10-03).
    const prev = cell.flight;
    const lerp = (a, b, e) => a + ((b - a) * e);
    const sizeAt = curveFn(SIZE_EASE);
    const prevRan = Boolean(prev) && prev.clock.startTime !== null && !prev.clock.pending;
    // The width the interrupted move last cut its words at -- the width on
    // screen -- in this move's units; from rest, the width they were seen at.
    // Carrying where the cut was heading instead re-cut a truncated name in
    // one frame at every step of a held run (2026-10-04).
    const carried = (key, seenW) => (prev ? prev[key] * (to.textF / prev.to.textF) : seenW * (to.textF / from.textF));
    const nameW = carried("nameW", from.w);
    const tagW = carried("tagW", from.w - (2 * BORDER));
    // RE-TARGETED IN PLACE, not landed and flown again. A held step used to
    // cancel and re-create every animation of every moving card -- about 150
    // -- and flip its classes and styles off and back on, and the frame after
    // each key restyled ~350 elements: 73ms of main thread a step against
    // 43ms for the transitions this replaced (2026-10-04). Now each animation
    // the new move needs takes over the old one on the same element and
    // property (new keyframes, timing and start), and only what the move no
    // longer needs is cancelled. Classes and styles change only where the
    // move's form does.
    const old = cell.anims || [];
    const reused = new Set();
    cell.anims = [];
    cell.flight = null;
    const ms = moveMs;
    const xc = xCurve(moveY1);
    // See pendingClock(): from rest, pending; taking over a running move, or
    // setting off while the run around it is moving (runBegin, from render()),
    // at the timeline's time -- left pending there, a card joining a held run
    // made every later step wait for it, and steps bunched two or three to a
    // frame (2026-10-04). Until it starts it is drawn at its first keyframe
    // -- the backwards fill -- never at the rest.
    const begin = prevRan ? document.timeline.currentTime : runBegin;
    const launch = (a) => { if (begin !== null) { a.startTime = begin; } };
    const run = (el, frames, curve) => {
      const sig = Object.keys(frames[0]).filter((k) => k !== "offset").sort().join(" ");
      let a = old.find((o) => !reused.has(o) && o.sig === sig && o.effect.target === el);
      if (a) {
        reused.add(a);
        a.effect.setKeyframes(frames);
        a.effect.updateTiming({ duration: ms, easing: curveCss(curve) });
      } else {
        a = el.animate(frames, { duration: ms, easing: curveCss(curve), fill: "backwards" });
        a.sig = sig;
      }
      cell.anims.push(a);
      launch(a);
      return a;
    };
    const sampled = (fn) => Array.from({ length: SAMPLES + 1 }, (_, i) => ({ offset: i / SAMPLES, transform: fn(i / SAMPLES) }));
    const fade = (a, b) => [{ opacity: Math.max(a, FADE_FLOOR) }, { opacity: Math.max(b, FADE_FLOOR) }];

    const flight = { ms, y1: moveY1, from, to, nameW, tagW };
    cell.flight = flight;
    const clip = cell.querySelector(":scope > .mod-cell-clip");
    const tinting = from.tone.some((v, i) => Math.abs(v - to.tone[i]) > 0.001);
    // A CARD THAT KEEPS ITS SHAPE AND ITS COLOUR MOVES WHOLE: the box, its
    // border and its picture scaled as one, so its 2px border and corners
    // scale with it for the length of the move and are exact again when it
    // lands. Only the cards crossing the focus (which change shape) and the
    // ones turning to or from the incoming green (which change colour) are
    // drawn in the pieces below. The operator watched both side by side
    // (2026-10-04): "It even looks better if anything." Most of a move's cost
    // was those pieces -- about 15 animations a card against about 7.
    const whole = !from.focus && !to.focus && !tinting;
    cell.classList.toggle("is-flying", !whole);
    cell.classList.toggle("is-tinting", !whole && tinting);
    if (!whole) {
      cell.style.setProperty("--tone-from", toneCss(from.tone));
      cell.style.setProperty("--tone-to", toneCss(to.tone));
    }

    // The clock: the whole cell rides on its x, overshoot and all.
    flight.clock = run(cell, [{ translate: `${from.x - to.x}px` }, { translate: "0px" }], xc);
    // The focus's full picture is asked for when it lands, not as it sets
    // off: promoted at the start of a move, the original was decoded again at
    // each size the flight drew it at, several times a move (2026-10-03), and
    // in a held run for cells only passing through the focus.
    flight.clock.onfinish = () => {
      if (cell.flight !== flight) { return; }
      land(cell);
      if (cell.classList.contains("is-focus")) { promoteMedia(cell, cell.slide); }
    };
    if (from.o !== to.o) { run(cell, fade(from.o, to.o), FADE_EASE); }
    if (whole) {
      // Out of pieces into a whole move: the box draws itself again.
      cell.style.removeProperty("--cap-r");
      clip.querySelectorAll(":scope > img, :scope > video").forEach((m) => m.removeAttribute("style"));
      // The stylesheet's translate(-50%, -50%) written in px: the box is laid
      // out at `to` (border-box). A percentage depends on the box's size, and
      // Chromium will not run such a transform on the compositor -- every
      // frame of a held run was a 40-50ms main-thread restyle (2026-10-04).
      const centre = `translate(${-to.w / 2}px, ${-to.h / 2}px) translateX(${to.x}px)`;
      run(cell, [{ transform: `${centre} scale(${from.w / to.w}, ${from.h / to.h})` }, { transform: `${centre} scale(1, 1)` }], SIZE_EASE);
    }

    // Size, in screen pixels at eased progress e: the box, and the clip 2px in.
    const wAt = (e) => lerp(from.w, to.w, e);
    const hAt = (e) => lerp(from.h, to.h, e);
    const W = to.w - (2 * BORDER);
    const H = to.h - (2 * BORDER);
    const cx = (e) => (wAt(e) - (2 * BORDER)) / W;
    const cy = (e) => (hAt(e) - (2 * BORDER)) / H;

    if (!whole) {
      // The corner. A box too small for the full radius has it cut down, as
      // the stylesheet's border-radius does; it holds for the flight and the
      // landing restores the box's own.
      const corner = Math.min(radius, (Math.min(from.w, from.h, to.w, to.h) - 1) / 2);
      if (corner < radius) { cell.style.setProperty("--cap-r", `${corner}px`); } else { cell.style.removeProperty("--cap-r"); }
      // The edges: one band spans the width between the corners' arcs for the
      // left and right edges, the other the height for the top and bottom, so
      // nothing but a cap is drawn in a corner. Both are 2px wide wherever the
      // clip is, because the clip is always exactly 2px inside them.
      // The second rim and set of caps are drawn only while the colour changes.
      const drawn = tinting ? "" : ":not(.mod-cell-rim--to, .mod-cell-caps--to)";
      cell.querySelectorAll(`:scope > .mod-cell-rim${drawn} > .mod-cell-edge`).forEach((edge) => {
        const across = edge.classList.contains("mod-cell-edge--h");
        const sx = across ? from.w / to.w : (from.w - (2 * corner)) / (to.w - (2 * corner));
        const sy = across ? (from.h - (2 * corner)) / (to.h - (2 * corner)) : from.h / to.h;
        run(edge, [{ transform: `scale(${sx}, ${sy})` }, { transform: "none" }], SIZE_EASE);
      });
      run(clip, [{ transform: `scale(${cx(0)}, ${cy(0)})` }, { transform: "none" }], SIZE_EASE);
      // A corner moves with its corner of the box and never changes size.
      const dx = (to.w - from.w) / 2;
      const dy = (to.h - from.h) / 2;
      cell.querySelectorAll(`:scope > .mod-cell-caps${drawn} > .mod-cell-cap`).forEach((cap) => {
        const sx = cap.classList.contains("mod-cell-cap--tl") || cap.classList.contains("mod-cell-cap--bl") ? 1 : -1;
        const sy = cap.classList.contains("mod-cell-cap--tl") || cap.classList.contains("mod-cell-cap--tr") ? 1 : -1;
        run(cap, [{ transform: `translate(${sx * dx}px, ${sy * dy}px)` }, { transform: "none" }], SIZE_EASE);
      });
      if (tinting) {
        run(cell.querySelector(":scope > .mod-cell-rim--to"), fade(0, 1), FADE_EASE);
        run(cell.querySelector(":scope > .mod-cell-caps--to"), fade(0, 1), FADE_EASE);
      }

      // The picture: laid out at its own rectangle for the destination fit, and
      // scaled uniformly to the rectangle that fit gives the box it is seen in.
      // object-fit chooses the same rectangle at rest; it just cannot be moved.
      const media = clip.querySelector(":scope > img, :scope > video");
      if (media) {
        // Cover, except under the microscope. An error card too: the skin's
        // contain rule for it is outweighed by the belt's own, so a thumbnail's
        // card is cropped like any other picture.
        const cover = media.classList.contains("mod-blog-cover") || !to.focus;
        let fitted = null;
        let fittedR = 0;
        const fit = () => {
          const r = aspectOf(media, cell.slide, W / H);
          if (fitted && Math.abs(r - fittedR) < 0.001) { return; }
          if (fitted) { fitted.cancel(); }
          fittedR = r;
          const fitW = (w, h) => (cover ? Math.max(w, h * r) : Math.min(w, h * r));
          const pw = fitW(W, H);
          const ph = pw / r;
          media.style.cssText = `position: absolute; left: ${(W - pw) / 2}px; top: ${(H - ph) / 2}px; width: ${pw}px; height: ${ph}px; max-width: none; max-height: none;`;
          fitted = run(media, sampled((e) => {
            const u = fitW(cx(e) * W, cy(e) * H) / pw;
            return `scale(${u / cx(e)}, ${u / cy(e)})`;
          }), SIZE_EASE);
          // A refit happens later in the move; it joins the move's own clock.
          if (flight.clock && flight.clock.startTime !== null) { fitted.startTime = flight.clock.startTime; }
        };
        fit();
        // A picture that fails in flight becomes an error card of another shape
        // (error_card.js swaps its src). It is fitted again, on the same clock,
        // when the card arrives, rather than riding the old picture's rectangle
        // until it lands. A src of the same shape -- the thumbnail a card gets
        // back as it leaves the focus -- keeps its fit: refitted on a late
        // clock, it stretched the leaving picture on every move (2026-10-03).
        const src = media.getAttribute("src");
        media.addEventListener("load", () => {
          if (cell.flight === flight && media.getAttribute("src") !== src) { fit(); }
        }, { once: true });
      }
    }
    // Words keep their proportions: the strip behind them spans the box, the
    // text inside it is scaled by the font size it would have had. The label's
    // strip is as tall as the inherited line height whatever its font size, so
    // only its glyphs scale; a blog card's spacing is in em, so all of it does.
    // sx/sy: how the box around them is scaled at e -- the clip for a card in
    // pieces, the card itself for one moving whole.
    const words = (strip, lines, fa, fb, inEm, sx = cx, sy = cy) => {
      const u = (e) => lerp(fa, fb, e) / fb;
      run(strip, sampled((e) => `scale(1, ${(inEm ? u(e) : 1) / sy(e)})`), SIZE_EASE);
      lines.forEach((line) => run(line, sampled((e) => `scale(${u(e) / sx(e)}, ${inEm ? 1 : u(e)})`), SIZE_EASE));
    };
    const tag = clip.querySelector(":scope > .mod-cell-tag");
    let tagText = null;
    const cutTag = (width) => {
      tagText.style.width = `${width}px`;
      tagText.style.marginLeft = `calc(50% - ${width / 2}px)`;
    };
    if (tag && !(from.textO > 0 || to.textO > 0)) { tag.querySelector(":scope > .mod-cell-tag-text").removeAttribute("style"); }
    if (tag && (from.textO > 0 || to.textO > 0)) {
      // Broken into lines where it was seen broken. Laid out at the
      // destination's width, the label rewrapped at the first frame of every
      // move; it starts at the width it was seen at, centred, and is cut
      // again during the move (below).
      tagText = tag.querySelector(":scope > .mod-cell-tag-text");
      cutTag(tagW);
      // In a card moving whole the strip and its glyphs are counter-scaled
      // against the card itself: scaled with it, the strip stretched up the
      // card and carried the label 7-11px high, off the card in a fast run
      // (2026-10-04).
      if (whole) {
        words(tag, [tagText], from.textF, to.textF, false, (e) => wAt(e) / to.w, (e) => hAt(e) / to.h);
      } else {
        words(tag, [tagText], from.textF, to.textF, false);
      }
      if (from.textO !== to.textO) { run(tag, fade(from.textO, to.textO), FADE_EASE); }
    }
    const blog = clip.querySelector(":scope > .mod-blog-words");
    if (blog && !whole && (from.wordsO > 0 || to.wordsO > 0)) {
      // The byline and blurb are drawn on the focus only; see the stylesheet.
      words(blog, Array.from(blog.children).filter((line) => to.focus || line.classList.contains("mod-blog-title")), from.blogF, to.blogF, true);
      if (from.wordsO !== to.wordsO) { run(blog, fade(from.wordsO, to.wordsO), FADE_EASE); }
    }

    // The creator's name under it: the same x, its top on the box's bottom
    // edge, its text scaled by the font size it would have had.
    const name = cell.nameEl;
    const named = Boolean(name) && (from.nameO > 0 || to.nameO > 0);
    let nameFrames = null;
    let nameSize = null;
    if (name && !named) { name.style.removeProperty("width"); }
    if (named) {
      // Cut where it was seen cut. Laid out at the destination's width, a name
      // receding into a narrower card was truncated for that card at the first
      // frame -- up to 42px of it vanished as the move began. It keeps the
      // width it had, in its own scaled units, until it lands.
      name.style.width = `${nameW}px`;
      run(name, [{ translate: `${from.x - to.x}px` }, { translate: "0px" }], xc);
      // Centred in px, not translate(-50%): see the whole card above. Its
      // width changes at each cut (below), which re-centres it the same way.
      nameFrames = (width) => [
        { transform: `translate(${-width / 2}px, ${(from.h - to.h) / 2}px) translateX(${to.x}px) scale(${from.textF / to.textF})` },
        { transform: `translate(${-width / 2}px, 0px) translateX(${to.x}px) scale(1)` },
      ];
      nameSize = run(name, nameFrames(nameW), SIZE_EASE);
      if (from.nameO !== to.nameO) { run(name, fade(from.nameO, to.nameO), FADE_EASE); }
    }

    // The label and the name are cut again DURING the move, while the card is
    // still travelling: held to the landing, every card rewrapped its label
    // and re-cut its name the moment it stopped, and cut once mid-move a
    // name's width jumped up to 31px in a frame where the transitions moved it
    // under 11 (2026-10-03). So three steps on the size curve, each one small
    // layout, timed on the move's own clock -- a timer counted from the step
    // fired before a pending move had begun. One empty animation at a time,
    // each ending at its cut and starting the next on the same start, so a
    // step pays for one, not three. A re-target carries the width last cut.
    old.forEach((a) => { if (!reused.has(a)) { a.cancel(); } });
    if (!named && !tagText) { return; }
    // In a run, one cut, halfway. Each cut restyles every name and its pill,
    // and with three, the first landed between every pair of held steps -- a
    // 48-element restyle in every frame between keys (Firefox profile,
    // 2026-10-04). Mid-run a move is interrupted before halfway, so its words
    // keep their width; the run's last move cuts once, halfway, so nothing is
    // re-cut on a card that has stopped.
    const cuts = burst > 1 ? [0.5] : CUTS;
    const cue = (i) => {
      const a = cell.animate([], { duration: ms * cuts[i] });
      cell.anims.push(a);
      if (i === 0) { launch(a); } else { a.startTime = flight.clock.startTime; }
      a.onfinish = () => {
        if (cell.flight !== flight) { return; }
        const e = sizeAt(cuts[i]);
        flight.nameW = lerp(nameW, to.w, e);
        flight.tagW = lerp(tagW, to.w - (2 * BORDER), e);
        if (named) { name.style.width = `${flight.nameW}px`; nameSize.effect.setKeyframes(nameFrames(flight.nameW)); }
        if (tagText) { cutTag(flight.tagW); }
        if (i + 1 < cuts.length) { cue(i + 1); }
      };
    };
    cue(0);
  }

  function render() {
    const belt = region("belt");
    if (!belt || !started) { return; }
    // A move still pending: draw once it has started (see pendingClock()).
    // A cancelled one rejects its ready, which draws too.
    const waiting = pendingClock();
    if (waiting) {
      if (!drawWhenStarted) {
        drawWhenStarted = true;
        // As a task of its own: run in the ready microtask it landed inside
        // Chromium's frame and made 100-138ms frames (2026-10-04).
        const draw = () => setTimeout(() => { drawWhenStarted = false; render(); }, 0);
        waiting.ready.then(draw, draw);
      }
      return;
    }
    const panel = root.querySelector(".modland-stage-wrap");
    if (!beltWatch) {
      beltWatch = new ResizeObserver(() => { beltStale = true; });
      beltWatch.observe(belt);
      if (panel) { beltWatch.observe(panel); }
    }
    if (beltStale) {
      beltBox = { w: belt.clientWidth, h: belt.clientHeight || 400, panel: panel ? panel.clientWidth : Infinity };
      beltStale = false;
    }
    const list = slidesOf(axis);
    // Nothing to show on this row: clear it rather than leave the previous
    // row's cards standing on the belt, which is what returning early did.
    if (!list.length) {
      cells.forEach((cell) => { if (cell.parentNode === belt) { land(cell); } });
      belt.querySelectorAll(".mod-cell, .mod-cell-name").forEach((el) => el.remove());
      renderCredit(null);
      renderTabs();
      return;
    }

    const placed = list.map((slide, i) => ({ slide, d: ringDelta(i, pos, list.length) }));
    const xs = layout(placed);
    const ranks = ranksFor(axis);

    const reach = reachFor(axis);
    // The panel clips at its padding box, and the belt is centred in it, so a
    // cell is inside it while its near edge is within half the panel's width.
    // Measured with the belt, only when one of them changed size.
    const halfPanel = beltBox.panel / 2;
    // The labels' sizes are clamped in rem, and a flying cell draws its own
    // corners; both read with the sizes above, before anything is written, so
    // they cost no extra layout.
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize);
    radius = parseFloat(getComputedStyle(belt).getPropertyValue("--mod-radius"));
    const clampPx = (lo, v, hi) => Math.min(Math.max(v, lo), hi);
    const still = lessMotion.matches;
    // A run in progress: something on the belt is flying on a started clock.
    // Cards that set off from rest in this draw join it at its time.
    const running = Array.from(cells.values()).some((c) => c.parentNode === belt && c.flight && c.flight.clock.startTime !== null);
    const runBegin = running ? document.timeline.currentTime : null;
    // A move nobody can see is not played: a cell that stays outside the panel
    // the whole way, overshoot included, or is transparent the whole way,
    // just goes to its rest.
    const peak = curveFn(xCurve(moveY1)).peak;
    const seenMoving = (from, to) => {
      const far = from.x + ((to.x - from.x) * peak);
      const half = Math.max(from.w, to.w) / 2;
      return (from.o > 0 || to.o > 0) && Math.min(from.x, to.x, far) - half < halfPanel && Math.max(from.x, to.x, far) + half > -halfPanel;
    };
    placed.forEach(({ slide, d }) => {
      const k = Math.abs(d);
      // Outside the window: not built, and released if it was.
      if (k > reach) { dropCell(axis, slide); return; }

      const cell = cellFor(axis, slide);

      const shown = k <= ranks;
      const x = (xs[Math.min(k, ranks + 1)] || 0) * Math.sign(d);
      const w = cellWidth(k, slide);
      const h = cellHeight(k);
      const co = k === 0 ? 1 : HEAD_O * Math.pow(ranks > RANKS ? falloffFor(ranks) : FALLOFF_O, k - 1);
      // The same rest, as numbers the move can play between: what the
      // stylesheet makes of these variables and classes.
      // The label and name share one size, from the cell's height. A blog
      // card's words go by the SMALLER of its height and width: on a phone the
      // focused card is tall and narrow, and text sized from its height alone
      // cut the title off mid-word. Written as px for the stylesheet below.
      const rest = {
        x, w, h, o: shown ? co : 0, focus: d === 0,
        textF: clampPx(0.5 * rem, h * 0.048, 0.86 * rem),
        blogF: clampPx(0.5 * rem, Math.min(h * 0.04, w * 0.06), rem),
        textO: d === 0 ? 0 : 1,
        nameO: d === 0 || !shown ? 0 : co,
        wordsO: d === 0 || k === 1 ? 1 : 0,
        tone: [d !== 0 && k !== 1 ? 1 : 0, k === 1 ? 1 : 0, d === 0 ? 1 : 0],
      };
      // Where it is seen now, if it is on this belt to be seen at all.
      const from = cell.parentNode === belt ? seenAt(cell) : null;
      cell.style.setProperty("--cx", `${x}px`);
      cell.style.setProperty("--cw", `${w}px`);
      cell.style.setProperty("--ch", `${h}px`);
      cell.style.setProperty("--co", String(co));
      cell.style.setProperty("--cz", String(10 - k));
      // The text sizes on the card (its name copies them) and on the label and
      // blog words that read them: they do not inherit (see the stylesheet).
      cell.style.setProperty("--cell-text", `${rest.textF}px`);
      const label = cell.querySelector(".mod-cell-tag");
      if (label) { label.style.setProperty("--cell-text", `${rest.textF}px`); }
      const blogWords = cell.querySelector(".mod-blog-words");
      if (blogWords) { blogWords.style.setProperty("--blog-text", `${rest.blogF}px`); }
      cell.dataset.d = String(d);

      // Sized BEFORE it joins the belt, not after. An error card picks its
      // layout from the element's measured width, and a cell appended without
      // its width yet measures at the stylesheet's fallback -- so the focal
      // cell was being handed the compact card meant for thumbnails, losing
      // the explanation that is the entire reason the cards are written out.
      // parentNode, NOT isConnected. A cell prewarmed for another axis sits in
      // the off-screen holder, which is in the document -- so isConnected is
      // true of it, and the cell was never moved onto the belt when its axis
      // became the current one. Its position was still computed and its
      // variables still written, so the run had a correctly-spaced hole in it
      // that moved with the conveyor, and stayed there: nothing ever
      // reconsidered a cell once it was "connected".
      if (cell.parentNode !== belt) { belt.appendChild(cell); }
      retuneCard(cell, w);

      cell.classList.toggle("is-offstage", !shown);
      // See mediaEl: a video plays while its cell is shown and overlaps the
      // panel, judged on where the cell is going, so one sliding into view
      // starts as it arrives. play() on a playing video is a no-op, and its
      // rejection (a file that will not load) is already an error card by way
      // of the error listener.
      const video = cell.querySelector("video");
      if (video && shown && Math.abs(x) - (w / 2) < halfPanel) { video.play().catch(() => null); } else if (video) { video.pause(); }
      cell.classList.toggle("is-focus", d === 0);
      cell.classList.toggle("is-incoming", k === 1);
      if (failed.has(String(slide.id))) { cell.classList.add("is-failed"); }
      placeName(cell, belt);

      // Play it from where it is seen to this rest -- unless it is already on
      // its way there, which a redraw for some other reason must not restart.
      // Asked for less motion, it is simply there.
      const aim = cell.flight ? cell.flight.to : cell.rest;
      // A card leaving the focus gives back its full picture, moving or not.
      if (cell.rest && cell.rest.focus && d !== 0) { demoteMedia(cell); }
      if (!from || still) { land(cell); } else if (!near(aim, rest)) {
        if (seenMoving(from, rest)) { fly(cell, from, rest, runBegin); } else { land(cell); }
      }
      cell.rest = rest;
      // A focus at rest has its full picture now; one in flight on landing.
      // Asked for less motion nothing flies, so a held run would fetch and
      // decode the original of every card it passed: there it waits until the
      // focus has stayed for a move's length (2026-10-03).
      if (d === 0 && !cell.flight) {
        clearTimeout(promoteSoon);
        if (still) {
          promoteSoon = setTimeout(() => { if (cell.classList.contains("is-focus") && !cell.flight) { promoteMedia(cell, slide); } }, BASE_MS);
        } else {
          promoteMedia(cell, slide);
        }
      }
    });

    // Cells belonging to other axes stay built but must not sit on this belt,
    // and neither may this axis's cells for slides no longer in its list. A
    // slide the blacklist marked after it was drawn -- a fresh set rescanned, a
    // rule switched on -- is never visited above, so its cell stayed where it
    // was, in full view (found 2026-10-03).
    const listed = new Set(list.map((slide) => `${axis}:${slide.id}`));
    cells.forEach((cell, key) => {
      if (cell.parentNode === belt && !listed.has(key)) { land(cell); cell.remove(); if (cell.nameEl) { cell.nameEl.remove(); } }
    });

    renderCredit(at(axis, pos));
    renderTabs();
    prewarm();
  }

  function renderAll() { render(); }

  // --- movement -----------------------------------------------------------
  //
  // A step is not an animation to be scheduled and waited on; it is a change of
  // one number. render() plays each cell from where it is seen to its new
  // rest, which is what lets input arrive mid-flight: the belt simply
  // re-targets from wherever it currently is.
  //
  // That is also the whole of "holding the arrow plays smoothly but faster" --
  // there is no queue to drain and no busy flag to bounce off. The duration
  // shortens as the burst grows so the belt keeps up with the key repeat.
  // The run has come to rest. Nothing to animate here any more -- the overshoot
  // has already happened, inside the last step's own travel. This just puts the
  // pace and the curve back where a fresh, unhurried step expects them.
  function settle() {
    burst = 0;
    moveMs = BASE_MS;
    moveY1 = easeFor(1);
  }

  // A fresh set ARRIVES AT THE RIGHT-HAND EDGE, one slide at a time.
  //
  // This replaced the whole payload at once, dropped every cell and rendered
  // again -- correct, and a visible reload: the entire belt blinked and
  // restarted. Operator, 2026-09-22: base it on the card entering from the far
  // right instead of on the focus, so new images scroll into view naturally.
  //
  // So a pull does not swap. It queues, and each advance installs ONE queued
  // slide into the slot about to enter the window. Over one traverse of the
  // row the whole set turns over and nothing ever blinks.
  const pending = new Map(); // category key -> slides still to be fed in

  // The queued slides' pool elements are added IMMEDIATELY, before any of them
  // is installed, because blockedIds() reads those elements and a slide whose
  // element is not there yet reads as not-blacklisted. Appended, not replaced:
  // the slides currently on the belt still need theirs.
  function queueFreshSet(next, poolHtml) {
    const pool = root.querySelector(".modland-pool");
    if (pool && typeof poolHtml === "string") {
      const seen = new Set(Array.from(pool.querySelectorAll("[data-id]"), (el) => el.dataset.id));
      const staging = document.createElement("div");
      staging.innerHTML = poolHtml;
      Array.from(staging.children).forEach((el) => {
        if (!seen.has(el.dataset.id)) { pool.appendChild(el); }
      });
      const box = document.querySelector("#blacklist-box");
      if (box && box.blacklist) { box.blacklist.rescan(); }
    }

    // ONLY ROWS THIS PAGE HAS. The tabs are fixed for the life of the page, so
    // a row that was empty at load -- the blog row while the blog has not been
    // read yet -- and arrives in a later set has no axis to drain into. Queued
    // anyway, it sat in `pending` forever, and prunePool, which waits for every
    // queue to empty, never ran again. It appears at the next page load.
    const onPage = new Set(cats.map((c) => c.key));
    next.forEach((c) => {
      if (onPage.has(c.key) && Array.isArray(c.slides) && c.slides.length) { pending.set(c.key, c.slides.slice()); }
    });
  }

  // Pool elements for slides nothing refers to any more. Left alone while a
  // queue is still draining, because a queued slide's element is what blockedIds()
  // will be asked about.
  function prunePool() {
    if (pending.size) { return; }
    const pool = root.querySelector(".modland-pool");
    if (!pool) { return; }
    const live = new Set();
    cats.forEach((c) => (c.slides || []).forEach((slide) => live.add(String(slide.id))));
    Array.from(pool.querySelectorAll("[data-id]")).forEach((el) => {
      if (!live.has(el.dataset.id)) { el.remove(); }
    });
  }

  // Install one queued slide into the slot that is about to enter the window
  // from the right, and give back the cell of whatever was there.
  //
  // The raw list and the list the ring walks are not the same array --
  // slidesOf filters out what the viewer's blacklist marked -- so the ring
  // index is mapped back to a raw one. A blocked slide is discarded rather
  // than installed: dropping one would shorten the filtered list under the
  // belt, and every position after it would jump.
  function feedOne(a) {
    const cat = cats[a];
    const queue = cat && pending.get(cat.key);
    if (!queue || !queue.length) { return; }

    const list = slidesOf(a);
    if (!list.length) { return; }

    // IDS MUST STAY UNIQUE WITHIN A CATEGORY.
    //
    // cellFor keys a cell by `${axis}:${id}`, so two entries sharing an id
    // share one DOM element -- and an element can only be in one place, so
    // render() moves it to the second position and the first draws NOTHING.
    // The server dedupes within one set, but this feed MIXES two: a fresh
    // random draw from the same creators overlaps the set already on the belt,
    // heavily. That is where the missing cards came from, and it showed on the
    // second lap because that is when fed-in slides first reach the eye.
    const present = new Set(cat.slides.map((slide) => String(slide.id)));

    const ids = blockedIds();
    let incoming = null;
    while (queue.length) {
      const candidate = queue.shift();
      if (ids.has(String(candidate.id))) { continue; }
      // Already on the belt: nothing to gain by moving it, and a hole to pay
      // for putting it in twice.
      if (present.has(String(candidate.id))) { continue; }
      incoming = candidate;
      break;
    }
    if (!queue.length) { pending.delete(cat.key); prunePool(); }
    if (!incoming) { return; }

    // The far right-hand edge: one past the outermost cell the window builds.
    const ringIndex = (((pos + reachFor(a) + 1) % list.length) + list.length) % list.length;
    const outgoing = list[ringIndex];
    if (!outgoing) { return; }

    const rawIndex = cat.slides.indexOf(outgoing);
    if (rawIndex < 0) { return; }

    cat.slides[rawIndex] = incoming;
    // Only give the cell back if nothing else still shows that slide. The list
    // is unique going forward, but this also holds if it ever was not.
    if (!cat.slides.some((slide) => String(slide.id) === String(outgoing.id))) {
      dropCell(a, outgoing);
    }
  }

  function step(delta) {
    const list = slidesOf(axis);
    if (list.length < 2) { return; }

    pos += delta;
    burst += 1;
    // One slide per step, at the edge the step is uncovering.
    feedOne(axis);

    // Every step gets the overshoot, and mid-run you never see it resolve: the
    // next step re-targets the move from wherever the cell has got to,
    // so the settle-back only plays on the step nobody follows. That is the
    // "no lurch while still scrolling" rule -- the curve simply runs out of
    // time on every step but the last.
    //
    // Which holds only while the next step arrives before the curve's peak.
    // The moves shorten as a run goes on (a long run's curve peaks at 42% of
    // a 200ms move, 84ms in), and when steps come slower than that -- a busy
    // machine, a slower key repeat -- the settle-back played between every
    // step, cards swinging back up to 140px in a frame (2026-10-04). So in a
    // run a move lasts long enough for twice the step interval just seen to
    // fall before its peak -- a re-target reaches the compositor a frame or
    // more after its key, and with a quarter to spare the swings were halved,
    // not gone (Chromium, 2026-10-04) -- never longer than a single step from
    // rest.
    moveY1 = easeFor(burst);
    const now = performance.now();
    const gap = burst > 1 ? now - lastStepAt : 0;
    lastStepAt = now;
    const ms = Math.min(BASE_MS, Math.max(MIN_MS, Math.round(BASE_MS / (1 + (burst * 0.38))), Math.round((gap * 2) / curveFn(xCurve(moveY1)).peakAt)));
    moveMs = ms;

    render();

    // The run has stopped only when nothing else has arrived. Every step pushes
    // this out, so a held arrow never lurches mid-travel -- it lurches once, at
    // the end, harder for having gone further.
    if (settleTimer) { clearTimeout(settleTimer); }
    settleTimer = setTimeout(settle, ms + SETTLE_MS);
  }

  // Up/down changes axis and carries the position with it, so the centre really
  // does change -- the post view keeps its centre because the post IS the thing
  // being sorted; here the axes hold different images.
  function goToAxis(target, direction) {
    if (target === axis || target < 0 || target >= cats.length || busy) { return; }
    busy = true;

    const outClass = direction > 0 ? "is-axis-down" : "is-axis-up";
    const inClass = direction > 0 ? "is-enter-down" : "is-enter-up";

    ride.classList.add(outClass);
    setTimeout(() => {
      axis = target;
      ride.classList.remove(outClass);
      ride.classList.add(inClass);
      render();
      requestAnimationFrame(() => requestAnimationFrame(() => {
        ride.classList.remove(inClass);
        busy = false;
      }));
    }, NAV_MS);
  }

  function selectAxis(a) {
    if (usable(a)) { goToAxis(a, a > axis ? 1 : -1); }
  }

  function shiftAxis(delta) {
    const target = nextUsable(axis, delta < 0 ? -1 : 1);
    if (target >= 0) { goToAxis(target, delta); }
  }

  // --- the ride -----------------------------------------------------------

  function resetRun(forAxis = axis) {
    runLeft = Math.max(slidesOf(forAxis).length - 1, 0);
  }

  // NOBODY WATCHING, NOTHING MOVES. Every advance runs 850ms of animation,
  // and while any animation runs the browser redraws on every frame --
  // measured in Firefox (bin/landing-cpu, 2026-10-03): 3% of a core at rest,
  // ~31% stepping every 2s, and the same ~30% with the belt HIDDEN, so the
  // cost is the moving, not the drawing. An advance nobody can see is that
  // cost for nothing: the ride holds while the carousel is scrolled out of
  // view or the tab is hidden, and carries on from the same slide when it is
  // seen again. The timer keeps ticking; it simply finds nothing to do.
  let onScreen = true;
  if ("IntersectionObserver" in window) {
    new IntersectionObserver((entries) => { onScreen = entries.some((e) => e.isIntersecting); }).observe(ride);
  }

  function autoAdvance() {
    if (!onScreen || document.hidden) { return; }
    if (runLeft > 0) {
      runLeft -= 1;
      step(1);
    } else {
      // A full run of this category is done; hand over to the next one.
      const next = nextUsable(axis, 1);
      if (next >= 0) { resetRun(next); shiftAxis(1); }
    }
  }

  function stopTimer() {
    if (advanceTimer) { clearInterval(advanceTimer); advanceTimer = null; }
  }

  function startTimer() {
    stopTimer();
    advanceTimer = setInterval(autoAdvance, cfg.advanceMs || 6000);
  }

  // PAUSED FOR AS LONG AS SOMEBODY IS BROWSING. The first touch holds the ride
  // RESUME_FIRST_MS; every touch after that ADDS time, each a little more than
  // the last, and the total never runs past the admin's resume setting (10s by
  // default). It used to pause once and ignore every touch after the first, so
  // the ride took the wheel back ten seconds into somebody's browsing
  // (operator, 2026-09-25: "each keypress in any given direction extends the
  // total restart timer by progressively longer amounts of time, capped at
  // 10s or so").
  const RESUME_FIRST_MS = 3000;
  const RESUME_STEP_MS = 800;
  const RESUME_GROWTH = 1.5;
  let resumeAt = 0;
  let touches = 0;
  let countdown = null;
  let fillAnim = null;

  function hideResume() {
    const box = region("resume");
    if (resumeTimer) { clearTimeout(resumeTimer); resumeTimer = null; }
    if (countdown) { clearInterval(countdown); countdown = null; }
    if (fillAnim) { fillAnim.cancel(); fillAnim = null; }
    if (box) { box.hidden = true; }
    touches = 0;
  }

  // A shove backwards before going forward, so the restart reads as picking up
  // where it left off rather than as the page twitching.
  function resume() {
    hideResume();
    ride.classList.add("is-lurching");
    setTimeout(() => {
      ride.classList.remove("is-lurching");
      resetRun();
      step(1);
      startTimer();
    }, 260);
  }

  // The countdown is the pill's fill and its seconds: the fill stands for the
  // whole cap, so an extension visibly pushes it back, and it runs to full as
  // the ride comes back.
  function showResume() {
    const box = region("resume");
    const fill = region("fill");
    const left = region("left");
    if (!box || !fill) { return; }
    box.hidden = false;

    const cap = cfg.resumeMs || 10000;
    const remaining = Math.max(0, resumeAt - Date.now());
    if (fillAnim) { fillAnim.cancel(); fillAnim = null; }
    // Somebody who asked for less motion gets the seconds without the sweep.
    if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      fillAnim = fill.animate(
        [{ transform: `scaleX(${1 - (remaining / cap)})` }, { transform: "scaleX(1)" }],
        { duration: remaining, easing: "linear", fill: "forwards" },
      );
    }

    const paint = () => { if (left) { left.textContent = `${Math.max(1, Math.ceil((resumeAt - Date.now()) / 1000))}s`; } };
    paint();
    if (!countdown) { countdown = setInterval(paint, 250); }

    if (resumeTimer) { clearTimeout(resumeTimer); }
    resumeTimer = setTimeout(resume, remaining);
  }

  function pause() {
    stopTimer();
    const now = Date.now();
    const cap = cfg.resumeMs || 10000;
    const add = touches === 0 ? RESUME_FIRST_MS : RESUME_STEP_MS * Math.pow(RESUME_GROWTH, touches - 1);
    touches += 1;
    resumeAt = Math.min(now + cap, Math.max(resumeAt, now) + add);
    showResume();
  }

  // MAXIMIZE HERO BAND. The class does the widening (stylesheet); the run is
  // re-laid for the width it now has; the choice is remembered server-side
  // through the same endpoint every other Modulation view choice uses.
  function toggleHero(btn) {
    const on = !root.classList.contains("is-hero-max");
    root.classList.toggle("is-hero-max", on);
    btn.setAttribute("aria-pressed", String(on));
    btn.title = on ? "Restore Hero Band" : "Maximize Hero Band";
    beltStale = true;
    requestAnimationFrame(() => { render(); positionThumb(); });
    fetch("/modulation/settings", {
      method: "PATCH",
      headers: { "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') || {}).content || "", "Content-Type": "application/json", Accept: "application/json" },
      credentials: "same-origin",
      body: JSON.stringify({ hero_band: on }),
    }).catch(() => {
      Notice.error("Could not save the hero band setting; it will not be remembered.");
    });
  }


  // --- the fresh set --------------------------------------------------------
  //
  // The candidates behind a random row are recomputed server-side every few
  // minutes (LandingShowcaseCache::REFRESH_EVERY). Until this was wired the
  // only way to see a new draw was to reload the page, and /landing/slides.json
  // was rendered by the controller and fetched by nobody.
  //
  // The swap replaces the hidden pool as well as the payload, and re-runs the
  // blacklist over it. A slide whose pool element the blacklist never saw is a
  // slide it never filtered.
  async function pullFreshSet() {
    if (!cfg.slidesUrl) { return; }
    // Not while someone is using it, and not while the tab is in the
    // background: a set swapped under a reader's hand is a set that loses their
    // place, and one swapped where nobody is looking is work for nothing. The
    // next tick asks again.
    if (document.hidden) { return; }

    try {
      const r = await fetch(cfg.slidesUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" });
      if (!r.ok) { throw new Error(`HTTP ${r.status}`); }
      const data = await r.json();
      if (Array.isArray(data.categories) && data.categories.length) {
        queueFreshSet(data.categories, data.pool);
      }
    } catch {
      // The page keeps the set it already has, which is the whole reason this
      // is a refresh and not a load. Reporting a background poll that will run
      // again in a few minutes would be noise over something the reader cannot
      // act on and has not lost.
    }
  }

  if (cfg.slidesUrl && cfg.refreshMs) {
    setInterval(pullFreshSet, cfg.refreshMs);
  }

  // --- interaction --------------------------------------------------------

  root.addEventListener("click", (e) => {
    const cell = e.target.closest(".mod-cell");
    if (cell && ride.contains(cell)) {
      const d = Number(cell.dataset.d || 0);
      // The cell under the microscope is the one you are looking at, so a click
      // there means "open this". Any other cell means "bring that one here",
      // which is the same gesture the arrows make, just aimed.
      if (d === 0) { return; }
      e.preventDefault();
      step(d);
      pause();
      return;
    }

    const act = e.target.closest("[data-act]");
    if (!act) { return; }

    if (act.dataset.act === "resume") { e.preventDefault(); resume(); return; }
    if (act.dataset.act === "hero") { e.preventDefault(); toggleHero(act); return; }

    e.preventDefault();
    if (act.dataset.act === "next") { step(1); } else if (act.dataset.act === "prev") { step(-1); } else if (act.dataset.act === "axis") {
      selectAxis(Array.from(root.querySelectorAll("[data-act='axis']")).indexOf(act));
    }
    pause();
  });

  // Same keys and the same guard as the post view: left/right along the axis,
  // up/down between axes. A key pressed while typing belongs to the field.
  window.addEventListener("keydown", (e) => {
    if (e.target.closest("input, textarea, select, [contenteditable]")) { return; }
    if (e.key === "ArrowLeft") { step(-1); pause(); } else if (e.key === "ArrowRight") { step(1); pause(); } else if (e.key === "ArrowUp") { e.preventDefault(); shiftAxis(-1); pause(); } else if (e.key === "ArrowDown") { e.preventDefault(); shiftAxis(1); pause(); }
  });

  // The wheel steps the belt, one notch one slide, by Technetium's rule
  // (fourier_wheel_step.js), and counts as browsing like any key. Over the
  // panel only, and the page does not scroll under it there: a wheel that
  // moved the belt AND the page would be two things for one gesture.
  const panel = root.querySelector(".modland-stage-wrap");
  let wheelState = WHEEL_IDLE;
  if (panel) {
    panel.addEventListener("wheel", (e) => {
      e.preventDefault();
      const r = wheelStep(wheelState, { dx: e.deltaX, dy: e.deltaY, mode: e.deltaMode, t: e.timeStamp });
      wheelState = r.state;
      if (r.step) { step(r.step); pause(); }
    }, { passive: false });
  }

  window.addEventListener("resize", () => { beltStale = true; positionThumb(); if (root.classList.contains("is-hero-max")) { scheduleRender(); } });

  // THE BLACKLIST FIRST. A slide is skipped when its pool element carries
  // the blacklist's mark, and those marks are made by the page's Blacklist
  // (#blacklist-box), which Alpine starts on its own schedule. Drawing before
  // it had applied would put a blacklisted picture on screen for as long as
  // the first slide holds. So nothing is drawn until it says it has applied,
  // and every later application (a fresh set rescanned, a rule toggled)
  // redraws. A page with no blacklist at all shows nothing and says why: the
  // rule is that blacklisted posts are never visible (operator, 2026-10-01),
  // and a carousel that cannot apply it must not guess.
  function start() {
    if (started) { return; }
    started = true;
    lamps.start();
    axis = usable(0) ? 0 : nextUsable(0, 1);
    if (axis < 0) { axis = 0; }
    resetRun();
    renderAll();
    startTimer();
  }
  document.addEventListener("danbooru:blacklist-applied", () => {
    if (!started) { start(); return; }
    if (!usable(axis)) { const a = nextUsable(axis, 1); if (a >= 0) { axis = a; resetRun(); } }
    scheduleRender();
  });
  const blacklistBox = document.querySelector("#blacklist-box");
  if (!blacklistBox) {
    console.error("landing carousel: this page has no blacklist (#blacklist-box), so the carousel is not drawn -- render BlacklistComponent in ModulationLandingComponent");
  } else if (blacklistBox.blacklist) {
    start();
  }
}

function initAll() {
  document.querySelectorAll("[data-modland]").forEach(initLanding);
}

$(document).ready(initAll);

export default { initAll };
