# LDA positioning and claims discipline

From the 2026-08-29 boundary and roadmap review. The buyer is a lawyer; they
will test every sentence, so precision beats volume. Anything public-facing
(site, App Store text, README, sales notes) draws from this file.

## Claims that may be made, with their verification

| Claim | Why it holds | How a buyer verifies it |
|---|---|---|
| Originals and detected PII plaintext never enter the model context | Handle-first MCP surface: tools accept and return opaque handles; only `read_redacted` returns body text, and only redacted text; `detect_entities` returns types, counts, and offsets only | Grep the agent transcript (session JSONL) for a client's name: zero hits. `attest` reports plaintext bytes returned this session, which is 0 by construction |
| The app's document pipeline cannot reach the network | The only network capability is the model-download path (`ModelInstaller`); the MCP server and CLI carry no network entitlement and open no sockets | `codesign -d --entitlements - LDA.app`; the MCP server is stdio only |
| Originals rest encrypted, keys bound to the Keychain | Documents staged for agent use live in the vault as AES-256-GCM containers; mapping sidecars and stores were already encrypted | `cat` any file under `~/Library/Application Support/LDA/Vault`: ciphertext |
| You can verify all of this yourself | The mechanisms above are OS-enforced or on-disk facts, not app promises | The three checks above, plus the PreToolUse guard hook in `macos/LDACore/integration/claude-code/` |

The competitor's equivalent claims are self-promises ("the software will
intercept all outbound requests"); LDA's are checkable by a third party. That
difference is the differentiator; state it as such and never overstate it.

## Claims that must NOT be made

- "Zero information upload": false; redacted text and aggregate counts do go
  up, and that is the product working as designed. Say what stays local
  instead.
- "100% detection": no anonymizer can promise this, and promising it assumes
  liability. The review pane and missed-item flow exist because detection is
  fallible; the copy must match.
- "More accurate than [competitor] on Chinese text": their public numbers lead
  today (they publish judgment-document F1 above 96 percent). Compete on
  verifiable isolation, encrypted rest, and the two-way workflow, not on a
  recall race.
- Anything implying LDA replaces a lawyer's compliance judgment.

## The three differentiators worth repeating

1. Agent-native WITH verifiable isolation. An agent integration that leaked
   paths or plaintext would be worse than none; LDA's is structurally sealed
   and auditable (see table above).
2. Encrypted at rest by construction, not by advising the user to turn on
   disk encryption themselves.
3. Two-way document automation: anonymize out AND fill-from-profile /
   fill-from-doc back in. The competitor's tool is one-way.

## Discipline

Do not market the agent integration ahead of what has shipped in a build the
public can install. A security-literate law-firm reviewer who finds the
marketing ahead of the binary does more damage than the feature's absence.
