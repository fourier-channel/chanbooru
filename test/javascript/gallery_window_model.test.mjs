// The gallery window's model (gallery_window_model.js): which posts the box
// shows, given the run of results the page holds, which of them the
// blocklist hides, and the post at the top left. No DOM, so it runs under
// Node's own test runner: `npm run test-js`.
//
// The operator's words it is held to (GALLERY_WINDOW.md section 2): "Only
// rendered images would appear so the grid would fill naturally, and any
// revealed images from a lifted tag would simply push the existing images
// into the next slot, with anything being pushed past 20 considered now 'on
// the next page'" -- and paging "takes the next image up and sets it to the
// top left and rebuilds from that point, stopping at the page's natural
// limit of 20."
import { test } from "node:test";
import assert from "node:assert/strict";
import { GalleryWindow } from "../../app/javascript/src/javascripts/gallery_window_model.js";

const CONFIG = { slots: 20, chunk: 40, chunkMax: 100, budgetRaw: 400, budgetFetches: 6, keepBehind: 60, hardCap: 500 };
const entries = (from, to) => Array.from({ length: to - from }, (_, i) => ({ id: String(from + i), key: `${from + i}~${from + i}` }));
const judged = (win, blocked = []) => win.setMarks(new Map(win.run.map((e) => [e.id, blocked.includes(e.id)])));
const shownIds = (win) => win.layout().shown.map((i) => win.run[i].id);

function make(n, { blocked = [], headDone = true, tailDone = true, anchorId = null } = {}) {
  const win = new GalleryWindow(CONFIG, { entries: entries(0, n), headDone, tailDone, anchorId });
  judged(win, blocked.map(String));
  return win;
}

// A seeded PRNG, so a fuzz failure replays.
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test("only posts that render take a slot: the box fills past blocked ones", () => {
  const win = make(40, { blocked: [1, 3, 5] });
  assert.deepEqual(shownIds(win), ["0", "2", "4", ...Array.from({ length: 17 }, (_, i) => String(i + 6))]);
});

test("an unjudged card counts as blocked: nothing shows before the blocklist has applied", () => {
  const win = new GalleryWindow(CONFIG, { entries: entries(0, 40), headDone: true, tailDone: true, anchorId: null });
  assert.deepEqual(shownIds(win), []);
  win.setMarks(new Map([["0", false], ["1", false]]));
  assert.deepEqual(shownIds(win), ["0", "1"]);
});

test("a lifted block drops its posts back into place and pushes the rest one slot along", () => {
  const win = make(40, { blocked: [4] });
  const before = shownIds(win);
  assert.equal(before[4], "5");
  judged(win, []);
  const after = shownIds(win);
  assert.equal(after[4], "4");
  assert.deepEqual(after.slice(5), before.slice(4, 19), "every later post moved one slot");
  assert.equal(before[19], "20");
  assert.ok(!after.includes("20"), "the post pushed past 20 is on the next page now");
});

test("next sets the first post past the box at the top left; prev is the mirror", () => {
  const win = make(80, { blocked: [25] });
  assert.equal(win.move("next"), "moved");
  assert.equal(shownIds(win)[0], "20");
  assert.equal(shownIds(win).length, 20);
  assert.ok(!shownIds(win).includes("25"));
  assert.equal(win.move("prev"), "moved");
  assert.equal(shownIds(win)[0], "0");
});

test("prev near the head shows the 20 from the head", () => {
  const win = make(80, { anchorId: "7" });
  assert.equal(shownIds(win)[0], "7");
  assert.equal(win.move("prev"), "moved");
  assert.equal(shownIds(win)[0], "0");
  assert.equal(win.move("prev"), "start", "at the head prev has nowhere to go");
});

test("a row step moves the top left by one row of the columns shown", () => {
  const win = make(80, { blocked: [2] });
  assert.equal(win.move("rowNext", 5), "moved");
  assert.equal(shownIds(win)[0], "6", "five rendered posts down: 0 1 3 4 5 were the first row");
  assert.equal(win.move("rowPrev", 5), "moved");
  assert.equal(shownIds(win)[0], "0");
  assert.equal(win.move("rowPrev", 5), "start");
  const short = make(22);
  assert.equal(short.move("rowNext", 4), "moved");
  assert.equal(short.move("rowNext", 4), "end", "nothing past the box: no step");
});

