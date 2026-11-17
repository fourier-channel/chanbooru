// THE GALLERY WINDOW'S MODEL: which posts the Modulation grid's box shows.
// No DOM, no imports, no `window`, so test/javascript/gallery_window_model
// .test.mjs runs it under Node; gallery_window.js is the page's glue.
//
// The operator's design (2026-10-17; GALLERY_WINDOW.md section 2): the grid
// is a fixed box of 20 slots over the search's results, "a grid of 20 that
// you scroll through like a directory, loading and unloading as needed. Only
// rendered images would appear so the grid would fill naturally, and any
// revealed images from a lifted tag would simply push the existing images
// into the next slot, with anything being pushed past 20 considered now 'on
// the next page'." Paging "really just tells the panel to take the next image
// up and set it to the top left and rebuild from that point, stopping at the
// page's natural limit of 20."
//
// So the state is:
//   - run: the results the page holds, in order -- { id, key, blocked } where
//     blocked is true, false, or null for not judged yet, which counts as
//     blocked: nothing shows before the blocklist has said it may;
//   - anchorId: the post at the top left AS INTENDED. The box starts at the
//     first rendered post at or after it, so a block on the anchor moves the
//     top on and lifting it brings the top back; a block never moves the
//     anchor, so it never touches the address either;
//   - headDone / tailDone: the run holds the first / last result;
//   - epoch: bumped by reset(), so a chunk asked for before it is dropped.
//
// Every move answers one word: "moved", "fetch" (the run must grow first;
// the move is pending and resume() finishes it), "end" or "start" (nothing
// further that way). Every fetch the window makes is counted against a
// per-action budget (raw posts and fetches); past it the window waits to be
// asked to keep looking. A failed fetch stops its direction until retry():
// nothing is ever retried by itself.

export class GalleryWindow {
  // @param config {slots, chunk, chunkMax, budgetRaw, budgetFetches,
  //   keepBehind, hardCap} -- the grid's data-window, from Ruby constants
  // @param init {entries, anchorId, headDone, tailDone, drawn} -- drawn: a
  //   random draw, which has no place behind it to fetch
  constructor(config, init) {
    this.config = config;
    this.drawn = Boolean(init.drawn);
    this.epoch = 0;
    this.pending = null;
    this.stopped = { ahead: null, behind: null };
    this.budget = { raw: 0, fetches: 0 };
    this.reset(init);
  }

  reset({ entries, anchorId = null, headDone, tailDone }) {
    this.run = [];
    this.merge(entries, "ahead");
    this.anchorId = anchorId;
    this.headDone = Boolean(headDone);
    this.tailDone = Boolean(tailDone);
    this.pending = null;
    this.stopped = { ahead: null, behind: null };
    this.epoch += 1;
  }

  hidden(entry) {
    return entry.blocked !== false;
  }

  anchorIndex() {
    if (this.anchorId === null) { return 0; }
    const at = this.run.findIndex((e) => e.id === this.anchorId);
    return at < 0 ? 0 : at;
  }

  // { top, shown }: shown is the run indices in the box, at most `slots`
  // rendered posts from the first at or after the anchor.
  layout() {
    const shown = [];
    for (let i = this.anchorIndex(); i < this.run.length && shown.length < this.config.slots; i++) {
      if (!this.hidden(this.run[i])) { shown.push(i); }
    }
    return { top: shown.length ? shown[0] : -1, shown };
  }

  // The ids the box covers, for the blocklist's "hidden in this view": from
  // the anchor through the last post shown, or the end of the run while the
  // box is short.
  scope() {
    const { shown } = this.layout();
    const end = shown.length === this.config.slots ? shown.at(-1) : this.run.length - 1;
    return this.run.slice(this.anchorIndex(), end + 1).map((e) => e.id);
  }

  // The anchor's cursor for the address, or null at the head of the search.
  anchorCursor() {
    const at = this.anchorIndex();
    if (at === 0 && this.headDone) { return null; }
    return this.run[at]?.key ?? null;
  }

  // @param kind "next" | "prev" | "rowNext" | "rowPrev"
  // @param cols the columns shown, for a row step
  move(kind, cols = 0) {
    this.pending = null;
    const answer = this[kind](cols);
    if (answer === "fetch") { this.pending = { kind, cols }; }
    return answer;
  }

