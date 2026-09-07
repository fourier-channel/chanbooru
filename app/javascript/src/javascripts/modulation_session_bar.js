// The Manage Session panel: a right-aligned control in the header row, one
// monitor per session.
//
// Monitor contract (operator design, 2026-09-04): each monitor's state is
// DERIVED from what the environment actually handed it -- its first read,
// and every read after -- then checked against a programmed constant, the
// one GO. Green is earned by that match plus a verified session; every
// other state renders as exactly what was read. There is no heartbeat: the
// observation rides in with the page, re-reads on window focus, and after
// auth actions ("the poll could be as infrequent as the normal token
// refresh and ALSO respond instantly to user input").
//
// 2026-09-06, three operator rulings applied here:
//   - the panel unfurls sideways out of the pill, so "open" is a class on the
//     group rather than the `hidden` attribute (which cannot be animated);
//   - the cookie NAME is tooltip-only, so the resting line is a fixed
//     "Booru:" / "Matrix:" and the read still drives the lamp;
//   - the page always reloads after an auth action. The opt-out checkbox is
//     gone; a session change you can half-see is worse than a reload.

const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function fmtDur(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

// One popup geometry for both logins, centred on the opener.
function openLoginPopup(url, name) {
  const w = 480;
  const h = 640;
  const x = window.screenX + (window.outerWidth - w) / 2;
  const y = window.screenY + (window.outerHeight - h) / 2;
  return window.open(url, name, `width=${w},height=${h},left=${x},top=${y}`);
}

function boot() {
  const bar = document.getElementById("modnav-session");
  if (!bar || bar.dataset.booted) {
    return;
  }
  bar.dataset.booted = "1";
  // The strip is a child of the HEADER now, not of a wrapper around the pill:
  // it descends full width under the bar rather than unfurling along the pill
  // row (operator ruling 2026-09-07). The open state therefore lives on the
  // header, which is the common ancestor of the button and the strip.
  const group = bar.closest(".modnav");
  const toggle = document.getElementById("modnav-session-toggle");

  // The panel starts closed unless the server said the viewer had left it
  // open. `hidden` is only the server's way of saying so in the markup; the
  // width animation needs the element to stay in flow, so the attribute is
  // converted to the class once and never used again.
  const startOpen = !bar.hasAttribute("hidden");
  bar.removeAttribute("hidden");
  if (group && startOpen) { group.classList.add("is-open"); bar.classList.add("is-settled"); }
  const isOpen = () => !!group && group.classList.contains("is-open");

  let obs = {};
  try {
    obs = JSON.parse(bar.dataset.observation || "{}");
  } catch {
    return;
  }
  // The tickers count from the SERVER's clock: baseNow anchors it to local
  // monotonic-ish time so "#s ago" is arithmetic, not polling.
  let baseNow = obs.now || Math.floor(Date.now() / 1000);
  let baseAt = Date.now();
  const nowEpoch = () => baseNow + (Date.now() - baseAt) / 1000;

  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || "";
  const persist = (changes) => fetch("/modulation/settings", {
    method: "PATCH",
    credentials: "same-origin",
    headers: { "X-CSRF-Token": csrf(), "Content-Type": "application/json" },
    body: JSON.stringify(changes),
  }).catch(() => {});

  const region = (monitor, name) => bar.querySelector(`[data-monitor="${monitor}"] [data-region="${name}"]`);
  const tick = (epoch, dir = "since") => `<span data-tick="${epoch}" data-dir="${dir}"></span>`;
  const code = (s) => `<code class="modnav-digest">${esc(s)}</code>`;

  // go > idle/unlit > stale > alarm. "idle" is an observed object with no
  // verified session behind it (an anonymous booru cookie); "stale" is the
  // matrix cookie the gate has not vouched for -- still owned, not signed
  // out; "alarm" is the monitor reading an object other than its GO.
  function lampState(m, kind) {
    if (!m.observed) return "unlit";
    if (m.observed !== m.expect) return "alarm";
    if (kind === "booru") return m.signed_in ? "go" : "idle";
    return m.linked ? "go" : (m.gate === "stale" ? "stale" : "idle");
  }

  // Condensed to the operator's line (2026-09-06):
  //   (lamp) Booru: [Log In]        |  (lamp) Matrix: [Log In]
  //   (lamp) Booru: saber [Manage Account] [Log Out]
  // Signed out is the ACTION alone -- "anonymous" was a word spent saying what
  // an unlit lamp beside an empty name already says.
  function renderBooru(m, state) {
    const st = region("booru", "status");
    const act = region("booru", "controls");
    if (state === "alarm") {
      st.textContent = "reading the wrong object";
      act.innerHTML = "";
    } else if (m.signed_in) {
      st.innerHTML = `<b>${esc(m.name)}</b>`;
      act.innerHTML = '<a class="modnav-session-btn" href="/profile">Manage Account</a>' +
        '<button type="button" class="modnav-session-btn" data-act="booru-logout">Log Out</button>';
    } else {
      st.textContent = "";
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="booru-login">Log In</button>';
    }
  }

  function renderMatrix(m, state) {
    const st = region("matrix", "status");
    const act = region("matrix", "controls");
    if (state === "alarm") {
      st.textContent = "reading the wrong object";
      act.innerHTML = "";
    } else if (m.linked) {
      st.innerHTML = `<b>${esc(m.matrix_id)}</b>`;
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="matrix-logout">Log Out</button>';
    } else if (state === "stale") {
      st.textContent = "cookie held, unverified";
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="matrix-login">Re-verify</button>' +
        '<button type="button" class="modnav-session-btn" data-act="matrix-logout">Discard</button>';
    } else {
      st.textContent = "";
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="matrix-login">Log In</button>';
    }
  }

  function renderTip(kind, m, state) {
    const lines = [];
    if (state === "go") {
      lines.push("<b>This green light actually means something.</b>");
    }
    lines.push(`monitor: expected ${esc(m.expect)}; reading ${m.observed ? esc(m.observed) : "nothing"}.`);
    if (kind === "booru") {
      if (m.previous_session) {
        lines.push(`Your previous session was ${code(m.previous_session.digest)} and it ended ${tick(m.previous_session.ended_at)} ago.`);
      }
      if (m.digest) {
        lines.push(`Your current session cookie is ${code(m.digest)}; its expiry refreshes with every request -- last refreshed ${tick(baseNow)} ago.`);
      }
      if (m.started_at) {
        lines.push(`This session began ${tick(m.started_at)} ago.`);
      }
    } else {
      if (m.info?.previous_digest) {
        lines.push(`Your previous token was ${code(m.info.previous_digest)} and it expired ${tick(m.info.previous_ended_at)} ago.`);
      }
      if (m.digest) {
        lines.push(`Your current ${m.linked ? "token" : "cookie"} is ${code(m.digest)}${m.verified_at ? `, verified by the gate ${tick(m.verified_at)} ago` : ""}.`);
      }
      if (m.info?.expires_at) {
        lines.push(`This session expires in ${tick(m.info.expires_at, "until")}.`);
      }
      if (m.info?.refresh_at) {
        lines.push(`There are ${tick(m.info.refresh_at, "until")} until the next refresh.`);
      } else if (m.digest && !m.info) {
        lines.push("The gate does not publish its session evidence to this host yet; expiry and previous-token lines appear here when it does.");
      }
    }
    region(kind, "tip").innerHTML = lines.map((l) => `<span class="modnav-tip-line">${l}</span>`).join("");
  }

  function renderMonitor(kind) {
    const m = obs[kind];
    if (!m) {
      return;
    }
    const state = lampState(m, kind);
    bar.querySelector(`[data-monitor="${kind}"]`).dataset.state = state;
    if (kind === "booru") renderBooru(m, state); else renderMatrix(m, state);
    renderTip(kind, m, state);
  }

  function renderSummary() {
    const rank = { alarm: 4, stale: 3, idle: 2, unlit: 1, go: 0 };
    const worst = ["booru", "matrix"]
      .map((k) => (obs[k] ? lampState(obs[k], k) : "unlit"))
      .sort((a, b) => rank[b] - rank[a])[0];
    if (toggle) {
      toggle.dataset.state = worst;
    }
  }

  function tickNow() {
    bar.querySelectorAll("[data-tick]").forEach((el) => {
      const t = +el.dataset.tick;
      el.textContent = fmtDur(el.dataset.dir === "until" ? t - nowEpoch() : nowEpoch() - t);
    });
  }

  function renderAll() {
    renderMonitor("booru");
    renderMonitor("matrix");
    renderSummary();
    tickNow();
  }

  setInterval(() => { if (isOpen()) tickNow(); }, 1000);

  let fetching = false;
  function refetch() {
    if (fetching) {
      return;
    }
    fetching = true;
    fetch("/modulation/session_status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((next) => { obs = next; baseNow = next.now; baseAt = Date.now(); renderAll(); })
      .catch(() => {})
      .finally(() => { fetching = false; });
  }
  window.addEventListener("focus", () => { if (isOpen()) refetch(); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && isOpen()) refetch(); });

  // Always. An auth action changes what the whole page is allowed to show, so
  // re-rendering only the header would leave the body describing the previous
  // account (operator ruling 2026-09-06, replacing the opt-out checkbox).
  const refreshNow = () => location.reload();

  function booruLogout() {
    fetch("/session", { method: "DELETE", credentials: "same-origin", headers: { "X-CSRF-Token": csrf(), Accept: "text/html" } })
      .then(refreshNow, refreshNow);
  }

  // The gate's own logout invalidates the server-side session; the second
  // call force-deletes the cookie on this host so the observed object goes
  // away too, and the monitor's next read says "nothing" truthfully.
  function matrixLogout() {
    fetch("/fourier/logout", { method: "POST", credentials: "same-origin" })
      .catch(() => {})
      .finally(() => {
        fetch("/modulation/matrix_logout", { method: "POST", credentials: "same-origin", headers: { "X-CSRF-Token": csrf() } })
          .then(refreshNow, refreshNow);
      });
  }

  // Both logins are the same shape: open a popup, and when focus comes back
  // ask the server what changed rather than assuming the popup succeeded.
  // Event-driven, not polled -- the popup closing hands focus back, and that
  // one event triggers the re-read.
  function afterPopup(check) {
    const onFocus = () => {
      window.removeEventListener("focus", onFocus);
      check();
    };
    window.addEventListener("focus", onFocus);
  }

  function matrixLogin() {
    window.__fourierLoginPopupOpen = true;
    openLoginPopup("/fourier/login", "fourier-login");
    afterPopup(() => {
      fetch("/fourier_identity.json", { credentials: "same-origin" })
        .then((r) => r.json())
        .then((d) => { if (d.linked && !(obs.matrix || {}).linked) refreshNow(); else refetch(); })
        .catch(refetch);
    });
  }

  // The booru login is a popup too (operator ruling 2026-09-06). `popup=1`
  // makes SessionsController render the blank layout and finish on a page that
  // closes itself, so password AND the 2FA step both happen in the popup.
  function booruLogin() {
    openLoginPopup("/login?popup=1", "chanbooru-login");
    afterPopup(() => {
      fetch("/modulation/session_status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
        .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
        .then((next) => { if (next.booru?.signed_in && !(obs.booru || {}).signed_in) refreshNow(); else { obs = next; baseNow = next.now; baseAt = Date.now(); renderAll(); } })
        .catch(refetch);
    });
  }

  bar.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]");
    if (!act) {
      return;
    }
    const a = act.dataset.act;
    if (a === "booru-logout") booruLogout();
    else if (a === "booru-login") { e.preventDefault(); booruLogin(); }
    else if (a === "matrix-login") { e.preventDefault(); matrixLogin(); }
    else if (a === "matrix-logout") matrixLogout();
  });

  if (toggle && group) {
    toggle.addEventListener("click", () => {
      const open = !isOpen();
      group.classList.toggle("is-open", open);
      // Clip while it moves, release when it lands: a tooltip inside the strip
      // has to be able to hang below it, and `overflow: hidden` was silently
      // cutting the lamps' tooltips off.
      bar.classList.remove("is-settled");
      if (open) {
        const settle = () => { bar.classList.add("is-settled"); bar.removeEventListener("transitionend", settle); };
        bar.addEventListener("transitionend", settle);
      }
      toggle.setAttribute("aria-expanded", String(open));
      // Sequenced, not parallel: for an anonymous viewer both requests
      // rewrite the cookie-store session, and a concurrent status GET can
      // land its Set-Cookie after the PATCH's -- silently undoing the write.
      persist({ session_bar_open: open }).finally(() => {
        if (open) {
          refetch();
        }
      });
    });
  }

  renderAll();
}

$(document).ready(boot);

export default { boot };
