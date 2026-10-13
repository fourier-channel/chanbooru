import { splitWords } from './utility';
import Cookie from './cookie';

// THE BLOCKLIST ENGINE (upstream's blacklist engine, kept under its upstream
// names; the person sees "blocklist" everywhere). It hides every post on the
// page that one of the person's blocks matches, and re-filters live when a
// block is added or removed -- no reload. One per page, started by
// BlocklistComponent in the header.
//
// The person's own list is the only filter (operator, 2026-10-13). There are
// no site-enforced rules, no per-rule off switch, no "show all" and no blur:
// a blocked post is hidden, and the way to see it again is to unblock it.
//
// Where the list lives: a signed-in person's on their account (the page
// hands it in; edits are saved through PATCH /modulation/settings); a
// signed-out viewer's in this browser's localStorage under STORAGE_KEY, sent
// with each edit so the server can normalise and check it. Every storage
// access is guarded: a browser that blocks storage still filters the page,
// and says it cannot keep the list.

const STORAGE_KEY = "blocklist";

// Surfaces that draw from a payload rather than from the marked elements --
// the landing carousel -- skip what the marks say and redraw on this. Said
// after every change to the marks: an apply, and a block added or removed.
// Only apply() said it, so a rule switched on left its picture on the
// carousel until the next slide, and for good while paused (found 2026-10-03).
function announceMarks() {
  document.dispatchEvent(new CustomEvent("danbooru:blacklist-applied"));
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || "";
}

// A post holds the set of blocks that match it. It is hidden while that set
// is not empty.
class Post {
  // @param {HTMLElement} post - The DOM element representing the post.
  // @param {Blacklist} blacklist - The engine that this post belongs to.
  constructor(post, blacklist) {
    this.post = post;
    this.blacklist = blacklist;
    this.rules = new Set();

    this.post.classList.add("blacklist-initialized");
    this.post.post = Alpine.reactive(this); // Attach the post object to the DOM element for access with `$("#post_123").get(0).post`
  }

  // Re-apply every block to the post when a block or the post changes.
  applyRules() {
    this.score = parseInt(this.post.getAttribute("data-score"));
    this.tags = new Set([
      ...splitWords(this.post.getAttribute("data-tags")),
      ...splitWords(this.post.getAttribute("data-flags")).map(s => `status:${s}`),
      `rating:${this.post.getAttribute("data-rating")}`,
      `uploaderid:${this.post.getAttribute("data-uploader-id")}`,
    ]);

    this.blacklist.rules.forEach(rule => rule.apply(this));
    this.update();
  }

  // @returns {Boolean} - True if at least one block matches the post.
  get blacklisted() {
    return this.rules.size > 0;
  }

  update() {
    if (this.blacklisted) {
      this.hide();
    } else {
      this.show();
    }
  }

  hide() {
    this.post.classList.add("blacklist-initialized", "blacklisted-active", "blacklisted-hidden");

    // XXX We should be calling pause() on the video player component instead of on the <video> itself, but the component may not be initialized yet.
    let video = this.post.querySelector(".video-component video");
    if (video) {
      video.pause();
      video.currentTime = 0;
    }
  }

  show() {
    this.post.classList.remove("blacklisted-active", "blacklisted-hidden");
    this.post.classList.add("blacklist-initialized");
  }
}

// A rule is one block: one line of the list, which may AND several tags,
// exempt with -, offer alternatives with ~, and cap a score with score:<N.
class Rule {
  // @param {Blacklist} blacklist - The engine that this rule belongs to.
  // @param {String} string - The rule string, as the server normalised it.
  // @param {Boolean} locked - A locked block cannot be removed until it is
  //   unlocked (the server refuses it as well; the panel hides its remove).
  constructor(blacklist, string, { locked = false } = {}) {
    this.blacklist = blacklist;
    this.string = string;
    this.locked = locked;
    this.tags = splitWords(string);
    this.require = [];
    this.exclude = [];
    this.optional = [];
    this.posts = new Set();
    this.min_score = null;

    this.tags.forEach(tag => {
      if (tag.charAt(0) === '-') {
        this.exclude.push(tag.slice(1));
      } else if (tag.charAt(0) === '~') {
        this.optional.push(tag.slice(1));
      } else if (tag.match(/^score:<.+/)) {
        var score = tag.match(/^score:<(.+)/)[1];
        this.min_score = parseInt(score);
      } else {
        this.require.push(tag);
      }
    });
  }

