#!/bin/sh
set -eu

: "${LLMGATE_BASE_URL:?LLMGATE_BASE_URL is required}"
: "${LLM_MODEL:?LLM_MODEL is required}"
: "${PROMPT:?PROMPT is required}"

# The ephemeral token arrives on stdin so it never shows up in host argv.
IFS= read -r LLMGATE_API_KEY
export LLMGATE_API_KEY
[ -n "$LLMGATE_API_KEY" ] || { echo "ai-fix: no ephemeral token on stdin" >&2; exit 1; }

ws=${AI_FIX_WORKSPACE:-/workspace}
maki_bin=${MAKI_BIN:-/usr/local/bin/maki}
[ -x "$maki_bin" ] || { echo "ai-fix: maki binary not found at $maki_bin" >&2; exit 1; }
[ -e "$ws/.git" ] || { echo "ai-fix: $ws is not a git checkout" >&2; exit 1; }
if [ -e "$ws/.keg.yaml" ]; then
  echo "ai-fix: $ws/.keg.yaml already exists, refusing to overwrite" >&2
  exit 1
fi

cfg=$ws/.ai-fix
rm -rf "$cfg"
mkdir -p "$cfg/xdg/maki"

# Direct mode mounts only the repo into the sandbox, so the host binary has
# to live inside it. Podman mounts it at /usr/local/bin/maki instead.
sandbox_maki=$maki_bin
if [ "${AI_FIX_COPY_MAKI:-0}" = 1 ]; then
  mkdir -p "$cfg/bin"
  cp "$maki_bin" "$cfg/bin/maki"
  chmod +x "$cfg/bin/maki"
  sandbox_maki=$cfg/bin/maki
fi

cat > "$cfg/xdg/maki/providers.toml" <<EOF
[llmgate]
display_name = "llmgate"
protocol = "openai"
base_url = "$LLMGATE_BASE_URL"
api_key_env = "LLMGATE_API_KEY"

[[llmgate.models]]
id = "$LLM_MODEL"
tier = "weak"
context_window = ${LLM_CONTEXT_WINDOW:-131072}
max_output_tokens = ${LLM_MAX_OUTPUT:-8192}
EOF

host=${LLMGATE_BASE_URL#*://}
host=${host%%/*}
host=${host%%:*}

{
  cat <<EOF
version: "1"
env:
  inherit: [LLMGATE_API_KEY, PROMPT]
  set:
    XDG_CONFIG_HOME: $cfg/xdg
network:
  mode: proxy
  sni_domains: ["$host"]
EOF
  # allow_networks is an allowlist: setting it for a remote gateway would
  # block every public destination.
  if [ -n "${AI_FIX_ALLOW_NETWORKS:-}" ]; then
    echo "  allow_networks: [\"$AI_FIX_ALLOW_NETWORKS\"]"
  elif [ "$host" = "llmgate.local" ]; then
    echo '  allow_networks: ["127.0.0.1/32"]'
  fi
} > "$ws/.keg.yaml"

keg trust --repo "$ws" >/dev/null

exec keg run --repo "$ws" -- "$sandbox_maki" \
  -p --output-format stream-json --yolo --no-commands \
  --allowed-tools read,edit,write,multiedit,edit_lines,bash,grep,glob,index \
  -m "llmgate/$LLM_MODEL" "$PROMPT"
