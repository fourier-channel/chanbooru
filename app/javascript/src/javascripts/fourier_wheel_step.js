// The mouse wheel: one notch is one step.
//
// A PORT of Technetium's wheelStep (technetium src/ui/carousel.ts, commit
// 906c73d, 2026-09-24), which its thread strip uses and its
// checks/wheelStep.check.ts holds against real event streams -- 4 to 400px
// notches, macOS acceleration, hi-res detents, trackpad flings, a 20,000-event
// fuzz. The rule and its numbers are Technetium's; change them there and here
// together. Operator, 2026-09-25: "Add mousewheel scrolling to threads and
// posts. Technetium currently has it for thread list view, reuse that
// mechanism."
//
// Technetium's reasoning, which is the whole design (operator, 2026-09-24:
// "two positions per single mousewheel tick, it should be just one"):
//
// A NOTCH IS KNOWN BY ITS TIMING, NOT ITS SIZE. Notch sizes run from 4px (a
// slow tick of an ordinary mouse in Chrome on macOS) to 400px, so no size
// threshold separates "one notch" from "a piece of a stream". What separates
// them is time: a notch arrives ON ITS OWN, a hi-res wheel's detent or a
// trackpad's swipe arrives as a BURST of events a few ms apart.
//  - an event that starts a burst (more than BURST_GAP_MS after the last one,
//    or in line/page units, which are a detent by definition) steps ONCE,
//    whatever its size;
//  - the rest of a burst is a stream: it steps again only after about a
//    card's width of scroll (STREAM_PX) AND at least STREAM_STEP_MS since the
//    last step, so a trackpad fling moves a handful of steps, not the list;
//  - a reversal inside a stream counts only past REVERSE_PX, so a resting
//    finger's jitter moves nothing.
// Time comes in with the event (its timeStamp), so this stays pure.
//
// The Modulation post page is one inline script that cannot `import`, so the
// rule is also hung on window.FourierWheel for it.
export const WHEEL = Object.freeze({
  LINE_PX: 16,
  PAGE_PX: 400,
  MIN_PX: 3,
  BURST_GAP_MS: 25,
  STREAM_PX: 360,
  STREAM_STEP_MS: 180,
  REVERSE_PX: 10,
});

export const WHEEL_IDLE = Object.freeze({ lastT: -Infinity, stepT: -Infinity, dir: 0, acc: 0 });

// ev: { dx, dy, mode (WheelEvent.deltaMode), t (WheelEvent.timeStamp) }.
// Returns { state, step } where step is -1, 0 or 1.
export function wheelStep(s, ev) {
  const raw = Math.abs(ev.dx) > Math.abs(ev.dy) ? ev.dx : ev.dy;
  const d = raw * (ev.mode === 1 ? WHEEL.LINE_PX : ev.mode === 2 ? WHEEL.PAGE_PX : 1);
  if (!Number.isFinite(d) || !Number.isFinite(ev.t) || Math.abs(d) < WHEEL.MIN_PX) {
    return { state: s, step: 0 };
  }
  const dir = d > 0 ? 1 : -1;
  const inBurst = ev.mode === 0 && ev.t - s.lastT <= WHEEL.BURST_GAP_MS;
  if (inBurst && dir !== s.dir) {
    // A reversal mid-stream: jitter unless it is decisive.
    if (Math.abs(d) < WHEEL.REVERSE_PX) { return { state: { ...s, lastT: ev.t }, step: 0 }; }
  } else if (inBurst) {
    const acc = s.acc + Math.abs(d);
    if (acc >= WHEEL.STREAM_PX && ev.t - s.stepT >= WHEEL.STREAM_STEP_MS) {
      return { state: { lastT: ev.t, stepT: ev.t, dir, acc: 0 }, step: dir };
    }
    return { state: { ...s, lastT: ev.t, acc }, step: 0 };
  }
  // A notch on its own, or the start of a new burst: one step.
  return { state: { lastT: ev.t, stepT: ev.t, dir, acc: 0 }, step: dir };
}

window.FourierWheel = { WHEEL, WHEEL_IDLE, wheelStep };
