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
// The Modulation post page is one inline script that cannot `import`, so this
// is also hung on window.FourierPayloads for it, as fourier_wheel_step.js is.

// load: key -> Promise of the payload (rejecting with the HTTP status).
export function payloadStore(load) {
  const cache = new Map();
  const inflight = new Map();

  function request(key) {
    const req = load(key)
      .then((p) => { if (inflight.get(key) === req) { cache.set(key, p); } return p; })
      .finally(() => { if (inflight.get(key) === req) { inflight.delete(key); } });
    inflight.set(key, req);
    return req;
  }

  return {
    // The cached payload, the request in flight, or a new request.
    get(key) {
      if (cache.has(key)) { return Promise.resolve(cache.get(key)); }
      return inflight.get(key) || request(key);
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

if (typeof window !== "undefined") { window.FourierPayloads = { payloadStore }; }
