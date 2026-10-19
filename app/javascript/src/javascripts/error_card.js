// Replace an image that failed to load with a card that says why.
//
// A failed <img> otherwise renders as a browser's broken-image glyph and, in
// some browsers, the raw filename -- which tells a visitor nothing about whether
// they lack permission, browsed too fast, or found a genuine hole. The status is
// the one useful thing the server said, and this is what puts it on screen.

// Only media. A blanket handler would also swap a broken 16px icon for a
// 640-wide card, which is worse than the glyph it replaced.
const MEDIA_SELECTOR = [
  "#image",
  ".post-preview-image",
  ".modgal-thumb",
  ".mod-image",
  ".modland-slide-img",
  ".modland-promoted-thumb",
  // The class sits on the wrapping link here, not the image, so the element
  // form of this never matched and the Creator of the Month thumbnail was the
  // one picture on the front page still showing a browser's broken-file icon.
  ".modcreator-thumb",
  "[data-error-card]",
].join(", ");

// The landing conveyor's cells DO match, via .mod-image, and that is a reversal
// of an earlier decision worth recording. When the flanks were a stacked column
// of 122px thumbnails they were excluded: a card sized for a 520px stage is
// unreadable that small, and six of them around the picture was worse than the
// glyph it replaced. The belt made them big enough to read, and the landing
// component retunes each card between the full and compact layouts as its cell
// changes size -- so the reason for the exclusion is gone.

// The card for a status we could not determine.
//
// Three digits, as a STRING, and that is not cosmetic. This was 0, which built
// the URL /errors/0.svg -- and the route constrains :status to \d{3}, so it
// 404'd. The fallback card has therefore never rendered once: every failure
// where the status could not be read fell back to a card that was itself a
// failure, and the reader got the browser's broken-image icon, which is the
// exact outcome this whole file exists to prevent.
//
// It reaches ErrorArt as 0 either way, so FALLBACK and the "?" code are
// unchanged; only the URL had to be three digits wide.
const UNKNOWN = "000";

// Below this, the full card's explanation renders too small to read, so the
// compact layout is served instead. Roughly the width at which 16px text inside
// a 640-wide viewBox drops under about 9px on screen.
const COMPACT_BELOW_PX = 320;

function cardUrl(status, width) {
  const compact = width > 0 && width < COMPACT_BELOW_PX ? "?compact=1" : "";
  return `/errors/${status || UNKNOWN}.svg${compact}`;
}

// The status is not on the error event -- the browser does not expose it to an
// <img> failure -- so it has to be asked for separately. Works for same-origin
// media and for cross-origin media that sends CORS headers; anything else
// answers "unknown", which still gets a card.
// The probe must carry what the image carried. Media on a sibling 41chan
// host (the Matrix media Worker) is authorized by a cookie the <img> sent;
// a "same-origin" probe drops it across origins and every refused picture
// read 401 when the server had said 403. The Worker echoes credentialed
// CORS for booru.41chan.net (2026-09-06), so "include" is answerable there;
// a host that does not answer CORS at all fails the probe the same way it
// always did, into UNKNOWN.
function probeCredentials(src) {
  try {
    return new URL(src, location.href).origin === location.origin ? "same-origin" : "include";
  } catch (e) {
    return "same-origin";
  }
}

// Fork: a 503 is the media gate's TRANSIENT refusal -- fourier-auth fails
// closed when it cannot ask the booru in time, and says Retry-After: 2 (the
// Worker keeps that refusal as long). Incident 2026-10-19: 78 thumbnails were
// refused in a burst and each card stayed up until the reader middle-clicked,
// though the next ask would have been answered. So a 503 card tries its image
// again ONCE, about three seconds on, jittered so a gallery's cards do not
// all come back in the same instant. Never a second time: a reload that fails
// is carded as any failure is, and stays. Every other status is final.
//
// A reload that loads says so on the image, bubbling (HEALED_EVENT): a page
// that marked the picture failed when it first failed takes the mark back.
// The hero band's conveyor does -- it shapes a failed cell like a card and
// never promotes it (modulation_landing_component.js).
const RETRY_STATUS = 503;
const RETRY_AFTER_MS = 3000;
const RETRY_JITTER_MS = 1000;
const HEALED_EVENT = "errorcard:healed";

function retryOnce(img, src) {
  if (img.dataset.errorRetried) { return; }
  img.dataset.errorRetried = "1";

  setTimeout(() => {
    // Let the image's next failure be carded again.
    delete img.dataset.errorCarded;
    img.classList.remove("error-card");
    // The next load is the picture -- or, when it failed again, its new
    // card, which cardify has marked by then.
    img.addEventListener("load", () => {
      if (!img.dataset.errorCarded) { img.dispatchEvent(new CustomEvent(HEALED_EVENT, { bubbles: true })); }
    }, { once: true });
    img.setAttribute("src", src);
  }, RETRY_AFTER_MS + Math.floor(Math.random() * RETRY_JITTER_MS));
}

function resolveStatus(src) {
  if (!src) { return Promise.resolve(UNKNOWN); }

  return fetch(src, { method: "HEAD", credentials: probeCredentials(src) })
    .then((r) => (r.status >= 400 ? r.status : UNKNOWN))
    .catch(() => UNKNOWN);
}

function cardify(img) {
  // Guard against the card itself failing and re-entering this handler.
  if (img.dataset.errorCarded) { return; }
  img.dataset.errorCarded = "1";

  const src = img.currentSrc || img.getAttribute("src");
  // Measured BEFORE the swap: replacing the source can collapse the element,
  // and then every card would look like a thumbnail.
  const width = img.clientWidth || img.getAttribute("width") || 0;

  // A <picture> resolves its own <source> ahead of the img's src, so setting
  // src alone would be ignored and the broken image would stay.
  const picture = img.closest("picture");
  if (picture) { picture.querySelectorAll("source").forEach((s) => s.remove()); }

  resolveStatus(src).then((status) => {
    img.classList.add("error-card");
    // Cover-cropping a card would cut the number off; the card knows its own
    // aspect ratio and should be shown whole.
    img.setAttribute("src", cardUrl(status, parseInt(width, 10) || 0));
    img.removeAttribute("srcset");
    if (status === RETRY_STATUS && src) { retryOnce(img, src); }
  });
}

// Capture phase: `error` does not bubble, so a listener on document only sees
// it on the way down. One listener covers everything, including markup added
// later by the gallery and the landing showcase.
//
// Attached at module scope rather than on ready, and that is load-bearing. The
// pack runs in <head> before the body is parsed, so this is listening before
// any image exists. On ready it was already too late for the post view, whose
// image is written by an inline script during parse -- the gallery's
// server-rendered thumbnails were slow enough to be caught, and the post image
// was not, which is a race that would have shown up as "works everywhere except
// the page you were actually looking at".
document.addEventListener("error", (event) => {
  const el = event.target;
  if (!(el instanceof HTMLImageElement)) { return; }
  if (!el.matches(MEDIA_SELECTOR)) { return; }
  cardify(el);
}, true);

// Belt and braces for anything that failed even earlier -- a cached failure can
// complete before this file runs at all. A loaded image has a natural width; a
// failed one does not.
function sweepFailedImages() {
  document.querySelectorAll(MEDIA_SELECTOR).forEach((el) => {
    if (el instanceof HTMLImageElement && el.complete && el.naturalWidth === 0 && el.getAttribute("src")) {
      cardify(el);
    }
  });
}

$(document).ready(sweepFailedImages);

export default { sweepFailedImages };
