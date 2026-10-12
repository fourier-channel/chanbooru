<!-- phase:S-69015a -->
# Content gating on chanbooru

Every rule that decides whether a viewer gets an account, sees a post, an
image, or a tag. First written 2026-08-30 from the code and the running site;
re-traced 2026-09-11; re-traced 2026-10-12 against chanbooru's `chanbooru`
branch, fourier-auth and its edge Worker, production's own config files and
production's database.

CANON. Lives in `fourier-basis`; hydrated into chanbooru and rendered into the
public site by `coherence hydrate`. This file is the only copy anyone edits.

**Where the code is.** chanbooru's fork lives on the `chanbooru` branch. Its
`master` is an untouched upstream Danbooru mirror, and reading it reports the
fork's rules as missing. The fork's policy VALUES (the gated tag list, the
browsing levels, the banished tags) live in `danbooru_local_config.rb`, which
is untracked in chanbooru; production mounts the canon copy at
`fourier-basis/ops/hetzner/danbooru/danbooru_local_config.rb`, and the creator
prefix list at `ops/hetzner/danbooru/creator_prefixes.yml`. Both were
byte-identical to production on 2026-10-12.

There are twelve independent gates. They are not layers of one system and they
do not share a switch: a post can pass eleven and be withheld by the twelfth.
When a user reports "this page doesn't work", the question is *which gate*,
and this document exists so that question has an answer that does not require
reading Ruby.

Gates 0 to 6 are the original Rails gates, numbered in the order they were
built. Gate 7 is different in kind: it lives at Cloudflare and at the reverse
proxy, and it acts before the application sees the request at all. Gates 8 to
11 were added after 2026-09-12 and are numbered in the order they were built.
The numbers are stable on purpose: the access matrix in fourier-coherence
(`coherence/accessmatrix.py`) labels its probes by them.

## How to read the matrices

Every section ends with a matrix: one example tag from the section, and what
each kind of viewer gets. The columns are always the same:

| column | who |
|---|---|
| Signed out | no booru session, no API key and no fourier session |
| Restricted | a signed-in account at level 10, where a signup flagged as suspicious starts |
| Member | level 20 |
| Gold+ | levels 30 to 37: Gold, Platinum, Builder, Contributor, Approver |
| Moderator | level 40 |
| Admin | levels 50 and 60 (Admin, Owner) with `reveal_banished` OFF, the default |
| Admin, reveal | an admin who has switched `reveal_banished` ON in their own settings |

And the cells:

| cell | meaning |
|---|---|
| **sees** | the post is listed and its image loads |
| **listed, no image** | the post appears in results; its image is withheld |
| **hidden** | absent from search, counts, paging and neighbours; its page and image answer as if it did not exist |
| **capped** | sees it, under gate 2's browsing cap |

A viewer the columns do not cover (the post's creator, the pipeline's bots, a
reader of a published page) is named below the matrix when a section treats
them differently.

**Uploaders are always bots.** Every post on this booru is made by the
pipeline -- the `sample` account (4chan) or the `tunnel` account (Matrix and
Discord) -- never by a person. Where the code says "the uploader can still see
its own post", that means the bot can keep working on a post the public cannot
see: tag it, jail it, release it. It never means a person sees anything.

## The distinction this site is built on

**A gate is unlocked, never bypassed.** An unlocked gate still runs and still has
an opinion -- it just says "okay". A bypassed gate has its opinion discarded.

That is not a stylistic preference. Every rule below evaluates for every viewer,
and qualifying viewers satisfy it rather than skipping it. `Post#visible?` is
`!safeblocked? && !levelblocked?(user) && !banblocked?(user)`, evaluated per
post per viewer; the query-level rules return an empty list of restrictions
when the viewer qualifies, rather than being conditionally omitted from the
query. The difference matters when something goes wrong: a gate that ran and
said yes can be asked why, and a gate that was skipped cannot.

**A hidden post answers nothing, by any door** (leak audits 2026-10-01 and
2026-10-02). `Post#hidden_from?` is one rule -- gates 1 (signed out), 4, 5, 8
and 9 -- and every route that names a post asks it: search, counts, the post
page, the image, post versions, favourites, pools, flags, commentary, related
tags, IQDB, the mod log. Adding a door that forgets to ask is the way this
breaks.