  // @returns {Number} - How many distinct posts on this page the block hides.
  get matchCount() {
    return new Set([...this.posts].map(post => post.post.dataset.id)).size;
  }

  // @param {Post} post - The post to check against this rule.
  // @returns {Boolean} - True if the rule matches the post.
  match(post) {
    let score_test = this.min_score === null || post.score < this.min_score;

    return (this.require.every(tag => post.tags.has(tag)) && score_test)
      && (this.optional.length === 0 || this.optional.some(tag => post.tags.has(tag)))
      && !this.exclude.some(tag => post.tags.has(tag));
  }

  // Record whether this rule matches a single post. The caller updates the
  // post once every rule has had its say.
  apply(post) {
    if (this.match(post)) {
      this.posts.add(post);
      post.rules.add(this);
    } else {
      this.posts.delete(post);
      post.rules.delete(this);
    }
  }
}

class Blacklist {
  // @param {HTMLElement} root - The root DOM element of the blocklist control.
  constructor(root) {
    this.root = root;
    this.rules = [];
    this.posts = [];
    this.error = "";
    this.signedIn = false;
    this.saving = Promise.resolve();
  }

  // @param {Array<{rule: String, locked: Boolean}>} blocks - The signed-in
  //   person's list, from the server. Ignored signed out: the list is read
  //   from this browser's storage instead.
  // @param {Boolean} signedIn
  initialize(blocks, { signedIn = false } = {}) {
    // Attach the engine to the root DOM element for access with `$("#blacklist-box").get(0).blacklist`
    this.root.blacklist = this;
    this.signedIn = signedIn;
    this.cleanupStorage();

    const stored = this.readStored() ?? [];
    this.setRules(signedIn ? blocks : stored);
    this.collectPosts();

    // A list kept while signed out joins the account on the first page after
    // signing in, adding only, and leaves this browser once it has.
    if (signedIn && stored.length > 0) {
      this.save({ op: "merge", blocks: stored }).then(ok => { if (ok) { this.writeStored(null); } });
    }

    // Signed out, another tab of this browser may change the list: follow it,
    // so this page never shows (or hides by) a block that is gone.
    if (!signedIn) {
      window.addEventListener("storage", event => {
        if (event.key === STORAGE_KEY || event.key === null) {
          this.setRules(this.readStored() ?? []);
          this.apply();
        }
      });
    }
  }

  // WHAT THE ENGINE CAN SEE, in one place.
  //
  // .modgal-card and .mod-blacklist-target are the Modulation gallery card and
  // the Modulation post view's media container -- the DEFAULT views of this
  // site, so a selector list that does not name them means the engine
  // matches nothing on almost every page. .modland-poolitem is the landing
  // carousel's hidden pool.
  //
  // Read by collectPosts(), which initialize() and rescan() both use. One
  // definition, because a selector that is right in one place and stale in
  // another silently stops filtering the surface it forgot.
  static POST_SELECTOR = ".post-preview, .image-container, #c-comments .post, .mod-queue-preview.post-preview, .modgal-card, .mod-blacklist-target, .modland-poolitem";

  // Re-read the page and apply the CURRENT rules to it.
  //
  // For a surface that replaces its matchable elements after load -- the
  // landing carousel swaps its hidden pool whenever it pulls a fresh set --
  // where the rules have not changed and the elements have.
  rescan() {
    this.collectPosts();
  }

  collectPosts() {
    // Posts from an earlier scan may have left the page; the pills count only
    // what this scan finds.
    this.rules.forEach(rule => rule.posts.clear());
    this.posts = $(Blacklist.POST_SELECTOR).toArray().map(post => new Post(post, this));
    this.apply();
  }

  // Apply all rules to all posts.
  apply() {
    this.posts.forEach(post => post.applyRules());
    announceMarks();
  }

