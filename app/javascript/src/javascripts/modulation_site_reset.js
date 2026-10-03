import Notice from "./notice";

// Hard refresh and purge: the rectangle at the right end of the Modulation
// header (operator, 2026-10-03). Markup and the reasons are in
// modulation_navbar_component.html.erb.
//
// HARD REFRESH fetches the page and every same-origin file it loaded past the
// browser's cache, then reloads onto the fresh copies -- Ctrl+Shift+R, from a
// button, which matters because inside Technetium's frame the browser's own
// reload belongs to the parent page.
//
// PURGE signs out of the booru and of the gate's session on this host, has the
// server expire the gate's cookie and send Clear-Site-Data for this origin's
// cache and storage, clears what script can reach itself (in case the header is
// not honoured), and reloads. It asks first, in place.

const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || "";

function hardRefresh() {
  const urls = [location.href];
  for (const e of performance.getEntriesByType?.("resource") || []) {
    if (e.name.startsWith(`${location.origin}/`)) { urls.push(e.name); }
  }
  Promise.all(urls.map((u) => fetch(u, { cache: "reload", credentials: "same-origin" }).catch(() => null)))
    .then(() => location.reload());
}

async function purge() {
  const post = (url, method = "POST") => fetch(url, {
    method,
    credentials: "same-origin",
    headers: { "X-CSRF-Token": csrf(), Accept: "application/json" },
  });
  const failed = [];
  // Each step on its own: a failure in one must not keep the others from
  // running, and must be said rather than swallowed.
  for (const [label, run] of [
    ["sign out of the booru", () => post("/session", "DELETE")],
    ["end the gate's session", () => post("/fourier/logout")],
    ["clear this site's data on the server's side", () => post("/modulation/purge")],
  ]) {
    try {
      const r = await run();
      if (!r.ok && r.status !== 303 && r.status !== 302) { failed.push(`${label} (HTTP ${r.status})`); }
    } catch {
      failed.push(`${label} (no answer)`);
    }
  }
  try { localStorage.clear(); } catch { /* storage disabled: nothing to clear */ }
  try { sessionStorage.clear(); } catch { /* same */ }
  for (const c of document.cookie ? document.cookie.split(";") : []) {
    const name = c.split("=")[0].trim();
    if (name) { document.cookie = `${name}=; Max-Age=0; path=/`; }
  }
  try {
    if (window.caches) { await Promise.all((await caches.keys()).map((k) => caches.delete(k))); }
  } catch { /* Cache API unavailable here: the server's Clear-Site-Data covers it */ }
  if (failed.length) {
    Notice.error(`Purge finished, but these steps did not: ${failed.join("; ")}. Purge again, or sign out from Manage Session.`);
    setTimeout(() => location.reload(), 4000);
    return;
  }
  location.reload();
}

function boot() {
  const box = document.querySelector(".modnav-reset");
  if (!box || box.dataset.booted) { return; }
  box.dataset.booted = "1";
  const confirmBox = box.querySelector(".modnav-reset-confirm");
  const purgeBtn = box.querySelector('[data-act="purge"]');

  const close = () => { confirmBox.hidden = true; };
  box.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "hard-refresh") { hardRefresh(); }
    if (act === "purge") {
      confirmBox.hidden = !confirmBox.hidden;
      if (!confirmBox.hidden) { confirmBox.querySelector('[data-act="purge-cancel"]').focus(); }
    }
    if (act === "purge-cancel") { close(); purgeBtn.focus(); }
    if (act === "purge-go") {
      e.target.disabled = true;
      e.target.textContent = "Purging...";
      purge();
    }
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !confirmBox.hidden) { close(); purgeBtn.focus(); } });
  document.addEventListener("click", (e) => { if (!confirmBox.hidden && !box.contains(e.target)) { close(); } });
}

$(document).ready(boot);

export default { boot };