  // Where a move would land, without making it: { answer, cursor } -- the
  // cursor of the post it would set at the top left (null for the head of
  // the search), when it would move. For the pager's hrefs.
  peek(kind, cols = 0) {
    const { anchorId, pending } = this;
    const answer = this[kind](cols);
    const cursor = answer === "moved" ? this.anchorCursor() : undefined;
    this.anchorId = anchorId;
    this.pending = pending;
    return cursor === undefined ? { answer } : { answer, cursor };
  }

  // Finish a pending move once its chunk has arrived and been judged.
  resume() {
    const pending = this.pending;
    return pending ? this.move(pending.kind, pending.cols) : null;
  }

  // The first rendered post past the box, at the top left.
  next() {
    const { shown } = this.layout();
    if (shown.length < this.config.slots) { return this.tailDone ? "end" : "fetch"; }
    for (let i = shown.at(-1) + 1; i < this.run.length; i++) {
      if (!this.hidden(this.run[i])) { this.anchorId = this.run[i].id; return "moved"; }
    }
    return this.tailDone ? "end" : "fetch";
  }

  // `slots` rendered posts back from the top; at the head, the head (a box
  // of 20 from the first result, overlapping the last).
  prev() {
    return this.back(this.config.slots);
  }

  rowNext(cols) {
    const { top, shown } = this.layout();
    if (shown.length < this.config.slots) { return this.tailDone ? "end" : "fetch"; }
    const beyond = this.run.slice(shown.at(-1) + 1).some((e) => !this.hidden(e));
    if (!beyond) { return this.tailDone ? "end" : "fetch"; }
    let seen = 0;
    for (let i = top + 1; i < this.run.length; i++) {
      if (!this.hidden(this.run[i]) && ++seen === cols) { this.anchorId = this.run[i].id; return "moved"; }
    }
    return "end";
  }

  rowPrev(cols) {
    return this.back(cols);
  }

  back(count) {
    const { top } = this.layout();
    const from = top < 0 ? this.anchorIndex() : top;
    let seen = 0;
    for (let i = from - 1; i >= 0; i--) {
      if (!this.hidden(this.run[i]) && ++seen === count) { this.anchorId = this.run[i].id; return "moved"; }
    }
    if (!this.headDone && !this.drawn) { return "fetch"; }
    if (this.anchorIndex() === 0 || this.run.length === 0) { return "start"; }
    this.anchorId = this.run[0].id;
    return "moved";
  }

  // Keep a post in a slot (1-based) and fill around it -- a bookmark's place
  // (GALLERY_WINDOW.md section 3). Near the head the box collapses: the
  // third result lands in slot 3.
  pin(id, slot) {
    const at = this.run.findIndex((e) => e.id === id);
    if (at < 0) { return "fetch"; }
    let seen = 0;
    for (let i = at - 1; i >= 0 && seen < slot - 1; i--) {
      if (!this.hidden(this.run[i])) { seen += 1; if (seen === slot - 1) { this.anchorId = this.run[i].id; return "moved"; } }
    }
    if (slot === 1) { this.anchorId = id; return "moved"; }
    if (!this.headDone && !this.drawn) { return "fetch"; }
    this.anchorId = this.run[0].id;
    return "moved";
  }

  // @param marks Map(id -> Boolean|null) -- the engine's marks
  setMarks(marks) {
    this.run.forEach((e) => { if (marks.has(e.id)) { e.blocked = marks.get(e.id); } });
  }

  // What the window should fetch next, if anything: { dir, need } (need is
  // how many rendered posts it lacks), { budget: true } when the box is
  // short and this action has looked as far as it may, or null.
  wants() {
    const { shown } = this.layout();
    const short = shown.length < this.config.slots;
    const over = this.budget.raw >= this.config.budgetRaw || this.budget.fetches >= this.config.budgetFetches;
    if (this.pending && ["prev", "rowPrev"].includes(this.pending.kind)) {
      if (this.headDone || this.drawn || this.stopped.behind) { return null; }
      return over ? { budget: true } : { dir: "behind", need: this.config.slots };
    }
    if (this.tailDone || this.stopped.ahead) { return null; }
    if (short) { return over ? { budget: true } : { dir: "ahead", need: this.config.slots - shown.length }; }
    // The box is full: look ahead until the next box is in hand, so next is
    // instant -- within the same budget. A move waiting on it asks to keep
    // looking past the budget; a look-ahead nobody is waiting on just stops.
    const ahead = this.run.slice(shown.at(-1) + 1).filter((e) => !this.hidden(e)).length;
    if (over) { return this.pending ? { budget: true } : null; }
    if (ahead >= this.config.slots && !this.pending) { return null; }
    return { dir: "ahead", need: Math.max(this.config.slots - ahead, 1) };
  }

