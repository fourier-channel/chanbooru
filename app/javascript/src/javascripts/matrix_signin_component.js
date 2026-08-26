// Drives the Matrix sign-in panel. See MatrixSigninComponent for why the
// completion signal is a poll of this site's own origin rather than anything
// the sign-in document tells us.

function initPanel(root) {
  if (root.dataset.mxsignBooted) return;
  root.dataset.mxsignBooted = "1";

  const cfg = JSON.parse(root.dataset.config || "{}");
  const region = (name) => root.querySelector(`[data-region="${name}"]`);
  let timer = null;
  let popup = null;
  // When the current attempt began. Null when nothing is in flight, which is
  // also what stops the panel polling at a page it has no reason to poll.
  let attemptStarted = null;

  // Captured from the server-rendered markup rather than written out again
  // here. The popup caveat is user-facing copy; keeping a second copy of it in
  // JavaScript is how the two end up saying different things.
  const noteEl = root.querySelector('[data-region="note"]');
  const NOTE_DEFAULT = noteEl ? noteEl.textContent : "";

  function show(name, visible) {
    const el = region(name);
    if (el) el.hidden = !visible;
  }

  function markLinked(matrixId) {
    rest();
    root.classList.add("is-linked");
    const stateText = region("state-text");
    if (stateText) stateText.textContent = "linked";
    const id = region("id");
    if (id) id.textContent = matrixId || "";

    // Hidden, not removed. Signing out has to be able to put this panel back
    // without reloading the page, and a removed element cannot come back.
    show("linked", true);
    show("fallback", false);
    window.__fourierLoginPopupOpen = false;
    if (popup && !popup.closed) popup.close();
  }

  function markUnlinked() {
    root.classList.remove("is-linked", "is-unavailable");
    const stateText = region("state-text");
    if (stateText) stateText.textContent = "not linked";
    const id = region("id");
    if (id) id.textContent = "";

    show("linked", false);
    show("fallback", true);
    const note = region("note");
    if (note) note.textContent = NOTE_DEFAULT;

    // Deliberately does NOT start watching. Signing out is not the start of
    // signing in, and the panel has no reason to poll until someone asks it to.
    // Coming back linked is caught by the focus handler below.
    rest();
  }

  function logout() {
    fetch(cfg.logoutUrl, {
      method: "POST",
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    })
      .then((r) => { if (r.ok) markUnlinked(); })
      .catch(() => {});
  }

  function rest() {
    if (timer) { clearInterval(timer); timer = null; }
    attemptStarted = null;
  }

  /**
   * Start watching for a sign-in that is actually in flight.
   *
   * The ceiling runs from HERE rather than from page load, and that distinction
   * is the bug this replaces. The panel used to start a 2-second heartbeat the
   * moment the login page rendered and stop it five minutes later, whether or
   * not anybody had clicked anything -- so opening /login cost 150 requests to
   * /fourier_identity.json on its own, and a reader who took longer than five
   * minutes to sign in (creating an account, finding a password) came back to a
   * panel that had stopped listening. The login had worked. Nothing was
   * watching for it.
   */
  function watch() {
    attemptStarted = Date.now();
    if (!timer) timer = setInterval(poll, cfg.pollIntervalMs || 2000);
    poll();
  }

  function poll() {
    if (attemptStarted !== null && Date.now() - attemptStarted > cfg.pollCeilingMs) {
      rest();
      return;
    }

    fetch(cfg.statusUrl, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : null))
      .then((d) => { if (d && d.linked) markLinked(d.matrix_id); })
      // A failed poll is not a failed login -- the next tick asks again.
      .catch(() => {});
  }

  function openPopup() {
    // Marks THIS window as the one waiting on a login popup. The popup reads it
    // back through window.opener to recognise that it is a login popup and
    // should close rather than render. See closeIfLoginPopup below for why this
    // flag exists instead of checking window.name.
    window.__fourierLoginPopupOpen = true;

    const w = 520;
    const h = 680;
    const y = window.top.outerHeight / 2 + window.top.screenY - h / 2;
    const x = window.top.outerWidth / 2 + window.top.screenX - w / 2;
    popup = window.open(cfg.loginUrl, "fourier-login",
      `popup=yes,width=${w},height=${h},top=${Math.max(0, y)},left=${Math.max(0, x)}`);

    // Clear the flag if the popup is dismissed without finishing. Otherwise it
    // stays set, and the next page of ours opened from this window -- any
    // target=_blank link -- would recognise itself as a login popup and close
    // on sight.
    if (popup) {
      const closeWatch = setInterval(() => {
        if (!popup || popup.closed) {
          clearInterval(closeWatch);
          window.__fourierLoginPopupOpen = false;
          // The popup closing is the likeliest moment for the answer to have
          // changed, so ask immediately rather than waiting out a tick.
          poll();
        }
      }, 500);
    }
    // Popup blocked: say so, and leave a real link rather than a dead button.
    if (!popup) {
      window.__fourierLoginPopupOpen = false;
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
    if (!act) return;
    if (act.dataset.act === "popup") { watch(); openPopup(); }
    else if (act.dataset.act === "logout") logout();
  });

  function markUnavailable() {
    root.classList.add("is-unavailable");
    const stateText = region("state-text");
    if (stateText) stateText.textContent = "unavailable";
    const note = region("note");
    if (note) note.textContent = "Matrix sign-in is not responding right now. The booru login still works.";
  }

  // Is the gate answering at all? /fourier/login is same-origin here (the proxy
  // forwards it), so unlike the provider's own pages this status IS readable.
  //
  // HEAD, and redirect: "manual", so this neither downloads the page nor walks
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

  // The gate can be down, and a button that opens a window onto a 502 is worse
  // than one that says so first. Same-origin through the proxy, so unlike the
  // provider's own pages this status IS readable.
  preflight().then((ok) => { if (!ok) markUnavailable(); });

  // Coming back to this tab is the strongest signal there is that something
  // happened elsewhere -- a popup finished, or a sign-in was completed in
  // another tab entirely. One request, on an event, instead of a heartbeat.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && !root.classList.contains("is-linked")) poll();
  });
  window.addEventListener("focus", () => {
    if (!root.classList.contains("is-linked")) poll();
  });

  // Exactly one request on load, to render the state the reader arrives with.
  // Everything after this is driven by something happening.
  poll();
}

