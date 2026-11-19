#!/usr/bin/env bash
# Resolve a merge conflict in <branch>: llmgate issues a 2h ephemeral key,
# maki runs in a keg sandbox, the result is verified and committed on
# ai-fix/<branch>. With AI_FIX_PUSH=1 the commit is pushed to <branch>.
#
#   LLMGATE_BASE_URL=https://gateway/v1 LLMGATE_API_KEY=sk-... \
#     scripts/ai-fix/run.sh feat/my-branch
#
# AI_FIX_RUNTIME=direct runs keg on the host (CI), podman runs it in the
# keg runtime image (local, pinned bwrap).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git rev-parse --show-toplevel)
STREAM_FILTER=$SCRIPT_DIR/stream-json.jq

RUNTIME=${AI_FIX_RUNTIME:-direct}
IMAGE=${AI_FIX_IMAGE:-maki-ai-fix:local}
MODEL=${LLM_MODEL:-deepseek-v4.1-flash}
TTL=${LLM_TTL_SECONDS:-7200}
UPSTREAM_REF=${AI_FIX_UPSTREAM:-upstream/main}
ATTEMPTS=${AI_FIX_ATTEMPTS:-3}
TIMEOUT=${AI_FIX_TIMEOUT:-900}
MAKI_BIN=${MAKI_BIN:-$HOME/.local/bin/maki}
NO_FETCH=${AI_FIX_NO_FETCH:-0}
KEEP=${AI_FIX_KEEP:-0}
PUSH=${AI_FIX_PUSH:-0}
CREDIT=${AI_FIX_CREDIT_USD:-}
CHECK_CMD=${AI_FIX_CHECK_CMD:-cargo check --workspace --tests}
MARKER_RE='^(<<<<<<< |>>>>>>> )'

BRANCH=${1:-}
[ -n "$BRANCH" ] || { echo "usage: $0 <feature-branch>" >&2; exit 2; }
ai_fix_ref="ai-fix/$BRANCH"
local_ref="ai-fix/${BRANCH//\//-}"

die() { echo "ai-fix: $*" >&2; exit 1; }

case "$RUNTIME" in
  direct | podman) ;;
  *) die "AI_FIX_RUNTIME must be direct or podman" ;;
esac
: "${LLMGATE_BASE_URL:?set LLMGATE_BASE_URL to the gateway base URL ending in /v1}"
: "${LLMGATE_API_KEY:?set LLMGATE_API_KEY to the long-lived gateway key}"
command -v jq >/dev/null || die "jq not found"
command -v curl >/dev/null || die "curl not found"
if [ "$RUNTIME" = podman ]; then
  command -v podman >/dev/null || die "podman not found"
else
  command -v keg >/dev/null || die "keg not found (set AI_FIX_RUNTIME=podman to use the image)"
  command -v bwrap >/dev/null || die "bwrap not found (set AI_FIX_RUNTIME=podman to use the image)"
fi

base_url=${LLMGATE_BASE_URL%/}
api_origin=${base_url%/v1}
[ "$api_origin" != "$base_url" ] || die "LLMGATE_BASE_URL must end in /v1"

