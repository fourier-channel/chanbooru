// The Creator Identity dashboard's script (creator_galleries/identity.html.erb;
// operator, 2026-11-05). Every form on the page works without it; it adds:
//
//   - POP OUT: after a warning, the dashboard in a menuless window of its
//     own (window.open popup=yes). While it is out, the main window shows a
//     note in its place. Its "Back to the main window" tells the opener and
//     closes; the opener also sees the window closed by its own frame (polled,
//     and asked again on focus). Either way the main window reloads, so it
//     shows what was done out there. When the opener never hears -- it was
//     reloaded itself, so it holds no handle on the window -- its Refresh
//     button and the note's link are the manual way back.
//   - THE SEARCH, in place: the Claim Pool grows by the rows the search
//     finds (fragment=pool), keeping the ticks already made.
//   - FOURIER'S TOURS (creator_identity_model.js): the first tour never ended
//     is offered on load, and either can be replayed from its button. How
//     each ended is the viewer's ModulationSetting "tours".
//
// Nothing here pushes the page about: the tour is a dock fixed over the
// page, a lit step is an outline, and the only thing that hides the page's
// sections is the viewer's own Pop out.
import Notice from "./notice";
import { FIRST_BUBBLE_MS, bubbleWait, tourSteps, tourToOffer } from "./creator_identity_model";

const POPUP_NAME = "creator-identity";
const DOCK_MESSAGE = "creator-identity:dock";

function saveTour(tour, ended, { keepalive = false } = {}) {
  return fetch("/modulation/settings", {
    method: "PATCH",
    headers: {
      "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') || {}).content || "",
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    credentials: "same-origin",
    keepalive,
    body: JSON.stringify({ tours: { [tour]: ended } }),
  }).then((r) => {
    if (!r.ok) { throw new Error(`HTTP ${r.status}`); }
  }).catch(() => Notice.error("Could not save how this tour ended, so Fourier may offer it again. Reload the page and finish or skip it once more."));
}

// --- pop out --------------------------------------------------------------

function popOut(root) {
  const url = root.dataset.popoutUrl;
  const sections = root.querySelectorAll(":scope > section");
  const popped = root.querySelector("[data-identity-popped]");
  let popup = null;
  let watch = null;

  // Coming back reloads the page, which drops the listeners with it.
  const dock = () => {
    clearInterval(watch);
    window.location.reload();
  };
  const onMessage = (e) => {
    if (e.origin === window.location.origin && e.source === popup && e.data === DOCK_MESSAGE) { dock(); }
  };
  const checkClosed = () => { if (popup && popup.closed) { dock(); } };

  const open = () => {
    const w = 560;
    const h = Math.min(900, window.screen.availHeight || 900);
    const x = window.screenX + window.outerWidth - w - 24;
    const y = window.screenY + 24;
    popup = window.open(url, POPUP_NAME, `popup=yes,width=${w},height=${h},left=${Math.max(0, x)},top=${Math.max(0, y)}`);
    if (!popup) {
      Notice.error("Your browser blocked the pop-out window. Allow pop-ups for this site, then press Pop out again; the dashboard stays here meanwhile.");
      return;
    }
    sections.forEach((section) => { section.hidden = true; });
    // A tour under way goes with the dashboard: the window out there offers it.
    root.dispatchEvent(new CustomEvent("identity:popped"));
    popped.hidden = false;
    window.addEventListener("message", onMessage);
    watch = setInterval(checkClosed, 500);
    window.addEventListener("focus", checkClosed);
  };

  const dialog = document.createElement("dialog");
  dialog.className = "creator-identity-dialog";
  dialog.innerHTML = `
    <form method="dialog">
      <p><strong>Pop out the dashboard?</strong></p>
      <p>It opens in a small window of its own, with no menus, so you can keep it open beside the site.
      Press Back to the main window in it, or close it, and the dashboard comes back here.</p>
      <div class="creator-identity-dialog-actions">
        <button value="cancel" class="button-outline-primary">Cancel</button>
        <button value="go" class="button-primary">Pop out</button>
      </div>
    </form>`;
  root.append(dialog);
  dialog.addEventListener("close", () => { if (dialog.returnValue === "go") { open(); } });

  const button = root.querySelector("[data-identity-popout]");
  button.hidden = false;
  button.addEventListener("click", () => { dialog.returnValue = ""; dialog.showModal(); });
  root.querySelector("[data-identity-bring-back]").addEventListener("click", () => {
    if (popup && !popup.closed) { popup.close(); }
    dock();
  });
}

// The window the dashboard popped out into: its way back, and links to the
// rest of the site opened in the main window, so this one stays the dashboard.
function poppedOut(root) {
  let opener = null;
  try {
    opener = (window.opener && !window.opener.closed && window.opener.location.origin === window.location.origin) ? window.opener : null;
  } catch (e) {
    opener = null; // an opener on another origin is not the page that popped this out
  }
  if (!opener) { return; }

  const back = root.querySelector("[data-identity-dock]");
  back.hidden = false;
  back.addEventListener("click", () => {
    opener.postMessage(DOCK_MESSAGE, window.location.origin);
    opener.focus();
    window.close();
  });
  root.querySelectorAll("[data-identity-main-link]").forEach((link) => {
    link.addEventListener("click", (e) => {
      e.preventDefault();
      opener.location.href = link.href;
      opener.focus();
    });
  });
}

// --- the Claim Pool's search ------------------------------------------------

function search(root) {
  const form = root.querySelector("[data-identity-search]");
  const pool = root.querySelector("[data-identity-pool]");
  if (!form || !pool) { return; }
  const empty = root.querySelector("[data-identity-pool-empty]");
  const status = root.querySelector("[data-identity-search-status]");

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const params = new URLSearchParams(new FormData(form));
    const query = (params.get("creator_q") || "").trim();
    if (query.length < 2) {
      status.textContent = "Type at least two letters of the name, then search.";
      return;
    }
    params.set("fragment", "pool");
    status.textContent = "Searching...";
    fetch(`${form.action}?${params}`, { credentials: "same-origin", headers: { Accept: "text/html" } })
      .then((r) => {
        if (!r.ok) { throw new Error(`HTTP ${r.status}`); }
        return r.text();
      })
      .then((html) => {
        const found = document.createElement("template");
        found.innerHTML = html;
        const shown = new Set([...pool.querySelectorAll("[data-name]")].map((row) => row.dataset.name));
        const fresh = [...found.content.querySelectorAll("[data-name]")].filter((row) => !shown.has(row.dataset.name));
        pool.append(...fresh);
        if (empty) { empty.hidden = pool.children.length > 0; }
        const all = found.content.querySelectorAll("[data-name]").length;
        if (all === 0) {
          status.textContent = `No creator name matches "${query}". Try part of it, or the whole name with its prefix (4chan_${query}).`;
        } else if (fresh.length === 0) {
          status.textContent = `Everything matching "${query}" is already in the pool.`;
        } else {
          status.textContent = `Added ${fresh.length} to the pool: tick the ones that are yours.`;
        }
      })
      .catch(() => {
        status.textContent = "";
        Notice.error("The search did not answer. Press Search again; if it keeps failing, reload the page.");
      });
  });
}

