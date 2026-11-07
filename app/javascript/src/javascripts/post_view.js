// A POST'S APPLIED VIEW (operator, 2026-11-01, item 8): how a creator moved,
// scaled, stretched or flipped one picture on their page. The server keeps it
// per gallery, place and post (CreatorGalleryPostView: the banner, the hero
// band's thumbnails, a miniband, a channel's picture -- each a frame of its
// own shape, operator 2026-11-07) and draws it; this module is
// the editor's half -- the same ranges, the same style strings (both held to
// test/fixtures/files/post_views.json), and the pure editing maths.
//
// The maths is hand-ported from Technetium's uitransform
// (~/technetium/src/ui/uitransform/transform.ts): nudge by a pixel delta,
// scaleBy, transformToBox / boxToTransform and resizeBox with its MIN_PX.
// Differences, all of them the view's shape: the centre is a permille pan
// from the frame's centre, not a [0,1] fraction; the size is a scale on top
// of the cover fit plus a stretch across, not a width multiplier and an
// aspect; there is no rotation. A corner drag is resizeBox's locked corner,
// an edge drag its free edge.
//
// x, y      pan, permille of the frame's width / height
// scale     milli, of the frame (the picture's cover fit)
// stretch   milli, the width against the height (Distort)

export const LIMITS = Object.freeze({
  x: Object.freeze([-1000, 1000]),
  y: Object.freeze([-1000, 1000]),
  scale: Object.freeze([200, 4000]),
  stretch: Object.freeze([500, 2000]),
});

// No view: what Reset sets, and what the server keeps no row for.
export const IDENTITY = Object.freeze({ flip_h: false, flip_v: false, x: 0, y: 0, scale: 1000, stretch: 1000 });

export const HANDLES = Object.freeze(["nw", "n", "ne", "e", "se", "s", "sw", "w"]);

// The smallest box a drag leaves, in frame pixels (uitransform's MIN_PX).
const MIN_PX = 24;

// Every field whole and in range; a flip is on only when it is true, and a
// value that is not a number is the identity's.
export function clamp(view) {
  const given = view || {};
  const fields = Object.entries(LIMITS).map(([key, [min, max]]) => {
    const value = Number.isFinite(given[key]) ? given[key] : IDENTITY[key];
    return [key, Math.round(Math.min(max, Math.max(min, value))) || 0];
  });
  return { flip_h: given.flip_h === true, flip_v: given.flip_v === true, ...Object.fromEntries(fields) };
}

export function isIdentity(view) {
  const clamped = clamp(view);
  return Object.keys(IDENTITY).every((key) => clamped[key] === IDENTITY[key]);
}

// A number as the server prints it (Ruby's shortest form, no ".0").
const css = (n) => String(n);

// The view's pan in percent and its scale across and down, null for the
// identity.
function parts(view) {
  const v = { ...IDENTITY, ...(view || {}) };
  if (Object.keys(IDENTITY).every((key) => v[key] === IDENTITY[key])) {
    return null;
  }
  return {
    x: css(v.x / 10),
    y: css(v.y / 10),
    across: css((v.scale * v.stretch / 1000000) * (v.flip_h ? -1 : 1)),
    down: css((v.scale / 1000) * (v.flip_v ? -1 : 1)),
  };
}

// The view as a CSS transform about the picture's centre, "" for the identity
// (CreatorGalleryPostView.transform).
export function transform(view) {
  const p = parts(view);
  return p ? `translate(${p.x}%, ${p.y}%) scale(${p.across}, ${p.down})` : "";
}

// The view on a hero band thumbnail (modulation_landing_component.js), as
// the cell's --cv-translate and --cv-scale, null for the identity: the same
// pan and scale, as the picture's own translate and scale properties, since
// the belt's flight owns its transform. The pan is in the clip's container
// units: in flight the picture is laid out at its own size, not the frame's.
export function cellView(view) {
  const p = parts(view);
  return p && { "--cv-translate": `${p.x}cqw ${p.y}cqh`, "--cv-scale": `${p.across} ${p.down}` };
}

// The --cg-view variable a banner, ground or miniband image composes.
export function style(view) {
  const t = transform(view);
  return t ? `--cg-view: ${t}` : "";
}