  // A chunk big enough to find `need` rendered posts at the share the
  // blocklist has let through so far. A random draw always asks for the
  // most: every draw repeats posts the run holds, and a set smaller than one
  // draw comes back whole, which is how its end is known.
  chunkSize(need) {
    if (this.drawn) { return this.config.chunkMax; }
    const judged = this.run.filter((e) => e.blocked !== null);
    const rate = judged.length ? judged.filter((e) => e.blocked === false).length / judged.length : 1;
    return Math.min(this.config.chunkMax, Math.max(this.config.chunk, Math.ceil(need / Math.max(rate, 0.1))));
  }

  // @returns "ok" | "end" | "dead" (nothing new though more was promised:
  //   asked again it would answer the same) | "drawn" (a random draw that
  //   brought nothing new: the set is likely all in the run, and a fresh
  //   draw is the viewer's to ask for) | "stale" | "version"
  receive(dir, epoch, chunk, version) {
    if (epoch !== this.epoch) { return "stale"; }
    if (chunk.version !== version) {
      this.stopped = { ahead: "version", behind: "version" };
      return "version";
    }
    this.budget.raw += chunk.entries.length;
    this.budget.fetches += 1;
    const added = this.merge(chunk.entries, dir);
    if (added === 0 && chunk.more) {
      this.stopped[dir] = this.drawn ? "drawn" : "dead";
      return this.stopped[dir];
    }
    if (!chunk.more) {
      if (dir === "ahead") { this.tailDone = true; } else { this.headDone = true; }
    }
    return added === 0 ? "end" : "ok";
  }

  merge(entries, dir) {
    const known = new Set(this.run.map((e) => e.id));
    const fresh = entries.filter((e) => !known.has(e.id) && known.add(e.id)).map((e) => ({ id: e.id, key: e.key ?? null, blocked: null }));
    this.run = dir === "ahead" ? this.run.concat(fresh) : fresh.concat(this.run);
    return fresh.length;
  }

  // A fetch that failed: its direction stops, named by cause, until retry().
  fail(dir, status) {
    const kind = status === 410 ? "cap" : status === 422 ? "place" : status === 429 ? "rate" : status >= 500 ? "server" : status === 0 ? "network" : "http";
    this.stopped[dir] = kind;
    return kind;
  }

  // The viewer's own act: a new action, a Retry, "keep looking".
  beginAction() {
    this.budget = { raw: 0, fetches: 0 };
  }

  retry() {
    this.stopped = { ahead: null, behind: null };
    this.beginAction();
  }

  keepLooking() {
    this.beginAction();
  }

  // Let go of the run far from the box: more than keepBehind posts before
  // the anchor, and past hardCap from the far end -- never a post shown, nor
  // the previous or next box. While either of those is not in hand (a short
  // box, a box whose neighbour is mostly blocked, cards not judged yet) the
  // cards on that side are the ones the window is looking through, and
  // nothing on that side goes: letting them go would fetch them again, and
  // a heavy blocklist would never get past hardCap. The run then grows only
  // as far as the viewer asks it to keep looking. @returns the ids let go.
  trim() {
    const removed = [];
    const { slots, keepBehind, hardCap } = this.config;
    const { top } = this.layout();
    const prevStart = this.drawn ? -1 : this.nthRendered((top < 0 ? this.anchorIndex() : top) - 1, -1, slots);
    const cut = prevStart < 0 ? 0 : Math.min(this.anchorIndex() - keepBehind, prevStart);
    if (cut > 0) {
      removed.push(...this.run.splice(0, cut).map((e) => e.id));
      this.headDone = false;
    }
    const { shown } = this.layout();
    const nextEnd = shown.length === slots ? this.nthRendered(shown.at(-1) + 1, 1, slots) : -1;
    if (nextEnd >= 0) {
      const keep = Math.max(nextEnd, shown.at(-1) + slots);
      while (this.run.length > hardCap && this.run.length - 1 > keep) {
        removed.push(this.run.pop().id);
        this.tailDone = false;
      }
    }
    return removed;
  }

  // The run index of the `count`th rendered post from `from` (counting it)
  // in direction `step`, or -1 when the run does not hold that many.
  nthRendered(from, step, count) {
    let seen = 0;
    for (let i = from; i >= 0 && i < this.run.length; i += step) {
      if (!this.hidden(this.run[i]) && ++seen === count) { return i; }
    }
    return -1;
  }
}
