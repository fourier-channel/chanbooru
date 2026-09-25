// The archive pulse: it breathes twice when it comes into view, and its
// tooltip says when the last upload was and when the next is expected.
//
// It beats on ARRIVAL rather than on page load because on the landing page the
// dot sits under the featured creators, below the fold for most visitors: a
// pulse that played at load would finish before anyone scrolled to it. Each
// time it comes back into view it beats again, unless it is still beating. See
// archive_pulse_component.scss for why it no longer loops.
function initPulse(dot) {
  if (dot.dataset.modpulseBooted) { return; }
  dot.dataset.modpulseBooted = "1";
  dot.addEventListener("animationend", () => dot.classList.remove("is-beating"));
  new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) { dot.classList.add("is-beating"); }
    });
  }).observe(dot);
}

// "4 minutes", "an hour", "a few seconds".
function span(seconds) {
  const s = Math.max(0, Math.round(seconds));
  const unit = [[86400, "day"], [3600, "hour"], [60, "minute"]].find(([size]) => s >= size);
  if (!unit) { return "a few seconds"; }
  const n = Math.round(s / unit[0]);
  return n === 1 ? `${unit[1] === "hour" ? "an" : "a"} ${unit[1]}` : `${n} ${unit[1]}s`;
}

// NEXT IS AN EXPECTATION, NEVER A COUNTDOWN. Nothing schedules the next upload
// (see ArchivePulse::BURST_GAP): the server hands over when the latest pass of
// uploads began and the usual gap between passes, and this projects one gap
// forward. It is worded as a guess and shows the pace it guessed from, and it
// says so plainly when there is no pace to go by rather than printing a number.
function describe(stat, now) {
  const d = stat.dataset;
  const last = Math.max(Date.parse(d.newestAt) || 0, Date.parse(d.lastAt) || 0);
  const lines = [`Last post: ${span((now - last) / 1000)} ago`];
  const every = Number(d.every);
  const burst = Date.parse(d.burstAt);

  if (!every || !burst) {
    lines.push("Next post: too few recent uploads to estimate");
    return lines.join("\n");
  }

  // Uploads inside one pass are seconds apart: a post under a minute old means
  // a pass is probably still running.
  const left = ((burst + (every * 1000)) - now) / 1000;
  if (now - last < 60000) {
    lines.push("Next post: uploading now");
  } else if (left > 60) {
    lines.push(`Next post: expected in about ${span(left)}`);
  } else if (left > 0) {
    lines.push("Next post: expected within a minute");
  } else if (left > -every) {
    lines.push("Next post: expected any moment");
  } else {
    lines.push("Next post: later than the recent pace, no estimate");
  }
  lines.push(`(uploads have been arriving about every ${span(every)})`);
  return lines.join("\n");
}

function initTooltip(stat) {
  const refresh = () => { stat.title = describe(stat, Date.now()); };
  refresh();
  stat.addEventListener("pointerenter", refresh);
  stat.addEventListener("focusin", refresh);
}

$(document).ready(() => {
  document.querySelectorAll(".modpulse-dot").forEach(initPulse);
  document.querySelectorAll(".modpulse-stat--live").forEach(initTooltip);
});

export default { initPulse, describe };