---

## 0. Getting an account -- signup tokens

    enable_signup?          false outside the test environment
    signup_requires_token?  true

41chan is not an open site. Until 2026-09-09 signup was closed outright and
accounts were made by hand. Now an admin issues a **signup token** that
permits one registration, several, or unlimited, and that can expire or be
revoked; the signup page asks for it, and a POST without a valid one is
refused by policy before any account is built. Redeeming the token and saving
the account are one transaction, so a token cannot be spent on a signup that
then fails and an account cannot be handed out on a token that ran out in
between. The model is MAS's registration tokens on the Matrix side,
deliberately, so both halves of the site work the same way.

An account so created starts at **Member** (`UserSignup#initial_level`), or at
**Restricted** when the signup is flagged: `new_user_verification?` is on, and
the signup comes from a banned IP, looks like a sockpuppet, reuses a recent IP
or comes through a proxy. `default_user_level` (Restricted) is the level of an
account made any other way.

**Example:** no tag -- this gate is about who exists, not what they see.

| | can register |
|---|---|
| holds a valid, unspent, unexpired token | yes, as Member; as Restricted if the signup is flagged |
| holds no token, or a spent, expired or revoked one | no |

---

## 1. Gated tags -- a property of the POST

`Danbooru.config.restricted_tags` marks material the site will not serve
casually. It classifies the **content**, not the viewer -- the question has
nothing to do with who is asking.

    loli  shota  toddlercon  child  toddler  baby  infant
    young  aged_down  age_regression  troll_jail

A post carrying any of these is `gated?`. Two different consequences follow,
and they are deliberately not the same rule:

**Signed-out visitors: the post does not exist.** `PostQuery#gated_metatags`
injects a negated term per gated tag into every query, so the post is excluded
from results, from the post COUNT, from the paginator and from the neighbour
lookups that drive post-to-post navigation. The image is refused too: the
media gate asks the booru as the reader (gate 3), and the booru says no.

**Signed in below Gold: the post is listed, the image is withheld.**
`Post#levelblocked?`. The browsing tier says "you may see this, but only if you
already know where it is"; gating says "you may not see this kind of thing at
all", and a rule of that shape is not satisfied by withholding the image while
still listing the post, its tags and its id. A signed-in viewer gets the
listing because for them there is something to do about it -- ask for a level.

Two unlocks for people, each on identity: a creator's named allow (gate 9)
lifts this gate for that viewer -- never for a signed-out one; and a live
published page (gate 11) shows its own images. The uploading bot is unaffected
by this gate, so it can keep working on the post.

`troll_jail` is on this list, but a jailed post is also DELETED, so gates 4 and
5 decide it long before this one does.

**Example: `loli`**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| a post tagged `loli` | hidden | listed, no image (capped) | listed, no image | sees | sees | sees | sees |

Also **sees**: a signed-in viewer the post's creator has named (gate 9);
anyone reading a live published page that shows it (gate 11).

---

## 2. Browsing tier -- a property of the VIEWER

    full_browsing_level           MEMBER (20)
    restricted_browsing_per_page  20
    default_user_level            RESTRICTED (10)

A viewer at or above `full_browsing_level` browses without restriction. Below
it, a search returns at most 20 posts and ONE page -- `?limit=` is clamped to
the same ceiling and a second page is refused, or the restriction would be one
query parameter wide -- and there is no post-to-post navigation.

An ordinary signup starts AT the threshold, as Member (gate 0); only a signup
flagged as suspicious starts below it. Lifting a Restricted account is an
explicit act by staff.

**Retired sections** do not exist on this fork for anyone but the Owner:

    comments  comment_votes  forum_topics  forum_posts  forum_post_votes
    forum_topic_visits  notes  note_versions  media_assets  ai_tags
    media_metadata  metrics  jobs

Comments, notes and the forum were ruled out 2026-09-06; media assets and AI
tags were retired 2026-09-30 and media metadata, metrics and jobs 2026-10-01,
because each listed images by md5 that their posts' rules would have hidden
(14,506 jailed images among them). They 404 the way a hidden post does,
including on the JSON API, because a link removed from a nav is not a page
that is gone. The status page is admin-only (`status_page_visibility_level`).

