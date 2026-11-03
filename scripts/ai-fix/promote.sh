#!/usr/bin/env bash
# Squash an AI resolution onto upstream/main and force-push the feature branch.
# The AI keeps its work on origin/ai-fix/<branch>; this script is the reviewed
# step that turns it into a clean, linear PR branch.
set -euo pipefail

REPO=$(git rev-parse --show-toplevel)
BRANCH=${1:-}
[ -n "$BRANCH" ] || { echo "usage: $0 <feature-branch>" >&2; exit 2; }

UPSTREAM_REF=${AI_FIX_UPSTREAM:-upstream/main}
die() { echo "promote: $*" >&2; exit 1; }

if [ "${AI_FIX_NO_FETCH:-0}" != 1 ]; then
  git -C "$REPO" fetch --no-tags origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || true
  git -C "$REPO" fetch --no-tags origin "+refs/heads/ai-fix/$BRANCH:refs/remotes/origin/ai-fix/$BRANCH" 2>/dev/null || true
  git -C "$REPO" fetch --no-tags "${UPSTREAM_REF%%/*}" "${UPSTREAM_REF#*/}" 2>/dev/null || true
fi

feature=$(git -C "$REPO" rev-parse "origin/$BRANCH^{commit}") || die "unknown origin/$BRANCH"
upstream=$(git -C "$REPO" rev-parse "$UPSTREAM_REF^{commit}") || die "unknown $UPSTREAM_REF"

if git -C "$REPO" rev-parse -q --verify "origin/ai-fix/$BRANCH" >/dev/null; then
  resolution=$(git -C "$REPO" rev-parse "origin/ai-fix/$BRANCH^{commit}")
  git -C "$REPO" merge-base --is-ancestor "$feature" "$resolution" \
    || die "ai-fix/$BRANCH is stale, rerun the AI fix"
else
  # One-off cleanup: the feature tip itself is an old AI merge commit.
  resolution=$feature
  parents=$(git -C "$REPO" rev-list --parents -n1 "$resolution" | wc -w)
  [ "$parents" -eq 3 ] || die "no ai-fix/$BRANCH branch and $BRANCH is not a merge"
fi
git -C "$REPO" merge-base --is-ancestor "$upstream" "$resolution" \
  || die "$resolution does not contain $UPSTREAM_REF"
[ "$(git -C "$REPO" rev-list --parents -n1 "$resolution" | wc -w)" -eq 3 ] \
  || die "$resolution is not a merge commit"

feature_sha=$(git -C "$REPO" rev-parse "$resolution^1")
git -C "$REPO" config user.name >/dev/null 2>&1 || die "set git user.name before promoting"
git -C "$REPO" config user.email >/dev/null 2>&1 || die "set git user.email before promoting"
msg=$(mktemp)
git -C "$REPO" log -1 --format=%B "$feature_sha" > "$msg"
author_name=$(git -C "$REPO" log -1 --format=%an "$feature_sha")
author_email=$(git -C "$REPO" log -1 --format=%ae "$feature_sha")
author_date=$(git -C "$REPO" log -1 --format=%aI "$feature_sha")

wt=$(mktemp -d "${TMPDIR:-/tmp}/maki-promote.XXXXXX")
rmdir "$wt"
git -C "$REPO" worktree add --detach "$wt" "$resolution" >/dev/null
cleanup() {
  git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
  rm -f "$msg"
}
trap cleanup EXIT

rm -rf "$wt/.ai-fix" "$wt/.keg.yaml" "$wt/.github/workflows"
git -C "$wt" checkout "$upstream" -- .github/workflows 2>/dev/null || true
git -C "$wt" add -A
tree=$(git -C "$wt" write-tree)

commit=$(GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
  GIT_AUTHOR_DATE="$author_date" \
  git -C "$REPO" commit-tree "$tree" -p "$upstream" -F "$msg")

git -C "$REPO" push --force-with-lease origin "$commit:refs/heads/$BRANCH"

echo "promote: $BRANCH -> $(git -C "$REPO" rev-parse --short "$commit")"
echo "promote: author $author_name <$author_email>"
echo "promote: one commit on $UPSTREAM_REF, workflows from upstream"
echo "promote: $(git -C "$REPO" diff --shortstat "$upstream" "$commit")"
