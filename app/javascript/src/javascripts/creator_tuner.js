import Notice from "./notice";
import { pictureStyle } from "./post_view";

// THE TUNER (CreatorTunerComponent; CREATOR_TUNER.md rev 3, sec 7): a
// creator's harmonics one card at a time. A, the Masthead Dial, tunes with a
// knob and a needle through static; B, the Skywave Dial, glides a card across
// a panel in the banner. Both carry the viewer's Scan, the only motion either
// makes on its own, and both hold still while the pointer or focus is on
// them, while they are under 60% in view, while the page is hidden, and
// while a dialog is open.
//
// Every harmonic opens the leaving notice first (sec 5.3); harmonicCard is
// CreatorHarmonicComponent's twin, for the builder to draw a draft with.

const clamp = (lo, x, hi) => Math.min(hi, Math.max(lo, x));
const inOut = (k) => (k < 0.5 ? 4 * k * k * k : 1 - ((((-2 * k) + 2) ** 3) / 2));
const inQ = (k) => k * k;
const outQ = (k) => 1 - ((1 - k) * (1 - k));
const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function el(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  Object.entries(attrs).filter(([, v]) => v !== false && v !== null && v !== undefined)
    .forEach(([k, v]) => node.setAttribute(k, v === true ? "" : String(v)));
  node.append(...kids);
  return node;
}

// --- a harmonic, drawn from its hash ----------------------------------------

const TIERS = { full: ["mark", "title", "subtitle", "button", "host"], compact: ["mark", "title", "host"] };

const drawn = (card, element) => ({
  mark: Boolean(card.places.mark),
  subtitle: Boolean(card.subtitle),
  button: Boolean(card.cta_label),
}[element] ?? true);

// CreatorHarmonicComponent#rows: a row holding a centre and a side place
// splits into thirds, so the centre stays centred.
export function cardRows(card, tier) {
  const elements = TIERS[tier].filter((element) => drawn(card, element));
  return ["t", "m", "b"].map((row) => {
    const columns = Object.fromEntries(["l", "c", "r"].map((column) => [column, elements.filter((element) => card.places[element] === `${row}${column}`)]));
    const occupied = ["l", "c", "r"].filter((column) => columns[column].length);
    const shown = (columns.c.length && occupied.length > 1) ? ["l", "c", "r"] : occupied;
    return [row, shown.length === 3, shown.map((column) => [column, columns[column]])];
  });
}

export function harmonicCard(card, { hidden = false, ring = false, logos = {}, shadeFloor = 35 } = {}) {
  const picture = card.picture;
  const words = {
    mark: () => el("span", { class: "cg-hm-mark" },
      el("i", {}, card.logo ? el("img", { src: logos[card.logo], alt: "" }) : card.name.charAt(0).toUpperCase()), el("b", {}, card.name)),
    title: () => el("span", { class: "cg-hm-title" }, card.title),
    subtitle: () => el("span", { class: "cg-hm-sub" }, card.subtitle),
    button: () => el("span", { class: "cg-hm-cta" }, card.cta_label),
    host: () => el("span", { class: "cg-hm-host" }, el("bdi", {}, card.host)),
  };
  const art = picture
    ? el("img", {
      class: "cg-hm-img mod-blacklist-target", src: picture.src, alt: "", loading: "lazy", decoding: "async", draggable: "false",
      style: pictureStyle(picture),
      "data-id": picture.id, "data-tags": picture.tags, "data-rating": picture.rating, "data-flags": picture.flags, "data-score": picture.score, "data-uploader-id": picture.uploader_id,
    })
    : el("span", { class: `cg-hm-grad cg-hm-grad--${card.gradient || 0}` });
  const classes = ["cg-hm", !(card.counts && card.shown) && "cg-hm--off", card.notice && "cg-hm--amber", ring && "cg-hm--ring"].filter(Boolean).join(" ");
  return el("a", {
    class: classes, href: card.url, target: "_blank", rel: "external noopener noreferrer nofollow ugc", draggable: "false",
    title: card.notice, hidden, "aria-label": `${card.title}, ${card.host}`,
    "data-cg-harmonic": card.id, "data-name": card.name, "data-host": card.host, "data-adult": String(Boolean(card.adult)),
  },
  el("span", { class: "cg-hm-art" }, art),
  el("span", { class: "cg-hm-shade", style: `opacity: ${picture ? Math.max(picture.shade, shadeFloor) / 100 : 0}` }),
  ...Object.keys(TIERS).map((tier) => el("span", { class: `cg-hm-safe cg-hm-safe--${tier}` },
    ...cardRows(card, tier).map(([row, thirds, columns]) => el("span", { class: `cg-hm-row cg-hm-row--${row}${thirds ? " cg-hm-row--3" : ""}` },
      ...columns.map(([column, elements]) => el("span", { class: `cg-hm-col cg-hm-col--${column}` }, ...elements.map((element) => words[element]()))))))));
}

