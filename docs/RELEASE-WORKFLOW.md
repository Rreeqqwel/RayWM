# Release workflow

RayWM uses three permanent branches and two public release channels.
This document is the rule book; `.github/workflows/release.yml` enforces
the parts a machine can check.

## Branches

| Branch | Purpose | Who updates it, how |
|---|---|---|
| `master` | Development and documentation: all source, tests, docs, CHANGELOG, agent instructions, measurements, build/packaging tools and CI. This is the only branch where development happens. | Direct pushes or merged pull requests. Force pushes and deletion are blocked. |
| `beta` | Beta releases. A generated **source-only** tree: `src`, `protocol`, `config`, `packaging`, `scripts`, `build.zig`, `build.zig.zon`, `LICENSE`, `.github/workflows/release.yml`, `SOURCE-COMMIT`. No docs, tests, CHANGELOG, README, SECURITY, agent files or development CI. **Default branch.** | Only `scripts/make-release-branch.sh <master-sha> beta`, then a fast-forward push. Never commit or merge here. Force pushes and deletion are blocked. |
| `release` | Stable releases: the same source-only layout as `beta`. | Only `scripts/make-release-branch.sh <master-sha> release`, then a fast-forward push. Never commit or merge here. Force pushes and deletion are blocked. |

`beta` and `release` are **derived**, not merged: every commit is generated
from a commit in `master` and records it in `SOURCE-COMMIT`. The generated
tree is linear and never contains the development tree, so the branches do
not share `master`'s commits after the initial cleanup. Their code is still
tested: CI runs on the recorded `SOURCE-COMMIT`, and the Release workflow
runs the complete suite on it before publishing.

