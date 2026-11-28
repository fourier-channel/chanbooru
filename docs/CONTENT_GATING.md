<!-- phase:S-69015a -->
# Content Gating

How 41chan's image board decides, on every request, who may see each post,
each image and each tag. Thirteen gates, numbered 0 to 12, each answer one
question; a request meets them in order, and the first that says no
decides. The numbers are names, not the order.

Pick who is asking above the diagram and what the post is on the right, or
start from an example post. The line runs left to right in the order a
request meets the gates, through every gate that lets it pass, and stops at
the first that refuses. The gates after a refusal are never asked: the
request has already been answered, so they are drawn as empty rings, with
no line and no verdict. Click a gate for its reason; each gate is written
out in full below, and its lamp there follows what you pick above.

## How a request meets the gates

A request travels through the gates in order, and the first gate that says
no ends it. At Cloudflare's edge, gate 7 turns away anything that is not a
browser, and a request it refuses never reaches the board. On the board,
gate 10 decides whether a signed-out visitor may reach the page at all, and
gate 2 limits how much a new account can list. Then the post's own rules are
asked, in this order: a jail or banished tag (4, 5), deleted (4), a
sensitive tag (1), for a Matrix post the rooms it lives in (3), a hidden
creator prefix (8), a flagged tag (12), and what its creator chose (9). The
image is answered separately, by the media gate, and follows the post's
answer (3). A creator's private tags are left off the page for everyone
else (6). Gates 1, 5, 8 and 12 also take their own tag names out of
site-wide tag lists and autocomplete, but on a post's page that never
decides anything: a viewer those names are hidden from is never shown the
post. Last, in your own browser, your blocklist hides what you chose not to
see. It is your own filter, not a gate, and is described beside gate 5.

Nothing that runs after a refusal can change it. The refusal is recorded
the way any answered request is, in the request logs, and that is all: a
later gate is not asked "just to see", and no later gate could open what an
earlier one closed. In a listing, the post's own rules are one database
query and are asked together; a post any of them hides is simply not in the
results.

Images are not behind the edge check. The media service (gate 3) answers
them and treats a robot exactly as a signed-out visitor: a robot that
already holds an image's address gets the answer a signed-out visitor would,
and finding that address takes a page it cannot open. That is why nearly
every signed-out refusal comes from gate 10.

**A refusal gives nothing away.** A hidden post answers 404, exactly as a
post that never existed. A board image answers 404 whenever it is refused,
whatever the reason. Only a Matrix image says more, because Matrix's own
media address does: 401 when you are not signed in through Matrix, 403 when
you are but not in its room. The one 403 that is not about a room is the
edge check's, which a robot meets on every page.

---

#### The principles

- **No gate is skipped because of who you are.** Every gate on the path is
  asked for every viewer, and a gate that lets you through has checked and
  said yes. The path ends at the first gate that says no, so when something
  looks wrong there is always one answer to "which gate said no?".
- **Hidden means hidden everywhere.** A hidden post is removed from the
  database query itself, so it is absent from search, counts, paging and
  next/previous, not drawn as a gap. Its page, image, history, favourites,
  pools, related tags, image search and the moderation log all answer as if
  it did not exist.
- **The image follows the post.** The image server asks the board, as the
  reader, whether the post may be seen. There is no way to load an image
  whose post you could not open.
- **Words go with their posts.** A tag you may not see is also missing from
  autocomplete, tag lists and tag pages.
- **Failures close, not open.** If a gate cannot make its check (a service
  is unreachable, a list cannot be refreshed), the answer is no.
- **Only "yes" is cached, and briefly.** Allows are remembered for a minute
  or two to keep pages fast; refusals never are. A post that has just been
  hidden stops loading within about three minutes.
- **One view, two layers.** Your board account and your Matrix account are
  separate but joined. What each rank may see is tuned in two layers, the
  board's gates and the rooms, and what you can see on the board you can see
  in Matrix. Together they keep unwanted content out of public spaces, and a
  signed-out visitor never sees an image above general.

## Who is asking

**Every post is uploaded by a bot, never by a person.** The `sample` account
posts what is collected from 4chan; the `tunnel` account posts what is
shared on Matrix and Discord. So when a bot can see a post, it is the bot
that uploaded it, keeping its work going (tagging, jailing, releasing),
never a person. The bots read Matrix images straight from storage.

"Signed in" means any of: a board session, an API key, or a verified Matrix
identity. The last is how Technetium reads the board. A Matrix account with
no linked board account yet counts as a new one.

---

