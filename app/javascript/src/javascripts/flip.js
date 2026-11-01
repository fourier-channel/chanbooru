// FLIP for a list redrawn from scratch: snapshot where every [data-flip-id]
// sat, redraw, then slide each moved node from its old place to its new one.
//
// A plain-JS port of Technetium's src/ui/flip.ts (prefersReducedMotion,
// contentPos, captureRects, playFLIP), kept to the same behaviour. The caller
// pairs the two around a redraw:
//
//   const prev = captureRects(strip); fill(strip, ...); playFLIP(strip, prev);

const DEFAULT_DURATION = 200;
const DEFAULT_EASING = "cubic-bezier(0.2, 0, 0, 1)";

export const prefersReducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Content-space, not viewport: a scroll between the snapshot and the redraw
// must not read as movement.
function contentPos(el, container) {
  const r = el.getBoundingClientRect();
  const c = container.getBoundingClientRect();
  return { top: r.top - c.top + container.scrollTop, left: r.left - c.left + container.scrollLeft };
}

export function captureRects(container) {
  const nodes = container ? [...container.querySelectorAll("[data-flip-id]")] : [];
  return new Map(nodes.map((el) => [el.dataset.flipId, contentPos(el, container)]));
}

// Nodes with no prior rect are newcomers -- their entrance is the deck's, not
// this. Nodes that did not move are skipped: a transition to the same value
// never fires transitionend (Technetium G-04f01d).
export function playFLIP(container, prev, { durationMs = DEFAULT_DURATION, easing = DEFAULT_EASING } = {}) {
  if (!container || prev.size === 0) { return; }

  const moved = [...container.querySelectorAll("[data-flip-id]")]
    .filter((el) => prev.has(el.dataset.flipId))
    .map((el) => {
      const before = prev.get(el.dataset.flipId);
      const now = contentPos(el, container);
      return { el, dx: before.left - now.left, dy: before.top - now.top };
    })
    .filter(({ dx, dy }) => dx !== 0 || dy !== 0);
  if (moved.length === 0) { return; }

  // Reduced motion: no sliding, a moved card fades up in its new slot.
  if (prefersReducedMotion()) {
    moved.forEach(({ el }) => el.animate([{ opacity: 0.35 }, { opacity: 1 }], { duration: 200, easing: "ease-out" }));
    return;
  }

  moved.forEach(({ el, dx, dy }) => {
    el.style.transition = "none";
    el.style.transform = `translate(${dx}px, ${dy}px)`;
  });
  // One forced reflow commits every inverted start at once.
  void container.offsetWidth;

  requestAnimationFrame(() => moved.forEach(({ el }) => {
    el.style.transition = `transform ${durationMs}ms ${easing}`;
    el.style.transform = "";
    const clear = () => {
      el.style.transition = "";
      el.style.transform = "";
      el.removeEventListener("transitionend", clear);
    };
    el.addEventListener("transitionend", clear);
    // transitionend is not guaranteed (interrupted, a sub-pixel no-op).
    setTimeout(clear, durationMs + 80);
  }));
}
