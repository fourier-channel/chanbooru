// The Creator Identity dashboard's tours (creator_identity_model.js). No DOM,
// so it runs under Node's own test runner: `npm run test-js`.
//
// The operator's brief (2026-11-05): two independent tours, creator name and
// OC, each a full walkthrough that can be skipped and re-run; the creator
// name tour reacts to a direct match, and otherwise says how to send the
// request.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bubbleWait, FIRST_BUBBLE_MS, TOURS, tourSteps, tourToOffer } from "../../app/javascript/src/javascripts/creator_identity_model.js";

const linked = { linked: true, linkable: false, directMatch: false, ready: false, slug: "maple" };
const targets = (steps) => steps.map((step) => step.target);
const said = (steps) => steps.flatMap((step) => step.lines).join(" ");

test("her timing is the sign-in pages' own", () => {
  assert.equal(FIRST_BUBBLE_MS, 300);
  assert.equal(bubbleWait("abc"), 450 + 48);
  assert.equal(bubbleWait("x".repeat(500)), 1800);
});

test("a direct match: she says it is ticked and the Send makes it theirs", () => {
  const steps = tourSteps("creator_name", { ...linked, directMatch: true });

  assert.deepEqual(targets(steps), [null, "pool", "search", "note", "send"]);
  assert.match(said(steps), /Signal found!/);
  assert.match(said(steps), /available for immediate claim/);
});

test("no direct match: she walks through the search, the note and the request", () => {
  const steps = tourSteps("creator_name", linked);

  assert.deepEqual(targets(steps), [null, "pool", "search", "note", "send"]);
  assert.doesNotMatch(said(steps), /Signal found!/);
  assert.match(said(steps), /goes off for review/);
});

test("an unlinked page: either tour stops at the link, and finishing that step does not end the tour", () => {
  TOURS.forEach((tour) => {
    const steps = tourSteps(tour, { ...linked, linked: false, linkable: true });
    const last = steps.at(-1);

    assert.deepEqual(targets(steps), [null, "link"]);
    assert.equal(last.record, false);
    assert.equal(last.next, "Got it");
  });
});

test("the OC tour: the waiting characters first when there are some, and the page's own name in the example", () => {
  assert.deepEqual(targets(tourSteps("oc", linked)), [null, "create", null]);
  const steps = tourSteps("oc", { ...linked, ready: true });

  assert.deepEqual(targets(steps), [null, "ready", "create", null]);
  assert.match(said(steps), /maple_\(maple\)/);
});

test("every step moves on with Next, and the last says Done and ends the tour", () => {
  const steps = tourSteps("oc", linked);

  assert.deepEqual(steps.map((step) => step.next), ["Show me", "Next", "Done"]);
  assert.ok(steps.every((step) => step.record));
});

test("a replay skips her offer", () => {
  assert.deepEqual(targets(tourSteps("creator_name", linked, { offer: false })), ["pool", "search", "note", "send"]);
});

test("a page load offers the first tour never ended, one at a time, and none where nothing can be claimed", () => {
  assert.equal(tourToOffer({}, linked), "creator_name");
  assert.equal(tourToOffer({ creator_name: "skipped" }, linked), "oc");
  assert.equal(tourToOffer({ creator_name: "done", oc: "done" }, linked), null);
  assert.equal(tourToOffer({}, { ...linked, linked: false, linkable: true }), "creator_name");
  assert.equal(tourToOffer({}, { ...linked, linked: false, linkable: false }), null);
});

test("every line is plain ASCII, as committed content must be", () => {
  const all = TOURS.flatMap((tour) => [true, false].flatMap((directMatch) => said(tourSteps(tour, { ...linked, directMatch, ready: true }))));
  all.forEach((text) => assert.match(text, /^[\x20-\x7E]*$/));
});
