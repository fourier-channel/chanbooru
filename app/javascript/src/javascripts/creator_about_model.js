// A creator gallery's About boxes: the heights a viewer may give a box's
// body, by its grip's drag and by key (creator_gallery_component.js). The
// bounds are the server's: ModulationSetting creator_about_boxes refuses a
// height outside 80..2000. They bound the body, not the box, so the least
// height still shows 80px of content under the box's head. No DOM, so
// test/javascript runs it under Node.

export const BOX_MIN = 80;
export const BOX_MAX = 2000;
const STEP = 24;
const BIG_STEP = 120;

export const clampHeight = (h) => Math.round(Math.min(BOX_MAX, Math.max(BOX_MIN, h)));

// The height a key on the grip gives a box `h` tall: ArrowDown grows it,
// ArrowUp shrinks it, Shift by more; Home gives it back its content's height
// (null). Any other key is not the grip's (undefined).
export function keyHeight(key, shift, h) {
  const step = shift ? BIG_STEP : STEP;
  if (key === "ArrowDown") { return clampHeight(h + step); }
  if (key === "ArrowUp") { return clampHeight(h - step); }
  if (key === "Home") { return null; }
  return undefined;
}
