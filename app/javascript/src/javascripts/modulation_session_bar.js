import Notice from "./notice";

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

const esc = (s) => String(s === null || s === undefined ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function fmtDur(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) { return `${s}s`; }
  const m = Math.floor(s / 60);
  if (m < 60) { return `${m}m ${s % 60}s`; }
  const h = Math.floor(m / 60);
  if (h < 24) { return `${h}h ${m % 60}m`; }
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

// One popup geometry for both logins, centred on the opener.
function openLoginPopup(url, name) {
  const w = 480;
  const h = 640;
  const x = window.screenX + ((window.outerWidth - w) / 2);
  const y = window.screenY + ((window.outerHeight - h) / 2);
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
  const isOpen = () => Boolean(group) && group.classList.contains("is-open");

  let obs = {};
  try {
    obs = JSON.parse(bar.dataset.observation || "{}");
  } catch {
    return;
  }
  // The tickers count from the SERVER's clock: baseNow anchors it to local
  // monotonic-ish time so "#s ago" is arithmetic, not polling.
  // Null while the last refetch succeeded; a timestamp while it is failing.
  // See refetch below: it is what keeps one outage to one report.
  let staleSince = null;
  let baseNow = obs.now || Math.floor(Date.now() / 1000);
  let baseAt = Date.now();
  const nowEpoch = () => baseNow + ((Date.now() - baseAt) / 1000);

  const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || "";
  const persist = (changes) => fetch("/modulation/settings", {
    method: "PATCH",
    credentials: "same-origin",
    headers: { "X-CSRF-Token": csrf(), "Content-Type": "application/json" },
    body: JSON.stringify(changes),
  }).catch(() => {
    Notice.error("Could not save that session-bar setting; it will not be remembered.");
  });

  const region = (monitor, name) => bar.querySelector(`[data-monitor="${monitor}"] [data-region="${name}"]`);
  const tick = (epoch, dir = "since") => `<span data-tick="${epoch}" data-dir="${dir}"></span>`;
  const code = (s) => `<code class="modnav-digest">${esc(s)}</code>`;

  // go > idle/unlit > stale > alarm. "idle" is an observed object with no
  // verified session behind it (an anonymous booru cookie); "stale" is the
  // matrix cookie the gate has not vouched for -- still owned, not signed
  // out; "alarm" is the monitor reading an object other than its GO.
  function lampState(m, kind) {
    if (!m.observed) { return "unlit"; }
    if (m.observed !== m.expect) { return "alarm"; }
    if (kind === "booru") { return m.signed_in ? "go" : "idle"; }
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
      // THE TOKEN'S OWN LIFE, which is not the session's. A session lasts a
      // day; the Matrix token inside it lasts five minutes and the gate renews
      // it as long as it holds a refresh token. A token past its life with no
      // way to renew is the state that refused pictures for weeks while this
      // bar said "23 hours remain" (2026-09-19). So it is said outright.
      if (m.info?.token_expires_at) {
        const left = m.info.token_expires_at - Math.floor(Date.now() / 1000);
        if (m.info.renewable) {
          lines.push(left > 0
            ? `Your Matrix token has ${tick(m.info.token_expires_at, "until")} left and the gate renews it ${tick(m.info.refresh_at, "until")} from now, on use.`
            : `Your Matrix token lapsed ${tick(m.info.token_expires_at)} ago; the gate renews it on your next request.`);
        } else {
          lines.push(left > 0
            ? `Your Matrix token has ${tick(m.info.token_expires_at, "until")} left and CANNOT be renewed: sign out and in before then, or pictures from Matrix will be refused.`
            : `Your Matrix token EXPIRED ${tick(m.info.token_expires_at)} ago and cannot be renewed: pictures from Matrix are being refused. Sign out and in.`);
        }
      } else if (m.info?.refresh_at) {
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
    if (kind === "booru") { renderBooru(m, state); } else { renderMatrix(m, state); }
    renderTip(kind, m, state);
  }

  function renderSummary() {
    const rank = { alarm: 4, stale: 3, idle: 2, unlit: 1, go: 0 };
    const worst = ["booru", "matrix"]
      .map((k) => (obs[k] ? lampState(obs[k], k) : "unlit"))
      .sort((a, b) => rank[b] - rank[a])[0];
    if (toggle) {
      toggle.dataset.state = worst;
      // Not green says what to do, in the pill itself: a first-time visitor
      // has no booru account and nothing else tells them they need one.
      const cta = toggle.querySelector('[data-region="cta"]');
      if (cta) {
        cta.textContent = worst === "alarm" ? "Check"
          : worst === "stale" ? "Re-verify"
          : !(obs.booru || {}).signed_in ? "Log in" : "";
      }
    }
  }

  function tickNow() {
    (group || bar).querySelectorAll("[data-tick]").forEach((el) => {
      const t = Number(el.dataset.tick);
      el.textContent = fmtDur(el.dataset.dir === "until" ? t - nowEpoch() : nowEpoch() - t);
    });
  }

  // --- the token card ------------------------------------------------------
  // Under the pill while it is hovered or focused (operator, 2026-10-03): each
  // token's life and fingerprint always; its VALUE only after "Show tokens"
  // (ruling the same day: real values, after a reveal). Values live in this
  // page's memory only and are never written anywhere.
  //
  // The copy square stays LIT while the clipboard still holds what it copied
  // -- as far as this site can tell. A page cannot read the clipboard without
  // a browser prompt, so "still holds" means: no other copy has been made on
  // the booru since (ruling 2026-10-03: lit until the next copy). A copy made
  // in another app or on another 41chan site is not visible from here.
  //
  // The booru re-issues its session cookie on every page, so the value on the
  // clipboard is soon an EARLIER copy of it -- still a working one until you
  // sign out. The square stays lit (it is about the clipboard) and says so.
  const card = document.getElementById("modnav-tokens");
  const COPIED_KEY = "modulation.copied";
  let revealed = null; // { cookieName: value }
  const readCopied = () => { try { return JSON.parse(localStorage.getItem(COPIED_KEY) || "null"); } catch { return null; } };
  const writeCopied = (v) => {
    try { if (v) { localStorage.setItem(COPIED_KEY, JSON.stringify(v)); } else { localStorage.removeItem(COPIED_KEY); } } catch { /* storage off: the square just will not survive a reload */ }
  };

  const cookieName = (m) => (m?.expect || "").replace(/^cookie:/, "");
  function tokenRows() {
    const rows = [];
    const b = obs.booru;
    if (b) {
      rows.push({
        key: cookieName(b),
        label: "Booru session cookie",
        digest: b.digest,
        life: b.digest
          ? "Lives until you close your browser or sign out; renewed on every page you load."
          : "None in this browser.",
      });
    }
    const m = obs.matrix;
    if (m) {
      rows.push({
        key: cookieName(m),
        label: "Matrix link cookie",
        digest: m.digest,
        life: !m.digest
          ? "None in this browser."
          : m.info?.expires_at
            ? `Expires in ${tick(m.info.expires_at, "until")}.`
            : "The gate does not publish this cookie's expiry to this host yet.",
      });
      if (m.info?.token_expires_at) {
        const left = m.info.token_expires_at - Math.floor(Date.now() / 1000);
        rows.push({
          key: null,
          label: "Matrix token",
          digest: null,
          life: (left > 0 ? `${tick(m.info.token_expires_at, "until")} left` : `lapsed ${tick(m.info.token_expires_at)} ago`) +
            (m.info.renewable ? "; the gate renews it on use." : "; it cannot be renewed -- sign out and in.") +
            " Held by the gate, not by this page, so it cannot be copied here.",
        });
      }
    }
    return rows;
  }

  const COPY_ICON = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 0 0-1-1H5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3"/></svg>';

  function renderTokens() {
    if (!card) { return; }
    const rows = tokenRows();
    const copied = readCopied();
    const copyable = rows.filter((r) => r.key && r.digest);
    const html = rows.map((r) => {
      const value = revealed && r.key ? revealed[r.key] : null;
      const lit = Boolean(copied && r.key && copied.key === r.key);
      const renewed = lit && copied.digest !== r.digest;
      const square = r.key && r.digest
        ? `<button type="button" class="modnav-copy${lit ? " is-lit" : ""}" data-copy="${esc(r.key)}"` +
          `${value ? "" : " disabled"} aria-pressed="${lit ? "true" : "false"}"` +
          ` title="${!value && !lit ? "Show tokens first"
            : renewed ? "Copied earlier -- the browser has renewed this cookie since, so your clipboard holds the earlier value"
              : lit ? "Copied -- still on your clipboard as far as this site can tell" : "Copy this token"}">${COPY_ICON}</button>`
        : "";
      return `<div class="modnav-token"><span class="modnav-token-name">${esc(r.label)}${r.digest ? ` ${code(r.digest)}` : ""}</span>${square}` +
        `<span class="modnav-token-life">${r.life}</span>` +
        `${value ? `<span class="modnav-token-value">${esc(value.length > 48 ? `${value.slice(0, 48)}...` : value)}</span>` : ""}</div>`;
    }).join("");
    const allLit = Boolean(copied && copied.key === "*");
    const actions = copyable.length
      ? (revealed
        ? `<button type="button" data-tokens="copy-all" class="${allLit ? "is-lit" : ""}">Copy all, sorted</button>` +
          '<button type="button" data-tokens="hide">Hide values</button>'
        : '<button type="button" data-tokens="show">Show tokens</button>' +
          '<span class="modnav-tokens-note">Shows the values so they can be copied. Anything running on this page can read them once shown.</span>')
      : '<span class="modnav-tokens-note">No session tokens in this browser for this site.</span>';
    card.innerHTML = `${html}<div class="modnav-tokens-row">${actions}</div>`;
    tickNow();
  }

  function renderAll() {
    renderMonitor("booru");
    renderMonitor("matrix");
    renderSummary();
    renderTokens();
    tickNow();
  }

  setInterval(() => { if (isOpen() || (card && !card.hidden)) { tickNow(); } }, 1000);

  let fetching = false;
  function refetch() {
    if (fetching) {
      return;
    }
    fetching = true;
    fetch("/modulation/session_status", { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((next) => { obs = next; baseNow = next.now; baseAt = Date.now(); renderAll(); staleSince = null; })
      .catch(() => {
        // A poll runs on every focus, so reporting each failure would be a
        // toast storm on a flaky connection. Say it ONCE per outage, and say
        // it again only after a refetch has succeeded in between.
        if (staleSince === null) {
          staleSince = Date.now();
          Notice.error("Session details could not be refreshed; what you see may be out of date.");
        }
      })
      .finally(() => { fetching = false; });
  }
  window.addEventListener("focus", () => { if (isOpen()) { refetch(); } });
  document.addEventListener("visibilitychange", () => { if (!document.hidden && isOpen()) { refetch(); } });

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
      .catch(() => {
        Notice.error("Could not clear the Fourier session cookie on this host; sign-out may be incomplete.");
      })
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
        .then((d) => { if (d.linked && !(obs.matrix || {}).linked) { refreshNow(); } else { refetch(); } })
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
        .then((next) => { if (next.booru?.signed_in && !(obs.booru || {}).signed_in) { refreshNow(); } else { obs = next; baseNow = next.now; baseAt = Date.now(); renderAll(); } })
        .catch(refetch);
    });
  }

  bar.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]");
    if (!act) {
      return;
    }
    const a = act.dataset.act;
    if (a === "booru-logout") { booruLogout(); } else if (a === "booru-login") { e.preventDefault(); booruLogin(); } else if (a === "matrix-login") { e.preventDefault(); matrixLogin(); } else if (a === "matrix-logout") { matrixLogout(); }
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

  if (card && toggle) {
    let hideTimer = null;
    const place = () => {
      const r = toggle.getBoundingClientRect();
      const w = card.offsetWidth;
      card.style.top = `${r.bottom + 6}px`;
      card.style.left = `${Math.max(8, Math.min(r.right - w, window.innerWidth - w - 8))}px`;
    };
    const show = () => {
      clearTimeout(hideTimer);
      if (!card.hidden) { return; }
      card.hidden = false;
      renderTokens();
      place();
      window.addEventListener("scroll", place, { passive: true });
      window.addEventListener("resize", place);
    };
    const hideSoon = () => {
      clearTimeout(hideTimer);
      // A short grace, so the pointer can travel from the pill into the card.
      hideTimer = setTimeout(() => {
        if (card.matches(":hover") || card.contains(document.activeElement) || toggle.matches(":hover")) { return; }
        card.hidden = true;
        window.removeEventListener("scroll", place);
        window.removeEventListener("resize", place);
      }, 250);
    };
    for (const el of [toggle, card]) {
      el.addEventListener("mouseenter", show);
      el.addEventListener("mouseleave", hideSoon);
      el.addEventListener("focusin", show);
      el.addEventListener("focusout", hideSoon);
    }
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !card.hidden) { card.hidden = true; toggle.focus(); } });

    const copy = (text, mark) => navigator.clipboard.writeText(text).then(() => {
      writeCopied(mark);
      renderTokens();
    }, () => {
      Notice.error("The browser refused the clipboard. Select the value in the card and copy it by hand, or allow clipboard access for this site.");
    });
    card.addEventListener("click", (e) => {
      const sq = e.target.closest("[data-copy]");
      if (sq && revealed) {
        const row = tokenRows().find((r) => r.key === sq.dataset.copy);
        if (row && revealed[row.key]) { copy(revealed[row.key], { key: row.key, digest: row.digest }); }
        return;
      }
      const act = e.target.closest("[data-tokens]")?.dataset.tokens;
      if (act === "show") {
        fetch("/modulation/session_tokens", { method: "POST", credentials: "same-origin", headers: { "X-CSRF-Token": csrf(), Accept: "application/json" } })
          .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
          .then((d) => {
            revealed = {};
            for (const tk of d.tokens || []) { revealed[tk.name] = tk.value; }
            renderTokens();
          })
          .catch((s) => Notice.error(`The tokens could not be fetched (${s}). Reload the page and try again.`));
      } else if (act === "hide") {
        revealed = null;
        renderTokens();
      } else if (act === "copy-all") {
        const rows = tokenRows().filter((r) => r.key && r.digest && revealed[r.key]).sort((a, b) => a.key.localeCompare(b.key));
        copy(rows.map((r) => `${r.key}=${revealed[r.key]}`).join("\n"),
          { key: "*", digest: rows.map((r) => r.digest).sort().join(",") });
      }
    });
    // Any other copy on this site means the clipboard no longer holds ours.
    for (const ev of ["copy", "cut"]) {
      document.addEventListener(ev, () => { if (readCopied()) { writeCopied(null); renderTokens(); } });
    }
    // Another booru tab copied something: follow it.
    window.addEventListener("storage", (e) => { if (e.key === COPIED_KEY) { renderTokens(); } });
  }

  // --- tooltip placement ----------------------------------------------------
  // The tips overlay the PAGE, not the header. They cannot do that with
  // `position: absolute`: .modnav-session-inner carries `overflow-x: auto` as a
  // last-resort scroll, and CSS resolves the other axis to `auto` whenever one
  // axis is not `visible` -- so a tip hanging below its monitor was not hidden,
  // it was scrolled out of a 2.2rem-tall box and only reachable by scrolling
  // inside the header. They are `position: fixed` now, which costs us the
  // placement.
  const TIP_GAP = 6;

  function placeTip(anchor, tip) {
    const r = anchor.getBoundingClientRect();
    // LEFT-anchored to its trigger, then pulled back inside the viewport if it
    // would overflow the right edge.
    //
    // It was right-anchored first, on the standing comment that "the group
    // lives at the right edge of the viewport". That stopped being true: the
    // monitors sit at the LEFT of a centred 1180px column. Measured on
    // production, right-anchoring put both tips at x=6 -- clamped off the left
    // edge -- so hovering Booru and hovering Matrix looked identical and
    // neither pointed at the lamp it described.
    const w = tip.offsetWidth;
    tip.style.top = `${r.bottom + TIP_GAP}px`;
    tip.style.left = `${Math.max(TIP_GAP, Math.min(r.left, window.innerWidth - w - TIP_GAP))}px`;
  }

  bar.querySelectorAll(".modnav-monitor").forEach((monitor) => {
    const tip = monitor.querySelector('[data-region="tip"]');
    // The lamp and the service name, not the whole row: the status text and the
    // sign-in control are not a question about the monitor.
    const trigger = monitor.querySelector('[data-region="trigger"]');
    if (!tip || !trigger) { return; }
    let follow = null;
    const show = () => {
      // Class first, THEN measure: offsetWidth of a display:none element is 0,
      // which would anchor every tip to the right edge of the window.
      tip.classList.add("is-open");
      placeTip(trigger, tip);
      if (follow) { return; }
      // #top.modnav is in normal flow, so the header moves when the page
      // scrolls and a fixed tip has to be told about it.
      follow = () => placeTip(trigger, tip);
      window.addEventListener("scroll", follow, { passive: true });
      window.addEventListener("resize", follow);
    };
    const hide = () => {
      tip.classList.remove("is-open");
      if (!follow) { return; }
      window.removeEventListener("scroll", follow);
      window.removeEventListener("resize", follow);
      follow = null;
    };
    trigger.addEventListener("mouseenter", show);
    trigger.addEventListener("mouseleave", hide);
    // The trigger carries tabindex, so the same evidence is reachable by
    // keyboard. focusin/focusout rather than focus/blur: they bubble.
    trigger.addEventListener("focusin", show);
    trigger.addEventListener("focusout", hide);
  });

  renderAll();
}

$(document).ready(boot);

export default { boot };
