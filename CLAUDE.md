<!-- phase:S-a9ad5a -->
# CLAUDE.md -- chanbooru

> Repo: `fourier-channel/chanbooru` (public; upstream Danbooru is BSD-2-Clause)
> **PRODUCTION SERVICE** at booru.41chan.net (Hetzner; `/opt/danbooru` there is
> both source tree and deploy dir). Media-gated through fourier-auth, fed by
> fourier-bmb. This is a Danbooru fork -- a large Rails app that is NOT ours;
> tread lightly. Runtime/deploy changes are OPERATOR-GATED: propose the block,
> the operator runs it. Dev work happens on the vesper checkout
> (`~/chanbooru`), on the `chanbooru` working branch -- NEVER on master.

Upstream's own agent guidance (theirs, untouched -- read it too): @AGENTS.md

## What this is

The 41chan Danbooru fork: metadata/classification layer for the media
pipeline. Receives posts from fourier-bmb, runs the autotagger service, serves
image requests through the fourier-auth gate. Fork rationale (master ref 4.3):
deeper exposure to Danbooru internals; plan to eventually replace the UI
entirely with a separate project speaking to Danbooru as a headless backend.
Long-term direction: chanbooru references NO media bytes of its own -- R2 is
the sole canonical store served via fourier-auth (decided and MINTED as
D-444bad; chanbooru's implementation share still pending, see below).

## The Fourier suite in brief

41chan.net is a self-hosted community platform: Matrix homeserver
(Synapse + MAS) + this booru + a custom web client, glued together by the
fourier suite (DSP-named, all under the `fourier-channel` org):

- **fourier-bmb** -- Matrix<->booru bridge appservice. Images posted in Matrix
  are uploaded to chanbooru, autotagged, and tags are written back to Matrix
  as state events.
- **fourier-auth** -- OIDC/PKCE media gate + presigned-URL broker for R2. The
  only door media is served through.
- **technetium** -- custom Matrix web client (Vite/React/matrix-js-sdk).
- **fourier-basis** -- PRIVATE canonical documentation + the fourier-phase
  registry. Source of truth for everything; canonical devlogs live there.
  It never enters dev sandboxes or non-vesper credential scopes.
- **fourier-coherence** -- cross-machine repo sync + status dashboard.
- **fourier-chan** -- the mascot / help bot, with her own canon repo.

Media pipeline TARGET state (D-444bad, minted in the phase registry): Matrix
upload -> autotagger runs inline on in-flight bytes -> tags forward to
Danbooru and back to Matrix state -> raw bytes land in R2 as the sole
canonical store -> R2 serves reads to Matrix and chanbooru alike, gated
through fourier-auth, regardless of interface.

## Working rules

Standard Fourier operator preferences, non-negotiable:

- One step per turn, with a verification gate ending every step.
- Hot and Ready: combinable commands combined into one paste block, ending in
  the relevant verification command.
- Disagree and commit: surface conflicts explicitly, get a ruling, record it;
  the prior version is noted as superseded, never silently dropped.
- Paste-safe edits: ASCII only in injected code; single distinctive-line
  anchors, never multi-line indented blocks; scripts delivered as quoted
  heredocs to /tmp, one heredoc per block; anchor-assert (dry-run guard)
  before any write.
- Secrets ONLY in .gitignored env files, entered via `read -s VAR` and
  referenced as variables; never in chat, never in URLs, never committed.
- Errors and decisions logged as draft G-/D- fourier-phase nodes in the
  devlog for later minting; never hand-insert S- markers.
- Devlogs are client-clean: no infrastructure internals, endpoints, bucket
  names, or server config. Canonical devlog: fourier-basis
  `docs/devlogs/devlog-chanbooru-01.md` -- read it first.
- Server separation is strict: Hetzner is production (root), vesper is dev
  (saber). Anything ambiguous gets asked about before it is assigned.

## Where chanbooru sits today (measured 2026-07-22, fresh vesper clone)

- **Live in production** at booru.41chan.net. On Hetzner, `/opt/danbooru` is
  the full source tree AND the deployment dir.
- **Branch law (deliberate design, not doc-debt):** `master` is a PRISTINE
  mirror of upstream, fast-forward only -- upstream boilerplate on master is
  intentional. ALL fork work lives on the `chanbooru` branch. Upstream sync:
  ff-merge upstream into master, push, then rebase `chanbooru` onto master
  (full workflow in the devlog).
- **Fork delta, measured: 4 commits ahead of master.** Two deployment-config
  commits (reverse proxy, bind-mount image storage to
  /mnt/storage/danbooru-images:/images, loopback-only port, DANBOORU_IMAGE
  pinned to the locally-built fork image), one in-repo fork devlog, and
  856114cc1: **media-gating application code has BEGUN** -- MXC-sourced posts
  routed through fourier-auth via config/danbooru_local_config.rb (+79) and
  config/nginx.conf (+10). Older claims of "no application code yet" are
  superseded by this measurement. How 856114cc1 relates to D-444bad's R2
  end-state (drop local /images; serve /data/ from R2 via fourier-auth --
  NOT yet implemented) is exactly what fork-notes reconciliation must
  document.
- **Devlog gap, known:** the canonical basis devlog predates 856114cc1 and
  still calls media gating "the next phase." Draft A-node queued. The in-repo
  FORK_DEVLOG.md (153 lines) vs the canonical basis devlog is a flagged
  Merge-and-Purge reconciliation; the basis copy is canonical by convention.
- **Tracked `.env` is upstream's own pattern** and carries non-secret values
  only (DANBOORU_IMAGE). Secrets live in gitignored `.env.local` -- on prod it
  is load-bearing at 640 root:1000 for the container uid; do NOT tighten to
  600 root:root, that breaks Rails on recreate (G-a41f77 class).
- **Secrets migration** (master ref section 7 table) still pending for
  chanbooru.
- **Vesper dev checkout established 2026-07-22** at `~/chanbooru`, both
  remotes wired (origin = fourier-channel, upstream = danbooru). A pre-fork
  relic (Feb compose experiment + a month-long crash-looping container stack)
  was laid to rest first. The autotagger image
  `ghcr.io/danbooru/autotagger:latest` (~3.3GB) on vesper is deliberate
  standing infrastructure -- NOT wreckage; it survives all cleanups.
- **Agent-doc slot:** on the working branch, upstream ships CLAUDE.md as a
  SYMLINK to AGENTS.md. This file replaces that symlink slot on the working
  branch ONLY; AGENTS.md is upstream's file and stays untouched (imported
  above); pristine master keeps its pristine symlink.

## Missions

Drafted by the operator per session. (The prior mission set -- branch map,
.env migration, and the blocked-later list -- is preserved in this file's git
history in fourier-basis.)

## Placement

Canonical copy: fourier-basis `docs/claude/CLAUDE-chanbooru.md` (this file;
the S-a9ad5a build-stamp refreshes automatically via fourier-commit.sh).
Working copy: `~/chanbooru/CLAUDE.md` on the `chanbooru` branch, replacing
the upstream symlink slot as described above. The two copies are identical
by construction (cp from basis); basis is canonical on any divergence.