| viewer | who |
|---|---|
| Robot | anything that is not a browser (a script, crawler, scraper or monitor) holding no session |
| Signed out | no account session, no API key and no Matrix sign-in |
| Restricted | level 10, where every new account starts |
| Member | level 20 |
| Gold+ | levels 30 to 37: Gold, Platinum, Builder, Contributor, Approver |
| Moderator | level 40 |
| Admin | levels 50 and 60: Admin and Owner |
| Pipeline | the board's system account and its posting bots, `sample` and `tunnel` |

## 0. Getting an account: invite codes

*who can create an account: invite codes only*

41chan is not open for public signup. An admin issues **invite codes** that
allow one registration, several or any number, and that can expire or be
revoked. The signup page asks for one, and a request without a valid code is
refused before any account is created. Using the code and creating the
account happen as a single step, so a code cannot be used up by a signup
that then fails. Matrix registration on 41chan works the same way.

A new account starts at **Restricted**, and staff raise it to Member (gate
2). A signup that looks suspicious (from a banned address, a likely
duplicate account, a recently used address or a proxy) starts Restricted
too.

This gate is about who exists, not what they see, so it is not on the path
above: every viewer there has got past it, or holds no account.

---

|  | can register |
|---|---|
| holds a valid, unused, unexpired code | yes, as Restricted |
| holds no code, or a used, expired or revoked one | no |

## 1. Sensitive tags: a property of the post

*such posts do not exist below Gold*

These tags mark material the site does not serve casually. They describe the
**content**, not the viewer. `loli` is one.

**Below Gold, a post carrying any of them does not exist**, signed out,
Restricted and Member alike. It is left out of results, counts, paging and
post-to-post navigation, its page answers 404, and its image is refused. The
tag names themselves are absent from tag lists, autocomplete, tag pages and
the search sidebar; they appear only on a post the viewer may open.

---

#### Below Gold, the only ways past

- the bot that uploaded the post;
- a viewer the post's **creator lets in** ([gate 9](#gate-9)), which opens
  the post and its image, never for a signed-out or banned viewer, and never
  for a jailed post;
