# Repository workflow

- When the user asks you to make commits, also push those commits to the GitHub
  repository at `origin`; local-only commits do not complete the request.
- Unless the user specifies another branch or asks for a pull request, publish
  completed, validated changes directly to `master`.
- Fetch the target branch before pushing and preserve remote changes. Never
  force-push or overwrite unrelated work. If publishing is blocked, report the
  exact blocker and clearly state which commits remain local.
- In the final response, distinguish local commits from commits successfully
  pushed to GitHub, and link to the published commits when available.
