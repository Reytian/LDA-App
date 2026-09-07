# Fix log for the 2026-09-06 full code review

Companion to [code-review-2026-09-06.md](code-review-2026-09-06.md), which reviewed
`f745917`. Every native finding below was fixed test-first on `feat/lda-macos-core`,
reviewed by the integrating session before merge, and verified by the full suite
with zero failures and zero skipped tests (live-model tests included). Final tip:
`b143b00`, 2413 tests.

The legacy Python prototype findings L1 to L3 were not fixed: that prototype is
retired and not in use.

## Findings

| # | Finding | Commits | Where | Regression tests |
|---|---------|---------|-------|------------------|
| 1 | Failed or invalid model completions passed the coverage gate; a missing `--model` fell back to patterns silently | `8690b38`, `784b225` | `EntityJSONParser` (`EntityParse` with `invalid`), `LLMExtractor.scanSegment`, new `LDAServiceDetector.swift` (`modelUnavailable`), CLI and MCP messages | `LLMExtractorFailureCoverageTests`, `ModelUnavailableRefusalTests`, `EntityJSONParserTests` |
| 2 | Export could include edits made after review | `0bc1423`, `6dc900e` | `SourceFingerprint.swift` checked immediately before a DOCX or image export reads the file; standing Save Redacted block; Save Workspace refuses too | `ReviewModelSourceIntegrityTests`, `WorkspaceSessionTests`, `SaveAvailabilityTests` |
| 3 | An exact PDF match hid wrapped occurrences on other pages | `78f8597`, `db452ef` | `PdfImporter.redactionCoverage`, new `PdfRedactionCoverage.swift`, `PdfReviewSurface.swift`; coverage counted per occurrence | `PdfCrossLineRedactionTests` |
| 4 | DOCX custom XML kept the original value | `b8eb8d5` | New `DocxPackagePolicy.swift`: members classified, `customXml/*` and `docProps/thumbnail*` dropped with bindings, relationships and overrides; unknown members refuse | `DocxCustomXMLStripTests` |
| 5 | Split field instructions bypassed target scrubbing | `9ad2913` | New `DocxFieldInstruction.swift`: instruction assembled per field, scrubbed, projected back onto its runs | `DocxSplitFieldInstructionTests` |
| 6 | Alternate XML prefixes hid text from detection | `8533782` | New `DocxNamespaceGuard.swift`: refuses the Word namespace bound to any prefix but `w`, at every start tag | `DocxNamespacePrefixTests` |
| 7 | Concurrent processes lost vault registrations | `b405fd5` | New `VaultCrossProcessLock.swift`: `flock(2)` on `registry.lock`, composed with the in-process lock around every registry transaction; staging encrypts unlocked between two locked phases | `VaultCrossProcessRaceTests` (spawns eight real `lda` processes, three times) |
| 8 | Reopening a workspace dropped the AI export warning | `9b8a098`, `fd65fb6` | `WorkspaceReviewSnapshot.aiCoverage` (format version 2), `AIScanCoverage.swift`; unknown coverage reads as did-not-run; a relocated snapshot re-applies warned | `ReviewModelWorkspaceCoverageTests`, `WorkspaceArchiveTests` |
| 9 | Cancelling a retry cleared the previous warning | `4c33d82` | `ReviewModel.anonymize` restores status, entities, coverage and learning note together | `ReviewModelScanCoverageTests` |
| 10 | A stale extraction could overwrite another portfolio | `d1c4372`, `dff9984` | `FillModel.editorGeneration` and `extractionSerial`; async intents in `FillModelAsyncIntents.swift` land only for the occupant they started for | `FillModelStaleCompletionTests`, `FillModelLibraryTests` |
| 11 | Shared session mappings corrupted literal template tokens | `f1f8560`, `10daced` | `Tokenizer` reserves literals across every session document before minting; `SessionSeamVerifier.reportTokenStyle` refuses a seed token a document spells | `SessionLiteralReservationTests`, `LDAServiceSessionTests` |
| 12 | Mixed-style restoration rewrote freshly restored originals | `7ab7aaa`, `ed826d8` | `Restorer.tokenStyleRestoreDecision`: tokens and carried literals decided in one pass over the input; the DOCX writer shares the decision | `RestorerMixedStyleOnePassTests`, `RestorePreviewParityTests` |
| 13 | One exact occurrence hid whitespace variants | `148ffcb` | `EntityLocator` runs the exact search and a bounded whitespace-variant search side by side (`EntityVariantPattern.swift`) | `EntityLocatorWhitespaceVariantTests`, `LLMExtractorTests` |
| 14 | Direct DOCX inflation bypassed archive limits | `1cbe924` | `DocxZip.readEntry` and `rewrite` charge `ArchiveBudget` for inflated bytes through one ledger per pass; size refusals keep their own error kind | `DocxArchiveBudgetTests` |

Coverage items from the review's closing notes: `LLMExtractor.keptTypes` now keeps
model-reported `NATIONAL_ID` (`ab1f995`), US Social Security numbers are detected
deterministically (`a3863f7`), and the live-model test helper resolves the installed
model from `Models.json` (`b0a927f`), so ordinary runs exercise the shipping model.

## Behaviour changes a user will notice

- Privacy export refuses a `.docx` that holds a member the redactor cannot clean:
  SmartArt, charts, embedded objects or workbooks, a glossary part, Word Editor
  caches, add-in data. The message gives a count, never a path. Filling a form is
  unaffected.
- The redacted copy of a `.docx` no longer carries `customXml` stores or the
  first-page thumbnail; bound content controls keep their redacted text and lose
  their binding.
- A `.docx` whose Word namespace is bound to a prefix other than `w` is refused
  at import with advice to save a copy from Word.
- A requested detection model that cannot run is a refusal at the CLI, the MCP
  server and in the app, never a silent pattern-only run.
- Save Redacted and Save Workspace refuse when the source file changed after the
  scan; opening the file again clears it.
- Workspaces are written in format version 2. Older builds refuse them rather
  than dropping the coverage record.
- A token-style session whose seed token a document spells literally is reported
  as a seam; single-document paths refuse release.

## Follow-ups recorded, not done here

- The app's own PDF export writes only the redacted text companion and no boxed
  review PDF; only the CLI and MCP path renders one, so the app's unboxed count is
  always zero for PDFs.
- Namespace-aware DOCX matching (the review's option a) remains open; refusal is
  the shipped behaviour.
- Redact the glossary part and drop Word Editor caches instead of refusing them.
- `word/settings.xml` document variables still copy through unchanged.
- `ReviewModel.swift` (1153 lines) and `Tokenizer.swift` (797) need splitting.
- The handoff card's advice sentence for seams predates token-style seams.

## Verification

Each branch ran the full suite on its own merged tree before landing (2308, 2345,
2335, 2372, 2379, 2411 and 2413 tests along the way, always zero failures and
zero skipped tests). The packaged app was rebuilt from the final tip with the
Developer ID provisioning profile embedded; it is not notarized and was not
launched, pending the Touch ID launch test.
