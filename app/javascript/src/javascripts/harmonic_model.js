// THE TUNER'S LINK MODEL: CreatorGalleryHarmonic.link, line for line, so the
// builder says what Save would say the moment a link is pasted (CREATOR_TUNER.md
// rev 3, sec 5). No DOM, no imports, no `window`: the registry
// (config/creator_harmonics.json) is handed in -- the page embeds it, and
// test/javascript/harmonic_model.test.mjs reads it from disk -- and both
// readers answer test/fixtures/files/harmonic_links.json alike.

// Characters a reader cannot see or that turn text around: controls, the soft
// hyphen, zero widths, bidi marks and overrides, the BOM.
// eslint-disable-next-line no-control-regex -- the controls are what it finds
const HIDDEN = /[\u{0}-\u{1f}\u{7f}-\u{9f}\u{ad}\u{61c}\u{200b}-\u{200f}\u{202a}-\u{202e}\u{2060}-\u{2064}\u{2066}-\u{2069}\u{feff}]/u;
// Spaces of every width, which no web address carries.
const SPACE = /[ \u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}]/u;
// What a path or query carries as itself (RFC 3986): an escape, or an
// unreserved, sub-delim or path character. Anything else is escaped.
const ESCAPED = /%[0-9A-Fa-f]{2}|[^A-Za-z0-9\-._~!$&'()*+,;=:@/?]/gu;
const UNRESERVED = /^[A-Za-z0-9\-._~]$/;
const REFUSED_HOSTS = [["shorteners", "link_shortener"], ["hubs", "link_hub"], ["invites", "link_invite"]];

// A pattern in the list is unanchored; it must match the whole string here.
const pattern = (source) => new RegExp(`^(?:${source})$`);

const refusal = (problem, vars = {}) => ({ problem, vars });

// A pattern's replacement with its groups (\1, \2) filled from a match.
const fill = (spelling, match) => spelling.replace(/\\(\d)/g, (_, n) => match[Number(n)] ?? "");

// A path or query with each character it cannot carry as itself escaped,
// each escape of one it can undone, and the rest in capitals: one spelling
// of every address (CreatorGalleryHarmonic.escape).
const escape = (part) => part.replace(ESCAPED, (found) => {
  if (/^%[0-9A-Fa-f]{2}$/.test(found)) {
    const char = String.fromCharCode(Number.parseInt(found.slice(1), 16));
    return UNRESERVED.test(char) ? char : found.toUpperCase();
  }
  return [...new TextEncoder().encode(found)].map((byte) => `%${byte.toString(16).toUpperCase().padStart(2, "0")}`).join("");
});

// What the server makes of what the editor sends, by Ruby's own character
// sets, not trim()'s: blank? is [[:space:]] alone, String#strip takes NUL and
// ASCII space off the ends, and CreatorGalleryLayout#whole is Integer(), which
// allows ASCII space around and one underscore between digits.
const BLANK = /^[\t\n\v\f\r \u{85}\u{a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}]*$/u;
const ENDS = /^[\0\t\n\v\f\r ]+|[\0\t\n\v\f\r ]+$/g;
const INTEGER = /^[\t\n\v\f\r ]*([+-]?[0-9]+(?:_[0-9]+)*)[\t\n\v\f\r ]*$/;
const present = (value) => value !== null && value !== undefined && value !== false && !BLANK.test(String(value));
export const strip = (text) => String(text ?? "").replace(ENDS, "");
const whole = (value) => {
  if (Number.isInteger(value)) { return value; }
  const digits = String(value ?? "").match(INTEGER)?.[1];
  return digits === undefined ? null : Number.parseInt(digits.replaceAll("_", ""), 10);
};

// Every cut a removal could sit at (CreatorHarmonicRemoval.prefixes): the
// link, it without its query, its origin, each whole-segment cut of its path.
export const prefixes = (url) => {
  const lower = url.toLowerCase();
  const base = lower.split("?")[0];
  const [, origin, path] = base.match(/^(https:\/\/[^/]*)(.*)$/);
  const segments = path.split("/").slice(1);
  return [...new Set([lower, base, origin, ...segments.map((_, i) => [origin, ...segments.slice(0, i + 1)].join("/"))])];
};

// FNV-1a, 64 bits, of a link's bytes: the removals as the page carries them
// (CreatorHarmonicRemoval.fingerprint), so it holds no list of what staff took down.
export const fingerprint = (text) => [...new TextEncoder().encode(text)]
  .reduce((hash, byte) => BigInt.asUintN(64, (hash ^ BigInt(byte)) * 0x100000001b3n), 0xcbf29ce484222325n)
  .toString(16).padStart(16, "0");

// @param removed Set of the removals' fingerprints
export const covered = (url, removed) => prefixes(url).some((cut) => removed.has(fingerprint(cut)));

// The registrable end of a host, what the smallest card must still show.
export const domain = (host) => host.split(".").slice(-2).join(".");

// @param registry the parsed config/creator_harmonics.json
// @return { sites, link(raw), sentence(key, vars) }
export function harmonicModel(registry) {
  const sites = registry.sites.map((site) => ({
    ...site,
    hostPattern: pattern(site.host),
    acceptPatterns: site.accept.map(pattern),
    postPatterns: site.posts.map(([source, profile]) => [pattern(source), profile]),
    canonicalPatterns: site.canonical.map(([source, spelling]) => [pattern(source), spelling]),
  }));
  const tracking = pattern(registry.tracking);

  // A pasted link, normalized: { url, host, site } or { problem, vars }.
  function link(raw) {
    const text = String(raw ?? "").toWellFormed().replace(/^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/g, "");
    if (text === "") { return refusal("link_blank"); }
    if (HIDDEN.test(text)) { return refusal("link_hidden"); }
    if (SPACE.test(text)) { return refusal("link_not_web"); }

    const [, scheme, rest] = text.match(/^([A-Za-z][A-Za-z0-9+.-]*):\/\/([\s\S]*)$/) ?? [];
    if (scheme?.toLowerCase() === "http") { return refusal("link_http"); }
    if (scheme?.toLowerCase() !== "https") { return refusal("link_not_web"); }

    const [, authority, tail] = rest.match(/^([^/?#]*)([\s\S]*)$/);
    if (authority.includes("@")) { return refusal("link_userinfo"); }
    if (authority.startsWith("[")) { return refusal("link_machine", { host: authority }); }

    const [, name, port] = authority.match(/^(.*?)(?::([^:]*))?$/);
    if (port && port !== "443") { return refusal("link_port", { port }); }

    // A full stop is a full stop however it is typed, as a browser reads it:
    // compatibility forms fold (NFKC), and the ideographic stop is a dot.
    let host = name.normalize("NFKC").toLowerCase().replaceAll("\u3002", ".").replace(/\.$/, "");
    // eslint-disable-next-line no-control-regex -- every ASCII character, controls included
    if (!/^[\x00-\x7f]*$/.test(host)) {
      try {
        host = new URL(`https://${host}/`).hostname;
      } catch {
        return refusal("link_not_web");
      }
    }
    if (!/^[a-z0-9.-]+$/.test(host)) { return refusal("link_not_web"); }
    if (host === "localhost" || host.endsWith(".localhost") || /^[0-9.]+$/.test(host) || !host.includes(".")) {
      return refusal("link_machine", { host });
    }

    const bare = tail.replace(/#[\s\S]*$/, "");
    const mark = bare.indexOf("?");
    const path = escape(mark < 0 ? bare : bare.slice(0, mark)).replace(/\/{2,}/g, "/");
    if (path.split("/").some((segment) => segment === "." || segment === "..")) { return refusal("link_dots"); }

    const query = escape(mark < 0 ? "" : bare.slice(mark + 1)).split("&")
      .filter((pair) => pair !== "" && !tracking.test(pair.split("=")[0].toLowerCase()))
      .join("&");
    const labels = host.split(".");
    if (labels.length > 2 && registry.host_prefixes.includes(labels[0])) { host = labels.slice(1).join("."); }
    host = registry.host_aliases[host] ?? host;

    const refused = REFUSED_HOSTS.find(([list]) => registry[list].some((d) => host === d || host.endsWith(`.${d}`)));
    if (refused) { return refusal(refused[1], { host }); }

    const site = sites.find((entry) => entry.hostPattern.test(host));
    if (!site) { return refusal("link_unlisted", { host }); }

    const spelled = `${host}${path.replace(/\/$/, "")}${query ? `?${query}` : ""}`;
    const rule = site.canonicalPatterns.map(([source, spelling]) => [spelled.match(source), spelling]).find(([found]) => found);
    const target = rule ? fill(rule[1], rule[0]) : spelled;
    host = target.match(/^[^/?]+/)[0];
    const url = `https://${target}`;
    const length = [...url].length;
    if (length > registry.limits.url) { return refusal("link_long", { length, max: registry.limits.url }); }

    const hit = site.postPatterns.map(([source, back]) => [target.match(source), back]).find(([post]) => post);
    if (hit?.[1]) { return refusal("link_post_profile", { host, profile: fill(hit[1], hit[0]) }); }
    if (hit) { return refusal("link_post", { host, shape: site.shape }); }
    if (!site.acceptPatterns.some((source) => source.test(target))) { return refusal("link_shape", { site: site.name, shape: site.shape }); }

    return { url, host, site: site.key };
  }

  // A refusal's sentence, from the list's words.
  function sentence(key, vars = {}) {
    return registry.problems[key].replace(/%\{(\w+)\}/g, (_, name) => {
      if (!(name in vars)) { throw new Error(`The sentence ${key} needs ${name}.`); }
      return String(vars[name]);
    });
  }

  const byKey = new Map(sites.map((site) => [site.key, site]));
  const limits = registry.limits;
  const SETTINGS = [["focus_x", "focus x", limits.focus], ["focus_y", "focus y", limits.focus], ["zoom", "zoom", limits.zoom], ["shade", "shade", limits.shade]];

  // The owner's list as Save would answer it (CreatorGalleryLayout#plan_harmonics),
  // problem for problem and in its order. Each comes with the number of the
  // harmonic it is about (null for the list's own), and a site not on the
  // list with the host to ask for.
  //
  // @param entries the draft's harmonics, in order
  // @param stored Map of id => { url, host, site, staff_hidden }: the rows as saved
  // @param removed Set of the fingerprints of the links staff took down
  // @param stale (entry) => true when the server found its saved background no longer showable
  // @param cap the gallery's harmonic cap
  // @return [{ n, text, ask }]
  function problems(entries, { stored, removed, stale, cap }) {
    const say = (n, key, vars, ask = null) => ({ n, text: sentence(key, vars), ask });
    const numbered = entries.map((entry, i) => ({ entry, n: i + 1, row: present(entry.id) ? (stored.get(whole(entry.id)) ?? null) : {} }));
    const owned = numbered.filter(({ row }) => row && !row.staff_hidden);

    const checked = owned.map(({ entry, row, n }) => {
      // A row whose site left the list keeps its link while it is unchanged.
      const kept = row.url !== undefined && !byKey.has(row.site) && String(entry.url ?? "") === row.url;
      const found = kept ? { url: row.url, host: row.host, site: row.site } : link(entry.url);
      const title = [...strip(entry.title)];
      const subtitle = [...strip(entry.subtitle)];
      const taken = Boolean(found.url && covered(found.url, removed));
      const cta = present(entry.cta) ? entry.cta : null;
      const places = Object.fromEntries(registry.elements.filter((element) => element in (entry.places ?? {})).map((element) => [element, entry.places[element]]));
      const picture = present(entry.background_post_id);
      const gradient = present(entry.background_gradient) ? whole(entry.background_gradient) : null;
      const values = Object.fromEntries(SETTINGS.map(([key]) => [key, whole(entry[key])]));
      const within = (value, [min, max]) => value !== null && value >= min && value <= max;
      // At the smallest size (160 px) a row holding a centre and a side place
      // splits into thirds of the safe area, and the host must keep its domain.
      const hostRow = ["mark", "title", "host"].map((element) => places[element]).filter(present).map(String)
        .filter((place) => place[0] === String(places.host ?? "")[0]);
      const split = hostRow.some((place) => place[1] === "c") && hostRow.some((place) => place[1] !== "c");
      const fitted = found.host ? domain(found.host) : null;
      const found_ = [
        found.problem && say(n, found.problem, { n, ...found.vars }, found.problem === "link_unlisted" ? found.vars.host : null),
        taken && say(n, "link_removed", { url: found.url.slice("https://".length) }),
        !title.length && say(n, "title_blank", { n, max: limits.title }),
        title.length > limits.title && say(n, "title_long", { n, length: title.length, max: limits.title }),
        subtitle.length > limits.subtitle && say(n, "subtitle_long", { n, length: subtitle.length, max: limits.subtitle }),
        cta && !registry.ctas.some(([key]) => key === cta) && say(n, "cta", { n, value: `"${cta}"`, allowed: registry.ctas.map(([key]) => key).join(", ") }),
        ...registry.elements.filter((element) => !(element === "mark" && !present(places[element])) && !registry.places.includes(places[element]))
          .map((element) => say(n, "place", { n, element, value: `"${places[element] ?? ""}"`, allowed: registry.places.join(", ") })),
        picture && present(entry.background_gradient) && say(n, "background_both", { n }),
        !picture && present(entry.background_gradient) && !registry.gradients.some(([key]) => key === gradient) &&
          say(n, "gradient", { n, value: `"${entry.background_gradient}"`, allowed: registry.gradients.map(([key, name]) => `${key} (${name})`).join(", ") }),
        picture && (whole(entry.background_post_id) === null || stale(entry)) && say(n, "background_stale", { n }),
        ...(picture ? SETTINGS : []).filter(([key, , range]) => !within(values[key], range))
          .map(([key, setting, [min, max]]) => say(n, "range", { n, setting, value: present(entry[key]) ? String(entry[key]) : "empty", min, max })),
        picture && within(values.shade, limits.shade) && values.shade < limits.shade_floor && say(n, "shade_floor", { n, value: values.shade, floor: limits.shade_floor }),
        fitted && split && fitted.length * 6.6 > (160 * 0.86) / 3 && say(n, "host_fit", { n, domain: fitted }),
      ].filter(Boolean);
      return { n, url: found.url, site: found.site, counts: entry.shown !== false && byKey.has(found.site) && !taken, problems: found_ };
    });

    const pages = Object.values(Object.groupBy(checked.filter(({ url }) => url), ({ url }) => url)).find((group) => group.length > 1);
    // The later of the first two support links is the one refused.
    const [first, second] = checked.filter(({ site }) => byKey.get(site)?.support);
    const counting = checked.filter(({ counts }) => counts).length;
    const twice = Object.values(Object.groupBy(numbered.filter(({ row }) => row?.url !== undefined), ({ entry }) => whole(entry.id))).find((listed) => listed.length > 1);
    const leftOut = [...stored.values()].filter((row) => row.staff_hidden && !numbered.some((x) => x.row === row)).length;
    const rows = entries.length + leftOut;
    const over = (count, most) => (count - most === 1 ? "one" : count - most);
    const all = [
      ...numbered.filter(({ row }) => !row).map(({ n }) => say(n, "unknown", { n })),
      twice && say(twice[1].n, "same_row", { a: twice[0].n, b: twice[1].n }),
      ...checked.flatMap(({ problems: found }) => found),
      pages && say(pages[1].n, "duplicate", { a: pages[0].n, b: pages[1].n }),
      second && say(second.n, "support_twice", { a: second.n, b: first.n, site_a: byKey.get(second.site).name, site_b: byKey.get(first.site).name }),
      counting > cap && say(null, "cap", { count: counting, cap, over: over(counting, cap) }),
      rows > limits.rows && say(null, "rows", { count: rows, max: limits.rows, over: over(rows, limits.rows) }),
    ].filter(Boolean);
    return all.filter((problem, i) => all.findIndex((other) => other.text === problem.text) === i);
  }

  return { sites, link, sentence, problems };
}
