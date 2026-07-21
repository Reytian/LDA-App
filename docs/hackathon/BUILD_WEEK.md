# OpenAI Build Week extension

LDA existed before OpenAI Build Week. The hackathon entry is based on the
meaningful native macOS extension completed during the Submission Period and
recorded in commit `047b30d` on July 20, 2026.

## What was added during Build Week

- A guided home screen that helps a lawyer choose the right privacy workflow.
- A matter workspace for organizing local sessions without exposing client
  content in plaintext metadata.
- Matter rename, archive, unarchive, reopen, and safe deletion workflows.
- Recovery for parked and interrupted sessions.
- Stronger encrypted metadata stores and identity-safe rename propagation.
- Clearer review, fill, restore, and custom-model routing.
- App Sandbox entitlements with no network access.
- A hardened Developer ID build, Apple notarization, and Gatekeeper validation.
- New automated coverage for guided presentation logic, matter metadata,
  parked sessions, AI settings, packaging, entitlements, and workflow routing.

The commit changes 43 files with 5,033 insertions and 351 deletions. The final
verification suite passes 808 tests, including the release-copy regression test.

## How Codex contributed

Codex was used as an engineering and product-design collaborator throughout
the extension. It helped trace existing state flows, identify recovery and
privacy edge cases, turn the guided-workflow direction into SwiftUI
presentation logic, implement rename and archive behavior across encrypted
stores, add regression tests, review the full change set, and automate release
signing and notarization checks.

The human product decisions remained explicit: prioritize minimal polish over
a redesign, introduce the guided workflow before advanced features, keep every
document operation review-first, preserve fully offline execution, and add
rename and archive before broader matter-management features.

## Dated evidence

| Evidence | Value |
| --- | --- |
| Submission-period commit | `047b30d` |
| Commit date | July 20, 2026 |
| Commit title | `feat: add guided matter workspace and harden app workflows` |
| Automated tests | 808 passing |
| Codex session ID | `019f7514-8c99-7cc2-aeb6-42d52061ab7d` |
| Apple notarization submission | `1a861114-8c51-4b36-ab68-49bde095a599` |

## GPT-5.6 confirmation

Before submission, confirm that GPT-5.6 was the selected Codex model for the
Build Week extension. The Devpost description and demo narration should only
state this after the model selection is confirmed by the entrant.
