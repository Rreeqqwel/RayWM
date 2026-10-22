#!/usr/bin/env python3
"""Stop hook: remind to commit/push RayWM work. Never stages, commits or pushes.

Exit 0 (allow stop) when:
  - this stop was already continued by a Stop hook (stop_hook_active), so
    the reminder fires at most once per Stop cycle and can never loop;
  - not in a git work tree, git is missing, or anything unexpected happens;
  - tracked files are clean and no local commits are unpublished.
Untracked files are ignored: they may belong to the user or other agents.

Exit 2 (block once, message on stderr) when:
  - tracked files are modified or staged  -> commit reminder;
  - commits exist that the upstream (or, without an upstream, any remote)
    does not have                        -> push reminder.
"""
import json
import shutil
import subprocess
import sys
from pathlib import Path

COMMIT_MSG = (
    "[RayWM checkpoint] Tracked files have uncommitted changes. Review your own "
    "changes, verify, and commit a coherent milestone (never unrelated or "
    "pre-existing work), then push. If tests, auth, remote or branch protection "
    "block this, report the exact blocker. If these changes are not yours, say so and finish."
)
PUSH_MSG = (
    "[RayWM checkpoint] {n} local commit(s) are not on {where}. Push them with an "
    "ordinary `git push` (no force), or report the exact blocker."
)


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(event, dict) or event.get("stop_hook_active") or not shutil.which("git"):
        return 0
    cwd = Path(event.get("cwd") or ".")

    def git(*args):
        return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=3, check=False)

    inside = git("rev-parse", "--is-inside-work-tree")
    if inside.returncode or inside.stdout.strip() != "true":
        return 0

    # Only tracked files count; untracked ones may belong to someone else.
    status = git("status", "--porcelain", "--untracked-files=no")
    if status.returncode == 0 and status.stdout.strip():
        print(COMMIT_MSG, file=sys.stderr)
        return 2

    if git("rev-parse", "--verify", "-q", "HEAD").returncode:
        return 0  # no commits yet
    upstream = git("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
    if upstream.returncode == 0:
        where = upstream.stdout.strip()
        ahead = git("rev-list", "--count", "@{upstream}..HEAD")
    else:
        if not git("remote").stdout.strip():
            return 0  # no remote configured: nothing to push to
        where = "any remote (no upstream set)"
        ahead = git("rev-list", "--count", "HEAD", "--not", "--remotes")
    n = ahead.stdout.strip()
    if ahead.returncode == 0 and n.isdigit() and int(n) > 0:
        print(PUSH_MSG.format(n=n, where=where), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
