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
- **Media can live in object storage behind a permission gate.** On the
  community's deployment, originals and the 180/360/720 variants the board
  renders from tmpfs are uploaded to R2, and every media URL is rewritten to
  a gated route, so that board holds no media on disk and serves none. That
  storage is configured by the deployment's own local config, which is not in
  this repository: a checkout without it stores media on the storage drive
  and serves it from `/data`, as upstream does.
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
  database pool sized to each other, the published port bound to loopback so
  the board is reached only through a proxy, `DANBOORU_REVERSE_PROXY` forced
  on.

## Installing it somewhere else

Upstream's quickstart does not produce this board: `docs/DOCKER.md`,
`bin/setup` (which clones upstream, not this repository) and the comment at
the top of `docker-compose.yaml` are upstream's and describe upstream's
compose file, not this one. The steps below do. They were rehearsed end to
end on a fresh Ubuntu 24.04 host on 2026-10-19 (Docker 29.9, Compose v5.6):
build, deploy, first owner, an upload, and the image served back.

### What the host needs

- **Linux with a GNU userland** -- bash, coreutils, `findmnt` (util-linux),
  git and curl -- and Docker Engine with the buildx and compose plugins.
  The scripts run as root (`sudo`).
- **A separate filesystem mounted at `/mnt/storage`.** The images live in
  `/mnt/storage/danbooru-images`, and every deploy refuses a directory that
  sits on the root disk, because that is where it lands when the drive did
  not mount.
- **Disk**: about 13 GB under `/var/lib/docker` after the first build, plus
  about 200 MB per release under `/srv/danbooru` (five are kept).
- **Outbound network for the first build**: Docker Hub, ghcr.io, GitHub, the
  Ubuntu archive, ruby-lang.org, nodejs.org, openresty.org, rubygems.org and
  the npm registry.
- **A reverse proxy in front.** The board answers only on `127.0.0.1:3000`,
  and it trusts `X-Forwarded-*` headers, so the proxy must set them (the
  header list is in `docs/DOCKER.md`, "Running a reverse proxy").

### Steps

1. **Clone the fork's branch.** The repository's default branch, `master`, is
   a pristine mirror of upstream; the fork is `chanbooru`.

        sudo git clone -b chanbooru https://github.com/fourier-channel/chanbooru /opt/danbooru
        cd /opt/danbooru

   Any directory works; the scripts' usage lines say `/opt/danbooru`.

2. **Write the four files the repository does not carry.** They are
   gitignored, and compose refuses to start without the first three.

   `.env` is read by compose itself, and it is the ONLY file compose reads
   for `${...}` values, so these two must be here and not in `.env.local`:

        DANBOORU_IMAGE=danbooru:latest
        DANBOORU_CANONICAL_URL=https://booru.example.com

   Without `DANBOORU_IMAGE`, compose runs upstream's published image against
   this fork's code and the app crash-loops on missing gems. Without
   `DANBOORU_CANONICAL_URL` (or with it only in `.env.local`), the board's
   own address falls back to `http://localhost:3000`.

   `.env.local` holds secrets for Rails, and the app runs as uid 1000, so it
   must be readable by that uid. A root-only file stops the app with
   `Errno::EACCES`.

        sudo sh -c 'umask 027; printf "DANBOORU_SECRET_KEY_BASE=%s\n" "$(openssl rand -hex 64)" > .env.local'
        sudo chown root:1000 .env.local

   Without the key, each container invents its own on every start: everyone
   is signed out on restart, and links signed by one container fail in
   another.

   `config/danbooru_local_config.rb` holds your overrides of
   `config/danbooru_default_config.rb`, and may start empty
   (`sudo touch config/danbooru_local_config.rb`). The fork's policy --
   closed signup, invite codes, retired sections, the browsing tier -- is in
   the default config, so an empty file gives you the same board.
   Policy belongs in this file rather than in `DANBOORU_*` environment
   variables: an environment value is a string, so `DANBOORU_ENABLE_SIGNUP=false`
   is truthy and opens signup.

   `fourier-config/creator_prefixes.yml` is the live creator-prefix list,
   read without a restart. Start from the repository's copy:

        sudo mkdir -p fourier-config
        sudo cp config/fourier/creator_prefixes.yml fourier-config/