**Example:** an ordinary post, `1girl solo`, with no gated tag.

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| the post | see gate 10 | capped: 20 results, one page | sees | sees | sees | sees | sees |
| a retired section | 404 | 404 | 404 | 404 | 404 | 404 (Owner: opens) | 404 (Owner: opens) |

---

## 3. Media -- the post's rules decide the image; R2 serves it

The booru stores metadata and references media it does not hold. Every image
request goes to a Cloudflare Worker at the edge, which asks fourier-auth for a
decision and streams the object from R2 itself, so no media byte crosses the
booru's host or the gate's. Only the Worker receives the presigned URL: it
proves itself with a shared edge secret, and a direct call to the gate gets the
decision with no URL (since 2026-10-01). Two routes, authorised differently:

| image | route | authorised by |
|---|---|---|
| a Matrix upload (the post's source is `mxc://...`) | `matrix.41chan.net/_matrix/client/v1/media/...` | membership of the Matrix room it was posted in |
| everything else | `/fourier/booru/<md5>.<ext>`, and the 180/360/720 thumbnails | the booru's own answer: may THIS reader see a post with this md5 |

**Booru images follow their post** (since 2026-10-01). The gate asks the booru
`posts.json?tags=md5:<md5>` first as a signed-out reader, and, only if that
says no and the request carries the reader's booru session, as that reader. So
an image is served exactly to the viewers its post is visible to: a gated
image to Gold and above, a deleted one to admins, a hidden one to nobody. A thumbnail of a hidden image is refused like the original. If the
booru cannot be reached the gate answers 503 -- it fails closed. A Matrix
upload's file is refused on this route unless a visible post that is not a
Matrix upload also holds it; it is served through the Matrix route only.

**Matrix images follow the room.** fourier-auth reads Synapse's own database --
which room the media was posted in, whether the viewer is joined -- and uses
Synapse's HTTP API only to validate the token. Synapse's authenticated-media
endpoint is NOT used: it authenticates the token but does not enforce room
membership. A booru account with no Matrix session, or one not in that room,
sees the post and not its image. The booru gets the fourier session with no
clicks from a signed-in Technetium through `POST /exchange`; the Matrix token
lives server-side and the browser holds an opaque session id.

**Never-posted media** (`unposted_media_assets_restricted?`, 2026-09-30): an
upload that never became a post is visible only to an admin (and to the bot
that uploaded it).

**Caching.** The Worker caches an ALLOW, never a denial, keyed on a hash of the
credential: 60 seconds for booru media, 240 for Matrix media. The gate keeps
its own 120-second cache of allows. So a just-jailed image can stay readable
for about three minutes, and a viewer who leaves a room can read its media for
about four.

`?w=` / `?h=` snap to the 180, 360 and 720 thumbnails rendered at upload; with
neither, the original is served; `?dl=1` serves it as an attachment.

**Not re-verified 2026-10-12:** that no user-posted media is held at rest on
the homeserver. That is the design; fourier-auth's MEDIA-URLS.md recorded it
as violated (2.3 GB held) on 2026-08-15, and nobody has checked since.

**Example 1: an image on a post tagged `1girl`, scraped from 4chan.** The
image follows the post's VISIBILITY, so this row is the post's own row from
gates 1, 4, 5, 8 and 9 -- and a signed-out visitor's image loads even where gate
10 keeps that post's PAGE closed to them. The booru answers a signed-out media
ask for any md5, provided it has exactly the shape fourier-auth sends
(`MembersOnly#anonymous_md5_ask?`).

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| the image | loads | loads | loads | loads | loads | loads | loads |

**Example 2: the image on a Matrix upload, creator tag `41chan_alice`, posted
in a room called #art.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| joined to #art, with a Matrix session | -- | loads | loads | loads | loads | loads | loads |
| not joined to #art, or no Matrix session | refused | refused | refused | refused | refused | refused | refused |

---

## 4. Deleted posts, and jailed posts

    deleted_post_visibility_level  ADMIN (50)

Below admin, `-status:deleted` is injected into every query, and a deleted
post's page answers as if it did not exist. This is deliberately tighter than
upstream, which hides deleted posts at the RENDER layer while still returning
and counting them. The one exception is the bot that uploaded the post, which
can still open it by direct link and keep working on it; no person can.

**Jailed means deleted** (operator, 2026-10-10). A jailed post is a deleted
post carrying `troll_jail`, and it follows exactly these rules -- there is no
second, jail-specific visibility layer. What the jail adds is that it is
withheld even from an admin until that admin switches `reveal_banished` on
(gate 5), and that it is released only from sampling's jail panel through
`POST /fourier_jail/release`: the booru's own tag pill refuses to take
`troll_jail` or the deletion off a jailed post. When the booru jails a post
itself (a moderator's pill, or gate 5's banished-tag failsafe), it reports the
jailing back to the panel through `GET /fourier_jail/release.json?since=`, so
no jailing is invisible to the place that controls it.

The `sample` bot is below Admin and cannot see deleted posts either: a lookup
for an image it has jailed returns nothing, which is why release goes through
the fork's own route.

Inherited from upstream and unchanged: a taken-down post is hidden from
viewers below Moderator, and a banned post from viewers below Approver.

**Example 1: a post a moderator deleted (`status:deleted`).**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| a deleted post | hidden | hidden | hidden | hidden | hidden | sees | sees |

**Example 2: a jailed post, tagged `troll_jail`.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| a jailed post | hidden | hidden | hidden | hidden | hidden | hidden | sees |

In both, the bot that uploaded the post (`sample` or `tunnel`) can still open
it by direct link; no person below Admin can. A published page never shows a
jailed image.

---

## 5. Banished tags and the blacklists

Three mechanisms. They are easy to conflate and they do different things.

**Banished tags** (`banished_tags`, 2026-09-04) do two things.

    guro scat gore ryona death corpse snuff dismemberment decapitation
    severed_head torture mutilation feces fart pooping

- **The words are removed** from tag listings, autocomplete and the tag panels
  for everyone, admins included, unless an admin has switched
  `reveal_banished` on. The operator's words: "hidden to me without a specific
  toggle on, and apparently missing/deleted from the server altogether for
  everyone else."
- **The post is jailed by the booru itself** (failsafe, 2026-09-24): a live
  post that GAINS a banished tag is tagged `troll_jail` and deleted in the same
  save, and the jailing is reported to sampling's jail panel. From then on gate
  4 governs it. A post released from the jail keeps its tags and is not
  re-jailed.

**The enforced blacklist** (`enforced_blacklist`, 2026-09-04) is applied to
every viewer, stored in no account and editable by nobody from the site. It
holds every banished tag plus four conjunctions, for example

    insect rating:e -pokemon_(creature) -pokemon_(species)

It is a view filter: it hides a matching post in listings and does not remove
it, so the post is still reachable by direct link. An admin with
`reveal_banished` on has the banished names taken out of their copy; the
conjunctions stay.

**The user blacklist** is the viewer's own, and it starts EMPTY (since
2026-09-04): a new account and a signed-out viewer have nothing in it. A line
is AND-ed and `-` excludes. Changing the default does not touch existing
accounts.