test("at the end of the loaded run, next asks for more, and says end when there is none", () => {
  const win = make(30, { tailDone: false });
  assert.equal(win.move("next"), "moved");
  assert.equal(win.move("next"), "fetch");
  assert.deepEqual(win.wants().dir, "ahead");
  const done = make(30);
  done.move("next");
  assert.equal(done.move("next"), "end");
});

test("a pending move finishes when its chunk arrives", () => {
  const win = make(20, { tailDone: false });
  assert.equal(win.move("next"), "fetch");
  const epoch = win.epoch;
  assert.equal(win.receive("ahead", epoch, { entries: entries(20, 60), more: true, version: "1" }, "1"), "ok");
  judged(win);
  assert.equal(win.resume(), "moved");
  assert.equal(shownIds(win)[0], "20");
});

test("blocking the top card and lifting it restores the top", () => {
  const win = make(60, { anchorId: "10" });
  judged(win, ["10"]);
  assert.equal(shownIds(win)[0], "11");
  judged(win, []);
  assert.equal(shownIds(win)[0], "10");
});

test("the counts' scope is the view: from the top left through the 20th rendered post", () => {
  const win = make(60, { anchorId: "10", blocked: [10, 12] });
  const scope = win.scope();
  assert.equal(scope[0], "10", "a blocked post at the anchor is hidden in this view");
  assert.equal(scope.at(-1), "31");
  assert.equal(scope.length, 22);
});

test("a chunk is merged by id, so a repeat is dropped", () => {
  const win = make(30, { tailDone: false });
  assert.equal(win.receive("ahead", win.epoch, { entries: entries(25, 50), more: true, version: "1" }, "1"), "ok");
  assert.equal(win.run.length, 50);
  assert.equal(new Set(win.run.map((e) => e.id)).size, 50);
});

test("a chunk asked for before a reset is discarded", () => {
  const win = make(30, { tailDone: false });
  const old = win.epoch;
  win.reset({ entries: entries(100, 140), anchorId: "100", headDone: false, tailDone: false });
  assert.equal(win.receive("ahead", old, { entries: entries(30, 70), more: true, version: "1" }, "1"), "stale");
  assert.equal(win.run[0].id, "100");
});

test("every failure stops that direction until the viewer asks again; nothing retries by itself", () => {
  for (const [status, kind] of [[410, "cap"], [422, "place"], [429, "rate"], [503, "server"], [0, "network"]]) {
    const win = make(20, { tailDone: false });
    win.fail("ahead", status);
    assert.equal(win.stopped.ahead, kind, `HTTP ${status}`);
    assert.equal(win.wants(), null, `HTTP ${status}: no fetch while stopped`);
    win.retry();
    assert.equal(win.wants().dir, "ahead", `HTTP ${status}: Retry asks again`);
  }
});

test("a chunk in another format is refused, not placed", () => {
  const win = make(20, { tailDone: false });
  assert.equal(win.receive("ahead", win.epoch, { entries: entries(20, 60), more: true, version: "2" }, "1"), "version");
  assert.equal(win.run.length, 20);
  assert.equal(win.wants(), null);
});

test("an empty chunk that says more, or one of nothing new, is a dead end -- never a loop", () => {
  const win = make(20, { tailDone: false });
  assert.equal(win.receive("ahead", win.epoch, { entries: [], more: true, version: "1" }, "1"), "dead");
  assert.equal(win.wants(), null);
  const dup = make(20, { tailDone: false });
  assert.equal(dup.receive("ahead", dup.epoch, { entries: entries(0, 20), more: true, version: "1" }, "1"), "dead");
  assert.equal(dup.wants(), null);
  const end = make(20, { tailDone: false });
  assert.equal(end.receive("ahead", end.epoch, { entries: [], more: false, version: "1" }, "1"), "end");
  assert.equal(end.tailDone, true);
});

// One action against an endless search whose posts the blocklist hides at
// `rate`: fetch whatever the window wants until it wants nothing.
function drive(rate, seed) {
  const random = rng(seed);
  const win = make(0, { tailDone: false });
  let next = 0;
  let fetches = 0;
  win.beginAction();
  for (let guard = 0; guard < 100; guard++) {
    const want = win.wants();
    if (!want || want.budget) { break; }
    const size = win.chunkSize(want.need);
    assert.ok(size >= CONFIG.chunk && size <= CONFIG.chunkMax, `chunk size ${size}`);
    const chunk = entries(next, next + size);
    next += size;
    fetches += 1;
    win.receive("ahead", win.epoch, { entries: chunk, more: true, version: "1" }, "1");
    win.setMarks(new Map(chunk.map((e) => [e.id, random() < rate])));
  }
  return { win, fetches, raw: next };
}