// A harmonic's picture: the view about the card's centre, then the card's own
// zoom about its focus (CreatorGalleryPostView.picture_style).
export function pictureStyle(picture) {
  const { focus_x: fx, focus_y: fy, zoom } = picture;
  const view = transform(picture.view);
  const around = view ? `translate(${50 - fx}%, ${50 - fy}%) ${view} translate(${fx - 50}%, ${fy - 50}%) ` : "";
  return `object-position: ${fx}% ${fy}%; transform-origin: ${fx}% ${fy}%; transform: ${around}scale(${css(zoom / 100)})`;
}

// Where the view draws the picture in a frame of `width` x `height` pixels,
// before its flips (uitransform's transformToBox).
export function toBox(view, { width: W, height: H }) {
  const v = clamp(view);
  const width = W * (v.scale / 1000) * (v.stretch / 1000);
  const height = H * (v.scale / 1000);
  const cx = W * (0.5 + (v.x / 1000));
  const cy = H * (0.5 + (v.y / 1000));
  return { left: cx - (width / 2), top: cy - (height / 2), width, height };
}

// The view drawing the picture in `box`, keeping `base`'s flips, clamped
// (uitransform's boxToTransform).
export function fromBox(box, base, { width: W, height: H }) {
  const scale = box.height / H;
  return clamp({
    flip_h: clamp(base).flip_h,
    flip_v: clamp(base).flip_v,
    x: (((box.left + (box.width / 2)) / W) - 0.5) * 1000,
    y: (((box.top + (box.height / 2)) / H) - 0.5) * 1000,
    scale: scale * 1000,
    stretch: (box.width / W / scale) * 1000,
  });
}

// `view` moved by a drag's whole pixel delta (uitransform's nudge). Moved from
// the drag's start view each time, so rounding never piles up.
export function move(view, dx, dy, { width: W, height: H }) {
  const v = clamp(view);
  return clamp({ ...v, x: v.x + ((dx / W) * 1000), y: v.y + ((dy / H) * 1000) });
}

// The wheel: `view` scaled by `factor`, clamped (uitransform's scaleBy).
export function scaleBy(view, factor) {
  const v = clamp(view);
  return clamp({ ...v, scale: v.scale * factor });
}

// uitransform's resizeBox: the opposite edge or corner stays; a corner keeps
// the box's own aspect (a uniform scale), an edge moves freely (a stretch).
function resizeBox(box, handle, px, py) {
  const hasE = handle.includes("e");
  const hasW = handle.includes("w");
  const hasS = handle.includes("s");
  const hasN = handle.includes("n");
  const left0 = box.left;
  const top0 = box.top;
  const right0 = box.left + box.width;
  const bottom0 = box.top + box.height;
  const right = hasE ? Math.max(px, left0 + MIN_PX) : right0;
  const left = hasW ? Math.min(px, right0 - MIN_PX) : left0;
  const bottom = hasS ? Math.max(py, top0 + MIN_PX) : bottom0;
  const top = hasN ? Math.min(py, bottom0 - MIN_PX) : top0;
  const width = right - left;
  const height = bottom - top;
  if (!((hasE || hasW) && (hasS || hasN))) {
    return { left, top, width, height };
  }
  // Corner: the box's aspect fitted to the larger requested size, anchored on
  // the fixed corner.
  const aspect = box.width / box.height;
  const fitted = width / aspect >= height ? { width, height: width / aspect } : { width: height * aspect, height };
  return {
    left: hasW ? right0 - fitted.width : left0,
    top: hasN ? bottom0 - fitted.height : top0,
    ...fitted,
  };
}

// `view` with `handle` dragged to (px, py) in frame pixels: a corner scales
// uniformly, an edge stretches; the result is clamped to the limits.
export function resize(view, handle, px, py, frame) {
  const v = clamp(view);
  return fromBox(resizeBox(toBox(v, frame), handle, px, py), v, frame);
}

// The editor's list of views, the draft's `views` (CreatorGalleryLayout#views):
// one entry per place and post, sorted by place and then post, none the
// identity.

// `id`'s view in `place`, the identity without one.
export function viewIn(views, place, id) {
  return views.find((entry) => entry.place === place && entry.post_id === id) || IDENTITY;
}

const byPlaceAndPost = (a, b) => (a.place === b.place ? a.post_id - b.post_id : (a.place < b.place ? -1 : 1));

// `views` with `id`'s view in `place` set to `view` (clamped, in the server's
// field order), or taken out for the identity; the list given is left as it
// was.
export function putView(views, place, id, view) {
  const rest = views.filter((entry) => entry.place !== place || entry.post_id !== id);
  return isIdentity(view) ? rest : [...rest, { place, post_id: id, ...clamp(view) }].sort(byPlaceAndPost);
}
