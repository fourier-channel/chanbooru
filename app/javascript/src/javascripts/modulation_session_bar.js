// The Manage Session bar: a stationary header row, one monitor per session.
//
// Monitor contract (operator design, 2026-09-04): each monitor's label is
// DERIVED from what the environment actually handed it -- its first read,
// and every read after -- then checked against a programmed constant, the
// one GO. Green is earned by that match plus a verified session; every
// other state renders as exactly what was read. There is no heartbeat: the
// observation rides in with the page, re-reads on window focus, and after
// auth actions ("the poll could be as infrequent as the normal token
// refresh and ALSO respond instantly to user input").

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

function boot() {
  const bar = document.getElementById("modnav-session");
  if (!bar || bar.dataset.booted) {
    return;
  }
  bar.dataset.booted = "1";
  const toggle = document.getElementById("modnav-session-toggle");

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
  let autorefresh = bar.dataset.autorefresh === "1";

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

  function renderBooru(m, state) {
    const st = region("booru", "status");
    const act = region("booru", "controls");
    if (state === "alarm") {
      st.textContent = "reading the wrong object";
      act.innerHTML = "";
    } else if (m.signed_in) {
      st.innerHTML = `signed in as <b>${esc(m.name)}</b>${m.level ? ` (${esc(m.level)})` : ""}`;
      act.innerHTML = '<a class="modnav-session-btn" href="/profile">My Account</a>' +
        '<button type="button" class="modnav-session-btn" data-act="booru-logout">Log out</button>';
    } else {
      st.textContent = "anonymous";
      act.innerHTML = `<a class="modnav-session-btn" href="/login?url=${encodeURIComponent(location.pathname + location.search)}">Log in</a>`;
    }
  }

  function renderMatrix(m, state) {
    const st = region("matrix", "status");
    const act = region("matrix", "controls");
    if (state === "alarm") {
      st.textContent = "reading the wrong object";
      act.innerHTML = "";
    } else if (m.linked) {
      st.innerHTML = `linked as <b>${esc(m.matrix_id)}</b>`;
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="matrix-logout">Log out</button>';
    } else if (state === "stale") {
      st.textContent = "cookie held; the gate has not verified this view";
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="matrix-login">Re-verify</button>' +
        '<button type="button" class="modnav-session-btn" data-act="matrix-logout">Discard cookie</button>';
    } else {
      st.textContent = "not linked";
      act.innerHTML = '<button type="button" class="modnav-session-btn" data-act="matrix-login">Log in with Matrix</button>';
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
    // The label is what was READ, never an assertion.
    region(kind, "label").textContent = m.observed ? m.observed.replace(":", " ") : `no ${m.expect.replace(":", " ")}`;
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

  setInterval(() => { if (!bar.hidden) tickNow(); }, 1000);

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
  window.addEventListener("focus", () => { if (!bar.hidden) refetch(); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && !bar.hidden) refetch(); });

  const maybeRefresh = () => (autorefresh ? location.reload() : refetch());

  function booruLogout() {
    fetch("/session", { method: "DELETE", credentials: "same-origin", headers: { "X-CSRF-Token": csrf(), Accept: "text/html" } })
      .then(maybeRefresh, maybeRefresh);
  }

  // The gate's own logout invalidates the server-side session; the second
  // call force-deletes the cookie on this host so the observed object goes
  // away too, and the monitor's next read says "nothing" truthfully.
  function matrixLogout() {
    fetch("/fourier/logout", { method: "POST", credentials: "same-origin" })
      .catch(() => {})
      .finally(() => {
        fetch("/modulation/matrix_logout", { method: "POST", credentials: "same-origin", headers: { "X-CSRF-Token": csrf() } })
          .then(maybeRefresh, maybeRefresh);
      });
  }

  function matrixLogin() {
    const w = 480;
    const h = 640;
    const x = window.screenX + (window.outerWidth - w) / 2;
    const y = window.screenY + (window.outerHeight - h) / 2;
    window.__fourierLoginPopupOpen = true;
    window.open("/fourier/login", "fourier-login", `width=${w},height=${h},left=${x},top=${y}`);
    // Event-driven, not polled: the popup closing hands focus back, and that
    // one event triggers the re-read.
    const onFocus = () => {
      window.removeEventListener("focus", onFocus);
      fetch("/fourier_identity.json", { credentials: "same-origin" })
        .then((r) => r.json())
        .then((d) => { if (d.linked && !(obs.matrix || {}).linked) maybeRefresh(); else refetch(); })
        .catch(refetch);
    };
    window.addEventListener("focus", onFocus);
  }

  bar.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]");
    if (!act) {
      return;
    }
    const a = act.dataset.act;
    if (a === "booru-logout") booruLogout();
    else if (a === "matrix-login") { e.preventDefault(); matrixLogin(); }
    else if (a === "matrix-logout") matrixLogout();
    else if (a === "session-autorefresh") { autorefresh = act.checked; persist({ session_autorefresh: autorefresh }); }
  });

  if (toggle) {
    toggle.addEventListener("click", () => {
      bar.hidden = !bar.hidden;
      toggle.setAttribute("aria-expanded", String(!bar.hidden));
      // Sequenced, not parallel: for an anonymous viewer both requests
      // rewrite the cookie-store session, and a concurrent status GET can
      // land its Set-Cookie after the PATCH's -- silently undoing the write.
      persist({ session_bar_open: !bar.hidden }).finally(() => {
        if (!bar.hidden) {
          refetch();
        }
      });
    });
  }

  renderAll();
}

$(document).ready(boot);

export default { boot };