The required check on `beta` and `release` is therefore the release-plan
check, not a test job on the filtered commit. A commit that cannot name a
master `SOURCE-COMMIT`, or whose release files differ from that commit,
is rejected by the Release workflow.

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
the next Stable only once it is newer (see "Version order").
`raywm-update` (since v0.2.2, [INSTALL.md](INSTALL.md#updates-raywm-update))
stores the subscription in `/etc/raywm/update.conf`, a file the package
does not own: the install scriptlet creates it once from the installed
package's channel and never changes it, so Beta ↔ Stable upgrades keep it.

## Version numbers and tags

- Beta: `vX.Y.Z-beta` (first candidate), then `vX.Y.Z-beta.2`,
  `vX.Y.Z-beta.3`, … (`-beta.1` is not used; `-beta` is the first).
- Stable: `vX.Y.Z-stable`.
- Tags are annotated (`git tag -a`), never moved or deleted (a ruleset
  blocks updates and deletion of `v*` tags).
- `build.zig.zon` `.version` and `src/lua.zig` `version` hold `X.Y.Z`
  (without the suffix) and must match the tag, which the workflow checks.
- `CHANGELOG.md` lives on `master` (not on `beta`/`release`) and must have a
  `## [vX.Y.Z]` section before the first Beta of a version. The Release
  workflow reads it from `master` for the notes.
- Every `beta`/`release` commit carries `SOURCE-COMMIT`, the full SHA of the
  tested `master` commit. The Release workflow requires it to be in
  `master` and the release files to match that commit.
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
| `v0.2.3-beta` | `0.2.3beta-1` |

`vercmp` orders these as listed: a Beta is older than the Stable of the same
version and newer than every earlier Stable, so an older Stable is never
offered as an update over a newer Beta. `tests/release-meta.sh` checks this
order with the real `vercmp`. Updaters must compare `pacman_version` with
`vercmp`, never tag strings.

## Release assets

Every release also has GitHub's automatic source ZIP/tarball for the tag;
the rules below are about the uploaded assets.

**Beta** (Pre-release, never "Latest"):
- `raywm-vX.Y.Z-beta[.N].tar.gz`: `git archive` of the tagged source-only
  commit, plus `zig-pkg/` (the pinned Zig dependencies, so it builds
  offline), `SOURCE-INFO` and `SOURCE-COMMIT`. It contains `src`,
  `protocol`, `config` with all shipped Lua plugins, `scripts`,
  `packaging/arch`, the build files and `LICENSE`; it contains no docs,
  tests, CHANGELOG, README, agent files, CI or measurement data. No
  binaries.
- `raywm-vX.Y.Z-beta[.N].tar.gz.sha256`, `SHA256SUMS`, `raywm-release.json`.

**Stable** (normal release, marked "Latest"):
- `raywm-X.Y.Z-1-x86_64.pkg.tar.zst`: built by `makepkg` from
  `packaging/arch/PKGBUILD.in` and the same kind of source archive. It
  installs `/usr/bin/raywm` (ReleaseSafe, `-Dcpu=baseline`, no test-only
  code), `/usr/bin/raywmctl`, `/usr/bin/raywm-update`, the default
  configuration (`ray.conf`, `init.lua`) and plugins in
  `/usr/share/raywm/config`, `/usr/share/wayland-sessions/raywm.desktop`
  and the license. Documentation stays on `master`. It never touches
  `~/.config/raywm`.
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

`raywm-update` (src/update.zig) treats all of it as untrusted input: it
derives channel, `pkgver` and the expected asset name from the tag with
the rules above, ignores releases whose tag is outside the scheme (the
historical ones), drafts, releases whose Pre-release flag contradicts the
tag and releases without the asset or the metadata, and accepts
`raywm-release.json` only if every field agrees with the tag and the asset
size with GitHub's listing; otherwise it falls back to the next older
release. Download URLs must be
`https://github.com/Rreeqqwel/RayWM/releases/download/<tag>/<asset>`.
Changing asset names, the tag scheme or the metadata fields therefore
breaks updates for installed versions: keep them, or add a new schema.

## Beta → Stable

1. On `master`: CHANGELOG section, version in `build.zig.zon` and
   `src/lua.zig`, full local matrix (`docs/TESTING.md`) and CI green.
2. Generate the Beta branch commit from that tested master commit:
   `scripts/make-release-branch.sh <master-sha> beta` and
   `git push origin beta` (a fast-forward; the commit records
   `SOURCE-COMMIT`).
3. Tag the beta head and push the tag:
   `git tag -a vX.Y.Z-beta -m "RayWM vX.Y.Z-beta" beta && git push origin vX.Y.Z-beta`.
   The Release workflow tests `SOURCE-COMMIT`, checks that the release
   files match it, builds the source archive and publishes the Pre-release.
   Manual `workflow_dispatch` runs are dry runs, but they need an existing
   tag because the tree is read from it.
4. Public testing (docs/GAMING-TESTING.md and HARDWARE-TESTING.md for
   hardware-dependent areas). A fix needs a new commit on `master`, a new
   `make-release-branch.sh <master-sha> beta` append and a new candidate
   `vX.Y.Z-beta.2` (steps 1–3). Stable never gets code that was not
   published as a Beta.
5. When a Beta is accepted, generate `release` from the **same master
   source commit** the Beta recorded:
   `source=$(git show vX.Y.Z-beta:SOURCE-COMMIT)` then
   `scripts/make-release-branch.sh "$source" release` and
   `git push origin release`.
6. Tag the stable head and push it:
   `git tag -a vX.Y.Z-stable -m "RayWM vX.Y.Z" release && git push origin vX.Y.Z-stable`.
   The workflow refuses a Stable tag unless a published Beta Pre-release of
   the same version records the same `SOURCE-COMMIT` and the tag commit is
   in `release`. The Stable and Beta trees are therefore identical even
   though their branch histories are independent.

## Testing requirements

The Release workflow calls the complete CI suite
(`Rreeqqwel/RayWM/.github/workflows/ci.yml@master`, including
`tests/perf.sh` and `tests/release-meta.sh`) on the `SOURCE-COMMIT` recorded
in the tag, because `beta` and `release` carry no tests. It also checks that
the tagged release files are identical to that master commit. It then runs
`tests/release-archive.sh --build` from the master checkout (structure, no
binaries, versions, a ReleaseSafe build and a headless config check) against
the source-only archive, and builds the pacman package from that archive
with `scripts/arch-package.sh` (as an unprivileged user, as
`raywm-update` does on users' machines for a Beta). It runs
`tests/release-package.sh` (pacman metadata, dependencies, file list
including `raywm-update` and `ray.conf`, nothing in `/etc`, baseline-CPU
binary without test code, headless start with the packaged configuration)
and `tests/release-install.sh` (real `pacman -U`, reinstall and `-R` in the
container: `/etc/raywm/update.conf` created once with the package's
channel, unowned, kept across reinstall and removal, switched by
`raywm-update --set-channel`). Only the Stable package is published; for a
Beta it proves the archive builds into a valid package. Publishing depends
on every job; a failure stops before anything is uploaded. CI runners have
no GPU display: hardware validation is manual and recorded in the release
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

## Migration to source-only release branches (2026-11-14)

`master` already held the development tree; `beta` and `release` held full
copies of it. They now hold generated source-only trees, and `beta` is the
default branch. The first cleanup commits were generated from the old
`beta` and `release` heads (so the already published `v0.2.3-beta` tag
still points to its full development commit) and appended as fast-forwards;
no history was rewritten. From the next candidate on, every release commit
is generated from the tested `master` commit and records it in
`SOURCE-COMMIT`. The required `build + tests (pixman)` check was removed
from the `beta`/`release` rulesets because the filtered tree has no tests;
the Release workflow now runs that suite on `SOURCE-COMMIT` instead.

## Migration record (2026-10-24, historical)

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

Outcome of the migration:

- `master` = default branch. `main` and the merged branches
  `feature/core`, `feature/output-mode`, `feature/v0.1.2-input-focus`,
  `feature/v0.2.0-complete`, `feature/v0.2.1-gaming` and `release/v0.1.1`
  were deleted after checking that each is an ancestor of `master`
  (`release/v0.1.1` also blocked the name `release`: Git cannot have both
  `refs/heads/release` and `refs/heads/release/…`). All four historical tags
  and releases are unchanged.
- `release` stays at `76d2d8c` (v0.2.0) until the first `-stable` release.
- `v0.2.1-beta` (on `4c74e80`) has no release: the first workflow version
  misread the pushed tag as lightweight. Tags are immutable, so the fix
  shipped as the next candidate, `v0.2.1-beta.2` (`618c25c`), the first
  published Beta. `beta` points to it.
- Rulesets: `master` (no deletion or force push), `beta`/`release`
  (no deletion or force push, linear history, required check
  `build + tests (pixman)`), tags `v*` (no update or deletion).