# The sandbox cannot use the host loopback directly. Podman gets a hostname
# through --add-host; direct mode needs a name that resolves on the host.
scheme=${base_url%%://*}
hostport=${base_url#*://}
hostport=${hostport%%/*}
if [[ $hostport == *:* ]]; then host=${hostport%:*}; port=:${hostport##*:}; else host=$hostport; port=; fi
container_url=$base_url
podman_net=()
if [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ]; then
  [ "$scheme" = "http" ] || die "https on the loopback is not supported, use a real hostname"
  [ "$RUNTIME" = podman ] \
    || die "a loopback gateway needs a hostname that resolves on the host, or AI_FIX_RUNTIME=podman"
  container_url="http://llmgate.local$port/v1"
  podman_net=(--network=host --add-host llmgate.local:127.0.0.1)
fi

if [ "$NO_FETCH" != 1 ]; then
  git -C "$REPO" fetch --no-tags origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || true
  git -C "$REPO" fetch --no-tags origin "+refs/heads/$ai_fix_ref:refs/remotes/origin/$ai_fix_ref" 2>/dev/null || true
  git -C "$REPO" fetch --no-tags "${UPSTREAM_REF%%/*}" "${UPSTREAM_REF#*/}" 2>/dev/null || true
fi
base_ref="origin/$BRANCH"
git -C "$REPO" rev-parse -q --verify "$base_ref" >/dev/null || base_ref=$BRANCH
git -C "$REPO" rev-parse -q --verify "$base_ref" >/dev/null || die "unknown branch $BRANCH"
base_sha=$(git -C "$REPO" rev-parse "$base_ref^{commit}")
upstream_sha=$(git -C "$REPO" rev-parse "$UPSTREAM_REF^{commit}") \
  || die "unknown ref $UPSTREAM_REF"

# The internal branch holds the last resolution. While it contains both the
# feature tip and upstream, there is nothing to resolve and no reason to pay
# for another model run.
if git -C "$REPO" rev-parse -q --verify "origin/$ai_fix_ref" >/dev/null \
  && git -C "$REPO" merge-base --is-ancestor "$base_sha" "origin/$ai_fix_ref" \
  && git -C "$REPO" merge-base --is-ancestor "$upstream_sha" "origin/$ai_fix_ref"; then
  echo "ai-fix: origin/$ai_fix_ref already contains $BRANCH and $UPSTREAM_REF"
  exit 0
fi

echo "ai-fix: issuing ephemeral key (ttl ${TTL}s, model $MODEL)"
name="maki-ai-fix-${BRANCH//\//-}-$(date +%s)"
name=${name:0:64}
body=$(jq -nc --arg name "$name" --arg model "$MODEL" --argjson ttl "$TTL" \
  '{name:$name,ttl_seconds:$ttl,models:[$model]}')
if [ -n "$CREDIT" ]; then
  body=$(jq -c --argjson c "$CREDIT" '. + {credit_limit_usd:$c}' <<<"$body")
fi
if ! resp=$(curl -fsS --max-time 30 -X POST "$api_origin/api/keys/ephemeral" \
  -H "Authorization: Bearer $LLMGATE_API_KEY" \
  -H 'Content-Type: application/json' -d "$body"); then
  die "failed to issue an ephemeral key"
fi
token=$(jq -r '.token // empty' <<<"$resp")
[ -n "$token" ] || die "no token in issuance response: $resp"
expires=$(jq -r '.expires_at // "unknown"' <<<"$resp")
# From here on the long-lived key must not leak into any child process.
unset LLMGATE_API_KEY
# GitHub only masks known secrets. Mark the ephemeral token too, so a stray
# `env` in a tool result cannot put it in the public job log.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::add-mask::$token"
  echo "::add-mask::$host"
fi

wt=""
cleanup() {
  local rc=$?
  if [ -n "${token:-}" ]; then
    curl -fsS -o /dev/null --max-time 15 -X POST "$api_origin/api/keys/ephemeral/revoke" \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg t "$token" '{token:$t}')" \
      || echo "ai-fix: warning: could not revoke the ephemeral key" >&2
  fi
  if [ -n "$wt" ] && [ "$KEEP" != 1 ]; then
    rm -rf "$wt"
  fi
  [ -z "${cfg:-}" ] || rm -rf "$cfg"
  exit "$rc"
}
trap cleanup EXIT

if [ "$RUNTIME" = podman ]; then
  # Always build: podman caches layers, and a stale image would run an old
  # entrypoint after a script change.
  podman build -q -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR" >/dev/null
fi
[ -x "$MAKI_BIN" ] || die "maki binary not found at $MAKI_BIN (set MAKI_BIN)"


slug=${BRANCH//\//-}
# A local clone instead of a worktree: the sandbox only sees this directory,
# so .git must live inside it. Keep it next to the repo so --local can
# hardlink, and fall back to a copy when the filesystems differ.
tmp_root=${AI_FIX_TMPDIR:-$(dirname "$REPO")}
if ! wt=$(mktemp -d "$tmp_root/.maki-ai-fix.XXXXXX" 2>/dev/null); then
  wt=$(mktemp -d "${TMPDIR:-/tmp}/maki-ai-fix.XXXXXX")
fi
if ! git clone -q --local --no-checkout "$REPO" "$wt" 2>/dev/null; then
  rm -rf "$wt"
  mkdir -p "$wt"
  git clone -q --no-hardlinks --no-checkout "$REPO" "$wt"
fi
git -C "$wt" checkout -q --detach "$base_sha"
# The runner has no global git identity; a merge without one aborts with
# "Committer identity unknown" before it writes any conflict markers.
git -C "$wt" config user.name "${GIT_AUTHOR_NAME:-maki-ai-fix}"
git -C "$wt" config user.email "${GIT_AUTHOR_EMAIL:-maki-ai-fix@localhost}"
merge_rc=0
git -C "$wt" merge --no-edit "$upstream_sha" >/dev/null || merge_rc=$?
[ "$merge_rc" -le 1 ] || die "git merge failed (exit $merge_rc)"
mapfile -t conflicts < <(git -C "$wt" diff --name-only --diff-filter=U)
if [ ${#conflicts[@]} -eq 0 ]; then
  echo "ai-fix: $BRANCH does not conflict with $UPSTREAM_REF"
  exit 0
fi

# The merge itself stages upstream's .github changes. Snapshot that tree so
# the guard below only catches edits made by the model.
github_hash() {
  ( cd "$wt" && find .github -type f -print0 2>/dev/null \
    | sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1 )
}
github_before=$(github_hash)

build_prompt() {
  cat <<EOF
You are resolving an in-progress merge of $UPSTREAM_REF ($upstream_sha) into the feature branch $BRANCH.
The conflicted files are listed at the end. Read both sides, the commits behind
them and the surrounding code before editing.

Rules:
- Keep the feature's intent and upstream's changes. Never drop a side just to
  silence a conflict.
- Leave no conflict markers behind.
- Do not touch .github/**.
- Leave the merge in progress: do not commit, push, branch or abort it.
  The harness verifies and commits your edits.
- Follow the project rules in AGENTS.md.

Conflicted files:
$(printf -- '- %s\n' "${conflicts[@]}")
${1:-}
EOF
}

markers() {
  grep -rIl --exclude-dir=.git --exclude-dir=target \
    -E "$MARKER_RE" "$wt" || true
}

run_maki() {
  if [ "$RUNTIME" = podman ]; then
    printf '%s\n' "$token" | timeout "$TIMEOUT" podman run --rm -i \
      "${podman_net[@]}" \
      --cap-add=SYS_ADMIN \
      --security-opt seccomp=unconfined \
      --security-opt label=disable \
      --security-opt unmask=ALL \
      -v "$wt:/workspace:rw" \
      -v "$cfg:/cfg:rw" \
      -v "$MAKI_BIN:/usr/local/bin/maki:ro" \
      -e AI_FIX_CONFIG_DIR=/cfg \
      -e LLMGATE_BASE_URL="$container_url" \
      -e LLM_MODEL="$MODEL" \
      -e LLM_CONTEXT_WINDOW="${LLM_CONTEXT_WINDOW:-131072}" \
      -e LLM_MAX_OUTPUT="${LLM_MAX_OUTPUT:-8192}" \
      -e AI_FIX_ALLOW_NETWORKS="${AI_FIX_ALLOW_NETWORKS:-}" \
      -e PROMPT="$1" \
      "$IMAGE"
  else
    printf '%s\n' "$token" | timeout "$TIMEOUT" env \
      AI_FIX_WORKSPACE="$wt" \
      AI_FIX_CONFIG_DIR="$cfg" \
      MAKI_BIN="$MAKI_BIN" \
      LLMGATE_BASE_URL="$container_url" \
      LLM_MODEL="$MODEL" \
      LLM_CONTEXT_WINDOW="${LLM_CONTEXT_WINDOW:-131072}" \
      LLM_MAX_OUTPUT="${LLM_MAX_OUTPUT:-8192}" \
      AI_FIX_ALLOW_NETWORKS="${AI_FIX_ALLOW_NETWORKS:-}" \
      AI_FIX_COPY_MAKI=1 \
      PROMPT="$1" \
      "$SCRIPT_DIR/entrypoint.sh"
  fi
}

outdir=$(mktemp -d "${TMPDIR:-/tmp}/maki-ai-fix-out.XXXXXX")
cfg=$(mktemp -d "${TMPDIR:-/tmp}/maki-ai-fix-cfg.XXXXXX")
extra=""
ok=0
for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
  echo "ai-fix: attempt $attempt/$ATTEMPTS"
  result=$outdir/result-$attempt.json
  # The log gets the readable rendering; the raw JSONL stays in $result for
  # the result check and the failure artifact.
  if ! run_maki "$(build_prompt "$extra")" | tee "$result" \
    | jq --unbuffered -n -r -R -f "$STREAM_FILTER"; then
    die "maki run failed or timed out after ${TIMEOUT}s (raw output in $result)"
  fi
  if ! jq -e -s 'map(select(.type == "result")) | last | .is_error == false' "$result" >/dev/null 2>&1; then
    jq -r -s 'map(select(.type == "result")) | last | .result? // empty' "$result" >&2 || true
    die "maki reported an error (raw output in $result)"
  fi
  check="$outdir/check-$attempt.log"
  echo "ai-fix: verifying"
  if ( cd "$wt" && CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$REPO/target}" $CHECK_CMD ) 2>&1 | tee "$check" \
    && [ -z "$(markers)" ]; then
    ok=1
    break
  fi
  echo "ai-fix: verification failed, feeding the log back"
  leftover=$(markers)
  extra="The previous attempt did not pass verification."
  if [ -n "$leftover" ]; then extra="$extra Conflict markers remain in: $leftover"; fi
  extra="$extra
$(tail -n 200 "$check")"
done
[ "$ok" = 1 ] || die "could not resolve $BRANCH after $ATTEMPTS attempts (logs in $outdir)"

[ -f "$wt/.git/MERGE_HEAD" ] || die "merge state was lost, aborting"
[ "$(github_hash)" = "$github_before" ] \
  || die "the AI touched .github/, refusing to commit (checkout: $wt)"
# GITHUB_TOKEN cannot push workflow file changes, and masu strips them anyway.
# Remove first: checkout only restores paths that exist in the base tree.
rm -rf "$wt/.github/workflows"
git -C "$wt" checkout "$base_sha" -- .github/workflows 2>/dev/null || true
git -C "$wt" add -A -- .github/workflows
git -C "$wt" add -A
if git -C "$wt" diff --cached --quiet; then
  die "the AI produced no changes (checkout: $wt)"
fi
workflow_diff=$(git -C "$wt" diff --cached --name-only "$base_sha" -- .github/workflows)
[ -z "$workflow_diff" ] \
  || die "workflow changes remain and cannot be pushed with GITHUB_TOKEN: $workflow_diff"
git -C "$wt" commit -q -m "merge: $UPSTREAM_REF into $BRANCH (AI conflict resolution)"
git -C "$REPO" fetch -q --no-tags "$wt" "+HEAD:refs/heads/$local_ref"
if [ "$PUSH" = 1 ]; then
  if git -C "$REPO" rev-parse -q --verify "origin/$ai_fix_ref" >/dev/null; then
    git -C "$REPO" push --force-with-lease origin "$local_ref:refs/heads/$ai_fix_ref"
  else
    git -C "$REPO" push origin "$local_ref:refs/heads/$ai_fix_ref"
  fi
fi

echo
echo "ai-fix: resolved $BRANCH"
echo "  key expires: $expires"
echo "  model:       $MODEL"
final=$(jq -c -s 'map(select(.type == "result")) | last' "$result")
echo "  turns:       $(jq -r '.num_turns' <<<"$final")"
echo "  cost:        \$$(jq -r '.total_cost_usd' <<<"$final")"
echo "  branch:      $local_ref"
[ "$KEEP" = 1 ] && echo "  checkout:    $wt"
if [ "$PUSH" = 1 ]; then
  echo "  pushed:      origin/$ai_fix_ref"
  echo "  review:      git diff origin/$BRANCH...origin/$ai_fix_ref"
  echo "  promote:     scripts/ai-fix/promote.sh $BRANCH"
else
  echo "  review:      git show $local_ref"
  echo "  publish:     git push origin $local_ref:refs/heads/$ai_fix_ref"
fi
