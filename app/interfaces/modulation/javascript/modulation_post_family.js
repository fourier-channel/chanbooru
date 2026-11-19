// The post family's strips (ModulationPostFamilyComponent) are drawn by the
// server for the post the page was opened on. The post view steps to other
// posts client-side (pushState, popstate) and never redraws them, so after a
// step they would offer one post's parent and children under another post.
//
// Fail closed: the section shows only while the address is its own post's.
// It is hidden, not removed, so walking back to that post shows it again.
// Watched through the viewer's own redraws (it renders, then pushes the
// address, in one task, so the observer reads the new address) and popstate.

export function isOwnPath(pathname, postId) {
  const m = /^\/posts\/(\d+)\/?$/.exec(pathname || "");
  return Boolean(m) && m[1] === String(postId);
}

function boot() {
  const family = document.querySelector("section.modfamily[data-post-id]");
  if (!family) { return; }

  const check = () => { family.hidden = !isOwnPath(window.location.pathname, family.dataset.postId); };
  check();
  window.addEventListener("popstate", check);

  const root = document.getElementById("modulation-root");
  if (root) { new MutationObserver(check).observe(root, { childList: true, subtree: true }); }
}

// No jQuery, so the pure check above runs under Node's test runner
// (test/javascript/modulation_post_family.test.mjs), where there is no page.
if (typeof document !== "undefined") {
  if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", boot); } else { boot(); }
}

export default { boot, isOwnPath };
