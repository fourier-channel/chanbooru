# Content gating on chanbooru

Every rule that decides whether a viewer sees a post, an image, or a tag. Written
2026-08-30, traced from the code and checked against the running site.

There are six independent gates. They are not layers of one system and they do
not share a switch: a post can pass five and be withheld by the sixth. When a
user reports "this page doesn't work", the question is *which gate*, and this
document exists so that question has an answer that does not require reading
Ruby.

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

### What this actually gates, measured 2026-08-30

<!-- derived-ok: a dated measurement of the corpus as it stood -->
13,731 posts of 64,910 -- 21% -- carry at least one gated tag.

| tag | posts |
|---|---|
| loli | 9,332 |
| troll_jail | 2,323 |
| shota | 2,210 |
| young | 1,897 |
| child | 879 |
| aged_down | 209 |
| baby | 24 |
| toddler | 4 |
| age_regression | 1 |
| toddlercon | 0 |
| infant | 0 |

**Worth reviewing before launch:** `young` (1,897) and `child` (879). Both are
ordinary words in the e621 taxonomy that the Hydra route emits, and they appear
in contexts that have nothing to do with what the list is for. `toddlercon` and
`infant` match nothing at all -- harmless, since a tag that does not exist is
inert, and listing tags the taggers have not emitted yet is deliberate.

---

## 2. Browsing tier -- a property of the VIEWER

    full_browsing_level           MEMBER (20)
    restricted_browsing_per_page  20
    default_user_level            RESTRICTED (10)
    enable_signup?                false

A viewer at or above `full_browsing_level` browses without restriction. Below
it, a search returns at most 20 posts -- and that ceiling clamps `?limit=` too,
or the restriction would be one query parameter wide.

New accounts start BELOW the threshold. Signup is disabled, so accounts are made
deliberately, and granting full browsing is an explicit act rather than
something that happens by default.

**This tier has never been exercised by a non-staff account.** Every account on
the site is currently at Moderator or above. The restricted path is covered by
tests, but no real session has ever run through it, and that is the most likely
source of a launch-day report.

---

## 3. Media -- fourier-auth, and the booru holds no bytes

The booru stores metadata and references media it does not have. Every image
request goes through the fourier-auth gate, which enforces the viewer's Matrix
permissions per request. Two routes, because they are authorised differently:

| route | authorised by |
|---|---|
| `mxc://...` -> `/fourier/media/<server>/<id>` | Synapse room membership |
| everything else -> `/fourier/booru/<md5>.<ext>` | the fourier session |

The second exists because a 4chan image lives in no Matrix room, so the
room-membership question is meaningless for it. It uses the same fourier login
already used to view Synapse media.

Synapse remains the single authority for both storage and authorisation. An
exposed MXC URI is only a pointer and grants no access without a valid,
permitted Matrix token, which never reaches the browser -- the browser holds an
opaque session cookie and the token stays server-side.

Thumbnail variants map to Synapse thumbnail sizes. `original` and `full` are
deliberately absent from that map: they get the ungated-size download.

**Consequence for a user report:** "images are broken but the page loads" is
almost always this gate, not the booru. It means a Matrix session problem or a
room-membership question, and it is diagnosed in fourier-auth, not here.

---

## 4. Deleted posts

    deleted_post_visibility_level  ADMIN (50)

Below admin, `-status:deleted` is injected into every query. 2,347 posts are
delete-flagged, of which 2,270 are the troll jail.

This is deliberately tighter than upstream, which hides deleted posts at the
RENDER layer while still returning and counting them. Here they are removed from
the query.

**Known consequence:** the `sampling` bot is an Approver (37) and therefore
cannot see deleted posts either. It can delete-flag a post and cannot afterwards
confirm it did -- a lookup for an already-jailed image is indistinguishable from
one that was never posted. Verifying the jail against the booru is a database
query, not an API call, until that changes.

---

## 5. Blacklist -- client-side, and view-filtering only

The default blacklist is an attribute default on `User`, so `User.anonymous`
carries it: it is both the signed-out blacklist and the starting value for a new
account. Extended 2026-08-30 to cover the material fourier-sampling auto-jails.

A blacklist line is AND-ed and `-` excludes, which is what lets a conjunction
with an exemption be expressed -- `arthropod rating:e -pokemon_(creature)`.

Two things it is not:

- **It is not a permission.** It filters a view. It does not remove a post, and
  a user can edit their own.
- **Changing the default does not touch existing accounts.** They hold their own
  stored value and only ever change it themselves.

It is deliberately redundant with the troll jail. The jail renders the post
inert at source; the blacklist hides the category by default for anyone who has
not chosen otherwise. Two mechanisms, two failure modes, on purpose.

---

## 6. Private tags

`FourierTagSource` withholds private creator tags from the DOM. Blacklists are
matched client-side against a `data-tags` attribute, so which tags a viewer may
see has to be answered before rendering -- and `post.tag_string` is the wrong
answer, because the denormalised string still contains the private tags this
class exists to withhold.

The documented consequence, and it is the correct trade: **a viewer's blacklist
cannot match a tag that viewer is not allowed to see.** You cannot filter on what
you cannot be shown, and the alternative is disclosing it.

Posts with no rows in that table are unaffected and keep their full tag string.

---

## Diagnosing a report

| symptom | gate |
|---|---|
| page loads, images broken | 3 -- fourier-auth / Matrix session |
| search returns exactly 20 and no more | 2 -- browsing tier |
| a post 404s for one viewer, loads for another | 1 (anonymous) or 4 (deleted) |
| post listed, image replaced by a prompt | 1 -- gated, signed in below Gold |
| a post is missing from a count as well as a page | 1 or 4 -- query level, not render level |
| a post is hidden but findable by direct link | 5 -- blacklist, which is a view filter |

## What is scaffolded and not configured

The user permission tiers exist as levels and thresholds and have never been
populated: there is no Member, no Gold, no Restricted account in use. Everything
in section 2 is therefore theory-tested only. That configuration is its own
project and is not attempted here.
