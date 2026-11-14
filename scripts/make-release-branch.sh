#!/bin/sh
# Builds the source-only tree used by the beta and release branches.
# Usage: scripts/make-release-branch.sh SOURCE_REF BRANCH
#
# SOURCE_REF is a commit in master whose code is being released (for the
# first cleanup it may also be the old beta/release head, which is in
# master's history). BRANCH is beta or release. The new commit keeps only:
#   src protocol config packaging scripts build.zig build.zig.zon LICENSE
#   .github/workflows/release.yml
# plus SOURCE-COMMIT, the master commit the Release workflow tests and
# documents. docs, tests, CHANGELOG, README, SECURITY, agent files and the
# development CI workflow stay on master.
#
# The commit is appended to the branch (linear history; no force-push).
# It is not pushed here. Run from any checkout of the repository.
set -eu
source_ref=${1:?usage: scripts/make-release-branch.sh SOURCE_REF BRANCH}
branch=${2:?usage: scripts/make-release-branch.sh SOURCE_REF BRANCH}
case "$branch" in beta|release) ;; *) echo "make-release-branch: branch must be beta or release" >&2; exit 2 ;; esac
root=$(git rev-parse --show-toplevel)
cd "$root"
source=$(git rev-parse "$source_ref^{commit}")
git merge-base --is-ancestor "$source" master ||
    { echo "make-release-branch: $source is not in master" >&2; exit 2; }
old=$(git rev-parse --verify "refs/heads/$branch" 2>/dev/null || true)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/tree"
paths=""
for p in src protocol config packaging scripts build.zig build.zig.zon LICENSE \
    .github/workflows/release.yml; do
    if git cat-file -e "$source:$p" 2>/dev/null; then paths="$paths $p"; fi
done
[ -n "$paths" ] || { echo "make-release-branch: no release files in $source" >&2; exit 2; }
# shellcheck disable=SC2086 # paths is a list of top-level paths
git archive "$source" -- $paths | tar -x -C "$tmp/tree"
# Older sources may predate this generator; the release tree keeps it so the
# next branch update can run from the release branch as well.
[ -e "$tmp/tree/scripts/make-release-branch.sh" ] ||
    cp "$root/scripts/make-release-branch.sh" "$tmp/tree/scripts/make-release-branch.sh"
printf '%s\n' "$source" >"$tmp/tree/SOURCE-COMMIT"
export GIT_INDEX_FILE="$tmp/index"
git --work-tree="$tmp/tree" read-tree --empty
git --work-tree="$tmp/tree" add -A
tree=$(git write-tree)
unset GIT_INDEX_FILE
if [ -n "$old" ]; then
    commit=$(git commit-tree "$tree" -p "$old" -m "release: source-only tree from $source")
else
    commit=$(git commit-tree "$tree" -m "release: source-only tree from $source")
fi
if [ -n "$old" ]; then
    git update-ref "refs/heads/$branch" "$commit" "$old"
else
    git update-ref "refs/heads/$branch" "$commit"
fi
printf '%s %s\n' "$commit" "$branch"
