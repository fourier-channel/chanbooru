# Content gating on chanbooru

Every rule that decides whether a viewer gets an account, sees a post, an
image, or a tag. First written 2026-08-30 from the code and the running site;
re-traced 2026-09-11 against both, with the corpus re-measured.

CANON. Lives in `fourier-basis`; hydrated into chanbooru and rendered into the
public site by `coherence hydrate`. This file is the only copy anyone edits.

There are seven independent gates. They are not layers of one system and they
do not share a switch: a post can pass six and be withheld by the seventh.
When a user reports "this page doesn't work", the question is *which gate*,
and this document exists so that question has an answer that does not require
reading Ruby.

## The distinction this site is built on

**A gate is unlocked, never bypassed.** An unlocked gate still runs and still has
an opinion -- it just says "okay". A bypassed gate has its opinion discarded.

That is not a stylistic preference. Every rule below evaluates for every viewer,
and qualifying viewers satisfy it rather than skipping it. `visible?` is
`!safeblocked? && !levelblocked? && !banblocked?`, evaluated per post per
viewer; the query-level rules return an empty list of restrictions when the
viewer qualifies, rather than being conditionally omitted from the query. The
difference matters when something goes wrong: a gate that ran and said yes can
be asked why, and a gate that was skipped cannot.

---

## 0. Getting an account -- signup tokens

    enable_signup?          false outside the test environment
    signup_requires_token?  true

41chan is not an open site. Until 2026-09-09 signup was closed outright and
accounts were made by hand. Now an admin issues a **signup token** that
permits one registration, several, or unlimited; the signup page asks for it,
and a POST without a valid one is refused by policy with a 403 before any
account is built. Redeeming the token and saving the account are one
transaction, so a token cannot be spent on a signup that then fails and an
account cannot be handed out on a token that ran out in between. The model is
MAS's registration tokens on the Matrix side, deliberately, so both halves of
the site work the same way.

An account so created starts at `default_user_level` (see gate 2).

---

## 1. Content gating -- a property of the POST

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
lookups that drive post-to-post navigation. This is at query level rather than
in a filter over results because a filter never sees those other four things,
and a row excluded from the query cannot leak through any of them.

**Signed-in below Gold: the post is listed, the image is withheld.**
`Post#levelblocked?`. The reasoning, from the source: the browsing tier says
"you may see this, but only if you already know where it is"; gating says "you
may not see this kind of thing at all", and a rule of that shape is not
satisfied by withholding the image while still listing the post, its tags and
its id. A signed-in viewer gets the listing "because for them there is something
to do about it" -- namely ask for a level.

The uploader always sees their own post. That is an unlock on identity.

### What this actually gates, measured 2026-09-11

<!-- derived-ok: a dated measurement of the corpus as it stood -->
34,762 posts of 165,431 -- 21% -- carry at least one gated tag. The corpus
has grown two and a half times since the 2026-08-30 measurement (64,910);
the share is unchanged.

| tag | posts |
|---|---|
| loli | 23,982 |
| young | 20,386 |
| child | 9,294 |
| shota | 5,706 |
| troll_jail | 3,500 |
| aged_down | 630 |
| baby | 50 |
| toddler | 49 |
| age_regression | 4 |
| toddlercon | 0 |
| infant | 0 |

**Still worth reviewing:** `young` (20,386) and `child` (9,294) are now the
second and third largest gated tags. Both are ordinary words in the e621
taxonomy that the Hydra route emits, and they appear in contexts that have
nothing to do with what the list is for. `toddlercon` and `infant` match
nothing at all -- harmless, since a tag that does not exist is inert, and
listing tags the taggers have not emitted yet is deliberate.

---

## 2. Browsing tier -- a property of the VIEWER

    full_browsing_level           MEMBER (20)
    restricted_browsing_per_page  20
    default_user_level            RESTRICTED (10)

A viewer at or above `full_browsing_level` browses without restriction. Below
it, a search returns at most 20 posts -- and that ceiling clamps `?limit=` too,
or the restriction would be one query parameter wide.

New accounts start BELOW the threshold. Granting full browsing is an explicit
act by staff rather than something that happens by default.

**Measured 2026-09-11:** eight accounts exist. Two are at Member; the rest are
staff and the pipeline's bots at Approver or above. No account has ever sat
at Restricted, so the restricted path is still covered by tests only, and it
is still the most likely source of a first report from a new signup.

Three sections do not exist on this fork at all: comments, notes and the
forum (`retired_sections`, ruled 2026-09-06). They 404 the way a hidden post
does, including on the JSON API, because a link removed from a nav is not a
page that is gone. The status page is admin-only
(`status_page_visibility_level`).

---

## 3. Media -- fourier-auth decides, R2 serves, the booru holds no bytes

The booru stores metadata and references media it does not have. Every image
request is authorised by fourier-auth, and since 2026-09-06 a Cloudflare
Worker at the edge asks fourier-auth for the decision and streams the object
from R2 itself, so no media byte crosses the booru's host or the gate's. Two
routes, because they are authorised differently:

| route | authorised by |
|---|---|
| `mxc://...` -> `/fourier/media/<server>/<id>` | Synapse room membership |
| everything else -> `/fourier/booru/<md5>.<ext>` and the 180/360/720 variants | the fourier session |

The second exists because a 4chan image lives in no Matrix room, so the
room-membership question is meaningless for it. It uses the same fourier login
already used to view Synapse media, which the booru obtains with no clicks
from a signed-in Technetium through `POST /exchange`.