test("a heavy blocklist ends within the budget, filled or not", () => {
  for (let seed = 1; seed <= 50; seed++) {
    const { win, fetches, raw } = drive(0.95, seed);
    assert.ok(fetches <= CONFIG.budgetFetches, `seed ${seed}: ${fetches} fetches`);
    assert.ok(raw < CONFIG.budgetRaw + CONFIG.chunkMax, `seed ${seed}: ${raw} raw posts`);
    const want = win.wants();
    assert.ok(want === null || want.budget, `seed ${seed}: still wanting ${JSON.stringify(want)}`);
  }
});

test("past the budget with the box short, it waits to be asked to keep looking", () => {
  const { win } = drive(0.99, 7);
  assert.deepEqual(win.wants(), { budget: true });
  assert.ok(win.layout().shown.length < 20);
  win.keepLooking();
  assert.equal(win.wants().dir, "ahead");
});

test("a next waiting on a chunk asks for it, and asks to keep looking past the budget -- never waits silently", () => {
  const win = make(20, { tailDone: false });
  win.beginAction();
  assert.equal(win.move("next"), "fetch");
  assert.equal(win.wants().dir, "ahead");
  win.budget = { raw: CONFIG.budgetRaw, fetches: 1 };
  assert.deepEqual(win.wants(), { budget: true });
});

test("the chunk grows with the share the blocklist hides", () => {
  const win = make(100, { blocked: Array.from({ length: 80 }, (_, i) => i) });
  assert.equal(win.chunkSize(20), 100);
  const clear = make(100);
  assert.equal(clear.chunkSize(20), 40);
});

test("trim keeps what is shown and what is near it", () => {
  const win = make(400, { anchorId: "300" });
  const removed = win.trim();
  assert.ok(removed.length > 0);
  assert.equal(shownIds(win)[0], "300");
  assert.equal(win.run[0].id, String(300 - CONFIG.keepBehind));
  assert.equal(win.headDone, false, "trimmed from the front: the head is no longer held");
});

test("pin keeps a post in its slot and fills around it, collapsing at the head", () => {
  const win = make(80);
  assert.equal(win.pin("30", 12), "moved");
  assert.equal(shownIds(win)[11], "30");
  assert.equal(win.pin("2", 12), "moved");
  assert.equal(shownIds(win)[2], "2", "the third result lands in slot 3");
});

test("fuzz: 20,000 random moves, blocks and lifts keep every invariant", () => {
  const random = rng(20261017);
  const win = make(300, { anchorId: "100" });
  const blocked = new Set();
  const pick = (n) => Math.floor(random() * n);
  for (let op = 0; op < 20000; op++) {
    const roll = random();
    const before = shownIds(win);
    const beforeTop = before[0];
    if (roll < 0.25) {
      const id = String(pick(300));
      const lifting = blocked.has(id);
      lifting ? blocked.delete(id) : blocked.add(id);
      judged(win, [...blocked]);
      const after = shownIds(win);
      const idx = win.run.findIndex((e) => e.id === id);
      const topIdx = win.run.findIndex((e) => e.id === beforeTop);
      const lastIdx = win.run.findIndex((e) => e.id === before.at(-1));
      if (lifting && before.length === 20 && idx > topIdx && idx < lastIdx) {
        const at = after.indexOf(id);
        assert.deepEqual(after.slice(at + 1), before.slice(at, 19), `op ${op}: a lift moves the following posts one slot`);
      }
    } else if (roll < 0.45) {
      win.move("next");
    } else if (roll < 0.65) {
      win.move("prev");
    } else if (roll < 0.8) {
      win.move(random() < 0.5 ? "rowNext" : "rowPrev", [2, 4, 5][pick(3)]);
    } else if (roll < 0.9) {
      // next then prev is the identity when the box was full and 20 render behind its new top.
      const top = shownIds(win)[0];
      if (before.length === 20 && win.move("next") === "moved") {
        assert.equal(win.move("prev"), "moved", `op ${op}`);
        assert.equal(shownIds(win)[0], top, `op ${op}: next then prev`);
      }
    } else {
      const top = shownIds(win)[0];
      if (top !== undefined) {
        blocked.add(top);
        judged(win, [...blocked]);
        blocked.delete(top);
        judged(win, [...blocked]);
        assert.equal(shownIds(win)[0], top, `op ${op}: block and lift the top restores it`);
      }
    }
    const L = win.layout();
    const visibleAfterTop = win.run.slice(win.anchorIndex()).filter((e) => e.blocked === false).length;
    assert.equal(L.shown.length, Math.min(20, visibleAfterTop), `op ${op}: the box holds min(20, rendered posts from the top)`);
    assert.equal(new Set(win.run.map((e) => e.id)).size, win.run.length, `op ${op}: no post twice`);
    assert.ok(L.shown.every((i) => win.run[i].blocked === false), `op ${op}: no hidden post shown`);
  }
});

