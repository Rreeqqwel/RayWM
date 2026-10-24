# Release workflow

RayWM uses three permanent branches and two public release channels.
This document is the rule book; `.github/workflows/release.yml` enforces
the parts a machine can check.

## Branches

| Branch | Purpose | Who updates it, how |
|---|---|---|
| `master` | Development: all source, tests, docs, CHANGELOG, agent instructions, build and packaging tools, CI configuration, experiments. Default branch. | Direct pushes or merged pull requests. Force pushes and deletion are blocked. |
| `beta` | Public testing. Holds exactly the commits that were offered as Beta candidates. | Fast-forward to a commit of `master` whose CI passed. Force pushes, deletion and commits without a passing `build + tests (pixman)` check are blocked. |
| `release` | Stable. Holds only commits that were published as a Beta and then promoted. | Fast-forward to a commit that carries a published `vX.Y.Z-beta[.N]` tag. Same protection as `beta`. |

Every commit on `beta` and `release` is also in `master`'s history (they
only ever fast-forward to commits from `master`). Nothing is developed on
`beta` or `release` directly.

Temporary branches (`feature/*`, `fix/*`, `hotfix/*`) branch from
`master`, run CI, and are merged back into `master`.

## Channels

| Channel | Receives | Asset |
|---|---|---|
| Beta | Beta and Stable releases | source archive `raywm-vX.Y.Z-beta[.N].tar.gz` |
| Stable | Stable releases only | Arch Linux package `raywm-X.Y.Z-1-x86_64.pkg.tar.zst` |

A subscription is a user setting, not a property of the installed
version: after `v0.2.1-beta → v0.2.1-stable` a Beta subscriber still gets
`v0.2.2-beta`, and a Stable subscriber who happens to run a Beta build gets
the next Stable only once it is newer (see "Version order"). The future
`raywm-update` tool stores the channel separately; this repository only
publishes the data it needs.

## Version numbers and tags

- Beta: `vX.Y.Z-beta` (first candidate), then `vX.Y.Z-beta.2`,
  `vX.Y.Z-beta.3`, … (`-beta.1` is not used; `-beta` is the first).
- Stable: `vX.Y.Z-stable`.
- Tags are annotated (`git tag -a`), never moved or deleted (a ruleset
  blocks updates and deletion of `v*` tags).
- `build.zig.zon` `.version` and `src/lua.zig` `version` hold `X.Y.Z`
  (without the suffix) and must match the tag, which the workflow checks.
- `CHANGELOG.md` must have a `## [vX.Y.Z]` section before the first Beta of
  a version; it becomes the release notes.
- Historical releases `v0.1.0`, `v0.1.1`, `v0.2.0` and `v0.2.1` predate this
  scheme. Their tags, releases and assets stay as they are; the scripts treat
  them as channel `legacy`.

### Version order (pacman `vercmp`)

| Tag | pacman version |
|---|---|
| `v0.2.1-beta` | `0.2.1beta-1` |
| `v0.2.1-beta.2` | `0.2.1beta.2-1` |
| `v0.2.1-stable` | `0.2.1-1` |
| `v0.2.2-beta` | `0.2.2beta-1` |

`vercmp` orders these as listed: a Beta is older than the Stable of the same
version and newer than every earlier Stable, so an older Stable is never
offered as an update over a newer Beta. `tests/release-meta.sh` checks this
order with the real `vercmp`. Updaters must compare `pacman_version` with
`vercmp`, never tag strings.

## Release assets

Every release also has GitHub's automatic source ZIP/tarball for the tag;
the rules below are about the uploaded assets.

**Beta** (Pre-release, never "Latest"):
- `raywm-vX.Y.Z-beta[.N].tar.gz`: `git archive` of the tagged commit
  without CI/agent files (`.github`, `.claude`, `CLAUDE.md`) and raw
  measurement data, plus `zig-pkg/` (the pinned Zig dependencies, so it
  builds offline) and `SOURCE-INFO`. It contains `src`, `protocol`, the
  `tests` that `build.zig` needs, `config` with all shipped Lua plugins,
  `scripts`, `packaging/arch`, and the user documentation. No binaries.
- `raywm-vX.Y.Z-beta[.N].tar.gz.sha256`, `SHA256SUMS`, `raywm-release.json`.

**Stable** (normal release, marked "Latest"):
- `raywm-X.Y.Z-1-x86_64.pkg.tar.zst`: built by `makepkg` from
  `packaging/arch/PKGBUILD.in` and the same kind of source archive. It
  installs `/usr/bin/raywm` (ReleaseSafe, `-Dcpu=baseline`, no test-only
  code), `/usr/bin/raywmctl`, the default configuration and plugins in
  `/usr/share/raywm/config`, `/usr/share/wayland-sessions/raywm.desktop`,
  documentation and the license. It never touches `~/.config/raywm`.
- `….pkg.tar.zst.sha256`, `SHA256SUMS`, `raywm-release.json`.

### Update metadata (`raywm-release.json`, schema 1)

```json
{
  "schema": 1,
  "project": "raywm",
  "tag": "v0.2.1-beta",
  "commit": "<full SHA>",
  "channel": "beta",
  "channels": ["beta"],
  "version": "0.2.1",
  "prerelease": 1,
  "pkgver": "0.2.1beta",
  "pacman_version": "0.2.1beta-1",
  "compare": "vercmp(pacman_version)",
  "assets": [{"name": "...", "kind": "source", "size": 0, "sha256": "..."}]
}
```

