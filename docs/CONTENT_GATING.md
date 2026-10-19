<!-- phase:S-69015a -->
# Content gating on chanbooru

Every rule that decides whether a viewer gets an account, sees a post, an
image, or a tag. First written 2026-08-30 from the code and the running site;
re-traced 2026-09-11; re-traced 2026-10-12 against chanbooru's `chanbooru`
branch, fourier-auth and its edge Worker, production's own config files and
production's database; brought up to date 2026-10-13 for the flagged-tag
quarantine and the end of the reveal setting (chanbooru 98a61151d,
fourier-auth 05e6c6f and 7f2be3e, fourier-sampling 0891d0c).

**Deployed 2026-10-13**, in order: chanbooru fe304ff1b (the 15 banished tags
moved into the database, the config list removed), then fourier-auth 7f2be3e
with its edge Worker (version ac3c1b42), fourier-sampling c4b1efc and
fourier-tunnel 63a75f9 -- each read the booru's quarantine document on its
first poll (generation 4364f977). Then chanbooru 7e659c926 with the box config
of fourier-basis 344dddf: the enforced blacklist removed, the user's own list
renamed the blocklist and made the only filter. Then chanbooru bb3944ca6
(operator rulings 2026-10-13): gate 1 hides a gated post from everyone below
Gold, a creator's allow opens post and image, and a signed-out image follows
gate 10 like its page.
Then gate 3 for posts, switched on 2026-10-15 by the operator ("Yes, turn it
on"; fourier-basis 20aa523, chanbooru c2f4cd776): a Matrix post follows its
image's rooms, admins included.

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

There are thirteen independent gates. They are not layers of one system and
they do not share a switch: a post can pass twelve and be withheld by the
thirteenth.
When a user reports "this page doesn't work", the question is *which gate*,
and this document exists so that question has an answer that does not require
reading Ruby.

Gates 0 to 6 are the original Rails gates, numbered in the order they were
built. Gate 7 is different in kind: it lives at Cloudflare and at the reverse
proxy, and it acts before the application sees the request at all. Gates 8 to
12 were added after 2026-09-12 and are numbered in the order they were built.
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
| Admin | levels 50 and 60 (Admin, Owner) |
| Pipeline | the booru's system user and the posting bots (`sample`, `tunnel`), which uploaded every post |

And the cells:

| cell | meaning |
|---|---|
| **visible** | the post is listed and its image loads |
| **hidden** | absent from search, counts, paging and neighbours; its page and image answer as if it did not exist |
| **capped** | visible, under gate 2's browsing cap |

A viewer the columns do not cover (the post's creator, a reader of a published
page) is named below the matrix when a section treats them differently.

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
2026-10-02). `Post#hidden_from?` is one rule -- gates 1 (below Gold), 3 (a Matrix post
outside the viewer's rooms), 4, 5, 8, 9 and 12 -- and every route that names a post asks it: search, counts, the post
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

A post carrying any of these is `gated?`, and **below Gold it does not
exist**: signed out, Restricted and Member alike (operator, 2026-10-13: "Gate 1
should hide sensitive posts to Restricted and Member the same way it withholds
the image"). `PostQuery#gated_metatags` excludes it from results, from the post
COUNT, from the paginator and from the neighbour lookups that drive
post-to-post navigation; its page answers 404; and the image is refused with
it, because the media gate asks the booru as the reader (gate 3). One answer
for post and image: `Post#hidden_as_gated?`.

Until 2026-10-13 a signed-in viewer below Gold got the post LISTED with the
image withheld. That was the browsing tier's shape -- "you may see this, but
only if you already know where it is" -- applied to a rule that says "you may
not see this kind of thing at all", which withholding the image while listing
the post, its tags and its id does not satisfy.

**The names go with the posts.** Below Gold the gated tag names are absent from
tag listings, autocomplete, tag pages and the search sidebar (operator,
2026-10-14). They appear only on a post the viewer may open.

Who gets past it below Gold, each on identity: the post's **uploader** (the
pipeline's bots, so they keep working on their own posts); a viewer its
**creator lets in** (gate 9) -- named, a member of a group the creator listed,
or the creator -- which opens the post AND its image ("the named-creator-allow
should control both the post and the image"), never for a signed-out or banned
viewer or a jailed post; and anyone reading a live published page that shows
the image (gate 11). A viewer the creator lets in reads that post's gated tags
on the post itself, and nowhere else.

`troll_jail` is on this list, but a jailed post is also DELETED, so gates 4 and
5 decide it long before this one does.

**Example: `loli`**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| a post tagged `loli`, and its image | hidden | hidden | hidden | visible | visible | visible | visible |
| the word `loli` in tag lists and autocomplete | absent | absent | absent | shown | shown | shown | shown |

Also **visible** to: its uploader; a signed-in viewer its creator lets in
(gate 9), post and image; anyone reading a live published page that shows the
image (gate 11).

---

## 2. Browsing tier -- a property of the VIEWER

    full_browsing_level           MEMBER (20)
    restricted_browsing_per_page  20
    default_user_level            RESTRICTED (10)

A viewer at or above `full_browsing_level` browses without restriction. Below
it -- signed out, Matrix-only, Restricted -- EVERY list is at most 20 records
and ONE page: posts, and tags, users, wiki pages, artists, pools, favorites,
versions and the rest (operator, 2026-10-18: "every listing"). `?limit=` is
clamped to the same ceiling and a second page is refused, or the restriction
would be one query parameter wide, and there is no post-to-post navigation
(`show_seq`, the pool and favorite group bars, the post view's neighbours). A
cursor of any kind is a second page: `page=a<id>`/`b<id>`, the gallery
window's `anchor=` and `before=`, and its `variant=window` chunks are refused
alike, with 410 (a signed-out viewer meets the default-deny's 404 first on any
door not open to them, gate 10).

The limit is asked of the user in one place -- `User#can_browse_freely?`,
`#listing_page_limit`, `#listing_per_page_limit`, derived from level -- and
enforced where every surface passes: `PaginationExtension#paginate` for every
list, the walkers for "the next post", and each unpaged list at its source
(autocomplete, related tags, IQDB matches, DText embeds). An id array inside a
response (`pools/N.json` `post_ids`, `?only=children[...]`) carries its first
20 -- except a favorite group's own creator, who gets its whole `post_ids`:
reading back what they wrote is not browsing, and an API read-append-save
would otherwise drop the rest of their own group (operator, 2026-10-19: "Keep
it"; pools have no creator, so no exemption). A creator's page shows its first 20 posts, then "Sign in to see more!" and
the rest as empty cards with no id, URL, tag or link. The hero band is exempt
by name (`PaginationExtension::TIER_EXEMPT`). One page size holds for every
list: 200 a page for a full account, 20 below. Reach over time is not capped
(operator, 2026-10-18: "No cap until measured"). Live since 2026-10-19
(chanbooru 739045224); a test walks every GET route and requires each list to
be bounded, with a full-account control per row.

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

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| the post | see gate 10 | capped: 20 results, one page | visible | visible | visible | visible | visible |
| any list (tags, users, pools...) | see gate 10 | capped: 20, one page | 200 a page | 200 a page | 200 a page | 200 a page | 200 a page |
| a retired section | 404 | 404 | 404 | 404 | 404 | 404 (Owner: opens) | 404 |

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

**Matrix images follow the room -- and the quarantine.** A Matrix image whose
booru post is jailed, or carries a banished or flagged tag (gates 4, 5, 12),
is refused at this route too, to everyone, admins included -- since
2026-10-15 no door opens it to a reviewer; Matrix posts are reviewed in
sampling's jail panel, which reads the image from R2 (fourier-auth reads the booru's quarantine document every
30 s, and on a failed read keeps the last good one for 30 minutes before
refusing every Matrix image). Otherwise fourier-auth reads Synapse's own database --
which room the media was posted in, whether the viewer is joined -- and uses
Synapse's HTTP API only to validate the token. Synapse's authenticated-media
endpoint is NOT used: it authenticates the token but does not enforce room
membership. The booru gets the fourier session with no
clicks from a signed-in Technetium through `POST /exchange`; the Matrix token
lives server-side and the browser holds an opaque session id.

**Matrix POSTS follow their image** (gate 3 for posts; chanbooru c2f4cd776,
on since 2026-10-15; design fourier-basis docs/design/GATE3_MATRIX_POSTS.md). A post
whose source is a Matrix upload is visible to exactly the viewers its image
is: its rooms (where the uploader posted it, forwards by members, less deleted
messages) intersected with the viewer's joined rooms -- or every signed-in
viewer with a verified Matrix identity when the image is a site asset (an
avatar, room icon or emote). Everyone else gets no post: not in search,
paging or next/previous, and its page answers 404. **Admins are not exempt**
(operator, 2026-10-14); Matrix posts are moderated in sampling's jail panel,
whose Flagged tab reads images from R2. Signed out, or signed in only with a
booru account and no verified Matrix identity, no Matrix post exists. A tag
name found only on posts a viewer cannot see is absent from that viewer's tag
lists and autocomplete. Counts are NOT narrowed: a tag's count, and a search's,
may include Matrix posts the viewer cannot see (operator, 2026-10-15: "it's
the null hypothesis"). fourier-auth's reader keeps the booru's record of each
image's rooms current from Synapse, and the booru asks fourier-auth for the
viewer's joined rooms (cached about 45 s); if it cannot learn them, the viewer
gets no Matrix posts.

**Deleting a message takes its image out of that room** (operator ruling
2026-10-15; fourier-auth 1c47440, a34d500). A room counts only while the
message that placed the image there stands: once the message is deleted
(redacted), that room's members are refused the image within the caches below,
even if Synapse has not yet scrubbed the message's content (it does that about
seven days later). Until 2026-10-15 a deleted message kept placing its image
for that week. The same holds for an avatar, room icon or emote whose event is
deleted.

**Never-posted media** (`unposted_media_assets_restricted?`, 2026-09-30): an
upload that never became a post is visible only to an admin (and to the bot
that uploaded it).

**Caching.** The Worker caches an ALLOW, never a denial, keyed on a hash of the
credential: 60 seconds for booru media, 150 for Matrix media (240 until
2026-10-12). The gate keeps its own 120-second cache of allows, and an
image's rooms for 120 seconds (6 hours until 2026-10-15). So a just-jailed or
just-flagged image, or one whose message was just deleted, can stay readable
for about three minutes. A viewer's own joined rooms are cached for five
minutes, so one who leaves a room can read its media for up to about seven
and a half (the earlier "two and a half" left that cache out). The operator
accepted that window as it is, 2026-10-16: "It's seven minutes my bot. Not a
big deal."

`?w=` / `?h=` snap to the 180, 360 and 720 thumbnails rendered at upload; with
neither, the original is served; `?dl=1` serves it as an attachment.

**Nothing at rest on the homeserver, and no fallback** (verified 2026-10-13).
Synapse's media store holds no files: every upload goes to R2, and a daily
purge frees the local copy once R2 lists it. An image R2 does not hold is
refused (404, "media not in object storage") -- there is no other source,
and fourier-auth refuses to start if asked for one (MEDIA-URLS.md).

**Example 1: an image on a post tagged `1girl`, scraped from 4chan.** The
image follows the post's VISIBILITY, so this row is the post's own row from
gates 1, 4, 5, 8, 9 and 10. Signed out that includes gate 10: since chanbooru
bb3944ca6 (operator, 2026-10-13) the booru answers a signed-out media ask
(`MembersOnly#anonymous_md5_ask?`) only for a post the site is showing signed
out, so the image loads exactly while the post's page would.

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| the image, while the post is on the newest posts or recently shown signed out | loads | loads | loads | loads | loads | loads | loads |
| the image, otherwise | refused (gate 10) | loads | loads | loads | loads | loads | loads |

**Example 2: the image on a Matrix upload, creator tag `41chan_alice`, posted
in a room called #art.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| joined to #art, with a Matrix session: post and image | -- | visible | visible | visible | visible | visible | visible |
| not joined to #art, or no Matrix session: post and image | hidden | hidden | hidden | hidden | hidden | hidden | visible |

---

## 4. Deleted posts, and jailed posts

    deleted_post_visibility_level  ADMIN (50)

Below admin, `-status:deleted` is injected into every query, and a deleted
post's page answers as if it did not exist. This is deliberately tighter than
upstream, which hides deleted posts at the RENDER layer while still returning
and counting them. The one exception is the bot that uploaded the post, which
can still open it by direct link and keep working on it; no person can.

**Jailed means deleted** (operator, 2026-10-10): a jailed post is a deleted
post carrying `troll_jail`. But a jailed post is withheld from **everyone
except the pipeline** -- admins included -- whether or not its deletion landed
(`TagBanishment.post_tags` holds `troll_jail` beside every banished name;
`Post#hidden_as_banished?`). Nothing on the booru shows a jailed post to a
person. Moderation of jailed posts happens in sampling's jail panel, which is
also the only place a post is released (`POST /fourier_jail/release`): the
booru's own tag pill refuses to take `troll_jail` or the deletion off a jailed
post. When the booru jails a post itself (a moderator's pill, gate 5's
banished-tag failsafe, a one-click Banish from gate 12's queue), it reports
the jailing to the panel (`GET /fourier_jail/release.json?since=`), so no
jailing is invisible to the place that controls it.

**A jailing is two writes.** Sampling adds `troll_jail`, then deletes, and the
delete needs Approver (37). If it is refused, the post is left live with the
tag -- and is still hidden from every person, because the tag alone withholds
it (fixed 2026-10-12; until then such a post was visible to Gold and above).
Sampling logs every refused delete as "booru did NOT change", and
`tools/jail-apply.ts --booru-only --md5 <list>` finishes it.

**The bots keep their level.** Danbooru's monthly approver pruning demotes any
Approver with too few approvals; it exempts the pipeline accounts since
chanbooru 98a61151d. On 2026-10-12 it had demoted `sample` to Contributor and
every jail delete was refused for a night.

Inherited from upstream and unchanged: a taken-down post is hidden from
viewers below Moderator, and a banned post from viewers below Approver.

**Example 1: a post a moderator deleted (`status:deleted`).**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| a deleted post | hidden | hidden | hidden | hidden | hidden | visible | visible (its own) |

**Example 2: a jailed post, tagged `troll_jail` -- deleted, or not.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| a jailed post | hidden | hidden | hidden | hidden | hidden | hidden | visible |

A published page never shows a jailed image (gate 11).

---

## 5. Banished tags and the blocklist

Two mechanisms, and only the first is a gate.

**Banished tags** are words removed from the site, and with them every post
that carries one. Since chanbooru 98a61151d (operator rulings 2026-10-12):

- **The list is in the database** (`TagQuarantine` rows in the banished
  state), not a config file. A tag is banished with ONE click from gate 12's
  review queue; the booru then jails every post carrying it, through its own
  jail (BanishTagJob), and reports each to sampling's jail panel. A post that
  gains a banished tag later is jailed the moment it does.
- **The words are gone for everyone but the pipeline**: tag listings,
  autocomplete, tag panels, related tags -- admins included. There is no
  reveal setting any more. The operator: "the booru itself will never be the
  surface that shows banished tags, ever. The troll jail panel in sampling
  will be used for moderation."
- **The posts are withheld from everyone but the pipeline**, deleted or not --
  a post released from the jail keeps its tags, and stays withheld while it
  carries a banished one. Releasing lifts the jail, not the banishment.
- **Unbanishing happens in sampling's jail panel** and nowhere on the booru:
  it takes the name off the list (`POST /fourier_jail/release.json` with
  `unbanish`, naming who pressed it in the mod log) and releases no jailed
  post -- that stays the panel's per-post release.

**The blocklist** is each viewer's own filter, and since chanbooru 7e659c926
(2026-10-13) the only one. The enforced blacklist -- a site-wide list applied
to every viewer -- is gone; the operator: it "was a fallback in case banished
posts were even potentially visible", and banished posts are now withheld on
the server, so the fallback could only hide a real bug. The user's list was
the blacklist and is renamed.

- It lives in a panel joined to the refresh/purge rectangle. Tags are added and
  removed at will and the view filters as they change.
- A rule can be **locked**, so it is not removed by accident; locks survive
  every way the list is written.
- It starts EMPTY. A line is AND-ed and `-` excludes. Signed out, the list
  lives in the browser and merges into the account at sign-in.
- Other apps read it from `GET /profile.json` as `blocklist`, a list of
  `{rule, locked}` -- not the raw `blacklisted_tags` text, which carries the
  lock marker.

**It is a filter in the browser, not a gate on the server.** The booru sends a
blocked post to everyone it is visible to, and that viewer's browser hides it:
the thumbnail in listings and the image on the post's page. Its page, its tags
and its image URL are still served. It decides what one person chooses not to
see; who MAY see a post is decided by the gates.

**Example 1: a post that gains `gore`.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| the post (jailed), and its image | hidden | hidden | hidden | hidden | hidden | hidden | visible |
| the same post released from the jail, still tagged `gore` | hidden | hidden | hidden | hidden | hidden | hidden | visible |
| the word `gore` in tag lists and autocomplete | absent | absent | absent | absent | absent | absent | shown |

**Example 2: a post tagged `insect`, for a viewer who has blocked `insect`.**

| | the viewer who blocked `insect` | every other viewer |
|---|---|---|
| its thumbnail in listings | hidden in the browser | shown, as their gates allow |
| its own page | opens, image hidden in the browser | opens, as their gates allow |
| its image file, by URL | loads | loads, as their gates allow |

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
attribute that a blocklist matches against in the browser, because
`post.tag_string` still contains them. The consequence, and it is the correct
trade: **a viewer's blocklist cannot match a tag that viewer is not allowed to
see.** Posts with no
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

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| the tag `masterpiece` on that post | absent | absent | absent | absent | absent | absent | absent |

Visible only to **alice herself**, and her generation data.

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

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| the post and image | hidden | hidden | hidden | hidden | hidden | visible | visible |
| the tag name in lists and autocomplete | absent | absent | absent | absent | absent | shown | shown |

Also **visible** to: the `tunnel` and `sample` accounts; `someone`, once their claim
on `aichan_someone` is approved. Once the tag is released, the post follows
gates 1-7 and 9-10 like any other.

---

## 9. Creator visibility -- the creator's own panel

Built 2026-10-07 to 2026-10-09 (`docs/design/CREATOR_VISIBILITY.md`). A
creator chooses who sees their posts, creator-wide or per post:

- **public** -- whoever the site's other gates allow. Narrows nothing.
- **groups** -- members of the groups they list, plus people they name.
- **private** -- only people they name. No group ever opens private.

Plus named **allows** and **blocks**: **a block beats every allow**. An
explicit allow -- a named viewer, a member of a listed group, or the creator --
can also WIDEN past gate 1 for that viewer, opening the post and its image
(since 2026-10-13; before, it opened only the image) -- never for a signed-out
viewer, a banned one, or a jailed post. A narrowed post is hidden
at query level and its page answers as a missing post. **Admins always see**,
and every admin view of a post its creator hid is written to the mod log.
Moderators can neither see nor act on it.

**Example: a post by `41chan_alice`, set to private, with bob named.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| a viewer alice has not named | hidden | hidden | hidden | hidden | hidden | visible (logged) | visible |
| bob, named, signed in | -- | visible | visible | visible | visible | visible | visible |

Also **visible** to: alice herself. If alice blocks carol, carol is hidden from it
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
- a post's own page, only while the site is showing that post to signed-out
  viewers: it is on the newest posts now, or in a promoted creator's curated
  set, or a page served to a signed-out viewer rendered it this hour or the
  last. A thumbnail clicked minutes later still opens; the permission lapses
  within two hours of the post last being shown (`MembersOnly#anonymous_shown_post?`);
- promoted creator galleries.

Every listing that names posts (popular, favourites, pools, approvals,
commentary and the rest) is members only (2026-10-07). Everything here still
passes through gates 1-9: a gated post is not on the landing page either.

**Images follow pages** (chanbooru bb3944ca6; operator, 2026-10-13). A
signed-out visitor loads a post's image only while its page would open to them;
the booru's one signed-out media answer (`MembersOnly#anonymous_md5_ask?`)
returns only posts the site is showing signed out. Until then this gate closed
pages but not images, and any ungated image loaded by URL. A cached answer can
outlive a post's "shown" status by about three minutes (fourier-auth's cache
and the edge Worker's), the same bound jailing has.

**Example: a `1girl` post that is not on the landing page.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| its post page | 404 | capped | visible | visible | visible | visible | visible |
| its image, by URL | refused | loads | loads | loads | loads | loads | loads |
| the same post, while it is on the newest posts or within an hour or two of being shown signed out | visible | capped | visible | visible | visible | visible | visible |

---

## 11. Published pages -- a grant, not a loophole

Sampling's console (`sample.41chan.net`) can PUBLISH a thread as a page at
`sample.41chan.net/p/<hash>`: a random, unguessable link, which can expire.
The publication IS the operator's grant (ruling 2026-10-02), separate from the
booru's browsing rules. While the page is live, a reader holding it gets a
cookie for that page, and fourier-auth releases each image the page lists --
including one the booru would hide from that reader, such as a gated one.
**A jailed, banished or flagged image is never released**: the page withholds
it ("Purposely disregarded"), with no digest and no tag name in what it sends.
Sampling reads the booru's quarantine document every 60 seconds; if it cannot,
the last good read governs for 30 minutes, and never read or past that, the
page withholds every image. When the page expires or is taken down, the grant
ends with it. If sampling cannot be reached the gate answers 503.

The console itself is a separate door: `GET /verify?gate=sample` opens
`sample.41chan.net` only to a Matrix account at power level 70 or above in the
moderators room, and fails closed.

**Example: a published thread showing a `loli` image and a `troll_jail` image.**

| | holding the live link | after it expires |
|---|---|---|
| the `loli` image | visible, whoever they are, signed in or not | refused unless the viewer's own gates allow it |
| the `troll_jail` image | never on the page | refused |
| an image carrying a flagged tag | withheld on the page | refused |

---

## 12. Flagged tags -- a review quarantine

Since chanbooru 98a61151d (operator rulings 2026-10-12). An admin can FLAG any
tag for review: "the tag's entire existence should immediately
disappear--but not as severe as banished because the idea is to immediately
flag any tag for review by admins."

- **Still visible to:** Admin and Owner levels ("I did mean 'owner' danbooru
  level"), every post -- a Matrix post only in the rooms they are joined to
  (gate 3); the booru's system user; and the posting bots on their
  OWN posts -- which is every post, since only the bots upload -- so they keep
  working on them, and the names everywhere, because they tag with them.
- **Everyone else:** every post carrying the tag, and the tag's name, are gone
  at every door -- search, counts, pages, images, tag lists, autocomplete --
  including posts that gain the tag later.
- **Review:** a "Flagged tags" queue on the admin console (who flagged it,
  when, how many posts), and -- for Matrix posts, which admins no longer see
  outside their rooms -- the Flagged tab of sampling's jail panel, which shows
  every post carrying the tag with its image (operator, 2026-10-14: "Move
  Matrix review into the jail panel"). **Release** puts everything back at
  once. **Banish** is one click: the tag becomes banished (gate 5) and its
  posts are jailed. Both work from either place and are written to the mod
  log, naming who pressed them.
- **Reach: everywhere, like the jail.** fourier-auth refuses a flagged image
  at the Matrix route and in publication grants; sampling withholds it from
  its external and published views; the tunnel stops writing the name into
  Matrix rooms' tag state, and rewrites that state when a flag changes.
- A flag jails nothing and hides nothing from an admin. That is the
  difference from a banishment.

**Example: a post carrying a tag an admin has flagged.**

| | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| the post and its image | hidden | hidden | hidden | hidden | hidden | visible | visible (its own) |
| the tag's name in tag lists and autocomplete | absent | absent | absent | absent | absent | shown | shown |

---

## Every gate at once -- the combination matrix

One example from each gate, and what each kind of viewer gets of the POST
(the post's own page) and of the IMAGE (the file, as the media gate answers
for it). Each cell has two halves, POST above IMAGE, and each half reads
VISIBLE in green or BLOCKED in grey. A BLOCKED half names the FIRST gate that
stops that viewer, taking the gates in the order a request meets them: the edge
challenge (7) passes every browser and stops every script, so it is not a
column; then the signed-out default-deny (10); then the rules about the post.
That is why a signed-out cell is almost always gate 10, POST and IMAGE alike:
since 2026-10-13 a signed-out image follows its page, so both close before the
post's own rules are asked. The exception is a Matrix upload's image, which
has its own route and its own rule (gate 3).

The creator-private TAGS of gate 6 and the grant of a published page (gate
11) are not about a viewer's level, so they are not rows here; see their
sections.

| example -- post / image | Signed out | Restricted | Member | Gold+ | Moderator | Admin | Pipeline |
|---|---|---|---|---|---|---|---|
| `1girl`, on the newest page | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} |
| `1girl`, not shown signed out | {no: gate 10} / {no: gate 10} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} |
| `loli` (gate 1) | {no: gate 10} / {no: gate 10} | {no: gate 1} / {no: gate 1} | {no: gate 1} / {no: gate 1} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} | {yes} / {yes} |
| deleted by a moderator (gate 4) | {no: gate 10} / {no: gate 10} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {yes} / {yes} | {yes: its own} / {yes: its own} |
| `troll_jail` (gate 4) | {no: gate 10} / {no: gate 10} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {no: gate 4} / {no: gate 4} | {yes} / {yes} |
| `gore`, banished (gate 5) | {no: gate 10} / {no: gate 10} | {no: gate 5} / {no: gate 5} | {no: gate 5} / {no: gate 5} | {no: gate 5} / {no: gate 5} | {no: gate 5} / {no: gate 5} | {no: gate 5} / {no: gate 5} | {yes} / {yes} |
| `aichan_someone` (gate 8) | {no: gate 10} / {no: gate 10} | {no: gate 8} / {no: gate 8} | {no: gate 8} / {no: gate 8} | {no: gate 8} / {no: gate 8} | {no: gate 8} / {no: gate 8} | {yes} / {yes} | {yes} / {yes} |
| creator set private (gate 9) | {no: gate 10} / {no: gate 10} | {no: gate 9} / {no: gate 9} | {no: gate 9} / {no: gate 9} | {no: gate 9} / {no: gate 9} | {no: gate 9} / {no: gate 9} | {yes: logged} / {yes} | {yes} / {yes} |
| a flagged tag (gate 12) | {no: gate 10} / {no: gate 10} | {no: gate 12} / {no: gate 12} | {no: gate 12} / {no: gate 12} | {no: gate 12} / {no: gate 12} | {no: gate 12} / {no: gate 12} | {yes} / {yes} | {yes: its own} / {yes: its own} |
| Matrix upload, viewer not in its room (gate 3) | {no: gate 10} / {no: gate 3} | {no: gate 3} / {no: gate 3} | {no: gate 3} / {no: gate 3} | {no: gate 3} / {no: gate 3} | {no: gate 3} / {no: gate 3} | {no: gate 3} / {no: gate 3} | {yes} / {yes: via R2} |

Pipeline is the booru's system user and the posting bots. "Its own" is every
post, since only the bots upload. The pipeline reads a Matrix image's file from R2
directly, never through the Matrix route.

---

## Diagnosing a report

| symptom | gate |
|---|---|
| a 403 with a `cf-mitigated` header, on any page | 7 -- the edge challenge, working |
| curl or a script gets 403 where a browser works | 7 -- no command-line tool can pass it |
| a signed-out visitor gets 404 on a page that loads when signed in | 10 -- the anonymous default-deny |
| a list stops at 20, or its page 2 or a cursor answers 410 | 2 -- below full browsing every list is one page of 20 |
| cannot register | 0 -- no token, or a spent, expired or revoked one |
| a booru image is broken but the post page loads | 3 -- the image follows its post: deleted, jailed, gated or hidden for this reader. A 503 means the booru or sampling was unreachable |
| a Matrix upload's image is broken | 3 -- the viewer is not in the room it was posted in, or has no Matrix session |
| a Matrix post 404s for one viewer and opens for another, admins included | 3 -- the post follows its image's rooms; moderate it in sampling's jail panel |
| a tag's count is higher than the posts a viewer can page through | 3 -- counts include Matrix posts outside the viewer's rooms, by design |
| a Matrix image stopped loading in a room it was posted to | 3 -- the message that posted it there was deleted; another room it was posted to still shows it |
| a just-jailed or just-flagged image still loads for a minute or two | 3 -- the decision caches, about three minutes at most |
| search returns exactly 20, and no second page | 2 -- browsing tier |
| a section 404s for everyone | 2 -- retired |
| a post 404s for one viewer and loads for another | 1 (gated, below Gold), 4 (deleted or jailed), 8 (creator prefix), 9 (creator visibility), 10 (signed out) or 12 (a flagged tag: only admins see it) |
| nobody, admins included, can see a jailed or banished post | 4 and 5 -- by design; moderate it in sampling's jail panel |
| a signed-out visitor's image link stopped working | 10 -- a signed-out image loads only while its post is shown signed out: on the newest posts, in a promoted set, or within an hour or two of being shown |
| a post is missing from a count as well as a page | 1, 4, 5, 8, 9 or 12 -- query level, not render level |
| a post is hidden in listings but its page opens | 5 -- the viewer's own blocklist: a filter in their browser, not a server gate |
| a post tagged `troll_jail` is live (not deleted) | 4 -- a jailing whose delete was refused (still hidden from every person); check the bot is at Approver (37), then `jail-apply.ts --booru-only` |
| a tag exists on a post but nowhere in autocomplete | 1 (a gated name, below Gold), 5 (banished), 8 (a hidden prefix such as `aichan_`) or 12 (flagged, for anyone below Admin) |
| a tag vanished, and its posts with it, for everyone but admins | 12 -- flagged for review; Release or Banish from the admin console's queue or sampling's jail panel (Flagged tab) |
| a banished tag needs to come back | 5 -- unbanish from sampling's jail panel; the booru has no surface for it |
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

No account has ever sat at Restricted: as of 2026-10-14 the one token has
been redeemed sixteen times, none of them flagged, so each started at Member. The restricted
path is still covered by tests only, and a flagged signup is still the most
likely source of a first report about it. No tag
grant has been issued, and only `edit` grants can be. The creator visibility
panel (gate 9) and the creator tag release (gate 8) are built and tested, and
each will meet its first ordinary user after this was written.