// One search of `total` results from the head, of which `pass` renders,
// driven the way the page drives it: receive a chunk, let go of the far
// cards, then the engine judges the new ones. `presses` rounds of "keep
// looking", each fetching whatever the window wants within its budget.
function walk({ total, pass, presses }) {
  const win = new GalleryWindow(CONFIG, { entries: entries(0, 40), headDone: true, tailDone: false });
  const judge = () => win.setMarks(new Map(win.run.map((e) => [e.id, !pass(Number(e.id))])));
  judge();
  for (let press = 0; press < presses; press++) {
    win.keepLooking();
    for (let guard = 0; guard < 20; guard++) {
      const want = win.wants();
      if (!want || want.budget) { break; }
      const from = Number(win.run.at(-1).id) + 1;
      const to = Math.min(from + win.chunkSize(want.need), total);
      win.receive("ahead", win.epoch, { entries: entries(from, to), more: to < total, version: "1" }, "1");
      win.trim();
      judge();
    }
  }
  return win;
}

test("a 99% blocklist past the cap: every keep looking reaches further, never the same tail again", () => {
  const win = walk({ total: 5000, pass: (id) => id % 100 === 99, presses: 12 });
  assert.ok(Number(win.run.at(-1).id) > 1500, `the run reached ${win.run.at(-1).id}`);
  assert.equal(shownIds(win).length, 20, "twenty rendered posts found, the twentieth at #1999");
  assert.equal(shownIds(win).at(-1), "1999");
});

test("trim never lets go of the cards a short box or the next box is still looking through", () => {
  // The box is full at 0..19; nothing renders after #29, so the next box is
  // not in hand and the tail is what the look-ahead is searching.
  const tail = make(700, { blocked: Array.from({ length: 670 }, (_, i) => i + 30) });
  tail.trim();
  assert.equal(tail.run.length, 700);
  // With the next box in hand the far tail goes, down to the cap.
  const full = make(700);
  full.trim();
  assert.equal(full.run.length, CONFIG.hardCap);
  assert.equal(full.tailDone, false);
  // A prev waiting on 100 cards fetched behind, not judged yet: the front is
  // what it is looking through, so nothing behind the box is let go.
  const back = make(40, { headDone: false, tailDone: true, anchorId: "0" });
  back.receive("behind", back.epoch, { entries: entries(-100, 0), more: true, version: "1" }, "1");
  back.trim();
  assert.equal(back.run[0].id, "-100");
});

test("a random draw that brings nothing new stops quietly for the viewer to draw again -- never an error, never a loop", () => {
  const win = new GalleryWindow(CONFIG, { entries: entries(0, 45), headDone: true, tailDone: false, drawn: true });
  judged(win);
  assert.equal(win.chunkSize(20), CONFIG.chunkMax, "a draw asks for the most it may: a set that fits in one ends exactly");
  assert.equal(win.receive("ahead", win.epoch, { entries: entries(0, 40), more: true, version: "1" }, "1"), "drawn");
  assert.equal(win.stopped.ahead, "drawn");
  assert.equal(win.wants(), null);
  win.retry();
  assert.equal(win.receive("ahead", win.epoch, { entries: entries(0, 45), more: false, version: "1" }, "1"), "end");
  assert.equal(win.tailDone, true, "a draw smaller than the chunk is the whole set: the end");
});

test("peek says where a move would land without making it", () => {
  const win = make(80, { anchorId: "30" });
  assert.deepEqual(win.peek("prev"), { answer: "moved", cursor: "10~10" });
  assert.deepEqual(win.peek("next"), { answer: "moved", cursor: "50~50" });
  assert.equal(win.anchorId, "30");
  assert.equal(shownIds(win)[0], "30");
  const head = make(80, { anchorId: "7" });
  assert.deepEqual(head.peek("prev"), { answer: "moved", cursor: null }, "prev near the head lands on the head");
  const short = make(30, { tailDone: false, headDone: false, anchorId: "0" });
  assert.equal(short.peek("prev").answer, "fetch");
  assert.equal(short.pending, null, "a peek leaves no move pending");
});