**Example 1: a post that gains `gore`.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| the post (now jailed) | hidden | hidden | hidden | hidden | hidden | hidden | sees |
| the word `gore` in tag lists and autocomplete | absent | absent | absent | absent | absent | absent | shown |

**Example 2: a post tagged `insect` and rated explicit, not Pokemon.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| in listings | filtered out | filtered out | filtered out | filtered out | filtered out | filtered out | filtered out |
| by direct link | its page (gate 10) | sees | sees | sees | sees | sees | sees |

---

## 6. Creator-private tags and generation data

Some tags on a post are PRIVATE: the ones derived from its creator's
generation prompt (`FourierTagSource` rows marked not public), and the
generation data itself (prompt, settings). Since 2026-09-29 the rule is one
sentence: **the creator decides, and until a control for sharing exists, the
creator alone sees them.** Not admins, not moderators, not the posting bot.
The creator is the Matrix account recorded for the post, matched to the
viewer's verified fourier identity -- never anything derived from the post's
tags.

The tags are withheld from the page itself, including the `data-tags`
attribute that client-side blacklists match against, because `post.tag_string`
still contains them. The consequence, and it is the correct trade: **a viewer's
blacklist cannot match a tag that viewer is not allowed to see.** Posts with no
private rows keep their full tag string.

