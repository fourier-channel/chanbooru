// Drives the Matrix sign-in panel. See MatrixSigninComponent for why the
// completion signal is a poll of this site's own origin rather than anything
// the sign-in document tells us.

function initPanel(root) {
  if (root.dataset.mxsignBooted) return;
  root.dataset.mxsignBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const region = (name) => root.querySelector(`[data-region="${name}"]`);
  const started = Date.now();
  let timer = null;
  let popup = null;

  function markLinked(matrixId) {
    if (timer) { clearInterval(timer); timer = null; }
    root.classList.add("is-linked");
    const stateText = region("state-text");
    if (stateText) stateText.textContent = "linked";
    const id = region("id");
    if (id) { id.textContent = matrixId || ""; id.hidden = !matrixId; }
    // The flow is done: everything that existed to run it goes away, in place,
    // without touching the rest of the page.
    ["frame-wrap", "fallback"].forEach((name) => {
      const el = region(name);
      if (el) el.remove();
    });
    if (popup && !popup.closed) popup.close();
  }

  function poll() {
    if (Date.now() - started > cfg.pollCeilingMs) {
      clearInterval(timer);
      timer = null;
      return;
    }

    fetch(cfg.statusUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (d && d.linked) markLinked(d.matrix_id); })
      // A failed poll is not a failed login -- the next tick asks again.
      .catch(() => {});
  }

  function openPopup() {
    const w = 520;
    const h = 680;
    const y = window.top.outerHeight / 2 + window.top.screenY - h / 2;
    const x = window.top.outerWidth / 2 + window.top.screenX - w / 2;
    popup = window.open(cfg.loginUrl, "fourier-login",
      `popup=yes,width=${w},height=${h},top=${Math.max(0, y)},left=${Math.max(0, x)}`);
    // Popup blocked: say so, and leave a real link rather than a dead button.
    if (!popup) {
      const note = region("note");
      if (note) {
        note.innerHTML = "";
        const a = document.createElement("a");
        a.href = cfg.loginUrl;
        a.textContent = "Popup blocked — open sign-in directly";
        note.appendChild(a);
      }
    }
  }

  root.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]");
    if (act && act.dataset.act === "popup") openPopup();
  });

  function markUnavailable() {
    root.classList.add("is-unavailable");
    const wrap = region("frame-wrap");
    if (wrap) wrap.remove();
    const stateText = region("state-text");
    if (stateText) stateText.textContent = "unavailable";
    const note = region("note");
    if (note) note.textContent = "Matrix sign-in is not responding right now. The booru login still works.";
  }

  // Preflight before framing. /fourier/login is same-origin here (the proxy
  // forwards it), so unlike the framed document itself its status IS readable --
  // and the difference between "the provider is fine and will redirect" and
  // "the gate is down" is worth knowing BEFORE handing the page a frame that
  // renders someone else's 502 in the middle of the login form.
  //
  // HEAD, and redirect: "manual", so this neither downloads the page nor follows
  // the flow: a healthy gate answers with an opaque redirect (status 0), which
  // is the success case, not a failure.
  function preflight() {
    return fetch(cfg.loginUrl, { method: "HEAD", redirect: "manual", credentials: "same-origin" })
      .then((r) => {
        if (r.type === "opaqueredirect") return true;
        return r.status < 400;
      })
      // A network error here is itself the answer.
      .catch(() => false);
  }

  const wrap = region("frame-wrap");
  if (wrap) {
    const frame = region("frame");
    // Held back until the preflight answers, so a broken gate never paints.
    const src = frame && frame.getAttribute("src");
    if (frame) frame.removeAttribute("src");

    preflight().then((ok) => {
      if (!ok) { markUnavailable(); return; }
      if (frame && src) frame.setAttribute("src", src);

      // The gate is up but the frame may still be refused by the provider, and
      // a refused frame can report that it loaded -- so this is a nudge on a
      // timer, not a diagnosis. Nothing here claims to know why it has not
      // finished, only that it has not.
      setTimeout(() => {
        if (root.classList.contains("is-linked")) return;
        root.classList.add("is-frame-stalled");
        const note = region("note");
        if (note) note.textContent = "Not loading? Use the button — some providers refuse to be embedded.";
      }, cfg.frameGraceMs);
    });
  }

  timer = setInterval(poll, cfg.pollIntervalMs);
  poll();
}

function initAll() {
  document.querySelectorAll("[data-mxsign]").forEach(initPanel);
}

$(document).ready(initAll);

export default { initAll };