// --- Fourier's tours ----------------------------------------------------------

function tours(root) {
  const ctx = {
    linked: root.dataset.claimant === "true",
    linkable: root.dataset.linkable === "true",
    directMatch: root.dataset.directMatch === "true",
    ready: root.dataset.ready === "true",
    slug: root.dataset.gallery,
  };
  const ended = { creator_name: root.dataset.tourCreatorName, oc: root.dataset.tourOc };
  const reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const buttons = root.querySelectorAll("[data-identity-tour]");
  if (!buttons.length) { return; }

  const dock = document.createElement("div");
  dock.className = "creator-identity-tour";
  dock.hidden = true;
  dock.innerHTML = `
    <aside class="fc-say" aria-label="Fourier-chan" aria-live="polite"></aside>
    <div class="creator-identity-tour-actions">
      <button type="button" class="button-outline-primary button-sm" data-tour-skip>Skip tour</button>
      <button type="button" class="button-primary button-sm" data-tour-next></button>
    </div>`;
  document.body.append(dock);
  const say = dock.querySelector(".fc-say");
  const next = dock.querySelector("[data-tour-next]");
  const portrait = root.dataset.portrait;

  let run = null; // { tour, steps, at, timers }

  const unlight = () => root.querySelectorAll("[data-identity-lit]").forEach((el) => el.removeAttribute("data-identity-lit"));
  const avatar = () => {
    const av = document.createElement("div");
    av.className = "fc-av";
    av.setAttribute("aria-hidden", "true");
    const img = document.createElement("img");
    img.src = portrait;
    img.alt = "";
    av.append(img);
    return av;
  };

  // Her lines for one step, said one after another as on the sign-in pages:
  // every bubble holds its place from the start and only fades in, and the
  // avatar moves down to the one she is saying.
  const speak = (lines) => {
    run.timers.forEach(clearTimeout);
    run.timers = [];
    say.replaceChildren(...lines.map((text) => {
      const line = document.createElement("div");
      line.className = "fc-line";
      const bubble = document.createElement("p");
      bubble.className = "fc-bubble";
      bubble.textContent = text;
      line.append(bubble);
      return line;
    }));
    const rows = [...say.children];
    const av = avatar();
    if (reduced) {
      rows.at(-1).setAttribute("data-speaks", "");
      rows.at(-1).prepend(av);
      return;
    }
    rows.forEach((row) => row.setAttribute("data-fc-pending", ""));
    av.setAttribute("data-fc-pending", "");
    say.setAttribute("data-fc-play", "");
    rows[0].prepend(av);
    rows[0].setAttribute("data-speaks", "");
    const line = (n) => {
      if (n > 0) {
        const from = av.getBoundingClientRect().top;
        rows[n - 1].removeAttribute("data-speaks");
        rows[n].prepend(av);
        rows[n].setAttribute("data-speaks", "");
        const dy = from - av.getBoundingClientRect().top;
        av.animate([{ transform: `translateY(${dy}px)` }, { transform: "translateY(0)" }], { duration: 280, easing: "cubic-bezier(.2,.8,.2,1)" });
      } else {
        av.removeAttribute("data-fc-pending");
      }
      rows[n].removeAttribute("data-fc-pending");
      if (n + 1 < rows.length) { run.timers.push(setTimeout(() => line(n + 1), bubbleWait(rows[n].textContent))); }
    };
    run.timers.push(setTimeout(() => line(0), FIRST_BUBBLE_MS));
  };

  const show = () => {
    const step = run.steps[run.at];
    unlight();
    const target = step.target && root.querySelector(`[data-identity-step="${step.target}"]`);
    if (target) {
      target.setAttribute("data-identity-lit", "");
      target.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
    }
    next.textContent = step.next;
    speak(step.lines);
  };

  const finish = (how) => {
    const { tour } = run;
    run.timers.forEach(clearTimeout);
    run = null;
    unlight();
    dock.hidden = true;
    if (how) {
      ended[tour] = how;
      saveTour(tour, how);
    }
  };

  const start = (tour, offer) => {
    if (run) { finish(null); }
    run = { tour, steps: tourSteps(tour, ctx, { offer }), at: 0, timers: [] };
    dock.hidden = false;
    show();
  };

  next.addEventListener("click", () => {
    const step = run.steps[run.at];
    if (run.at + 1 < run.steps.length) {
      run.at += 1;
      show();
    } else {
      finish(step.record ? "done" : null);
    }
  });
  dock.querySelector("[data-tour-skip]").addEventListener("click", () => finish("skipped"));
  // Escape skips the tour on show, never one meant for an open dialog.
  document.addEventListener("keydown", (e) => {
    if (run && e.key === "Escape" && !dock.hidden && !document.querySelector("dialog[open]")) { finish("skipped"); }
  });
  root.addEventListener("identity:popped", () => { if (run) { finish(null); } });

  // Sending a ticked name during the name tour is its end: she said so.
  const pool = root.querySelector("[data-identity-pool-form]");
  if (pool) {
    pool.addEventListener("submit", () => {
      if (run && run.tour === "creator_name" && pool.querySelector("input[name='claim_tag[]']:checked:not([disabled])")) {
        run.timers.forEach(clearTimeout);
        saveTour("creator_name", "done", { keepalive: true });
      }
    });
  }

  buttons.forEach((button) => {
    button.hidden = false;
    button.addEventListener("click", () => start(button.dataset.identityTour, false));
  });
  const offered = tourToOffer(ended, ctx);
  if (offered) { start(offered, true); }
}

function initIdentity(root) {
  if (root.dataset.popout === "true") {
    poppedOut(root);
  } else if (typeof window.open === "function" && typeof HTMLDialogElement === "function") {
    popOut(root);
  }
  search(root);
  // The tour plays in one window: the main one, or the popped-out one.
  tours(root);
}

$(() => document.querySelectorAll("#creator-identity").forEach(initIdentity));

export default { initIdentity };