// --- holding still ----------------------------------------------------------
//
// A Tuner pauses while hovered, focused, under 60% in view, while the page
// is hidden or while a dialog is open; the leaving notice tells every Tuner
// when it opens and closes.

const WATCHERS = new Set();
const recheck = () => WATCHERS.forEach((update) => update());

function watch(node, pause, resume) {
  const life = new AbortController();
  const state = { hover: false, focus: false, view: true };
  const paused = () => state.hover || state.focus || !state.view || document.hidden || Boolean(document.querySelector("dialog[open]"));
  const update = () => (paused() ? pause() : resume());
  node.addEventListener("pointerenter", (e) => { if (e.pointerType === "mouse") { state.hover = true; update(); } }, { signal: life.signal });
  node.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") { state.hover = false; update(); } }, { signal: life.signal });
  node.addEventListener("focusin", () => { state.focus = true; update(); }, { signal: life.signal });
  node.addEventListener("focusout", (e) => { if (!node.contains(e.relatedTarget)) { state.focus = false; update(); } }, { signal: life.signal });
  document.addEventListener("visibilitychange", update, { signal: life.signal });
  const seen = new IntersectionObserver((entries) => { state.view = entries[entries.length - 1].intersectionRatio >= 0.6; update(); }, { threshold: [0, 0.6, 1] });
  seen.observe(node);
  WATCHERS.add(update);
  return { paused, stop: () => { life.abort(); seen.disconnect(); WATCHERS.delete(update); } };
}

// --- Scan --------------------------------------------------------------------
//
// The viewer's own choice, remembered (ModulationSetting tuner_scan). No
// opinion is on, unless the viewer's system asks for less motion.

