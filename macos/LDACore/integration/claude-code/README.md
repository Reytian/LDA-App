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
(`list_pending`, `detect_entities`, `anonymize`, `anonymize_session`,
`read_redacted`, `restore`, `export`, `attest`).

Bash commands invoking `lda vault` or `lda-mcp` are also refused: `lda vault
list` prints original filenames (the handle-to-name correlation the MCP
surface deliberately withholds), and staging is a human action by design. Be
honest about the limit: an agent host with an unrestricted Bash tool has
countless other ways to run a binary, so this refusal is a speed bump that
makes the attempt visible, not a wall. The wall is that vault CONTENTS are
ciphertext at rest; the filename correlation in the registry is equally
sealed, but any locally runnable CLI that can open the vault can print what
it decrypts.

Verified cases (see the script's history for the harness): direct reads,
tilde paths, backslash-escaped `Application\ Support` spellings inside Bash
commands, Grep/Glob path and pattern arguments, the `LDA_VAULT_DIR` override,
and pass-through for unrelated paths, unrelated tools, and malformed hook
payloads.

## The tool surface the agent sees

| Tool | Arguments | Returns |
|---|---|---|
| `list_pending` | none | handles plus neutral metadata (`kind`, `format`, `byteCount`, `pages`, `stagedAt`, `sourceHandle`) |
| `detect_entities` | `handle`, `modelPath?` | `detectionId` and `entities[]` of `{id, type, start, end}`; the detected text never leaves the machine |
| `anonymize` | `handle`, `passphrase?`, `modelPath?`, `style?`, `excludeEntityIds?` with `detectionId`, `excludeTypes?` | `redactedHandle`, counts per type, `excludedCount`, `detectionChanged` |
| `anonymize_session` | `handles`, `passphrase?`, `modelPath?`, `client?`, `style?`, `excludeTypes?` | one `redactedHandle` per document, counts, `excludedCount`, `unresolvedSeams` |
| `read_redacted` | `handle` (red_) | the redacted `text`; the only tool that returns body text |
| `restore` | `redactedHandle`, `passphrase?`, at most one of `editedText?` or `editedHandle?` | `restoredHandle`, `format`, `restoredCount`, `orphanTokens`, `suspectPlaceholders`, `ambiguousReplacements` |
| `export` | `handle` (red_ or res_) | `ok`; the file lands in the vault's `outbox/` |
| `attest` | none | the server's data-boundary posture and byte counters |

Review before redacting: call `detect_entities` once, then pass the ids to
keep visible as `excludeEntityIds` together with the `detectionId` they came
with, and whole types as `excludeTypes`. An id the fresh detection does not
know is refused (`unknown_entity_id`) and nothing is written.

## Word round trip (.docx in, restored .docx out)

`restore` with `editedText` restores to TEXT (`format: "txt"`) even when the
redacted artifact was a `.docx`. Formatting is kept only when the edited
`.docx` itself travels through the vault and is passed as `editedHandle`:

1. Human: `lda vault stage Agreement.docx` (doc_a1).
2. Agent: `anonymize {handle: doc_a1}` (red_b2), then `export {handle: red_b2}`;
   the redacted file appears as `outbox/Agreement_redacted.docx`.
3. Human: edits that file in Word, keeping the placeholders (accept all
   tracked changes), saves it as `Agreement-edited.docx`, and stages it:
   `lda vault stage Agreement-edited.docx` (doc_c3).
4. Agent: `restore {redactedHandle: red_b2, editedHandle: doc_c3}` (res_d4,
   `format: "docx"`), then `export {handle: res_d4}`; the restored file appears
   as `outbox/Agreement-edited_restored.docx` with its formatting intact.

Staging is the human's action by design: an agent that ran the CLI itself
would be handling the path this surface keeps out of context, which is why the
hook above also refuses `lda vault` and `lda-mcp` in Bash.
