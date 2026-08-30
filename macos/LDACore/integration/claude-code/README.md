# Claude Code integration for LDA

Pieces an agent-host user installs on their own machine. Nothing here runs
inside the app.

## lda-vault-guard.sh (PreToolUse hook)

Blocks Claude Code's built-in Read / Grep / Glob / Bash / Write / Edit tools
from touching the LDA document vault (`~/Library/Application Support/LDA/Vault`
and, when set, `$LDA_VAULT_DIR`).

This is defense in depth, not a security boundary. The vault's primary
protections are structural: MCP tools accept and return opaque handles, never
paths; only `read_redacted` returns body text, and only redacted text; and the
encryption phase makes vault objects unreadable ciphertext at rest. A deny
list can always be dodged, so the hook's real job is to turn an agent's
accidental "let me just read that file" into a visible refusal during
development, instead of a silent leak into model context.

Install by adding to `~/.claude/settings.json` (user scope, so it guards every
project):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Grep|Glob|Bash|Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/lda-vault-guard.sh"
          }
        ]
      }
    ]
  }
}
```

Behavior on a blocked call: the tool call is refused (exit 2) and the agent
sees a one-line explanation pointing it at the MCP tools instead
(`list_pending`, `anonymize`, `read_redacted`, `restore`, `export`, `attest`).

Verified cases (see the script's history for the harness): direct reads,
tilde paths, backslash-escaped `Application\ Support` spellings inside Bash
commands, Grep/Glob path and pattern arguments, the `LDA_VAULT_DIR` override,
and pass-through for unrelated paths, unrelated tools, and malformed hook
payloads.