`channels` lists the subscriptions that should be offered this release
(`["beta"]` for a Beta, `["beta", "stable"]` for a Stable). `kind` is
`source` or `arch-package`. An updater picks, among releases whose
`channels` contain the user's channel, the greatest `pacman_version` by
`vercmp` that is greater than the installed one, then verifies `sha256`.
New fields may be added within schema 1; a breaking change needs a new
schema number.

## Beta → Stable

1. On `master`: CHANGELOG section, version in `build.zig.zon` and
   `src/lua.zig`, full local matrix (`docs/TESTING.md`) and CI green.
2. Rehearse: run the **Release** workflow manually (Actions → Release → Run
   workflow, on `master`, tag `vX.Y.Z-beta`). It is always a dry run: it
   tests, builds and checks the assets and keeps them as workflow
   artifacts without tagging or publishing.
3. Promote the exact tested commit: `git push origin <sha>:beta` (a
   fast-forward; the ruleset requires the commit's CI to have passed).
4. Tag it and push the tag:
   `git tag -a vX.Y.Z-beta -m "RayWM vX.Y.Z-beta" <sha> && git push origin vX.Y.Z-beta`.
   The Release workflow runs the tests again, builds the source archive and
   publishes the Pre-release.
5. Public testing (docs/GAMING-TESTING.md and HARDWARE-TESTING.md for
   hardware-dependent areas). A fix needs a new commit on `master` and a new
   candidate `vX.Y.Z-beta.2` (steps 1–4). Stable never gets code that was not
   published as a Beta.
6. When a Beta is accepted, rehearse `vX.Y.Z-stable` (dry run), then
   promote **that Beta's commit** (not `beta`'s current head):
   `git push origin <beta-sha>:release`,
   `git tag -a vX.Y.Z-stable -m "RayWM vX.Y.Z" <beta-sha> && git push origin vX.Y.Z-stable`.
   The workflow refuses a Stable tag unless a published Beta Pre-release of
   the same version points to the same commit and the commit is in
   `release`.

## Testing requirements

The Release workflow runs the complete CI suite (`.github/workflows/ci.yml`,
including `tests/perf.sh` and `tests/release-meta.sh`) on the tagged commit,
then `tests/release-archive.sh --build` (structure, no binaries, versions,
build and unit tests from the extracted archive) and, for Stable,
`tests/release-package.sh` (pacman metadata, dependencies, file list,
baseline-CPU binary without test code, headless start with the packaged
configuration, `pacman -U`/`-R` in a clean container). Publishing depends on
every job; a failure stops before anything is uploaded. CI runners have no
GPU display: hardware validation is manual and recorded in the release
report.

## When a release run fails

- Nothing is published unless every job succeeded. Fix the cause on
  `master`.
- Do not delete or move the tag. If the tagged commit itself is wrong,
  publish the next candidate (`-beta.2`). If only CI infrastructure failed
  (network, runner), re-run the failed jobs; the workflow refuses to run
  against a tag that already has a release, so a re-run can never replace a
  published version.
- Keep failure logs (Actions keeps them; link them in the release report).

## Hotfixes

A hotfix is an ordinary change: branch `hotfix/<topic>` from `master` (or
commit to `master`), CI, then a new Beta candidate of the next patch
version (`vX.Y.(Z+1)-beta`), and Stable only after that Beta. Hotfixes are
never committed to `beta` or `release` directly.

## Temporary branches

Delete a `feature/*`, `fix/*` or `hotfix/*` branch once
`git merge-base --is-ancestor <branch> master` holds (its commits are in
`master`). Branches with commits not in `master` are kept until their fate
is decided. Tags keep every released commit reachable regardless of
branches.

## Migration record (2026-10-24)

Before the migration the default branch was `main` (only `5482beb`
"Initial commit"); all development lived in `feature/*` and
`release/v0.1.1`, each an ancestor of `feature/v0.2.1-gaming`
(`9552af7`). History was linear, so `master` was created from `9552af7`
without merges or cherry-picks. Initial `beta` = `9552af7` (v0.2.1, the
published, not yet hardware-validated candidate), initial `release` =
`76d2d8c` (v0.2.0). The original ref map is kept locally under
`refs/backup/migration-2026-10-24/`:

| Ref | SHA |
|---|---|
| main | 5482bebbaeb7d4c795d09d17565b637621d3fb22 |
| feature/core | 9efbdde13f02e09bca1d944118994b8f47508b5b |
| feature/output-mode | 2096b0cab1199b4602ae8b24e5cca6dc002af025 |
| feature/v0.1.2-input-focus | c3f2d2feb09a4e5bbdf409bee17fb94aab80bc92 |
| release/v0.1.1 | f428c053480a9a3f126bc2ae9ce3c4b8214dd53b |
| feature/v0.2.0-complete | 76d2d8c5dac5e9c99a8e8d08f6dce17cf2d0040f |
| feature/v0.2.1-gaming | 9552af71b119306acb2416952fa3b2c8010e458d |
| tag v0.1.0 (→ commit) | a5874f39… → 9efbdde13f02e09bca1d944118994b8f47508b5b |
| tag v0.1.1 | 09d1ffdd… → f428c053480a9a3f126bc2ae9ce3c4b8214dd53b |
| tag v0.2.0 | 6e63ee48… → 76d2d8c5dac5e9c99a8e8d08f6dce17cf2d0040f |
| tag v0.2.1 | 92364593… → 9552af71b119306acb2416952fa3b2c8010e458d |
