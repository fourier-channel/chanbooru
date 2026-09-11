# chanbooru

A fork of [Danbooru](https://github.com/danbooru/danbooru) that serves as the
image board of a Matrix community. Upstream's README describes upstream; this
one describes what the fork changes, because several of upstream's
instructions no longer hold here.

## What the fork adds

- **Matrix identity.** Sign-in is by Matrix account, through a separate
  authorization service (fourier-auth) and a reverse-proxy identity header
  that the proxy strips from clients and sets itself. A popup sign-in lands
  on a done page; a first-party client can sign the board in with no clicks.
- **Media lives in object storage behind a permission gate.** Originals and
  the 180/360/720 variants the board renders from tmpfs are uploaded to R2,
  and every media URL is rewritten to a gated route. The board holds no
  media on disk and serves none.
- **Modulation**: a replacement skin and post page (gallery, navbar, landing
  panel, session strip) that is the default everywhere but the test
  environment.
- **Invite-only signup** with admin-issued signup tokens; public
  registration is off outside tests.
- **Tiered browsing.** New accounts are restricted: a clamped page size,
  hidden deleted-post and status pages, retired sections. Membership lifts
  it.
- **Moderation vocabulary**: banished tags (removed from the vocabulary and
  autocomplete), an enforced blacklist applied to every viewer, a troll-jail
  tag with a release endpoint for the pipeline that jails, and per-user
  tag grants.
- **Creator galleries and artist claims**, a landing page at the root
  route with an admin editor, a permission manifest with tooling to render
  the effective matrix, sort-aware previous/next on posts, tag-source
  provenance on posts written by the bridge, error-page art, and a
  session-observation bar.
- **Operational hardening** after a documented outage: puma workers and the
  database pool sized to each other, the app bound to loopback behind the
  proxy, `DANBOORU_REVERSE_PROXY` forced on.

## Running it

Upstream's `docker compose up` quickstart does not produce this board. The
compose file binds a host directory for images and expects locally built
image tags; `config/danbooru_local_config.rb` is tracked and carries the
deployment's policy (signup closed, restricted default level); and the root
route is the landing page. Deploy with `bin/chanbooru-deploy` (fast-forward,
build with `bin/build-docker-image`, restart, verify), on a host prepared
for it. There is no one-liner that gives you a fresh instance to try.

## Development

Upstream's full suite cannot be green here: the fork's own gate is
`script/fork-tests.sh`, which runs the fork-owned tests inside the dev
stack, and the commit hook is `.githooks/pre-commit` (opt in with
`git config core.hooksPath .githooks`). `coherence.gate.yaml` declares the
gate. Danbooru's `docs/README.md` remains upstream's document.

Support for the fork is not upstream's Discord or discussions. Upstream's
`bin/setup` clones upstream, not this repository.

## License

Danbooru's license applies to the upstream code; see `LICENSE`. Fork-specific
code is under the same terms.