// A page of ours that finds itself inside the login popup closes immediately,
// rather than rendering.
//
// The sign-in flow ends by redirecting the popup to this site's post-login URL,
// which is a whole page -- so without this the popup loads and paints the entire
// landing page for a moment before the opener notices the login finished and
// closes it. That flash is the "click here to leave the page and we will send
// you back" pattern showing through, and there is no reason for a login popup to
// render a site at all.
//
// The signal is a flag the opener sets on ITSELF, read back through
// window.opener, which is same-origin and therefore readable. Deliberately not
// window.name: browsers clear that across cross-origin navigation, and this
// window has been to the identity provider and back by the time it matters.
//
// Runs at module scope on purpose. The pack is a blocking script in <head>, so
// this executes before the body is parsed -- which is the difference between
// closing silently and closing after a flash of the site.
function closeIfLoginPopup() {
  try {
    const opener = window.opener;
    if (!opener || opener.closed) return;
    // Cross-origin opener throws here, which is the correct answer: not ours.
    if (!opener.__fourierLoginPopupOpen) return;

    opener.__fourierLoginPopupOpen = false;
    window.close();
  } catch (e) {
    // Not our opener, or not allowed to look. Render normally.
  }
}

closeIfLoginPopup();

function initAll() {
  document.querySelectorAll("[data-mxsign]").forEach(initPanel);
}

$(document).ready(initAll);

export default { initAll };
