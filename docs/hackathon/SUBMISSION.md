# Devpost submission draft

## Project name

LDA: Private Legal AI Workspace

## Tagline

An offline macOS workspace that anonymizes, restores, and fills legal documents
before confidential information reaches cloud AI.

## Category

Work and productivity

## Inspiration

Lawyers want the productivity benefits of modern AI, but legal documents carry
client names, deal terms, personal data, bank details, signatures, and other
sensitive information. Uploading an untouched agreement to a general-purpose
cloud service can create confidentiality and data-protection risk. LDA creates
a practical privacy boundary on the lawyer's own Mac.

## What it does

LDA imports legal documents, detects sensitive entities locally, and gives the
lawyer a review screen before replacing approved items with typed placeholders
such as `{PERSON_1}` and `{COMPANY_1}`. The anonymized document can then be used
in an external AI workflow. When the work returns, LDA restores the original
values locally from an encrypted mapping.

The app also maintains encrypted matter workspaces, supports rename and
archive workflows, recovers interrupted sessions, and can fill draft documents
from encrypted client profiles. It supports text, DOCX, and PDF workflows and
runs a local GGUF model through llama.cpp and Metal. Its macOS App Sandbox has
no network entitlement, so the operating system blocks outbound network access.

## How we built it

The native app is written in Swift and SwiftUI. LDACore combines deterministic
detectors for structured data with on-device language-model inference for
contextual entities. Mapping and matter data are stored in versioned AES-GCM
containers, with app keys protected by the macOS Keychain. Document processing
supports reversible tokenization, review-first restoration, PDF redaction, and
form filling. The release is signed with Developer ID, notarized by Apple, and
validated by Gatekeeper.

During OpenAI Build Week, Codex helped turn an existing technical app into a
coherent guided product. The July 20 extension added the matter workspace,
rename and archive actions, session recovery, privacy-safe metadata migrations,
workflow routing, extensive regression tests, and hardened packaging. Codex
accelerated codebase tracing, implementation, test design, code review, and the
notarized release workflow. The entrant made the key product and privacy
decisions and verified the resulting behavior.

Model wording to confirm before submission: GPT-5.6 was the selected Codex
model for the Build Week extension.

## Challenges

The hardest problem was preserving a simple experience while maintaining a
strict local privacy boundary. Matter names and lifecycle state had to remain
usable without leaking client data into ordinary preferences or logs. Rename,
archive, restore, and deletion also had to stay consistent across encrypted
mappings and resumable sessions. Packaging a 2.5 GB on-device model from an
iCloud-synced checkout introduced additional signing and filesystem edge cases.

## Accomplishments

- A guided workflow that makes a complex privacy process understandable.
- Reversible anonymization with local review and encrypted mappings.
- Matter rename, archive, unarchive, and interruption recovery.
- Fully offline App Sandbox entitlements with no network capability.
- A signed and Apple-notarized macOS application.
- 808 passing automated tests across core, UI logic, security stores, CLI,
  MCP, document formats, packaging, and entitlements.

## What we learned

Privacy is not one feature. It shapes storage, UI labels, logs, recovery,
testing, and distribution. Guided workflows are especially important in legal
software because a technically correct tool still fails if the user cannot see
what will happen before applying a change. We also learned that local AI product
quality depends as much on packaging and recovery as it does on inference.

## What's next

Next steps include a smaller downloadable model, broader language evaluation,
team-safe profile exchange, more PDF form controls, signed automatic updates,
and structured audit exports that reveal process metadata without exposing
client content.

## Built with

Swift, SwiftUI, Swift Package Manager, llama.cpp, Metal, PDFKit, CryptoKit,
macOS Keychain, App Sandbox, Codex, GPT-5.6 (pending entrant confirmation)

## Testing instructions

1. Download and unzip the notarized test build.
2. Run it on an Apple Silicon Mac with macOS 14 or later.
3. Open `docs/hackathon/sample-matter.txt` or another fictional document.
4. Choose Anonymize, review the detected entities, and create the protected
   output.
5. Open Matters to rename or archive the saved matter.
6. Use Restore with the encrypted mapping to recover the original text.

The release is free for judging and requires no account, API key, server, or
network connection.

## Submission links

- Repository: `https://github.com/Reytian/LDA-App/tree/feat/lda-macos-core`
- Test build: add public Google Drive URL
- Demo video: add public YouTube URL
- Codex session ID: `019f7514-8c99-7cc2-aeb6-42d52061ab7d`
