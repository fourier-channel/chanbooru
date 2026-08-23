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
  ".modcreator-thumb",
  "[data-error-card]",
].join(", ");

// Deliberately NOT the carousel's flank thumbnails (.mod-sortrow img). A card
// sized for a 520px stage is unreadable at 122px, and six of them stacked either
// side of the picture is worse than the broken icon it replaced. Those degrade
// to the stage's own empty-slot hatch instead -- see the landing component.

// The card for a status we could not determine. Rendered by the same endpoint,
// which answers for any number.
const UNKNOWN = 0;

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
function resolveStatus(src) {
  if (!src) return Promise.resolve(UNKNOWN);

  return fetch(src, { method: "HEAD", credentials: "same-origin" })
    .then((r) => (r.status >= 400 ? r.status : UNKNOWN))
    .catch(() => UNKNOWN);
}

function cardify(img) {
  // Guard against the card itself failing and re-entering this handler.
  if (img.dataset.errorCarded) return;
  img.dataset.errorCarded = "1";

  const src = img.currentSrc || img.getAttribute("src");
  // Measured BEFORE the swap: replacing the source can collapse the element,
  // and then every card would look like a thumbnail.
  const width = img.clientWidth || img.getAttribute("width") || 0;

  // A <picture> resolves its own <source> ahead of the img's src, so setting
  // src alone would be ignored and the broken image would stay.
  const picture = img.closest("picture");
  if (picture) picture.querySelectorAll("source").forEach((s) => s.remove());

  resolveStatus(src).then((status) => {
    img.classList.add("error-card");
    // Cover-cropping a card would cut the number off; the card knows its own
    // aspect ratio and should be shown whole.
    img.setAttribute("src", cardUrl(status, parseInt(width, 10) || 0));
    img.removeAttribute("srcset");
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
  if (!(el instanceof HTMLImageElement)) return;
  if (!el.matches(MEDIA_SELECTOR)) return;
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