function saveScan(on) {
  fetch("/modulation/settings", {
    method: "PATCH",
    headers: {
      "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') || {}).content || "",
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    credentials: "same-origin",
    body: JSON.stringify({ tuner_scan: on }),
  }).then((response) => {
    if (!response.ok) { throw new Error(response.statusText); }
  }).catch(() => {
    Notice.error("Scan was not remembered: it holds on this page only. Reload and switch it again to keep it.");
  });
}

// --- A, the Masthead Dial ----------------------------------------------------

const HOLD_A = [8000, 6000];

// The static between stations, after fourier.channel's front page
// (~/fourier-domain/sites/fourier.channel/index.html, its glitch field and
// noise waves): sparse grey speckles and hairlines on a dark veil, a band
// torn sideways now and then, and two or three orange waves seen only in
// fragments, each flickering out. Its strength is the dial's noise; it is
// drawn only while the needle moves, so it ends with the tuning.
function staticWaves() {
  const now = performance.now();
  return Array.from({ length: 2 + Math.floor(Math.random() * 2) }, () => ({
    freq: 1 + (Math.random() * 3),
    amp: 0.03 + (Math.random() * 0.08),
    y: 0.5 + (((Math.random() * 2) - 1) * 0.35),
    phase: Math.random() * Math.PI * 2,
    travel: Math.random(),
    speed: (0.05 + (Math.random() * 0.2)) * (Math.random() < 0.5 ? -1 : 1),
    env: Math.random(),
    envWidth: 0.2 + (Math.random() * 0.3),
    envSpeed: (0.15 + (Math.random() * 0.35)) * (Math.random() < 0.5 ? -1 : 1),
    out: 0,
    next: now + 150 + (Math.random() * 600),
  }));
}

const WAVE_SEGMENTS = 32;

function drawStatic(context, { w, h, dpr }, noise, waves, orange, dt) {
  const now = performance.now();
  const grey = (lo, span, a) => {
    const v = lo + Math.floor(Math.random() * span);
    return `rgba(${v}, ${v}, ${v}, ${a.toFixed(3)})`;
  };
  context.clearRect(0, 0, w, h);
  context.globalAlpha = 1;
  context.fillStyle = "rgba(10, 10, 10, 0.7)";
  context.fillRect(0, 0, w, h);

  context.strokeStyle = orange;
  context.lineWidth = 1;
  waves.forEach((wave) => {
    wave.env += (wave.envSpeed * dt) / 1000;
    if (wave.env > 1.5) { wave.env -= 2; } else if (wave.env < -0.5) { wave.env += 2; }
    wave.travel += (wave.speed * dt) / 1000;
    wave.travel -= Math.floor(wave.travel);
    if (now >= wave.next) {
      wave.out = now + 60 + (Math.random() * 180);
      wave.next = wave.out + 250 + (Math.random() * 700);
    }
    if (now < wave.out) { return; }
    const at = (k) => [((k + wave.travel) % 1) * w, (wave.y + (wave.amp * Math.sin((wave.freq * k * Math.PI * 2) + wave.phase))) * h];
    Array.from({ length: WAVE_SEGMENTS }, (_, seg) => seg).forEach((seg) => {
      const env = Math.max(0, 1 - (Math.abs(((seg + 0.5) / WAVE_SEGMENTS) - wave.env) / wave.envWidth));
      const [x1, y1] = at(seg / WAVE_SEGMENTS);
      const [x2, y2] = at((seg + 1) / WAVE_SEGMENTS);
      // A segment across the wrap would draw a line over the whole card.
      if (env <= 0 || x2 < x1) { return; }
      context.globalAlpha = env * (0.25 + (0.5 * noise));
      context.beginPath();
      context.moveTo(x1, y1);
      context.lineTo(x2, y2);
      context.stroke();
    });
  });
  context.globalAlpha = 1;

  Array.from({ length: Math.floor(70 * noise) }).forEach(() => {
    context.fillStyle = grey(150, 105, 0.15 + (0.35 * Math.random() * noise));
    context.fillRect(Math.random() * w, Math.random() * h, 1 + Math.random(), 1 + Math.random());
  });
  Array.from({ length: Math.floor(10 * noise) }).forEach(() => {
    const y = Math.floor(Math.random() * h) + 0.5;
    context.strokeStyle = grey(180, 75, 0.08 + (0.12 * noise));
    context.beginPath();
    context.moveTo(0, y);
    context.lineTo(w, y);
    context.stroke();
  });
  // The tear: a band of what is drawn, laid back over itself sideways. The
  // source is in the canvas's own pixels, the destination in CSS pixels.
  if (Math.random() < 0.35 * noise) {
    const band = 3 + (Math.random() * 9);
    const y = Math.random() * (h - band);
    const dx = (Math.random() < 0.5 ? -1 : 1) * (2 + (Math.random() * 10)) * noise;
    context.drawImage(context.canvas, 0, y * dpr, w * dpr, band * dpr, dx, y, w, band);
  }
}

function dialA(section, view, reduce) {
  const slot = section.querySelector(".cg-tuner-slot");
  const cards = Array.from(slot.querySelectorAll(".cg-hm"));
  const canvas = section.querySelector(".cg-tuner-static");
  const context = canvas.getContext("2d");
  const needle = section.querySelector(".cg-tuner-needle");
  const knob = section.querySelector(".cg-tuner-knob");
  const scale = section.querySelector(".cg-tuner-scale");
  const stations = Array.from(scale.querySelectorAll(".cg-tuner-station"));
  const n = cards.length;
  const LO = -0.42;
  const HI = n - 1 + 0.42;
  const life = new AbortController();
  const on = { signal: life.signal };
  // The card drawn unhidden is where the needle starts: the first, or in the
  // editor the one being built.
  const first = Math.max(0, cards.findIndex((card) => !card.hidden));
  let p = first;
  let target = first;
  let segs = [];
  let raf = 0;
  let lastT = 0;
  let lastP = 0;
  let vel = 0;
  let noise = 0;
  let shown = first;
  let drag = false;
  let wandering = false;
  let hold = 0;
  // The static's size in CSS pixels and its pixel ratio, its waves and its
  // orange (the formant's own, never a literal), all taken as a tuning starts.
  const size = { w: 0, h: 0, dpr: 1 };
  let waves = [];
  let orange = "";
  let staticT = 0;

  const near = () => clamp(0, Math.round(p), n - 1);

  function aria(k) {
    knob.setAttribute("aria-valuenow", k + 1);
    knob.setAttribute("aria-valuetext", stations[k].dataset.station);
    stations.forEach((station, i) => station.classList.toggle("is-on", i === k));
  }

  function paint() {
    const k = near();
    noise = reduce ? 0 : clamp(0, (Math.abs(p - k) * 1.4) + (Math.min(vel / 6, 1) * 0.45), 1);
    if (k !== shown) {
      cards[shown].style.filter = "";
      cards[shown].style.transform = "";
      cards.forEach((card, i) => { card.hidden = i !== k; });
      if (reduce) { cards[k].animate([{ opacity: 0 }, { opacity: 1 }], 150); }
      shown = k;
    }
    const f = (p + 0.5) / n;
    needle.style.left = `${(f * 100).toFixed(3)}%`;
    knob.style.setProperty("--rot", `${(-135 + (f * 270)).toFixed(1)}deg`);
    if (noise > 0.01) {
      const now = performance.now();
      drawStatic(context, size, noise, waves, orange, staticT ? Math.min(100, now - staticT) : 16);
      staticT = now;
      cards[k].style.filter = `blur(${(noise * 2).toFixed(2)}px) saturate(${(1 - (noise * 0.6)).toFixed(2)})`;
      // The card tears sideways with the static, and hardly moves up or down.
      cards[k].style.transform = `translate(${((Math.random() - 0.5) * noise * 10).toFixed(1)}px, ${((Math.random() - 0.5) * noise).toFixed(1)}px)`;
      canvas.style.opacity = Math.min(1, noise * 1.5).toFixed(3);
    } else {
      staticT = 0;
      context.clearRect(0, 0, size.w, size.h);
      canvas.style.opacity = "0";
      cards[k].style.filter = "";
      cards[k].style.transform = "";
    }
  }

  let watcher = null;

  function rest() {
    lastT = 0;
    vel = 0;
    wandering = false;
    aria(near());
    // arm() leads back here through wander(): one of the cycle comes first.
    // eslint-disable-next-line no-use-before-define
    arm();
  }

  function frame(t) {
    raf = 0;
    if (segs.length) {
      const seg = segs[0];
      if (seg.t0 === undefined) { seg.t0 = t; seg.from = p; }
      const k = Math.min(1, (t - seg.t0) / seg.dur);
      p = seg.from + ((seg.to - seg.from) * seg.ease(k));
      if (k >= 1) { segs.shift(); }
    }
    const dt = lastT ? Math.max(8, t - lastT) : 16;
    vel = (Math.abs(p - lastP) * 1000) / dt;
    lastP = p;
    lastT = t;
    paint();
    if (segs.length || drag || noise > 0.01) {
      raf = requestAnimationFrame(frame);
    } else {
      rest();
    }
  }

  function go() {
    if (!raf) {
      lastT = 0;
      lastP = p;
      size.dpr = Math.min(window.devicePixelRatio || 1, 2);
      size.w = slot.clientWidth;
      size.h = slot.clientHeight;
      const [w, h] = [Math.round(size.w * size.dpr), Math.round(size.h * size.dpr)];
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      context.setTransform(size.dpr, 0, 0, size.dpr, 0, 0);
      waves = staticWaves();
      orange = getComputedStyle(section).getPropertyValue("--mod-active-fg").trim();
      raf = requestAnimationFrame(frame);
    }
  }

  function tuneTo(to) {
    const t = clamp(0, to, n - 1);
    target = t;
    wandering = false;
    clearTimeout(hold);
    if (reduce) {
      segs = [];
      p = t;
      vel = 0;
      paint();
      rest();
      return;
    }
    const dist = Math.abs(t - p);
    const sign = t > p ? 1 : -1;
    segs = dist < 0.02 ? [{ to: t, dur: 120, ease: outQ }] : [{ to: t + (sign * 0.07), dur: 350 + (300 * dist), ease: inOut }, { to: t, dur: 220, ease: outQ }];
    go();
  }

  // Scan's move: a wobble, a bounce off at least one end of the scale, and a
  // settle on another station, two or more away when there is one.
  function wander() {
    const c = near();
    const others = cards.map((_, i) => i).filter((i) => i !== c);
    const far = others.filter((i) => Math.abs(i - c) >= 2);
    const pool = far.length ? far : others;
    const t = pool[Math.floor(Math.random() * pool.length)];
    if (reduce) {
      tuneTo(t);
      return;
    }
    const farEnd = Math.abs(LO - t) > Math.abs(HI - t) ? LO : HI;
    const otherEnd = (end) => (end === LO ? HI : LO);
    const e1 = Math.random() < 0.7 ? farEnd : otherEnd(farEnd);
    const list = [];
    let q = p;
    const to = (x, dur, ease) => {
      list.push({ to: x, dur, ease });
      q = x;
    };
    const bounce = (end) => {
      to(end, 300 + (420 * Math.abs(end - q)), inQ);
      to(end + ((end === LO ? 1 : -1) * (0.45 + (Math.random() * 0.25))), 300, outQ);
    };
    const w = (Math.random() < 0.5 ? -1 : 1) * (0.22 + (Math.random() * 0.18));
    to(c + w, 420 + (Math.random() * 200), inOut);
    to(c - (w * 0.6), 380, inOut);
    bounce(e1);
    if (Math.random() < 0.3) { bounce(otherEnd(e1)); }
    to(t + ((t > q ? 1 : -1) * 0.08), 300 + (420 * Math.abs(t - q)), inOut);
    to(t, 260, outQ);
    segs = list;
    target = t;
    wandering = true;
    go();
  }

  function arm() {
    clearTimeout(hold);
    if (!view.scan || n < 2 || !watcher || watcher.paused()) { return; }
    hold = setTimeout(() => { if (view.scan && !watcher.paused()) { wander(); } }, HOLD_A[0] + (Math.random() * HOLD_A[1]));
  }

  // Held mid-wander, the needle settles on the nearest station at once.
  function settleNow() {
    clearTimeout(hold);
    if (wandering) {
      wandering = false;
      target = near();
      segs = [{ to: target, dur: 260, ease: outQ }];
      go();
    }
  }

  watcher = watch(section, settleNow, () => { if (!raf) { arm(); } });

  knob.addEventListener("keydown", (e) => {
    const step = { ArrowRight: 1, ArrowUp: 1, PageUp: 1, ArrowLeft: -1, ArrowDown: -1, PageDown: -1 }[e.key];
    const to = step ? target + step : { Home: 0, End: n - 1 }[e.key];
    if (to === undefined) { return; }
    e.preventDefault();
    tuneTo(to);
  }, on);

  // A drag past 4 px turns the knob or slides the needle; a tap on the scale
  // tunes to the nearest station.
  function grab(e, node, place) {
    e.preventDefault();
    node.setPointerCapture(e.pointerId);
    const start = { x: e.clientX, y: e.clientY, p };
    let moved = false;
    const move = (ev) => {
      if (!moved && Math.abs(ev.clientX - start.x) + Math.abs(ev.clientY - start.y) > 4) {
        moved = true;
        clearTimeout(hold);
        wandering = false;
        segs = [];
        drag = true;
        go();
      }
      if (moved) { p = place(ev, start); }
    };
    const up = (ev) => {
      node.removeEventListener("pointermove", move);
      node.removeEventListener("pointerup", up);
      node.removeEventListener("pointercancel", up);
      if (moved) {
        drag = false;
        tuneTo(near());
      } else if (node === scale) {
        const box = scale.getBoundingClientRect();
        tuneTo(Math.round(clamp(0, (((ev.clientX - box.left) / box.width) * n) - 0.5, n - 1)));
      }
    };
    node.addEventListener("pointermove", move);
    node.addEventListener("pointerup", up);
    node.addEventListener("pointercancel", up);
  }

  knob.addEventListener("pointerdown", (e) => {
    knob.focus();
    grab(e, knob, (ev, start) => clamp(LO, start.p + (((ev.clientX - start.x) - (ev.clientY - start.y)) / 26), HI));
  }, on);
  scale.addEventListener("pointerdown", (e) => {
    grab(e, scale, (ev) => {
      const box = scale.getBoundingClientRect();
      return clamp(LO, (((ev.clientX - box.left) / box.width) * n) - 0.5, HI);
    });
  }, on);

  // Under 24 px a station the marks hide (CreatorTunerComponent).
  const fit = new ResizeObserver(() => scale.classList.toggle("cg-tuner-scale--bare", scale.clientWidth / n < 24));
  fit.observe(scale);

  paint();
  aria(first);
  arm();
  return {
    scan: () => (view.scan ? arm() : settleNow()),
    stop: () => {
      cancelAnimationFrame(raf);
      clearTimeout(hold);
      watcher.stop();
      fit.disconnect();
      life.abort();
    },
  };
}

// --- B, the Skywave Dial -----------------------------------------------------

const HOLD_B = 8000;
const GLIDE = { duration: 480, easing: "cubic-bezier(0.45, 0, 0.2, 1)" };

function skyB(section, view, reduce) {
  const cards = Array.from(section.querySelectorAll(".cg-tuner-slot .cg-hm"));
  const pips = Array.from(section.querySelectorAll(".cg-tuner-pip"));
  const n = cards.length;
  const life = new AbortController();
  let index = Math.max(0, cards.findIndex((card) => !card.hidden));
  let busy = false;
  let hold = 0;
  let watcher = null;

  // The card arriving enters from the side it is on, the card leaving goes
  // out the other, both clipped by the panel.
  function show(i, dir) {
    if (i === index || busy) { return; }
    const leaving = cards[index];
    const arriving = cards[i];
    index = i;
    pips.forEach((pip, j) => pip.setAttribute("aria-current", String(j === i)));
    arriving.hidden = false;
    if (reduce) {
      leaving.hidden = true;
      arriving.animate([{ opacity: 0 }, { opacity: 1 }], 150);
      return;
    }
    busy = true;
    const distance = section.querySelector(".cg-tuner-panel").offsetWidth;
    leaving.animate([{ transform: "translateX(0)" }, { transform: `translateX(${-dir * distance}px)` }], GLIDE);
    arriving.animate([{ transform: `translateX(${dir * distance}px)` }, { transform: "translateX(0)" }], GLIDE).finished.then(() => {
      leaving.hidden = true;
      busy = false;
    });
  }

  function arm() {
    clearTimeout(hold);
    if (!view.scan || n < 2 || !watcher || watcher.paused()) { return; }
    hold = setTimeout(() => {
      if (!view.scan || watcher.paused()) { return; }
      show((index + 1) % n, 1);
      arm();
    }, HOLD_B);
  }

  watcher = watch(section, () => clearTimeout(hold), arm);

  section.addEventListener("click", (e) => {
    const step = e.target.closest("[data-cg-step]");
    const pip = e.target.closest("[data-cg-pip]");
    if (step) {
      const dir = Number(step.dataset.cgStep);
      show((index + dir + n) % n, dir);
    } else if (pip) {
      const i = Number(pip.dataset.cgPip);
      show(i, i > index ? 1 : -1);
    }
  }, { signal: life.signal });

  arm();
  return {
    scan: arm,
    stop: () => {
      clearTimeout(hold);
      watcher.stop();
      life.abort();
    },
  };
}

// --- a Tuner ---------------------------------------------------------------------

// Starts one Tuner section; returns what stops it, for the editor's redraw.
// Held (the editor's Tuner), Scan is off and cannot be switched: a card
// being built stays put.
export function mountTuner(section, { hold = false } = {}) {
  const reduce = reducedMotion();
  const saved = section.dataset.scan;
  const view = { scan: !hold && (saved === "" ? !reduce : saved === "true") };
  const button = section.querySelector("[data-cg-scan]");
  button.setAttribute("aria-pressed", String(view.scan));
  if (hold) {
    button.disabled = true;
    button.title = "Scan holds while you edit. Visitors see it as they set it.";
  }
  const dial = (section.dataset.cgTuner === "A" ? dialA : skyB)(section, view, reduce);
  const toggle = () => {
    view.scan = !view.scan;
    section.dataset.scan = String(view.scan);
    button.setAttribute("aria-pressed", String(view.scan));
    saveScan(view.scan);
    dial.scan();
  };
  button.addEventListener("click", toggle);
  return () => {
    button.removeEventListener("click", toggle);
    dial.stop();
  };
}

// CreatorTunerComponent's twin, for the editor: the draft's cards, the one
// being built shown first and ringed, and while there is room an add tile
// after the last.
export function tunerSection(placement, cards, { logos = {}, shadeFloor = 35, add = false, ring = null } = {}) {
  const start = ring ?? 0;
  // A station is [its name, its letter, its bundled logo]: the logo is the
  // mark, the letter stands in for a site with none.
  const stations = [...cards.map((card) => [`${card.name}: ${card.title}`, card.name.charAt(0).toUpperCase(), card.logo && logos[card.logo]]), ...(add ? [["Add a channel", "+", null]] : [])];
  const n = stations.length;
  const tiles = [
    ...cards.map((card, i) => harmonicCard(card, { hidden: i !== start, ring: i === ring, logos, shadeFloor })),
    ...(add ? [el("button", { type: "button", class: "cg-hm cg-hm--add", hidden: cards.length !== start, "data-cg-add": true, "aria-label": "Add a channel" },
      el("span", { class: "cg-hm-add" }, el("b", { "aria-hidden": "true" }, "+"), "Add a channel"))] : []),
  ];
  const scan = () => el("button", { type: "button", class: "cg-tuner-scan", "data-cg-scan": true, "aria-pressed": "false" }, "Scan");
  const section = el("section", { class: `cg-tuner cg-tuner--${placement.toLowerCase()}`, "aria-label": "Tuner", "data-cg-tuner": placement, "data-scan": "false" });
  if (placement === "A") {
    section.append(el("div", { class: "cg-tuner-plate" },
      el("div", { class: "cg-tuner-slot" }, ...tiles,
        el("canvas", { class: "cg-tuner-static", width: 320, height: 200, "aria-hidden": "true" })),
      el("div", { class: "cg-tuner-dial" }, scan(),
        el("div", { class: "cg-tuner-scale", "aria-hidden": "true" },
          ...Array.from({ length: (n * 4) + 1 }, (_, k) => el("span", { class: "cg-tuner-tick", style: `left: ${((k * 25) / n).toFixed(3)}%` })),
          ...stations.map(([station, letter, src], i) => el("span", { class: `cg-tuner-station${i === start ? " is-on" : ""}`, "data-station": station, style: `left: ${(((i + 0.5) * 100) / n).toFixed(3)}%` },
            el("b", {}, src ? el("img", { src, alt: "" }) : letter))),
          el("span", { class: "cg-tuner-needle" })),
        el("div", { class: "cg-tuner-knob", role: "slider", tabindex: 0, "aria-label": "Tuner station", "aria-valuemin": 1, "aria-valuemax": n },
          el("span", { class: "cg-tuner-cap" })))));
  } else {
    section.append(
      el("div", { class: "cg-tuner-panel" }, el("div", { class: "cg-tuner-slot" }, ...tiles)),
      el("div", { class: "cg-tuner-controls" },
        el("button", { type: "button", class: "cg-tuner-step", "data-cg-step": -1, "aria-label": "Previous channel" }, "\u2039"),
        ...stations.map(([station], i) => el("button", {
          type: "button", class: "cg-tuner-pip", "data-cg-pip": i, "aria-current": String(i === start),
          "aria-label": i < cards.length ? `Channel ${i + 1} of ${cards.length}: ${cards[i].title}` : station,
        })),
        scan(),
        el("button", { type: "button", class: "cg-tuner-step", "data-cg-step": 1, "aria-label": "Next channel" }, "\u203a")));
  }
  return section;
}

// --- the leaving notice --------------------------------------------------------
//
// A click, a tap, Enter or a middle click on a harmonic opens the notice
// first; Go opens the link with nothing of the booru sent along. The context
// menu is the link's own. In the editor's Tuner and the builder a card is
// being set, not followed ([data-cg-build], harmonic_builder.js).
export function bindLeave(root) {
  const dialog = root.querySelector("[data-cg-leave]");
  if (!dialog) { return; }
  let url = null;

  function open(e) {
    const card = e.target.closest("a.cg-hm");
    if (!card || !root.contains(card) || card.closest("[data-cg-build]")) { return; }
    if (e.type === "auxclick" && e.button !== 1) { return; }
    e.preventDefault();
    url = card.href;
    dialog.querySelectorAll("[data-cg-leave-service]").forEach((node) => { node.textContent = card.dataset.name; });
    dialog.querySelector("[data-cg-leave-addr]").textContent = url;
    dialog.querySelector("[data-cg-leave-adult]").hidden = card.dataset.adult !== "true";
    dialog.returnValue = "";
    dialog.showModal();
    recheck();
  }

  root.addEventListener("click", open);
  root.addEventListener("auxclick", open);
  // A click on the backdrop is a click on the dialog itself: stay.
  dialog.addEventListener("click", (e) => { if (e.target === dialog) { dialog.close("stay"); } });
  dialog.addEventListener("close", () => {
    if (dialog.returnValue === "go") { window.open(url, "_blank", "noopener,noreferrer"); }
    url = null;
    recheck();
  });
}
