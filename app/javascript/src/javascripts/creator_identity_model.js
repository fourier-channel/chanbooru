// The Creator Identity dashboard's tours (creator_identity.js): what Fourier
// says at each step and which part of the page the step is about. Two tours,
// independent of each other (operator, 2026-11-05): creator_name, claiming a
// creator name, which branches on whether the page's Matrix name is a direct
// match; and oc, claiming an original character. Each starts with her offer,
// so a first visit is never railroaded (her canon: the tour or explore on
// your own, the viewer's choice), and either can be skipped, then replayed
// from the dashboard's buttons. No DOM, so test/javascript runs it under Node.
//
// A step: { target, lines, next, record }. target names the page's
// data-identity-step it is about (null: none); lines are her bubbles; next is
// the label of the button that moves on; record false on the last step means
// finishing it does not end the tour, because the page cannot go further
// until the viewer acts (linking the page) and the tour should meet them
// after.

export const TOURS = ["creator_name", "oc"];

// Her timing, the sign-in pages' own (MAS components/fourier.html): the
// first bubble after 300ms, then long enough to read each before the next.
export const FIRST_BUBBLE_MS = 300;
export const bubbleWait = (text) => Math.min(1800, 450 + (16 * text.length));

const LINK_STEP = {
  target: "link",
  lines: [
    "First things first: this page needs linking to your booru account, so everything you claim lands on you.",
    "Press Link this page to my booru account, and I'll pick up right where we left off.",
  ],
  next: "Got it",
  record: false,
};

const CREATOR_NAME_OFFER = {
  target: null,
  lines: [
    "Hi, I'm Fourier! This is your Creator Identity dashboard: your names, your characters and who sees your posts, all in one place.",
    "Want a quick tour of claiming your creator name? About thirty seconds, and you can skip it anytime.",
  ],
  next: "Show me",
};

const DIRECT_MATCH = [
  {
    target: "pool",
    lines: [
      "Signal found! Your Matrix name matches a creator name that's already on posts here, so it's ticked for you in the Claim Pool.",
      "Anything marked available for immediate claim is yours the moment you send it. No waiting on anyone.",
    ],
  },
  {
    target: "search",
    lines: ["Post under other names too? Search for them here. Every match joins the pool, and any name you can't take says why."],
  },
  {
    target: "note",
    lines: ["A name that isn't a direct match goes to an admin. A line here about where you post as it helps them say yes faster."],
  },
  {
    target: "send",
    lines: ["That's the whole loop! Press Send, and your direct match is yours right away."],
  },
];

const NO_MATCH = [
  {
    target: "pool",
    lines: [
      "Your Matrix name doesn't match a creator name that's on posts here yet, so nothing's ticked for you. That's okay, let's find yours.",
    ],
  },
  {
    target: "search",
    lines: ["Search for the names your posts carry, like 4chan_yourname. Tick each one that's yours; one request can hold several."],
  },
  {
    target: "note",
    lines: ["Then tell the admin how they'll know it's you: where you post, a link, anything that shows the name is yours."],
  },
  {
    target: "send",
    lines: ["Press Send, and your request goes off for review. The answer shows up right here, under Your creator names."],
  },
];

const OC_OFFER = {
  target: null,
  lines: [
    "Let's talk original characters! I'm Fourier, and I can show you how to make one officially yours.",
    "Want the tour? About thirty seconds, and you can skip it anytime.",
  ],
  next: "Show me",
};

const ocSteps = (slug, ready) => [
  ...(ready ? [{
    target: "ready",
    lines: ["Signal found! These characters are already tagged under your name, and they're available for immediate claim. One press each and they're yours."],
  }] : []),
  {
    target: "create",
    lines: [
      `To make a new one, type its name here. Your name goes in the brackets for you, so maple becomes maple_(${slug}).`,
      "A character under your own name is yours the moment you create it, and you can tag posts with it straight away.",
    ],
  },
  {
    target: null,
    lines: ["Once it's yours, only you and the admins edit its wiki page. Fan art can still use the tag, so everyone gets to celebrate your character!"],
  },
];

// The steps of `tour` for a dashboard in state `ctx`:
//   linked: the page is linked to the viewer's booru account (they may claim)
//   directMatch: a name in the Claim Pool is available for immediate claim
//   ready: original characters wait for them, available for immediate claim
//   slug: the page's name, which goes in an original character's brackets
// With `offer` false (a replay, asked for by its button) she skips the offer.
export function tourSteps(tour, ctx, { offer = true } = {}) {
  const first = (tour === "oc") ? OC_OFFER : CREATOR_NAME_OFFER;
  const byTour = (tour === "oc") ? ocSteps(ctx.slug, ctx.ready) : (ctx.directMatch ? DIRECT_MATCH : NO_MATCH);
  const rest = ctx.linked ? byTour : [LINK_STEP];
  const steps = offer ? [first, ...rest] : rest;
  return steps.map((step, i) => ({
    next: (i === steps.length - 1) ? "Done" : "Next",
    record: true,
    ...step,
  }));
}

// The tour a page load offers by itself: the first one the viewer has never
// ended, one at a time, and none to a viewer who may not claim or link here.
// `ended` is ModulationSetting "tours": {creator_name: "done"|"skipped"}.
export function tourToOffer(ended, ctx) {
  if (!ctx.linked && !ctx.linkable) { return null; }
  return TOURS.find((tour) => !ended[tour]) || null;
}