3. **Install the image directory** on the mounted drive:

        sudo bin/chanbooru-storage install

4. **Deploy.**

        sudo bin/chanbooru-deploy

   It checks the image directory, builds the image when the host has none
   (from source: Ruby, libvips, FFmpeg, OpenResty and the gems; about 28
   minutes on two cores in the rehearsal), installs the commit as a release
   under `/srv/danbooru`, recreates the containers, and passes only when the
   running code is that commit and the front page answers 200. Later deploys
   run the same command: it fast-forwards `origin/chanbooru` and rebuilds the
   image only when a runtime file changed, so a code change takes seconds.
   `sudo bin/chanbooru-deploy --rollback` goes back one release.

5. **Make the first account, which becomes the Owner.** Signup needs an
   invite code; mint one as the system account the database was seeded with:

        sudo docker compose exec danbooru bin/rails runner \
          'puts SignupToken.create!(creator: User.system, usage_limit: 1, note: "first owner").token'

   Open `/users/new`, enter the code, and register. Invite everyone else from
   the admin menu (`/admin/signup_tokens`).

6. **Make a posting account.** Only accounts named in
   `fourier_posting_bot_names` (`sample` and `tunnel`) may upload or post --
   everyone else, the Owner included, gets 403. The community's bridge,
   fourier-tunnel, posts as `tunnel`:

        sudo docker compose exec danbooru bin/rails runner \
          'u = User.create!(name: "tunnel", password: SecureRandom.hex(20), password_confirmation: nil, level: User::Levels::BUILDER); puts ApiKey.create!(user: u, name: "bridge").key'

   Upload with `POST /uploads.json`, then `POST /posts.json` with the
   `upload_media_asset_id` it returns, authenticated as that account.

### What a stand-alone board does without the rest of the suite

- **Media** is stored on the storage drive and served by the board's own
  nginx at `/data`.
- **Password sign-in** works. **Matrix sign-in** (`/fourier/login`) and the
  identity header need a fourier-auth container that the board's nginx can
  reach as `fourier-auth:8010` on the compose network; without one that route
  answers 502 and every visitor is a booru user or anonymous.
- **Defaults that name the community**: `landing_blog_index_url`,
  `fourier_sample_url`, `fourier_matrix_server_name` and `source_code_url`
  point at its sites, and the signup page calls the board 41chan. Override
  the settings in `config/danbooru_local_config.rb`.

## Development

Upstream's full suite cannot be green here: the fork's own gate is
`script/fork-tests.sh`, which runs the fork-owned tests inside the dev
stack, and the commit hook is `.githooks/pre-commit` (opt in with
`git config core.hooksPath .githooks`). `coherence.gate.yaml` declares the
gate. Danbooru's `docs/README.md` remains upstream's document.

To run the gate on a fresh clone: add upstream
(`git remote add upstream https://github.com/danbooru/danbooru.git && git fetch upstream`
-- the script derives the fork's tests from the diff against `upstream/master`
and refuses without it), build the dev image from this fork
(`TARGETS=development bin/build-docker-image danbooru`, then
`DANBOORU_DEV_IMAGE=danbooru:development` in `.env`; otherwise the dev stack
runs upstream's published image), start the stack with `bin/dev up -d`, then
`bash script/fork-tests.sh`. The dev stack is upstream's: it has no
fourier-auth and no R2. The commit hook runs the organisation's coherence
checks, not the tests, and needs a `fourier-coherence` checkout beside this
one; without it every commit is refused.

Support for the fork is not upstream's Discord or discussions. Upstream's
`bin/setup` clones upstream, not this repository.

## License

Danbooru's license applies to the upstream code; see `LICENSE`. Fork-specific
code is under the same terms.
