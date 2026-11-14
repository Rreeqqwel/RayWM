# Repository workflow

## Branches

- `master` is the only development branch and keeps every development
  artefact: source, tests, all documentation (`docs/`, README, CHANGELOG,
  SECURITY, AGENTS), measurements, packaging and CI. Commit and push
  development work here.
- `beta` is the default branch. It is a generated **source-only** tree for
  Beta releases: `src`, `protocol`, `config`, `packaging`, `scripts`,
  `build.zig`, `build.zig.zon`, `LICENSE`,
  `.github/workflows/release.yml` and `SOURCE-COMMIT`. Never commit,
  merge or edit it by hand.
- `release` is the same source-only tree for Stable releases. Never commit,
  merge or edit it by hand.
- Generate or update `beta`/`release` only with
  `scripts/make-release-branch.sh <master-sha> beta|release`, then push the
  resulting fast-forward. Never force-push. Full rules and tag workflow:
  `docs/RELEASE-WORKFLOW.md`.
- Do not add docs, tests, CHANGELOG, README, SECURITY, agent files or
  development CI to `beta` or `release`.

## Publishing

- When the user asks you to make commits, also push those commits to the GitHub
  repository at `origin`; local-only commits do not complete the request.
- Unless the user specifies another branch or asks for a pull request, publish
  completed, validated changes directly to `master`.
- Fetch the target branch before pushing and preserve remote changes. Never
  force-push or overwrite unrelated work. If publishing is blocked, report the
  exact blocker and clearly state which commits remain local.
- In the final response, distinguish local commits from commits successfully
  pushed to GitHub, and link to the published commits when available.

## Documentation

Every change that alters the public surface updates the affected
documents in the same commit, and pushes them with it. Behaviour, API,
settings, defaults and limits stay in one place per document; do not
append a note about the change where the old sentence belongs (release
notes go to `CHANGELOG.md`).

| Change | Documents |
|---|---|
| `raywm.*` or `ctx.*` function, argument, return value, event | `docs/API.md` (table row, section text, example if it teaches) |
| `ray.conf` section, key, default, range, reload behaviour | `docs/CONFIGURATION.md` table, `config/ray.conf`, `docs/API.md` (`raywm.settings`) |
| IPC method, field, limit, error | `docs/IPC.md`, `scripts/raywmctl` |
| command-line option, environment variable, log message users see | README options list, `docs/INSTALL.md` table |
| added, renamed, removed `src/*.zig` module | `docs/ARCHITECTURE.md` module table, README project layout |
| test suite, CI step, build flag | `docs/TESTING.md`, README |
| user-visible behaviour, fix, performance rule | `CHANGELOG.md` under the pending version and every doc that states the old behaviour |
| new measurements or screenshots | new `docs/measurements/vX.Y.Z/` directory, existing image replaced only when it shows the same thing |

- Run `tests/docs-sync.sh` before committing. It fails when an API
  name, setting, IPC method, option or module reference in the docs is
  missing or stale; CI runs it on every push.
- Documentation is part of the deliverable: a change whose docs still
  describe the old behaviour is not finished. Prune text the change made
  false instead of leaving it as history.
