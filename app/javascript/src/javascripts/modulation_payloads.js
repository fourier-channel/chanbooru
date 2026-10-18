// The Modulation post view's payload store: every modulation.json answer the
// page has fetched, keyed "id|search", for navigation, preloads and looking
// further along a blocked flank.
//
// A request already in flight is shared, not repeated: a preload of a flank
// pick and a look further from it (or an arrow press) often ask for the same
// payload within the same moment. But only the LATEST request for a key may
// fill the cache. A write (a vote, a favourite) re-reads its post with
// refresh(), and a request sent before that write -- an earlier refresh, a
// preload -- answers with a state the server no longer holds: handed to the
// refresh, or landing in the cache after it or after a clear(), it would be
// what the page shows until the next re-read.
//
// The cache is BOUNDED (max, least recently used out first): the lookahead
// fetches several posts ahead, and a store that never let one go held every
// post a long walk passed for the life of the page.
//
// The Modulation post page is one inline script that cannot `import`, so this
// is also hung on window.FourierPayloads for it, as fourier_wheel_step.js is.

// load: key -> Promise of the payload (rejecting with the HTTP status).
export function payloadStore(load, { max = 64 } = {}) {
  const cache = new Map();
  const inflight = new Map();

  function remember(key, p) {
    cache.delete(key);
    cache.set(key, p);
    while (cache.size > max) { cache.delete(cache.keys().next().value); }
  }

  function request(key) {
    const req = load(key)
      .then((p) => { if (inflight.get(key) === req) { remember(key, p); } return p; })
      .finally(() => { if (inflight.get(key) === req) { inflight.delete(key); } });
    inflight.set(key, req);
    return req;
  }

  return {
    // The cached payload, the request in flight, or a new request.
    get(key) {
      if (cache.has(key)) {
        const p = cache.get(key);
        remember(key, p);
        return Promise.resolve(p);
      }
      return inflight.get(key) || request(key);
    },
    // Whether a payload for key is cached or on its way.
    has(key) { return cache.has(key) || inflight.has(key); },
    // Of several keys for the same post (a full read, a prefetch), the one
    // to ask: a cached one first, then one in flight, in the order given;
    // neither, the first.
    choose(keys) {
      return keys.find((key) => cache.has(key)) || keys.find((key) => inflight.has(key)) || keys[0];
    },
    // A new request whatever is cached or in flight: the re-read after a write.
    refresh(key) {
      cache.delete(key);
      return request(key);
    },
    // Forget everything, including what is still in flight.
    clear() {
      cache.clear();
      inflight.clear();
    },
    // Whether p is what the store now holds for key -- false for the answer
    // of a refresh that a later one overtook.
    current(key, p) { return cache.get(key) === p; },
  };
}

// THE VISIT READ (?visit=1, ModulationPostComponent#visit_payload): after the
// page shows a post from its prefetch, the read that records the visit
// carries only what the prefetch lacked -- random's preset, that preset's
// candidates and the comments. This lays it over the payload being shown and
// keeps everything else: a full re-read applied there could land after a vote
// and put the pre-vote score back (review, 2026-10-18). A new object: the
// payload given is the store's cached copy, which a return visit hands back.
export function mergeVisit(payload, visit) {
  if (visit.id !== payload.id) { throw new Error("a visit read for post #" + visit.id + " cannot complete post #" + payload.id); }
  const byKey = new Map((visit.presets || []).map((p) => [p.key, p]));
  return {
    ...payload,
    presets: (payload.presets || []).map((p) => byKey.get(p.key) || p),
    candidates: { ...(payload.candidates || {}), ...(visit.candidates || {}) },
    comments_html: visit.comments_html,
  };
}

if (typeof window !== "undefined") { window.FourierPayloads = { payloadStore, mergeVisit }; }
