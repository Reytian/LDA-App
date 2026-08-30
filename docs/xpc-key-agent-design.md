# XPC key agent: design for roadmap phase 6 (Plan B, keyless client)

Status: DESIGNED, not yet implemented. The code seam it plugs into shipped
with vault encryption at rest: `Sources/LDACore/Security/DocumentVaultEncryption.swift`
is the single file that touches the vault master key, and `attest` already
reports `vaultKeyProtection` as a runtime-derived string. This document fixes
the architecture decisions so the implementation session does not relitigate
them.

## Goal

`lda-mcp` (and any other headless client) holds NO key material. Stealing the
binary, its memory, or its Keychain scope yields ciphertext only. LDA.app (or
its helper) is the sole key holder and can demand Touch ID for the first
unseal of a launch. After this ships, `attest` reports
`vaultKeyProtection: "xpc-app-held"` and the marketing line "the agent-side
process cannot decrypt anything by itself" becomes literally true.

## Decisions

1. **Host: an SMAppService LaunchAgent bundled in LDA.app** (macOS 13+ API,
   package already targets macOS 14). The app registers
   `Contents/Library/LaunchAgents/ai.openclaw.lda.keyagent.plist` declaring a
   `MachServices` name; the helper executable hosts an `NSXPCListener` for it.
   Reason: a sandboxed GUI app cannot register a global Mach service itself,
   and hand-rolled UNIX-socket IPC would mean hand-rolled framing and peer
   auth. SMAppService is the supported path and survives the app being closed
   (the agent runs in the user session on demand).
2. **The client never receives the key.** The XPC protocol is
   operation-level: the client sends the sealed container (by file descriptor
   or bytes) plus the facet tag; the agent decrypts and returns plaintext via
   `NSFileHandle` (fd passing), or seals plaintext the client sends. The
   master key never crosses the connection in either direction.
3. **Peer verification by code signature.** The listener resolves the
   connecting process from its audit token (`SecCodeCopyGuestWithAttributes`)
   and requires: same Team ID (B53GT262L4) and a designated requirement
   naming the lda-mcp / lda identifiers. Consequence: **lda-mcp must be
   signed and shipped inside LDA.app** (Contents/Helpers). That also retires
   the "unsigned headless binary cannot use data-protection keychain"
   constraint that forced today's silent-key mode; `package-app.sh` grows the
   helper-signing step.
4. **Touch ID policy lives in the agent.** First unseal per login session (or
   per app launch, configurable) evaluates `LAContext` with the same
   user-presence policy the GUI already uses; subsequent operations ride the
   existing reuse window. Headless callers therefore inherit human-gated
   unsealing without holding any secret.
5. **Backend selection with honest fallback.** `DocumentVaultEncryption`
   gains `VaultKeyBackend { inProcess, xpcAgent }`. Default: probe the Mach
   service; use `xpcAgent` when reachable, else fall back to `inProcess`
   (today's behavior) and report it: `attest.vaultKeyProtection` says
   `"keychain-silent"` on the fallback, `"xpc-app-held"` only when the agent
   actually served the session. No silent downgrade: the value is derived per
   session from which backend performed the first unseal.
6. **Migration**: the master key moves from the client-readable Keychain item
   to an item readable only by the agent (new service name, agent-signed
   access). The agent migrates on first run (read old item, add new, delete
   old); a vault sealed under the old regime opens unchanged because the key
   BYTES are unchanged, only custody moves.

## Failure modes to design tests around

- Agent not registered yet (user has not approved the login item in System
  Settings): probe fails, inProcess fallback, attest says so.
- App never launched since install (agent binary present, service reachable
  via launchd on demand): expected to work; this is the headless-first case.
- Touch ID denied or canceled: the XPC call returns a typed refusal; MCP
  tools surface `vault_locked` with the handle, no content.
- Version skew between app and helper: protocol carries a version; mismatch
  refuses with a readable error.
- Concurrent clients (GUI + MCP): the agent serializes unseal state; the
  reuse window is shared.

## Why not ship it in this wave

The cutover's risk is not the Swift, it is the packaging and OS integration:
SMAppService approval UX, signing three artifacts with the right
requirements, and Touch ID prompts from an agent context can only be
verified on a real signed build of LDA.app, launched as a bundle, on this
Mac (packaging memory: build outside iCloud, sign with the Developer ID).
That is a session of its own with the app in hand, not a change to land
between suite runs. Until then the shipped posture is: encrypted at rest,
keys in the silent file Keychain, honestly reported by `attest`.
