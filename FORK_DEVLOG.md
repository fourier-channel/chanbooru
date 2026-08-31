<!-- coherence:hydrated -- canon is fourier-basis/docs/repos/chanbooru/FORK_DEVLOG.md
     Edit canon and run `coherence hydrate`, never this delivered copy.
     An edit here is drift: hydration will refuse to overwrite it and the
     doc axis reports it edited-in-place until someone promotes or discards it. -->
# Chanbooru — Fork Dev Log

**Fork of:** danbooru/danbooru  ·  **Your repo:** sabertrtr/chanbooru
**Local checkout:** /opt/danbooru/ (this is the full source tree AND the deployment dir)
**Part of:** the Fourier / 41chan ecosystem (booru backend behind the eventual new UI)
**Status:** Fork set up, build pipeline proven, baseline verified identical to upstream.
No application code changes yet — media-gating work is the next phase.

---

## 1. Why this fork exists

Two goals:
1. Long-term: a completely new UI layered over Danbooru as a headless backend. That UI is a
   SEPARATE project (not a Danbooru fork) talking to Danbooru's API + fourier-auth for media.
2. Interim + learning: browsable as an actual booru now, and deeper exposure into Danbooru's
   internals. This is why a fork (not just a sidecar/config override) was chosen.

The immediate technical driver: route Danbooru's media serving through fourier-auth so that
booru media is gated by Matrix permissions, instead of being served openly from /data/.

Licensing: Danbooru is BSD-2-Clause — permissive, allows commercial use and private
modifications; only requires retaining the copyright/license notice. (This fork is public
anyway, partly as a gesture to the maintainer.)

---

## 2. Repo / branch structure

- origin = git@github.com:sabertrtr/chanbooru.git (SSH; your fork, where you push)
- upstream = https://github.com/danbooru/danbooru.git (HTTPS; for fetching their updates)

Branch discipline (deliberate, to keep upstream syncing clean):
- master — PRISTINE mirror of upstream. Never put your changes here. Fast-forward only.
- chanbooru — your work branch. ALL modifications live here (deploy config now, media-gating
  next).

Sync workflow when upstream updates:
  git checkout master
  git fetch upstream
  git merge --ff-only upstream/master
  git push origin master
  git checkout chanbooru
  git rebase master      (replay your changes on top of the new upstream)

---

## 3. What is currently changed on the chanbooru branch

Only DEPLOYMENT config so far — NO application code:

- docker-compose.yaml: DANBOORU_REVERSE_PROXY="true" (behind Cloudflare); image storage
  switched from a Docker named volume to the bind mount /mnt/storage/danbooru-images:/images;
  port bound to 127.0.0.1 only; named image volume commented out.
- .env: appended DANBOORU_IMAGE=danbooru:latest so the deployment uses the locally-built fork
  image instead of pulling ghcr.io/danbooru/danbooru:production.

These are deployment-environment specifics. They cause minor merge friction on upstream sync
but are small and isolated.

---

## 4. Build pipeline (proven on this hardware)

Danbooru builds via the maintainers' own script: bin/build-docker-image danbooru
- Builds from git archive HEAD (COMMITTED tree only — commit before building).
- Produces two images: danbooru:latest (production) and danbooru:development.
- Uses buildkitd.toml to cap stage parallelism at 1 (avoids OOM); within stages JOBS=nproc.
- Heavy multi-stage build: compiles MozJPEG, VIPS, FFmpeg, ExifTool, OpenResty, Ruby 4.0.2,
  Node 24, plus Rails assets. Takes tens of minutes. Ran cleanly on the 12-core/64GB host.
- Run the long build inside tmux (session name was chanbooru-build) so SSH drops don't kill it.

Deploying the built image:
- The compose image refs are ${DANBOORU_IMAGE:-ghcr.io/danbooru/danbooru:production} at two
  places (the base template the app/cron/jobs inherit, and the nginx service).
- IMPORTANT: compose variable substitution reads from the project-dir .env file (and shell
  env), NOT from .env.local. .env.local is mounted INTO the container as app config — a
  different mechanism. So DANBOORU_IMAGE must be in .env (or inline/shell) to take effect.