  // Replace the rules with a list, keeping the Rule object of every block
  // that is still there, and re-filter the page.
  setRules(blocks) {
    const kept = new Map(this.rules.map(rule => [rule.string, rule]));
    const next = blocks.map(({ rule, locked }) => {
      const existing = kept.get(rule);
      if (existing) {
        existing.locked = Boolean(locked);
        kept.delete(rule);
        return existing;
      }
      return new Rule(this, rule, { locked: Boolean(locked) });
    });

    // A block that left the list lets go of the posts it was hiding.
    kept.forEach(gone => gone.posts.forEach(post => post.rules.delete(gone)));
    this.rules = next;
  }

  get blocks() {
    return this.rules.map(rule => ({ rule: rule.string, locked: rule.locked }));
  }

  // @returns {Promise<Boolean>} - True once the block is on the list.
  add(text) {
    if (!String(text).trim()) {
      this.error = "Type a tag to block first, then press Enter or Block.";
      return Promise.resolve(false);
    }
    return this.save({ op: "add", rule: text });
  }

  remove(rule) {
    return this.save({ op: "remove", rule: rule.string });
  }

  setLocked(rule, locked) {
    return this.save({ op: locked ? "lock" : "unlock", rule: rule.string });
  }

  // Send one edit and re-filter the page with the list that comes back.
  // Edits are chained, so they reach the server in the order they were made.
  // A signed-out edit carries the list this browser holds when its turn
  // comes -- read from storage then, not this page's copy, so a tab opened
  // earlier never drops (or unlocks) a block another tab added since. Only
  // where storage is blocked does it fall back to this page's copy.
  //
  // @returns {Promise<Boolean>} - True if the edit was made.
  save(edit) {
    this.saving = this.saving.then(async () => {
      const blocklist = this.signedIn ? edit : { ...edit, list: this.readStored() ?? this.blocks };
      const response = await fetch("/modulation/settings", {
        method: "PATCH",
        credentials: "same-origin",
        headers: { "X-CSRF-Token": csrfToken(), "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ blocklist }),
      }).catch(() => null);
      if (!response) {
        this.error = "Could not reach the booru to save your blocklist. Check your connection, then try again.";
        return false;
      }
      const body = await response.json().catch(() => ({}));

      if (!response.ok || !Array.isArray(body.blocklist)) {
        this.error = body.error || `Your blocklist could not be saved (HTTP ${response.status}). Reload the page and try again.`;
        return false;
      }

      this.error = "";
      this.setRules(body.blocklist);
      if (!this.signedIn) { this.writeStored(this.blocks); }
      this.apply();
      return true;
    });
    return this.saving;
  }

  // @returns {Array<{rule, locked}>|null} - The list this browser holds
  //   (empty when there is none), or null when storage is blocked.
  readStored() {
    try {
      const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
      return Array.isArray(stored) ? stored.filter(b => b && typeof b.rule === "string") : [];
    } catch {
      if (!this.signedIn) {
        this.error = "This browser blocks site storage, so a signed-out blocklist cannot be kept here. Allow storage for this site, or sign in to keep it on your account.";
      }
      return null;
    }
  }

  // @param {Array|null} blocks - The list to keep, or null to forget it.
  writeStored(blocks) {
    try {
      if (blocks === null || blocks.length === 0) {
        localStorage.removeItem(STORAGE_KEY);
      } else {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(blocks));
      }
    } catch {
      if (!this.signedIn) {
        this.error = "This browser refused to store your blocklist, so it applies to this page only. Allow storage for this site, or sign in to keep it on your account.";
      }
    }
  }

  // @returns {Number} - How many distinct posts on this page are hidden.
  get blacklistedPostCount() {
    return new Set(this.posts.filter(post => post.blacklisted).map(post => post.post.dataset.id)).size;
  }

  // Tidy-up only: the old per-rule switches and box state upstream kept in
  // this browser mean nothing now, and the old "dab" cookie never did.
  cleanupStorage() {
    Cookie.remove("dab");
    try {
      Object.keys(localStorage).filter(key => key.startsWith("blacklist.")).forEach(key => localStorage.removeItem(key));
    } catch {
      // Storage blocked: there is nothing stored to tidy.
    }
  }
}

Blacklist.Post = Post;
Blacklist.Rule = Rule;

export default Blacklist;
