// TAG HYPE, for every Modulation surface: which names wear it, and the spin a
// hyped pill does under the pointer.
//
// The MOTION is canon (formant mod-hype-*, and "the exact same tag behavior
// will be visible on all surfaces", operator ruling 2026-09-17), so what lives
// here is the one local decision -- the list -- and the state machine that
// drives canon's three classes. Both were inline in the post page; /posts had
// neither, so a hyped tag sat still there (operator, 2026-09-25: "get
// /posts's tag elements into formant compliance"). The list is the same one
// Technetium keeps (src/client/hypeTags.ts); the two move together until it
// is canon's.
//
// The post page's inline script cannot `import`, so this is also hung on
// window.FourierHype.

export const HYPE = new Set(["butthole"]);

export const isHype = (tag) => HYPE.has(String(tag).trim().toLowerCase());

// Where the pointer is, for every surface at once.
const pointer = { x: -1, y: -1 };
let tracking = false;
function trackPointer() {
  if (tracking) { return; }
  tracking = true;
  document.addEventListener("pointermove", (e) => { pointer.x = e.clientX; pointer.y = e.clientY; }, { passive: true });
  document.addEventListener("pointerout", (e) => { if (!e.relatedTarget) { pointer.x = -1; pointer.y = -1; } });
}

// THE HYPED TAG'S STATE MACHINE. Not :hover -- see the stylesheet. The spin
// goes on at pointer-enter and is never touched by hover again: one continuous
// spin. While a pill spins, a 100ms poll asks whether the pointer is still over
// the pill's LAYOUT box (offsetLeft/offsetTop against the offsetParent, which a
// transform does not move), and only after the pointer has been away for
// --mod-hype-grace does the wind-down start. That grace is what absorbs the
// pill rotating out from under a still pointer, and what the operator asked for
// by name. The poll runs only while something is spinning; nothing ticks on an
// idle page.
export function bindSpin(root) {
  if (!root || root.dataset.hypeBound) { return; }
  root.dataset.hypeBound = "1";
  trackPointer();
  const grace = parseFloat(getComputedStyle(root).getPropertyValue("--mod-hype-grace")) || 800;
  const overLayoutBox = (el) => {
    const op = el.offsetParent || document.body;
    const pr = op.getBoundingClientRect();
    const pad = 6;
    const l = pr.left + el.offsetLeft;
    const t = pr.top + el.offsetTop;
    return pointer.x >= l - pad && pointer.x <= l + el.offsetWidth + pad && pointer.y >= t - pad && pointer.y <= t + el.offsetHeight + pad;
  };
  const spinning = new Map(); // pill -> { away: ms since the pointer left, or null; timer }
  function windDown(pill) {
    const st = spinning.get(pill);
    if (st) { clearTimeout(st.timer); }
    spinning.delete(pill);
    pill.classList.remove("is-spinning");
    if (pill.isConnected) { pill.classList.add("is-spinning-down"); }
  }
  function startSpin(pill) {
    if (spinning.has(pill)) { return; } // already spinning: never restart
    pill.classList.remove("is-spinning-down");
    pill.classList.add("is-spinning");
    const st = { away: null, timer: null };
    spinning.set(pill, st);
    const tick = () => {
      if (!pill.isConnected) { windDown(pill); return; } // the panel re-rendered under it
      if (overLayoutBox(pill)) { st.away = null; } else if (st.away === null) { st.away = performance.now(); }
      if (st.away !== null && performance.now() - st.away >= grace) { windDown(pill); return; }
      st.timer = setTimeout(tick, 100);
    };
    tick();
  }
  root.addEventListener("pointerenter", (e) => {
    const pill = e.target && e.target.closest && e.target.closest(".mod-pill--hype");
    if (pill) { startSpin(pill); }
  }, true);
  root.addEventListener("animationend", (e) => {
    if (e.animationName === "mod-hype-spin-down") { e.target.classList.remove("is-spinning-down"); }
  });
}

// Server-rendered pills carry data-tag; mark the hyped ones.
export function markHype(root) {
  root.querySelectorAll(".mod-pill[data-tag]").forEach((pill) => {
    if (isHype(pill.dataset.tag)) { pill.classList.add("mod-pill--hype"); }
  });
}

window.FourierHype = { HYPE, isHype, bindSpin, markHype };

$(document).ready(() => document.querySelectorAll(".modgal").forEach((g) => { markHype(g); bindSpin(g); }));
