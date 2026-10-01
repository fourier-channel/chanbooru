// THE CREATOR'S LAMP, for a surface that shows artist pills outside the post
// page: the landing carousel and the landing console. A pill's dot is lit
// while that creator is ACTIVE -- a post of theirs, direct or attributed
// through sample or the tunnel, inside the server's creator_active_window --
// and is re-read while the page is visible, because a lamp lit at render and
// never re-read stays lit for as long as the page is left open: a lamp that
// lies. The post page has the same poll inline (modulation_post_component).
//
// A pill is `.mod-pill--cat-artist[data-tag]`; paint() lights one as it is
// built, so a pill made after the last poll is right at once, and refresh()
// repaints every pill under the root when the answer changes.
const MAX_NAMES = 100; // CreatorActivity::MAX_NAMES

export default class CreatorLamps {
  // @param root [Element] where the pills are
  // @param live [Array<String>] the names lit at render
  // @param windowSeconds [Number] the server's window, for the poll and the hover
  // @param names [Function] the names to ask about; by default every pill under root
  constructor(root, { live = [], windowSeconds = 300, names = null } = {}) {
    this.root = root;
    this.live = new Set(live);
    this.windowSeconds = windowSeconds;
    this.names = names || (() => Array.from(new Set(Array.from(root.querySelectorAll(".mod-pill--cat-artist[data-tag]"), (el) => el.dataset.tag))));
  }

  title(on) {
    const minutes = Math.round(this.windowSeconds / 60);
    return on ? `active: posted within the last ${minutes} min` : `no post in the last ${minutes} min`;
  }

  paint(el) {
    const on = this.live.has(el.dataset.tag);
    el.classList.toggle("is-live", on);
    el.title = this.title(on);
  }

  paintAll() {
    this.root.querySelectorAll(".mod-pill--cat-artist[data-tag]").forEach((el) => this.paint(el));
  }

  refresh() {
    const names = this.names().slice(0, MAX_NAMES);
    if (!names.length || document.hidden) { return; }
    fetch(`/modulation/creator_activity?tags=${encodeURIComponent(names.join(","))}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
      .then((d) => {
        if (!d || !Array.isArray(d.active)) { return; }
        this.live = new Set(d.active);
        if (d.window) { this.windowSeconds = d.window; }
        this.paintAll();
      })
      // Said, not swallowed: the lamps keep their last answer, and the console
      // is where someone looking at them would check why.
      .catch((e) => console.warn(`creator lamps: could not re-read /modulation/creator_activity (${e.message}); the lamps show the last answer`));
  }

  start() {
    this.paintAll();
    setInterval(() => this.refresh(), Math.max(15000, Math.round((this.windowSeconds * 1000) / 5)));
    document.addEventListener("visibilitychange", () => { if (!document.hidden) { this.refresh(); } });
    return this;
  }
}
