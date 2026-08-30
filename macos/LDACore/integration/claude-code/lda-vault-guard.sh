#!/bin/bash
# lda-vault-guard.sh
#
# A Claude Code PreToolUse hook that blocks the built-in Read / Grep / Glob /
# Bash tools from touching the LDA document vault.
#
# Why this exists (and what it is NOT): the vault holds lawyers' ORIGINAL
# documents. The primary defense is the vault design itself (opaque handles,
# no paths over MCP, and, from the encryption phase on, ciphertext at rest).
# A deny list like this one is inherently leaky, so this hook is NOT a
# security boundary. Its job is to turn an agent's accidental "let me just
# read that file to understand it" into a VISIBLE refusal during development
# instead of a silent leak into model context.
#
# Install (user scope, recommended): add to ~/.claude/settings.json:
#
#   {
#     "hooks": {
#       "PreToolUse": [
#         {
#           "matcher": "Read|Grep|Glob|Bash|Write|Edit",
#           "hooks": [
#             {
#               "type": "command",
#               "command": "/absolute/path/to/lda-vault-guard.sh"
#             }
#           ]
#         }
#       ]
#     }
#   }
#
# Contract: Claude Code pipes one JSON object on stdin describing the pending
# tool call. Exit 0 allows the call. Exit 2 blocks it and shows stderr to the
# model. Any other exit code is a non-blocking hook error.
#
# House rules: all comments and strings in English. No em-dash and no
# en-dash-as-separator anywhere.

set -u

# The vault roots to guard: the default location, plus LDA_VAULT_DIR when the
# environment overrides it (mirrors DocumentVault.environmentKey).
DEFAULT_VAULT="$HOME/Library/Application Support/LDA/Vault"
VAULT_ROOTS=("$DEFAULT_VAULT")
if [ -n "${LDA_VAULT_DIR:-}" ]; then
  VAULT_ROOTS+=("$LDA_VAULT_DIR")
fi

INPUT="$(cat)"

# Pull the fields we can judge with. python3 ships with macOS and parses the
# JSON reliably; jq is not assumed.
read_field() {
  printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys
key = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
value = payload.get(key)
if isinstance(value, str):
    sys.stdout.write(value)
' "$1" 2>/dev/null
}

read_input_field() {
  printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys
key = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool_input = payload.get("tool_input") or {}
value = tool_input.get(key)
if isinstance(value, str):
    sys.stdout.write(value)
' "$1" 2>/dev/null
}

TOOL_NAME="$(read_field tool_name)"

block() {
  echo "lda-vault-guard: blocked $TOOL_NAME touching the LDA document vault." >&2
  echo "Originals in the vault are off limits to the agent by design. Use the" >&2
  echo "MCP tools instead: list_pending, anonymize, read_redacted (redacted" >&2
  echo "text only), restore, export, attest." >&2
  exit 2
}

# True when $1 contains $2 as a substring.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Path-taking tools: block when the target path resolves under a vault root.
# Bash: block when the command STRING mentions a vault root at all, in plain,
# quoted, or backslash-escaped spelling. Escaped spellings matter because
# "Application Support" carries a space.
check_against_root() {
  local root="$1"
  local root_escaped="${root// /\\ }"
  local root_tilde="${root/#$HOME/~}"
  local root_tilde_escaped="${root_tilde// /\\ }"

  case "$TOOL_NAME" in
    Read|Grep|Glob|Write|Edit)
      local target
      for key in file_path path pattern; do
        target="$(read_input_field "$key")"
        if [ -n "$target" ]; then
          local expanded="${target/#\~/$HOME}"
          if contains "$expanded" "$root" || contains "$expanded" "$root_tilde"; then
            block
          fi
        fi
      done
      ;;
    Bash)
      local command
      command="$(read_input_field command)"
      if [ -n "$command" ]; then
        if contains "$command" "$root" \
          || contains "$command" "$root_escaped" \
          || contains "$command" "$root_tilde" \
          || contains "$command" "$root_tilde_escaped"; then
          block
        fi
        # The vault CLI reveals the handle-to-filename correlation the MCP
        # surface deliberately withholds (lda vault list prints original
        # filenames for the human). Staging and listing are HUMAN actions;
        # an agent reaching for them gets a visible refusal instead.
        if contains "$command" "lda vault" || contains "$command" "lda-mcp"; then
          block
        fi
      fi
      ;;
  esac
}

for root in "${VAULT_ROOTS[@]}"; do
  check_against_root "$root"
done

exit 0