fourier-auth answers the room question by reading Synapse's own database --
which room the media was posted in, whether the viewer is joined -- and uses
Synapse's HTTP API only to validate the token. Synapse's authenticated-media
endpoint is NOT used: it authenticates the token but does not enforce room
membership. Synapse is the source of the facts; fourier-auth is the authority
that decides; R2 is the store. No user-posted media lives on the homeserver,
only site assets -- avatars, emojis, room icons -- and those need only a valid
token.

If the check passes, the caller gets a short-lived presigned R2 URL (a 302, or
a JSON envelope for cross-origin fetches), and the Worker caches an ALLOW at
the edge for 240 seconds keyed on the credential, never a denial. A viewer who
leaves a room can read for at most four more minutes. An exposed MXC URI is
only a pointer and grants nothing without a valid, permitted session; the
Matrix token never reaches the browser.

Thumbnail variants map to sizes the booru rendered at upload and stored in R2.
`original` and `full` get the ungated-size download; `?dl=1` turns it into an
attachment.

**Consequence for a user report:** "images are broken but the page loads" is
almost always this gate, not the booru. It means a session problem or a
room-membership question, and it is diagnosed in fourier-auth's decision log,
not here.

---

## 4. Deleted posts

    deleted_post_visibility_level  ADMIN (50)

Below admin, `-status:deleted` is injected into every query. Measured
2026-09-11: 3,581 posts are delete-flagged, of which 3,500 are the troll jail.

This is deliberately tighter than upstream, which hides deleted posts at the
RENDER layer while still returning and counting them. Here they are removed from
the query.

**Known consequence:** the `sampling` bot is an Approver (37) and therefore
cannot see deleted posts either. It can delete-flag a post and cannot afterwards
confirm it did -- a lookup for an already-jailed image is indistinguishable from
one that was never posted. Verifying the jail against the booru is a database
query, not an API call; releasing a jailed post goes through the fork's own
`POST /fourier_jail/release`, because both halves of an ordinary undelete are
closed to that account.

---

## 5. Blacklists -- three of them, and only one is the user's

**The user blacklist** is a view filter the user edits. The default is an
attribute default on `User`, so `User.anonymous` carries it: it is both the
signed-out blacklist and the starting value for a new account. A line is
AND-ed and `-` excludes, which is what lets a conjunction with an exemption be
expressed -- `arthropod rating:e -pokemon_(creature)`. Changing the default
does not touch existing accounts; they hold their own stored value.

**The enforced blacklist** (`enforced_blacklist`, 2026-09-04) is applied to
every viewer, stored in no account, and editable by nobody from the site. It
carries the banished tags plus the conjunction rules the sampling jail also
uses. It is a view filter too: it hides, it does not remove, and a post it
hides is still reachable by direct link.

**Banished tags** (`banished_tags`, ruled 2026-09-04) are removed from the
vocabulary outright: absent from tag listings, autocomplete and the tag
panels for everyone including admins, unless an admin has switched
`reveal_banished` on in their own settings. The operator's words: "hidden to
me without a specific toggle on, and apparently missing/deleted from the
server altogether for everyone else." Posts carrying them are handled by
the jail, not by this list; this list is about the words.

The user blacklist is deliberately redundant with the troll jail. The jail
renders the post inert at source; the blacklist hides the category by default
for anyone who has not chosen otherwise. Two mechanisms, two failure modes, on
purpose.

---

## 6. Private tags, and the grants that open them

`FourierTagSource` withholds private creator tags from the DOM. Blacklists are
matched client-side against a `data-tags` attribute, so which tags a viewer may
see has to be answered before rendering -- and `post.tag_string` is the wrong
answer, because the denormalised string still contains the private tags this
class exists to withhold.

The documented consequence, and it is the correct trade: **a viewer's blacklist
cannot match a tag that viewer is not allowed to see.** You cannot filter on what
you cannot be shown, and the alternative is disclosing it.

Since 2026-09-04 a creator can open that door per person: a **tag grant** is
one user, one tag, one ability. `view` lets the grantee see the private
creator tags on posts carrying that tag, exactly as the creator and moderators
do; `edit` lets them edit the one artist the tag names, as an approved
claimant does. In the operator's words, a creator allowing others to see
their work "is, in essence, maintaining a user whitelist on their creator
tag". Grants are issued by admins; none have been issued yet.

Posts with no rows in the tag-source table are unaffected and keep their full
tag string.

---

## Diagnosing a report

| symptom | gate |
|---|---|
| cannot register | 0 -- no token, or a spent one |
| page loads, images broken | 3 -- fourier-auth / the fourier session |
| search returns exactly 20 and no more | 2 -- browsing tier |
| a section 404s for everyone | 2 -- retired |
| a post 404s for one viewer, loads for another | 1 (anonymous) or 4 (deleted) |
| post listed, image replaced by a prompt | 1 -- gated, signed in below Gold |
| a post is missing from a count as well as a page | 1 or 4 -- query level, not render level |
| a post is hidden but findable by direct link | 5 -- a blacklist, which is a view filter |
| a tag exists on a post but nowhere in autocomplete | 5 -- banished |
| a creator's tag is visible to one viewer and not another | 6 -- a grant |

## What is scaffolded and lightly used

The permission tiers exist and two accounts now sit at Member; nobody has
sat at Restricted. Tag grants exist and none are issued. Signup tokens exist
and one has been issued. Each of these is real and tested, and each will meet
its first ordinary user after this was written.
