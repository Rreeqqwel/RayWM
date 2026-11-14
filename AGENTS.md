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