- Verify what compose will use: docker compose config | grep "image:"

---

## 5. Baseline verification (done)

Confirmed the fork builds and runs IDENTICALLY to the upstream image before any code changes:
- danbooru-danbooru-1 runs image danbooru:latest (the local build), not the ghcr pull.
- App + DB working: API returns post data; a known existing post (#4, created earlier by the
  bridge) resolves HTTP 200.
- All data intact — only the application image was swapped; Postgres, /mnt/storage images, and
  volumes untouched.

This is the known-good baseline: any future breakage is attributable to your changes, not the
fork setup.

---

## 6. The media-gating target (next phase — NOT yet done)

Current state of Danbooru media serving (the gap to close):
- Served by OpenResty (nginx + Lua), config at /danbooru/config/nginx.conf (in-repo) which is
  mounted as a Docker config into the nginx container.
- The /data/ location maps to /images/ (root /images; rewrite ^/data/(.*) /$1) and serves
  files as OPEN static files with NO auth. This is what must be gated.
- Files physically stored under /images/<variant>/xx/yy/<md5>.<ext> (variants: 180x180,
  360x360, 720x720, sample, original).

The auth gate (fourier-auth) is already built, containerized, and reachable from Danbooru's
network as http://fourier-auth:8010. It proxies media from Synapse using the viewer's
Matrix-session token and enforces Matrix permissions. See /opt/fourier/auth/.

Design intent for the integration (to be worked out in implementation):
- Danbooru stores metadata + the MXC URI (pointer), not bytes long-term. The bridge already
  writes posts with the MXC as source.
- Media requests should route through fourier-auth (gated) instead of /data/ open static.
- Open questions to resolve when implementing: how the user's fourier-auth session cookie
  reaches the gate from a booru page; how a Danbooru post resolves to its MXC at request time;
  whether gating is done by modifying the OpenResty /data/ location (access_by_lua ->
  fourier-auth check) or by changing how Danbooru renders image URLs (Ruby views/helpers).
  The OpenResty/Lua route is likely least invasive; Ruby view changes are the deepest cut.

---

## 7. Operational reference

Build the fork image (commit first):
  cd /opt/danbooru
  git commit --all -m "..."          (or ensure HEAD is what you want)
  tmux new-session -d -s chanbooru-build "bin/build-docker-image danbooru 2>&1 | tee /tmp/chanbooru-build.log"
  tail -f /tmp/chanbooru-build.log

Deploy (uses danbooru:latest via .env override):
  cd /opt/danbooru && docker compose up -d

Confirm running image:
  docker inspect danbooru-danbooru-1 --format '{{.Config.Image}}'

Sync from upstream: see section 2.

---

## 8. Cross-references

- fourier-auth (the media gate): /opt/fourier/auth/ — repo sabertrtr/fourier-auth
- fourier-bmb (the bridge that creates posts + writes MXC tags): /opt/fourier/bmb/ — repo
  sabertrtr/fourier-bmb
- Both have their own DEVLOG.md. fourier-auth/DEPENDENCIES.md has the cross-cutting version
  manifest.
- GitHub org fourier-channel exists (personal) for eventual consolidation of these repos.

---

## 9. Backlog -- deferred / shelved

- **Autotagger self-training loop (SHELVED, operator 2026-08-06).** Feeding
  user-corrected tags back into the tagger so it self-improves is parked until
  the tag sample size is large enough to be worth it. Nothing is blocked on it:
  the tag provenance model already records exactly what a training feed needs
  (creator / auto / both / human buckets + approval status), so the loop can be
  built on top when it is un-shelved. Not started; revisit when tag volume
  warrants.
- **Custom saved sorts.** Gallery navigation ships the default sorts (#, date,
  same-artist); user-saved custom sorts (a tag/query persisted to settings) are
  designed but not yet built.
- **Thread panel.** Replacing comments with an embedded Matrix thread view is
  cross-repo with technetium and deferred to its own phase.

---

Development log for the chanbooru fork. Written at the end of the fork-setup / baseline phase,
before any application code changes.