- a reader of a live published page that shows the image ([gate
  11](#gate-11)).

## 2. Browsing tier: a property of the viewer

*how much a new account can list*

Below Member (signed out, signed in only through Matrix, or Restricted)
**every list is at most 20 results and one page**: posts, tags, users, wiki
pages, artists, pools, favourites, histories and the rest. Asking for more
results per page is clamped to the same 20, asking for a second page is
refused (410), and there is no post-to-post navigation. Lists embedded in a
response carry their first 20 as well, except that the creator of a
favourite group always gets the whole of their own group. A creator's page
shows its first 20 posts, then "Sign in to see more!" over placeholders that
carry no link, tag or address. The front page's showcase is the one
exemption. A full account sees 200 per page everywhere.

Raising a Restricted account to Member is a deliberate act by staff.

**Retired sections** are closed to everyone but the Owner. Comments, notes
and the forum are not part of this site. The media and metadata sections
listed uploaded images by their checksum, including images their posts'
rules would have hidden, so they were closed. Each answers 404 exactly like
a missing post, including through the API. The server status page is for
admins only.

This gate limits listings. It never stops a single post, so on the path
above it always passes.

---

|  | below Member | Member and above |
|---|---|---|
| any list | 20, one page; page 2 is 410 | 200 a page |
| a retired section | 404 | 404 (the Owner: opens) |

#### Retired sections

`comments` `comment_votes` `forum_topics` `forum_posts` `forum_post_votes`
`forum_topic_visits` `notes` `note_versions` `media_assets` `ai_tags`
`media_metadata` `metrics` `jobs`

## 3. Images: they follow their post

*images follow their posts; Matrix images and posts follow their rooms*

The board keeps no images of its own. Every image lives in object storage
(Cloudflare R2), and every request for one is answered at Cloudflare's edge
by our media service. It asks the access gate for a decision and, only on a
yes, streams the file from storage itself, so no image passes through the
board's server or the gate's. Only the edge service receives a storage link;
anything else asking the gate gets the decision alone.

This is one gate with two doors. On the page, a Matrix post is visible only
to members of its rooms; on the image, the media gate answers.

#### Board images follow their post

The gate asks the board first as a signed-out reader and, only if that is a
no, as you. So an image is served exactly to the viewers its post is visible
to: a sensitive image to Gold and above, a deleted one to admins, a hidden
one to nobody. A thumbnail is refused like its original. A refused image
answers 404, the same as one that does not exist. If the board cannot be
reached, the gate refuses (503). A Matrix upload's file is never served on
this route unless a visible post that is not a Matrix upload holds the same
file.

#### Matrix images follow their room, and the quarantine

A Matrix image whose post is jailed, or carries a banished or flagged tag
(gates 4, 5, 12), is refused to everyone, admins included; it is reviewed
only in the moderation console's jail panel, which reads it from storage.
Otherwise the gate checks which rooms the image was posted in and whether
you are joined to one. The gate re-reads the quarantine list every 30
seconds; if it cannot, it keeps the last good list for 30 minutes and then
refuses every Matrix image until it can.

#### In its rooms, a Matrix image follows its post too

Being in the room is not enough: when the board hides the image's post from
you by any other gate (a sensitive tag below Gold, deleted or jailed, a
hidden source, its creator's choice, a flagged tag), the gate refuses you
the image with 404, as it refuses a board image. A new image shows until the
tagger has tagged it, moments after it is posted; in Technetium the picture
then visibly pops out of the room, so the room sees that it does not belong
there. Another Matrix client keeps the message without its picture. The
level that counts is your linked board account's; a Matrix account that has
none yet counts as a new one. An image no post holds is decided by its rooms
alone. If the board cannot be asked, the gate refuses (503). Encrypted rooms
(today only direct messages) are outside this: their images are never
matched to a post.

#### Matrix posts follow their image

A post whose image came from Matrix is visible to exactly the viewers who
can see the image: the rooms it was posted in (including forwards by
members, less messages since deleted), intersected with the rooms you have
joined. A site asset (an avatar, a room icon, an emote) is visible to any
signed-in viewer with a verified Matrix identity. Everyone else gets no
post: not in search, paging or next/previous, and its page answers 404.
**Admins are not exempt**; Matrix posts are moderated in the jail panel.
Signed in with a board account but no verified Matrix identity, there are no
Matrix posts at all; signed out, none either. A tag name found only on
Matrix posts you cannot see is absent from your tag lists. Counts are not
narrowed: a tag's count may include Matrix posts you cannot see. If the
board cannot learn which rooms you have joined, you get no Matrix posts.

#### Deleting a message takes its image out of that room

A room counts only while the message that placed the image there still
stands. Once it is deleted, that room's members are refused the image within
the caching window. The same holds for a deleted avatar, room icon or emote.

#### A creator's public gallery lets its own pictures out

A Matrix post a creator placed on a gallery that is not private (a hero
pick, a miniband picture, the banner, a Tuner picture) passes this gate for
everyone, signed in or out, for about two hours after the gallery is viewed,
and the next view renews it. The grant belongs to the gallery, not to
whoever viewed it. While it is placed, the board decides through its own
gates for the reader's rank: the creator's placement makes the board the
more permissive surface, so a Gold reader outside the rooms sees a placed
sensitive post and its image. Signed out still sees general-rated posts only
(gate 10). It passes this gate only: a deleted, jailed, flagged or otherwise
hidden post stays hidden, a post whose every message was deleted stays
hidden, and a private gallery grants nothing. When the grant lapses, the
post is hidden again; inside its rooms it shows as ever.

> Rolling out 2026-11-11: until it is live, a placed picture behind a
> sensitive tag stays off the gallery for every rank.

**An upload that never became a post** is visible only to admins and to the
bot that uploaded it.

---

#### Two kinds of image

| image | fetched from | decided by |
|---|---|---|
| a Matrix upload | Matrix's own media address, `matrix.41chan.net/_matrix/client/v1/media/...` | membership of the room it was posted in |
| everything else | `/fourier/booru/<checksum>`, and the 180, 360 and 720 thumbnails | the board's answer: may THIS reader see a post with this image? |

#### A refused Matrix image answers

| answer | meaning |
|---|---|
| 401 | not signed in through Matrix |
| 403 | signed in, but outside its rooms |
| 404 | quarantined, or its post is hidden from you |
| 503 | the gate cannot decide right now |

#### Caching

Only allows are cached: the edge keeps one for 60 seconds for board images
and 150 for Matrix images, and the gate keeps its own for 120. So an image
that has just been jailed or flagged, or whose message was just deleted, can
stay readable for about three minutes. Your list of joined rooms is cached
for five minutes, so after you leave a room its images can stay readable for
up to about seven and a half.

`?w=` and `?h=` pick the 180, 360 or 720 thumbnail made at upload; with
neither, the original is served; `?dl=1` serves it as a download.

#### Is Synapse's own media service used?

Not for reading. Matrix apps fetch images from Matrix's standard
authenticated-media address, and on 41chan that address is answered by our
edge service, never by Synapse. Synapse's own handler checks only that you
are signed in, not which rooms you are in, so it cannot be reached from the
internet at all. The older unauthenticated media addresses are closed (404),
and media requests from other servers are refused (403); this server does
not federate. Synapse still receives uploads; it writes each one straight to
storage and frees its local copy within a day.

Measured against production on 2026-10-20 with a freshly posted image: a
room member got the image; an account outside the room was refused on the
authenticated address (403), on its thumbnail (403), on every malformed
variant of the address (404), on the old unauthenticated addresses (404) and
on the federation address (403); a request with no account was refused
(401).

**Nothing is kept on the homeserver, and there is no fallback.** An image
that storage does not hold is refused (404); there is no second source.

## 4. Deleted and jailed posts

*deleted posts are gone below Admin; jailed posts from everyone but the
bots*

Below Admin, deleted posts are left out of every query, and a deleted post's
page answers as if it did not exist. Standard Danbooru is looser: it still
returns and counts deleted posts and only declines to draw them. The bot
that uploaded a post can still open it by direct link and keep working on
it; no person can.

**A jailed post is a deleted post carrying `troll_jail`**, and it is
withheld from **everyone except the bots**, admins included, even if its
deletion did not go through, because the tag alone withholds it. Jailed
posts are reviewed and released only in the moderation console's jail panel;
the board itself refuses to remove the jail tag or the deletion. When the
board jails a post on its own (a moderator's tag, a banished tag's safety
net, a banish from the flagged-tag queue), it reports the jailing to the
panel, so no jailing goes unseen by the place that controls it.

Inherited from standard Danbooru and unchanged: a taken-down post is hidden
below Moderator, and a banned post below Approver.

---

|  | who still sees it |
|---|---|
| deleted | Admin and Owner; the uploading bot, by direct link |
| jailed | the bots only; reviewed in the jail panel |
| taken down | Moderator and above |
| banned | Approver and above |

A published page never shows a jailed image ([gate 11](#gate-11)).

## 5. Banished tags, and your blocklist

*words removed from the site, and your own filter*

Two mechanisms, and only the first is a gate.

#### Banished tags

Words removed from the site, and with them every post that carries one.

- A tag is banished with one click from the flagged-tag queue ([gate
  12](#gate-12)). The board then jails every post carrying it, and a post
  that gains the tag later is jailed the moment it does.
- **The words are gone for everyone but the bots** (tag lists, autocomplete,
  tag panels, related tags), admins included. No setting reveals them;
  banished tags are moderated only in the jail panel.
- **The posts are withheld from everyone but the bots**, deleted or not. A
  post released from the jail keeps its tags and stays withheld while it
  carries a banished one: releasing lifts the jail, not the banishment.
- A tag is unbanished only in the jail panel. Unbanishing releases no post;
  each jailed post is still released on its own.

#### Your blocklist

Your own filter, and the only one. There is no site-wide blacklist: banished
posts are withheld on the server, so a second filter in the browser could
only hide a bug.

- It sits in a panel next to the refresh and purge buttons. Add and remove
  tags at will and the view updates as you go.
- A rule can be **locked** so it is not removed by accident.
- It starts empty. Tags on one line must all match; `-` excludes. Signed
  out, the list lives in your browser and joins your account when you sign
  in.
- Other apps can read it from your profile.

**It is a filter in your browser, not a gate on the server.** The board
still sends a blocked post to everyone allowed to see it, and your browser
hides its thumbnail and image. Its page, tags and image address are still
served. It decides what you choose not to see; who may see a post is decided
by the gates.

---

#### Your blocklist, for a post tagged `insect`

|  | you, who blocked `insect` | every other viewer |
|---|---|---|
| its thumbnail in listings | hidden in the browser | shown, as their gates allow |
| its own page | opens, image hidden in the browser | opens, as their gates allow |
| its image file, by address | loads | loads, as their gates allow |

## 6. Creator-private tags and generation data

*tags from a creator's prompt are the creator's alone*

Some tags on a post are **private**: the ones that came from its creator's
generation prompt, and the generation data itself (the prompt and settings).
**The creator decides, and until there is a control for sharing them, the
creator alone sees them**: not admins, not moderators, not the bots. The
creator is the Matrix account recorded for the post, matched to the viewer's
verified Matrix identity, never anything inferred from the post's tags.

The private tags are left out of the page entirely, including the part of
the page a blocklist matches against. So **your blocklist cannot match a tag
you are not allowed to see.** A post with no private tags keeps all of them.

This gate decides tags, not the image: the image follows the post's other
gates. It does not depend on the viewer's level, and on the path above it
has its own column, Private tags, after the post's own gates. It is the
only gate that trims the tags on a post's page. Gates 1, 5, 8 and 12 take
their tag names out of tag lists and autocomplete too, but a viewer those
names are hidden from is never shown the post.

**Tag grants** let staff give one user the ability to edit the one artist a
tag names. There is no grant that reveals private tags.

---

#### Example

`masterpiece` on a Matrix upload by `41chan_alice`, there only because her
prompt contained it. Every column of viewer, Admin and Pipeline included,
sees the post without that tag. Only **alice herself** sees it, along with
her generation data.

## 7. The edge check: browsers only

*anything that is not a browser is turned away before the board*

This gate is not part of the board; a request meets it before the board is
involved. **Every signed-out request to `booru.41chan.net` gets an invisible
Cloudflare check.** A browser passes it silently and is remembered; a reader
who is signed in never sees it. Behind it, the server itself refuses any
request that carries neither a session nor that clearance, so the rule holds
even while a change to it is still reaching every part of Cloudflare's
network.

The cost is that the board is closed to anything that will not run a
browser: scripts, crawlers and command-line tools. That is acceptable here
and would not be on an open site. **A 403 carrying a `cf-mitigated` header
is this gate working, not an outage.**

#### Exempt, each for a reason

- **Form submissions** are never checked at the edge, because a check can
  lose what was submitted. A person is checked on the form's page, and the
  submit that follows goes straight through.
- **The sign-in and signup pages** are exempt at the server too: they are
  the only pages a person must reach before holding any session, so nothing
  may ever stand between a new person and registering.
- **The media and sign-in exchange paths** enforce their own rules ([gate
  3](#gate-3)).
- **`robots.txt`** stays readable, so the refusal it declares can be read.
- **Discord's link previews** may fetch the front page, so a link pasted
  into Discord shows a preview.

---

#### Any page, say a `1girl` post's

|  | reaches the board |
|---|---|
| a signed-in browser | yes, unchecked |
| a signed-out browser | yes, after an invisible check; then gate 10 applies |
| scripts, crawlers, monitoring | no: 403 with `cf-mitigated` |
| Discord fetching a preview of the front page | yes |

## 8. Creator prefixes: whole sources hidden by default

*a post's source decides who sees it first*

Every post's creator tag carries a prefix naming where it came from. Each
prefix is visible to everyone, to members, or to admins.

**`aichan_` is admins only.** A post whose creator tag carries a hidden
prefix is hidden at every door, and the tag names are withheld from tag
lists and autocomplete. Admins and the bots always see them.

There are two ways out: the creator, once their claim on exactly that tag is
approved, sees their own posts; and an admin or that creator can **release**
the tag, after which its posts follow the ordinary rules. Prefix tags are
locked: only an admin or a bot can add or remove one.

---

| prefix | came from |
|---|---|
| `4chan_` | collected from 4chan |
| `41chan_` | posted on Matrix |
| `aichan_` | posted on the AIchan Discord; admins only |

A post tagged `aichan_someone` is also visible to `someone`, once their
claim on that tag is approved. Once the tag is released, the post follows
the other gates like any other.

## 9. Creator visibility: the creator's own choice

*what each creator chooses*

A creator chooses who sees their posts, for all of them or post by post:

- **public**: whoever the site's other gates allow. Narrows nothing.
- **groups**: members of the groups they list, plus people they name.
- **private**: only the people they name. No group ever opens a private
  post.

Creators can also **allow** and **block** named people, and **a block beats
every allow**. An explicit allow (a named viewer, a member of a listed
group, or the creator) can also open a post that gate 1 would hide from that
viewer, post and image alike, but never for a signed-out or banned viewer or
a jailed post. A narrowed post is hidden at query level and its page answers
as a missing post.

**Admins always see**, and every admin view of a post its creator hid is
written to the moderation log. Moderators can neither see nor act on it.

---

#### Example

Say the post is by `41chan_alice` and she named bob: bob sees it too, and so
does alice herself. If alice blocks carol, carol cannot see it, even through
a group alice opened.

## 10. Signed out: closed by default, general-rated only

*every page not on an explicit list is closed*

A signed-out visitor is refused **every page that is not on an explicit
list**, with the same 404 a hidden post gets; a 403 or a redirect to sign in
would confirm there is something there. A page added to the site later is
closed until someone opens it on purpose, and an automated test walks every
route to hold that.

Every other listing (popular, favourites, pools and the rest) is for
members. Everything that is open still passes the other gates: a sensitive
post is not on the front page either.

**Signed out sees general-rated posts only** (since 2026-11-08). Every
open page browses in safe mode for a signed-out visitor: only posts rated
general (`rating:g`) are drawn, listed, opened or have their image loaded. A
post rated sensitive, questionable or explicit is absent for them, as if
hidden, wherever it would otherwise appear, a creator's gallery bands
included. Signing in lifts it.

A **published page** ([gate 11](#gate-11)) shows exactly what it showed
before; this rule neither closes nor opens anything there. A Matrix reader
whom a room refuses is signed in, only not in that room, so a public creator
gallery's placed posts still reach them by their rank ([gate 3](#gate-3)).

**Images follow pages.** A signed-out visitor loads a post's image only
while that post's page would open for them. A cached answer can outlast a
post's "being shown" status by about three minutes.

---

#### What stays open

Narrowed so that none of it can be used to walk the board:

- the front page;
- the newest posts, or one featured creator's first page;
- a post's own page, only while the site is showing it to signed-out
  visitors: it is among the newest posts, in a promoted creator's curated
  set, or was shown to a signed-out visitor within roughly the last hour or
  two;
- promoted creator galleries.

## 11. Published pages: a grant, not a loophole

*published threads and creators' timed links: a deliberate, expiring grant*

Moderators can **publish** a thread as a page with a random, unguessable
address, which can expire. Publishing is a deliberate grant, separate from
the board's browsing rules: while the page is live, a reader holding the
address can see each image it shows, including one the board would hide from
that reader, such as a sensitive one. **A jailed, banished or flagged image
is never released:** the page withholds it, with no checksum or tag name in
what it sends. The publishing service re-reads the quarantine list every 60
seconds; if it cannot, the last good list holds for 30 minutes, and after
that the page withholds every image. When the page expires or is taken down,
the grant ends with it. If the service cannot be reached, the gate refuses.

**A creator's timed link is the same grant.** A creator picks up to 24 of
their own posts, at any rating, on their gallery's edit screen, and an end
date at most 30 days out; the booru hands that list to the same publishing
service once, and the service serves the page and the grant exactly as for a
published thread: the same withholding of jailed, banished and flagged
images on every view, the same end. The creator can end it early with End
now; a creator has at most 5 live links. Both numbers are settings. The
booru, not the service, decides which posts are the creator's own. A post
hidden later for any other reason stays on a live link until it ends or is
ended.

The moderation console itself is separate: it opens only to a Matrix account
at power level 70 or above in the moderators' room, and fails closed.

This grant sits beside the board, not in its order. Tick "Via a published
page" above to draw its own lane.

---

#### A published thread showing a `loli` image and a `troll_jail` image

|  | holding the live address | after it expires |
|---|---|---|
| the `loli` image | visible, signed in or not | refused unless the viewer's own gates allow it |
| the `troll_jail` image | never on the page | refused |
| an image carrying a flagged tag | withheld on the page | refused |

## 12. Flagged tags: a review quarantine

*a tag and its posts disappear at once, pending review*

An admin can **flag** any tag for review. The tag and every post carrying it
disappear at once. It is less severe than a banishment, because the point is
a quick review.

- **Everyone else:** every post carrying the tag, and the tag's name, are
  gone at every door (search, counts, pages, images, tag lists,
  autocomplete), including posts that gain the tag later.
- **Review:** a "Flagged tags" queue on the admin console shows who flagged
  it, when, and how many posts carry it; Matrix posts, which admins see only
  in their own rooms, are reviewed in the jail panel's Flagged tab.
  **Release** puts everything back at once. **Banish** is one click: the tag
  becomes banished ([gate 5](#gate-5)) and its posts are jailed. Both work
  from either place and are written to the moderation log, naming who
  pressed them.
- **Reach:** everywhere the jail reaches. The media gate refuses a flagged
  image on Matrix and on published pages, the moderation console withholds
  it from its outside views, and the Matrix bridge stops writing the tag's
  name into rooms.

A flag jails nothing and hides nothing from an admin. That is the difference
from a banishment.

---

#### Still visible to

- Admins and the Owner, on every post; a Matrix post only in the rooms they
  have joined ([gate 3](#gate-3));
- the board's system account;
- the bots, on the posts they uploaded (which is every post), and the names
  everywhere, because they tag with them.

## If something does not load

| what you see | gate | why |
|---|---|---|
| a 403 with a `cf-mitigated` header, on any page | [7](#gate-7) | the edge check, working |
| a script gets 403 where a browser works | [7](#gate-7) | only browsers pass |
| signed out, a page answers 404 that opens when signed in | [10](#gate-10) | closed by default |
| a list stops at 20, or page 2 answers 410 | [2](#gate-2) | below Member every list is one page of 20 |
| cannot register | [0](#gate-0) | no code, or a used, expired or revoked one |
| a board image answers 404 but the post's page opens | [3](#gate-3) | the image follows its post; a 503 means a service was unreachable |
| a Matrix image answers 401 | [3](#gate-3) | you are not signed in through Matrix |
| a Matrix image answers 403 | [3](#gate-3) | you are not in the room it was posted in |
| a Matrix image answers 404 for everyone, admins included | [4](#gate-4), [5](#gate-5), [12](#gate-12) | jailed, or carrying a banished or flagged tag |
| a Matrix image answers 404 in its own room | [3](#gate-3) | its post is hidden from you by another gate |
| a Matrix post opens for one viewer and 404s for another, admins included | [3](#gate-3) | the post follows its image's rooms |
| a tag's count is higher than the posts you can page through | [3](#gate-3) | counts include Matrix posts outside your rooms |
| a Matrix image stopped loading in a room it was posted in | [3](#gate-3) | the message that posted it there was deleted |
| a just-jailed or just-flagged image still loads for a minute or two | [3](#gate-3) | allows are cached for about three minutes at most |
| a section 404s for everyone | [2](#gate-2) | retired |
| a post opens for one viewer and 404s for another | 1, 4, 8, 9, 10 or 12 | see each gate |
| nobody, admins included, can see a jailed or banished post | [4](#gate-4), [5](#gate-5) | by design; it is moderated in the jail panel |
| signed out, an image link stopped working | [10](#gate-10) | a signed-out image loads only while its post is being shown signed out |
| a post is missing from a count as well as a page | 1, 4, 5, 8, 9 or 12 | hidden in the query, not on the page |
| a post is hidden in listings but its page opens | [5](#gate-5) | your own blocklist, in your browser |
| a tag is on a post but nowhere in autocomplete | 1, 5, 8 or 12 | words go with their posts |
| a tag and its posts vanished for everyone but admins | [12](#gate-12) | flagged for review |
| a tag shows for one viewer and not another on the same post | [6](#gate-6) | a creator-private tag |
| an image loads on a published page but not on the board | [11](#gate-11) | the published page is its own grant |

CANON. Lives in `fourier-basis`; hydrated into chanbooru and fourier-domain,
and rendered into the public page at 41chan.net/content-gating.html. Everything
from this paragraph to the end is for maintainers and is stripped from the
public page; the page above is written for members and visitors, so what
belongs only here belongs only here.

### Maintainers' notes

**Where the code is.** chanbooru's fork is the `chanbooru` branch (the
repository's default); `master` is an untouched upstream mirror and reads as
if the fork's rules were missing. Policy defaults are in
`config/danbooru_default_config.rb`; production's values in
`danbooru_local_config.rb`, untracked, with the canon copy at
`fourier-basis/ops/hetzner/danbooru/danbooru_local_config.rb`; the creator
prefix list at `ops/hetzner/danbooru/creator_prefixes.yml`. Gate numbers are
stable: fourier-coherence `coherence/accessmatrix.py` labels its probes by
them. Rulings and their history are in git, the phase registry and memory,
not here.

**By gate.** 0: `enable_signup?`, `signup_requires_token?`,
`UserSignup#initial_level`, `default_user_level`. 1: `restricted_tags`
(the full list, which the public page does not print),
`PostQuery#gated_metatags`, `Post#hidden_as_gated?`. 1/3/4/5/8/9/12:
`Post#hidden_from?`, asked by every door. 2: `User#can_browse_freely?`,
`#listing_page_limit`, `#listing_per_page_limit`,
`PaginationExtension#paginate`, `PaginationExtension::TIER_EXEMPT`,
`FourierRetiredSections` with `retired_sections`,
`status_page_visibility_level`. 3: fourier-auth and its edge Worker
(`worker/media-worker.mjs`, routes in `worker/wrangler.toml`: only
`/_matrix/client/v1/media/{download,thumbnail}` and `/fourier/booru/*`;
everything else passes to the origin), `MEDIA-URLS.md`,
`docs/design/GATE3_MATRIX_POSTS.md`, `unposted_media_assets_restricted?`,
`POST /exchange` for the zero-click fourier session. 4:
`TagBanishment.post_tags`, `Post#hidden_as_banished?`,
`POST /fourier_jail/release`, `GET /fourier_jail/release.json?since=`. 5:
`TagQuarantine` (banished state), `BanishTagJob`; the blocklist is
`blacklisted_tags`, served as `blocklist` `{rule, locked}` in
`/profile.json`. 6: `FourierTagSource` (non-public rows); tag grants are
`edit` only. 8: `creator_prefixes.yml` `visible_to`. 9:
`docs/design/CREATOR_VISIBILITY.md`. 10: `MembersOnly::ANONYMOUS_DOORS`,
`MembersOnly#anonymous_shown_post?`, `MembersOnly#anonymous_md5_ask?`. 11:
`GET /verify?gate=sample`, grant cookie `fourier_pub_<hash>`. 12:
`TagQuarantine` (flagged state).

**Gate 7, recorded copy of the edge rule.** fourier-coherence's `edge_rule`
probe (coh.105) reads the live rule through the cf CLI and compares it with
the block below: the expression with whitespace normalised, the action, and
whether it is enabled. A difference is RED on the plane. So a change made at
Cloudflare is written here the same day, and this block stays one fenced
block whose info line says where the rule lives. The probe token is never
written here: the rule tests it as `"<BOORU_PROBE_TOKEN>"`, and the probe
masks any quoted run of 32 or more hex digits on both sides before comparing.

```cf-rule gate-7 zone=6c1a27108bd8ec459e6e680a84f5f85c phase=http_request_firewall_custom rule=030ce108c13440dbbfc9d9f96cba30ca action=managed_challenge enabled=true
http.host eq "booru.41chan.net"
and http.request.method ne "POST"
and not starts_with(http.request.uri.path, "/fourier/")
and not http.request.uri.path in {"/robots.txt" "/favicon.ico"}
and not http.cookie contains "fourier_session="
and not starts_with(http.request.uri.path, "/iqdb_queries")
and not starts_with(http.request.uri.path, "/.well-known/acme-challenge/")
and not any(http.request.headers["x-fourier-probe"][*] eq "<BOORU_PROBE_TOKEN>")
```

The rule is "Useless Idiots" in the zone's custom ruleset. Since 2026-10-24
a `_danbooru2_session` cookie is no pass: Rails mints one for every anonymous
page view (memory booru-login-signup-are-challenged).

Behind it Caddy's `@no_clearance` (in `ops/hetzner/caddy/Caddyfile`, which
filedrift watches as `caddy-edge`) refuses a request that carries no
`cf_clearance`, no `X-Fourier-Identity` set by /verify from a real
`fourier_session`, and no probe token. Its exemptions are the edge rule's
plus `/login`, `/users/new`, the `Discordbot` user agent on `/`, and a POST
carrying `_danbooru2_session`. Tell the gate from the app by headers, never status: a
challenge carries `cf-mitigated` and `server: cloudflare`; the app carries
`x-request-id` and `x-runtime`. A health check must read the origin or treat a
`cf-mitigated` 403 as healthy.

**Gate 3, what "replaced" means.** Synapse keeps a working
authenticated-media handler and an R2 storage provider
(`s3_storage_provider`, `store_synchronous`), so on the box Synapse would
serve any image to any valid token with no room check. It is unreachable from
outside: Cloudflare routes the two media paths to the Worker, the origin's
firewall accepts 80/443 only from Cloudflare's ranges, Synapse's port is
loopback-only, and Caddy answers federation media with 403. Probed 2026-10-20
(test accounts claudekey, claudeone; the DM "thread-start test 2026-10-19"):
member 200; outsider 403 on download and thumbnail; 404 on legacy v3 and r0,
an extra segment, a thumbnail filename, a double slash and an encoded slash
(all of which the Worker passes to the origin); 401 without a token; 403
federation; 200 for the outsider only when asking Synapse on loopback. The
origin does not require Cloudflare's client certificate; the origin address
is the accepted boundary.

**Gate 4, repair.** A jailing is two writes: add `troll_jail`, then delete,
and the delete needs Approver (37). A refused delete leaves the post live but
withheld by the tag; sampling logs "booru did NOT change", and
`tools/jail-apply.ts --booru-only --md5 <list>` finishes it. Danbooru's
monthly approver pruning exempts the pipeline accounts; before that exemption
it demoted `sample` and every jail delete was refused for a night.

**Caches, in full.** Worker: allows only, keyed on a hash of the credential,
60 s booru, 150 s Matrix. fourier-auth: allows 120 s, an image's rooms 120 s,
a viewer's joined rooms 300 s, the quarantine document polled every 30 s with
a 30-minute stale limit. The board asks fourier-auth for a viewer's joined
rooms and caches them about 45 s. Sampling polls the quarantine document
every 60 s with the same 30-minute limit.

This file is the only copy anyone edits.
