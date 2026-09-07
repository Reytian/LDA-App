# Fix log for the 2026-09-07 verification review

Companion to [code-review-2026-09-07-verification.md](code-review-2026-09-07-verification.md),
Codex's re-verification of `4895760`. It closed nine of the first review's
fourteen findings, called five partial, and reported nine outstanding items
(R1 to R9). Every item below was fixed test-first on `feat/lda-macos-core`
with the reviewer's own reproduction as the RED test, reviewed by the
integrating session before merge, and verified by the full suite with zero
failures and zero skipped tests, live model included. Final code tip: `daa3e99`,
2483 tests.

## Items

| Id | Finding | Commits | Where | Regression tests |
|----|---------|---------|-------|------------------|
| R1 | Malformed entity rows passed the coverage gate | `5bd24b3`, `8ce747c` | `EntityJSONParser` validates every row: a missing or unknown type, an empty value, or another schema marks the completion invalid while readable rows stay as salvage | `EntityRowValidationRefusalTests` |
| R2 | Namespace guard bypassed by an encoded URI or a Unicode prefix | `91ee61b` | `DocxNamespaceGuard` decodes the namespace name and accepts any attribute-name prefix | `DocxNamespacePrefixTests` |
| R3 | Field targets: encoded scheme survived, apostrophe truncated the address | `85a9ad4` | New `DocxDecodedXML` (decoded text with a per-unit map to the raw bytes) and `DocxFieldTargets` (instruction arguments tokenized by their own delimiters, scheme to argument end replaced) | `DocxFieldTargetScrubTests` |
| R4 | Document variables kept originals in settings.xml | `089d309` | New `DocxSettingsScrub` strips `w:docVars` and `w:mailMerge` plus the mail-merge source relationships, privacy export only, failing closed | `DocxSettingsScrubTests` |
| R5 | A decomposed, wrapped repeat stayed visible | `316564d` | `EntityVariantPattern` alternates the canonical spellings of each grapheme cluster, deduplicated by scalar | `EntityLocatorCanonicalVariantTests` |
| R6 | Markdown-escaped literals bypassed reservation and restored into text | `6c6e20e` | New `MarkdownTokenDecode` (plain and offset-mapped decode) feeds `Tokenizer` reservation and `SessionSeamVerifier`, which verifies on the decoded text and reports could-not-verify if the map fails | `SessionEscapedLiteralReservationTests`, `MarkdownTokenDecodeTests` |
| R7 | An export finishing after a matter switch adopted the previous matter's mapping | `0c1e115` | New `ExportMappingHome` snapshots the workspace payload and matter identity before the export suspends; adoption into the live session requires the same matter generation and label, otherwise a localized shell advisory names the workspace that holds the key | `ExportMatterBoundaryTests` |
| R8 | Restore approval wrote a source edited after the preview | `7e943f4` | New `RestoreSourceGuard`: the file is fingerprinted when the preview is computed and checked after the save panel, immediately before the write; a changed file refuses and writes nothing | `RestoreSourceGuardTests` |
| R9 | Replanning the same target let an older plan overwrite the newer one | `51363ba` | `FillModel.planSerial`, bumped at every plan start and by Back to Profile, carried in a `PlanTicket` checked at success, failure and display-text completions | `FillModelPlanRevisionTests` |

## Behaviour changes a user will notice

- A model completion with an unreadable row (missing or unknown type, a row
  in another schema) now refuses release as an incomplete scan instead of
  exporting the names it could not classify.
- A .docx whose Word namespace is spelled with character references or bound
  to a non-ASCII prefix is refused at import like the plain alternate prefix.
- The redacted .docx no longer carries document variables or mail-merge data;
  the mail-merge data source relationship is removed with them.
- Restore approval refuses when the edited file changed after the preview and
  asks for a fresh preview. Nothing is written.
- An export that finishes after you switched matters keeps its mapping in the
  starting matter's workspace and says so in the shell; it is not loaded into
  the matter now on screen.

## Follow-ups recorded, not done here

- `word/webSettings.xml` and `word/styles.xml` still copy through unaudited.
- `SessionModel.swift` is 1667 lines because Swift extensions cannot hold
  stored properties; the split it needs is a refactor of its own.
- Three MCP fill tests fail when the package source is snapshotted outside the
  allowed roots (a relative `fake-model.gguf` path); the tests are correct in
  the canonical checkout, so this is a test-environment note, not a defect.

## Verification

Each branch ran the full suite on its own merged tree before landing: DOCX
2437 tests, engine 2472, UI 2483 (the final merged tree, `daa3e99`). Always zero failures and
zero skipped tests, with the live model loaded. The packaged app was rebuilt
from the final tip with the Developer ID provisioning profile embedded.