This gate decides TAGS, not the image: the image follows the post's other
gates.

**Tag grants** are now edit-only. A grant is one user, one tag, one ability,
issued by staff from the user-edit console. `edit` lets the grantee edit the
one artist the tag names. `view` grants can no longer be created and are read
by nothing: a moderator could grant themselves `view` and read a creator's
prompts, and the creator-only rule closed that.

**Example: `masterpiece` on a Matrix upload by `41chan_alice`, present only
because her prompt contained it.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| the tag `masterpiece` on that post | absent | absent | absent | absent | absent | absent | absent |

Only **alice herself** sees it, and her generation data.

---

## 7. Reaching the site at all -- the edge challenge

Added 2026-09-12, in response to a scrape. This gate is not Rails, and a viewer
meets it before the application is involved.

**Every anonymous request to `booru.41chan.net` is given a Cloudflare Managed
Challenge.** A browser solves it invisibly and receives a `cf_clearance`
cookie; a signed-in reader carrying `_danbooru2_session` or `fourier_session`
is exempt and never sees it.

    http.host eq "booru.41chan.net"
    and http.request.method ne "POST"
    and not starts_with(http.request.uri.path, "/fourier/")
    and not http.request.uri.path in {"/robots.txt" "/favicon.ico"}
    and not http.cookie contains "_danbooru2_session="
    and not http.cookie contains "fourier_session="

That expression is the recorded copy; the live rule at Cloudflare was not read
on 2026-10-12. Behind it, Caddy refuses anything that holds none of the three
cookies (`@no_clearance` in the booru block, verified live 2026-10-12), with the
same path exemptions plus `/login` and `/users/new`. Caddy does not exempt POST
in general. It also lets Discord's link-preview bot (`Discordbot` user agent)
fetch `/`, so a link pasted into Discord shows a preview. The edge decides who
may pass; the origin rule makes that decision hold everywhere while it is still
spreading, because a Cloudflare rule does NOT reach every datacentre at once.

### Why each exemption exists

**POST is never challenged at the edge.** `POST /users` creates an account and
`POST /login` signs in, and challenging a POST can lose its body. A person is
challenged on the form PAGE, gets clearance, and the submit that follows is
untouched. **`/login` and `/users/new` are additionally exempt from the Caddy
rule** -- they are the only pages a person must reach before they can hold any
of the three cookies, so a propagation gap must never be able to break
registration. An earlier rule that caught `POST /users` broke signup for
sixteen hours on 2026-09-11; that is the mistake these exemptions exist to
prevent.

**`/fourier/`** carries the zero-click sign-in exchange and the media route,
which enforce their own rules (gate 3).

**`robots.txt`** stays readable so the refusal it declares can actually be read.

### What this gate costs and what it bought

It closes the booru to anyone who will not run a browser. That is acceptable
HERE and would not be on an open site. In the hour before the rule went in,
3,831 requests reached the booru through Cloudflare and none of them carried a
session cookie; traffic reaching the origin fell from about 400 requests per
minute to zero.

**A 403 on any booru page is this gate, not an outage.** Tell it apart by the
headers, never by the status code: a challenge carries `cf-mitigated` and
`server: cloudflare`, while a refusal from the application carries
`x-request-id` and `x-runtime`. **No command-line tool can pass it**; a health
check against the booru must read the origin directly or treat a
`cf-mitigated` 403 as healthy.

**Example:** any page, say the post page of a `1girl` post.

| | reaches the booru |
|---|---|
| a signed-in browser (booru or fourier session cookie) | yes, unchallenged |
| a signed-out browser | yes, after an invisible challenge; then gate 10 applies |
| curl, scripts, monitoring, crawlers | no: 403 `cf-mitigated` |
| Discord fetching a link preview of `/` | yes |

---

## 8. Creator prefixes -- whole sources hidden by default

Every post's creator tag carries a prefix that names where it came from
(operator, 2026-10-04): `4chan_` (scraped), `41chan_` (posted from Matrix),
`aichan_` (posted from the AIchan Discord). The prefix list
(`creator_prefixes.yml`, canon in fourier-basis) gives each prefix a
`visible_to`: `everyone` (the default), `members`, or `admins`.

**`aichan_` is admins only** (operator, 2026-10-07: "Did I forget to specify
that I needed aichan_ posts to be hidden by default?"). A post carrying a
creator tag under a hidden prefix is hidden at every door, and the tag NAMES
are withheld from the tag index and autocomplete too. Admins, and the editor
accounts that post for the pipeline (`tunnel`, `sample`), always see them.
Two ways out of the default: the creator, holding an APPROVED claim on exactly
that tag, sees their own posts; and an admin or that creator can RELEASE the
tag, after which those posts follow the ordinary rules. Creator prefix tags are
also locked: only an admin or an editor account may add or remove them.

**Example: `aichan_someone`, a Discord post.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| the post and image | hidden | hidden | hidden | hidden | hidden | sees | sees |
| the tag name in lists and autocomplete | absent | absent | absent | absent | absent | shown | shown |

Also **sees**: the `tunnel` and `sample` accounts; `someone`, once their claim
on `aichan_someone` is approved. Once the tag is released, the post follows
gates 1-7 and 9-10 like any other.

---

## 9. Creator visibility -- the creator's own panel

Built 2026-10-07 to 2026-10-09 (`docs/design/CREATOR_VISIBILITY.md`). A
creator chooses who sees their posts, creator-wide or per post:

- **public** -- whoever the site's other gates allow. Narrows nothing.
- **groups** -- members of the groups they list, plus people they name.
- **private** -- only people they name. No group ever opens private.

Plus named **allows** and **blocks**: **a block beats every allow**. A named
allow can also WIDEN, lifting gate 1's level block for that viewer -- never for
a signed-out viewer, a banned one, or a jailed post. A narrowed post is hidden
at query level and its page answers as a missing post. **Admins always see**,
and every admin view of a post its creator hid is written to the mod log.
Moderators can neither see nor act on it.

**Example: a post by `41chan_alice`, set to private, with bob named.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| a viewer alice has not named | hidden | hidden | hidden | hidden | hidden | sees (logged) | sees (logged) |
| bob, named, signed in | -- | sees | sees | sees | sees | sees | sees |

Also **sees**: alice herself. If alice blocks carol, carol is hidden from it
even when a group alice opened would otherwise let her in.

---

## 10. Signed out -- the anonymous default-deny

Since 2026-10-08 a signed-out visitor is refused EVERY page that is not on an
explicit list (`MembersOnly::ANONYMOUS_DOORS`), with the same 404 a hidden post
gets: a 403 or a redirect to the login page would confirm there is something
there. A route added later is closed until someone opens it on purpose, and a
test walks the whole routes table to hold that. Signed in means any of: a booru
session, an API key, or a verified Matrix identity through the fourier session
-- Technetium reads the booru with the last alone.

What stays open to a signed-out visitor, narrowed so none of it can enumerate
the booru:

- the landing page;
- `/posts` as the newest posts, or one featured creator's first page;
- a post's own page, only for a post the site has already shown signed-out
  viewers;
- promoted creator galleries.

Every listing that names posts (popular, favourites, pools, approvals,
commentary and the rest) is members only (2026-10-07). Everything here still
passes through gates 1-9: a gated post is not on the landing page either.

This gate closes PAGES, not images. A signed-out visitor who has an image's
URL can load it whenever its post is visible to signed-out viewers (gate 3),
whether or not the post's page is open to them; the booru keeps one narrow
door open for exactly that ask.

**Example: a `1girl` post that is not on the landing page.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Admin, reveal |
|---|---|---|---|---|---|---|---|
| its post page | 404 | capped | sees | sees | sees | sees | sees |
| its image, by URL | loads | loads | loads | loads | loads | loads | loads |
| the same post, once shown on the landing page or newest posts | sees | capped | sees | sees | sees | sees | sees |

---

## 11. Published pages -- a grant, not a loophole

Sampling's console (`sample.41chan.net`) can PUBLISH a thread as a page at
`sample.41chan.net/p/<hash>`: a random, unguessable link, which can expire.
The publication IS the operator's grant (ruling 2026-10-02), separate from the
booru's browsing rules. While the page is live, a reader holding it gets a
cookie for that page, and fourier-auth releases each image the page lists --
including one the booru would hide from that reader, such as a gated one.
**A jailed image is never released**: it is redacted from the page before it is
published. When the page expires or is taken down, the grant ends with it. If
sampling cannot be reached the gate answers 503.

The console itself is a separate door: `GET /verify?gate=sample` opens
`sample.41chan.net` only to a Matrix account at power level 70 or above in the
moderators room, and fails closed.

**Example: a published thread showing a `loli` image and a `troll_jail` image.**

| | holding the live link | after it expires |
|---|---|---|
| the `loli` image | sees, whoever they are, signed in or not | refused unless the viewer's own gates allow it |
| the `troll_jail` image | never on the page | refused |

---

## Diagnosing a report

| symptom | gate |
|---|---|
| a 403 with a `cf-mitigated` header, on any page | 7 -- the edge challenge, working |
| curl or a script gets 403 where a browser works | 7 -- no command-line tool can pass it |
| a signed-out visitor gets 404 on a page that loads when signed in | 10 -- the anonymous default-deny |
| cannot register | 0 -- no token, or a spent, expired or revoked one |
| a booru image is broken but the post page loads | 3 -- the image follows its post: deleted, jailed, gated or hidden for this reader. A 503 means the booru or sampling was unreachable |
| a Matrix upload's image is broken | 3 -- the viewer is not in the room it was posted in, or has no Matrix session |
| a just-jailed image still loads for a minute or two | 3 -- the decision caches, about three minutes at most |
| search returns exactly 20, and no second page | 2 -- browsing tier |
| a section 404s for everyone | 2 -- retired |
| a post 404s for one viewer and loads for another | 1 (signed out), 4 (deleted or jailed), 8 (creator prefix), 9 (creator visibility) or 10 (signed out) |
| an admin cannot see a jailed post | 4 and 5 -- switch `reveal_banished` on |
| post listed, image replaced by a prompt | 1 -- gated, signed in below Gold |
| a post is missing from a count as well as a page | 1, 4, 8 or 9 -- query level, not render level |
| a post is hidden in listings but opens by direct link | 5 -- the enforced blacklist or the viewer's own, which are view filters |
| a tag exists on a post but nowhere in autocomplete | 5 (banished) or 8 (a hidden prefix such as `aichan_`) |
| a Discord post is invisible to everyone but admins | 8 -- `aichan_` is admins only |
| a tag shows for one viewer and not another on the same post | 6 -- a creator-private tag: only the creator sees it |
| an image on a published page loads, the same image on the booru does not | 11 -- the published page is its own grant |

## Measured 2026-10-12

<!-- derived-ok: a dated measurement of production as it stood on 2026-10-12 -->
Read-only, from production's booru database. The 2026-09-11 figures are kept
beside them for the trend.

| | 2026-09-11 | 2026-10-12 |
|---|---|---|
| posts | 165,431 | 1,049,783 |
| posts carrying a gated tag | 34,762 (21%) | 260,948 (24.9%) |
| deleted posts | 3,581 | 23,438 |
| of those, jailed (`troll_jail`) | 3,500 | 10,014 |
| `aichan_` posts (gate 8) | -- | 40,492, of them 701 deleted |
| accounts | 8 | 18 |
| accounts at Restricted | 0 | 0 |
| signup tokens | 1 | 1, unlimited uses, redeemed 13 times |
| tag grants | 0 | 0 |

<!-- derived-ok: per-tag post counts on 2026-10-12, from the tags table -->
Gated tags by post count: `young` 225,226; `loli` 185,599; `child` 103,315;
`shota` 43,743; `troll_jail` 10,023; `aged_down` 4,846; `toddler` 675; `baby`
342; `age_regression` 29; `toddlercon` and `infant` match nothing. `young` and
`child` are ordinary words in the e621 taxonomy the hydra route emits, and they
appear in contexts that have nothing to do with what the list is for; they are
still worth reviewing. A tag that does not exist is inert, and listing tags the
taggers have not emitted yet is deliberate.

## What is scaffolded and lightly used

No account has ever sat at Restricted: thirteen people have registered with
the one token, and none was flagged, so each started at Member. The restricted
path is still covered by tests only, and a flagged signup is still the most
likely source of a first report about it. No tag
grant has been issued, and only `edit` grants can be. The creator visibility
panel (gate 9) and the creator tag release (gate 8) are built and tested, and
each will meet its first ordinary user after this was written.
