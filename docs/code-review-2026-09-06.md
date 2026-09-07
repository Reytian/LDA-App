# LDA full code review

Reviewed commit: `f745917bf79da8dba889c1dc14d20fb78978188c` (September 6, 2026).

The review confirmed **14 native-app issues: 13 P1 findings and one P2 finding**. Three additional defects affect the legacy Python prototype. The existing suite is green, but targeted adversarial probes expose privacy leaks, incorrect restoration, and lost state. The P1 issues should be addressed before relying on the affected export and restoration workflows for confidential documents.

P1 means a high-priority correctness, privacy, or data-loss issue. P2 means a material issue with a narrower trigger or impact. No production code was changed. Temporary regression tests were removed after execution.

## Validation and scope

- Native baseline: **2,136 tests, zero failures, eight skipped**. The skips referenced the retired `lda-v2-Q4_K_M.gguf` path.
- Explicit installed Quick model run: **12 selected tests, zero failures, zero skips**, including all eight previously skipped live-model cases. Model: `Qwen3.5-4B-Q4_K_M.gguf`.
- Legacy Python: **75 passed, one live-backend test skipped**.
- Document-security regression probes: **five tests, five expected assertion failures, zero unexpected errors**. Each failure demonstrates a missing safety invariant described below.
- Additional synthetic probes exercised UI models, the actual tokenization/restoration engine, the compiled CLI, and six concurrent CLI vault processes.

The review covered native engine/domain/service code, DOCX/PDF/image/archive I/O, encrypted persistence, UI orchestration, app wiring, CLI/MCP boundaries, packaging, and relevant tests. The source inventory includes 182 Swift source files and 207 Swift test files. Legacy Python processing, UI, and skill bridge were also inspected. This was a source review with focused runtime verification, not a line-by-line audit of third-party dependencies or the prebuilt llama binary. No packaged GUI session, model download, signing, or notarization run was performed. The live-model tests are smoke/regression evidence, not a comprehensive recall benchmark.

## Native app findings

### 1. [P1] Failed or invalid model completions pass the coverage gate

Location: [LLMExtractor.swift:389](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/LLMExtractor.swift:389>), especially the `incomplete: false` return at line 395. Related: [EntityJSONParser.swift:108](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/EntityJSONParser.swift:108>) and [LDAService.swift:624](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Service/LDAService.swift:624>).

A backend exception becomes an empty successful segment. A response such as `I cannot process this text.` also becomes an empty, non-truncated extraction. The service checks `fullyCovered`, so it accepts these results and writes an artifact although the model did not scan its names and addresses. An explicitly supplied missing or unloadable model also silently falls back to deterministic detection.

**Evidence:** Both a throwing completer and a non-JSON completer returned `fullyCovered=true, spans=0, incompleteSegmentCount=0`. Independently, the compiled CLI accepted a nonexistent `--model`, exited 0, and wrote:

```text
Alice Smith signed for Acme Corporation.
Contact {EMAIL_1}.
```

It reported one entity and no model-failure warning. Distinguish a valid empty entity array from backend, schema, and parsing failures. Propagate those failures or mark the scan incomplete. Require an explicit, reported fallback when a requested model cannot run.

### 2. [P1] Export can include changes made after document review

Location: [ReviewModelDetection.swift:382](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/ReviewModelDetection.swift:382>).

The GUI snapshots reviewed text and accepted spans, but DOCX export reopens the mutable original file. It does not check that the source still matches the reviewed version. If the user edits that file in Word between scanning and exporting, new body content is copied into the export without detection or review; earlier edits can also invalidate offsets.

**Evidence:** After scanning a synthetic DOCX containing one email, the probe rewrote the source with a second email and exported. `reviewedContainsAddedPII=false`, `exportedContainsAddedPII=true`, and `reportedRedactions=1`. Export succeeded.

Export from immutable imported bytes, or verify a source-content fingerprint immediately before use and require a new scan when it differs.

### 3. [P1] An exact PDF match prevents boxing other wrapped occurrences

Location: [PdfImporter.swift:159](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/PdfImporter.swift:159>). Related: [LDAService.swift:348](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Service/LDAService.swift:348>).

Normalized PDF search runs only when a value has no exact match anywhere in the document. If a name appears normally on one page and across two lines on another, only the normal occurrence gets a redaction box. The unboxed-token count also treats a token as covered when any box exists, hiding this partial coverage.

**Evidence:** A two-page PDF produced `exact=1`, `normalizedPages=[0,1,1]`, but production `redactionBoxes` returned `actualPages=[0]`. The unboxed page retains the original pixels. This probe verified the production geometry methods, not the complete LLM-to-PDF export pipeline.

Combine exact and normalized occurrence coverage, deduplicate boxes, and measure coverage by occurrence rather than by unique token.

### 4. [P1] DOCX custom XML retains the original confidential value

Location: [DocxParts.swift:61](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxParts.swift:61>), with unchanged member copying in [DocxXML.swift:173](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxXML.swift:173>).

The redactor processes a fixed set of Word text parts and copies other ZIP members. A content control's `customXml/item*.xml` data store can therefore retain the original value after the visible body is redacted. Its data binding also survives. Unzipping the exported file is sufficient to retrieve the value.

**Evidence:** Full `LDAService.anonymize` on a synthetic document reported one redaction. The body no longer contained `client@example.test`, but `customXml/item1.xml` still did: `entityCount=1 bodyPII=false customPII=true`. No claim about Word automatically refreshing the binding is necessary; the plaintext leak was directly verified in the output archive.

Remove or sanitize custom XML stores and associated bindings during privacy export, or refuse unsupported packages explicitly.

### 5. [P1] Split DOCX field instructions bypass target scrubbing

Location: [DocxMarkupScrub.swift:86](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxMarkupScrub.swift:86>).

Complex Word fields can split a hyperlink instruction across several `w:instrText` elements. Scrubbing each element independently misses a target whose scheme and address occur in different runs. Instruction text is outside the ordinary visible-text detector.

**Evidence:** For an instruction split between `HYPERLINK "mailto:` and `client@example.test"`, the production scrubber replaced `mailto:` with `about:blank` while leaving the complete email in the next instruction element.

Assemble field instructions across runs before scrubbing, and project the sanitized result back into the original segments. Add cases split at every part of the target, including scheme, address, and closing quote.

### 6. [P1] Valid alternate XML prefixes hide DOCX text from detection

Location: [DocxXML.swift:292](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxXML.swift:292>) and [DocxRunText.swift:21](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxRunText.swift:21>).

The parser recognizes literal names such as `w:t` rather than resolving namespace bindings. Equivalent WordprocessingML using an alternate prefix, including a prefix applied only to selected runs, is preserved as markup but omitted from the imported text. The parser does not reject this unsupported representation.

**Evidence:** `<x:t>client@example.test</x:t>` with `x` bound to the normal WordprocessingML namespace parsed successfully as empty text; serialization still contained the full email: `importedText="" preservedPII=true`.

Recognize the namespace URI plus local name consistently in parsing and scrubbing. Until supported, reject documents whose Word text elements would otherwise bypass extraction.

### 7. [P1] Concurrent processes lose successful vault registrations

Location: [DocumentVault.swift:201](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Security/DocumentVault.swift:201>) and [DocumentVault.swift:289](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Security/DocumentVault.swift:289>).

The registry read-modify-write transaction uses `NSLock`, which serializes threads in one process only. CLI staging and MCP processes can share the same vault. Concurrent writers can each read the same registry, append their own entry, and overwrite the other writer's update.

**Evidence:** Six concurrent compiled `lda vault stage` processes against an isolated vault all exited 0 and returned distinct handles. A subsequent list contained only **one** entry, although **six** encrypted object directories existed. The five lost handles were no longer registered; the encrypted objects were orphaned, not physically deleted.

Use a cross-process lock around the complete transaction or a transactional store. Apply it to staging, derived commits, migration, and all other registry mutations.

### 8. [P1] Workspace reopening removes the AI export warning

Location: [ReviewModel+Workspace.swift:52](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/ReviewModel+Workspace.swift:52>) and [ReviewModel+Workspace.swift:84](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/ReviewModel+Workspace.swift:84>).

Workspace snapshots preserve entity decisions but omit AI scan coverage. Applying a snapshot sets the document to ready while leaving the new model's AI warning fields empty. A failed or partial scan that required export confirmation before saving therefore no longer requires that confirmation after reopening.

**Evidence:** A no-model scan initially had `ready=true, gate=didNotRun`. Capturing and applying its actual workspace snapshot produced `ready=true, gate=nil, warning=nil` with the same detected entities.

Persist structured coverage state with the snapshot. Treat older snapshots whose coverage is unknown conservatively. Readiness to review must not imply a complete AI scan.

### 9. [P1] Cancelling a retry clears the previous scan's warning

Location: [ReviewModel.swift:529](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/ReviewModel.swift:529>) and [ReviewModel.swift:578](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/ReviewModel.swift:578>).

Starting a rescan clears `aiWarning` and `aiRanPartially`. Cancellation restores the prior status and entities, but not their coverage fields. Cancelling a retry of a failed or partial scan consequently leaves the old result exportable without its prior warning.

**Evidence:** The actual scan/cancel orchestration changed `ready=true, gate=didNotRun` into `ready=true, gate=nil, warning=nil` after cancellation.

Keep the previous completed scan result and its coverage together until a new completed result replaces them. Restore all of that state on cancellation. This and finding 8 share an invariant but require separate cancellation and serialization fixes.

### 10. [P1] A stale extraction can overwrite another portfolio

Location: [FillModel.swift:594](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/FillModel.swift:594>). Related: [FillModelLibrary.swift:174](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/FillModelLibrary.swift:174>).

Back to Library remains available during extraction. Navigating away and opening portfolio B does not invalidate extraction A. When A finishes, it loads A's profile into the editor while retaining B's `currentPortfolioID`. A nonempty extraction marks the profile dirty, and Save uses the retained B ID.

**Evidence:** A blocked synthetic extraction, a navigation/open transition, and then completion produced `profile=Synthetic Portfolio A`, `saveStillTargetsB=true`, `profileDirty=true`, and `canSaveToLibrary=true`. The probe exercised the real extraction orchestration but emulated the completed library-open transition to avoid accessing user data. The final overwrite follows directly from the production save call `lib.save(profile, id: existingID)`; no real portfolio was overwritten.

Bind asynchronous work to a generation and portfolio identity. Invalidate that ownership on navigation/open/create, and ignore stale completions before they modify profile contents or identity.

### 11. [P1] Shared session mappings corrupt literal template tokens

Location: [Tokenizer.swift:311](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/Tokenizer.swift:311>) and [Tokenizer.swift:334](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/Tokenizer.swift:334>).

Token collision reservation examines only the current document, while restoration uses the session's final shared mapping. A token minted for one document can collide with a literal template token in another. Retaining an older seed binding creates the same problem even if the tokenizer refuses to reuse it for a new redaction.

**Evidence:** Document 1, `Alice`, became `{PERSON_1}`. Document 2, `Fill in {PERSON_1}.`, was unchanged during anonymization but restored as `Fill in Alice.`. Orphan, ambiguity, and seam warnings were empty, and the outbound release gate passed.

Reserve literals across the entire session before minting and verify restoration with the final union mapping. Existing seed collisions need an explicit refusal or provenance policy; minting a new token does not neutralize the old restore entry.

### 12. [P1] Mixed-style restoration rewrites newly restored originals

Location: [Restorer.swift:81](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/Restorer.swift:81>).

A token-style mapping can carry older pseudonyms. Restoration first expands brace tokens, then searches that expanded output for the carried pseudonyms. The second pass can match inside an original value just restored by the first pass and silently change it.

**Evidence:** With an existing `Person A -> Alice` pseudonym binding, token-style anonymization of the company `Person A Holdings` produced `{COMPANY_1}`. Restoration returned `Alice Holdings` and reported two restorations. Both mappings were produced through supported tokenizer/seed paths.

Plan token and literal substitutions against the original returned text in one pass. Never search newly restored values for additional replacements. Verify DOCX and text parity when changing the restore algorithm.

### 13. [P1] One exact name occurrence hides missed whitespace variants

Location: [LLMExtractor.swift:262](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/LLMExtractor.swift:262>).

The unanchored-value safeguard runs only when a model-reported value has zero exact matches. If one exact occurrence exists, another occurrence with different whitespace or line wrapping remains visible while the result is called fully anchored. Full-document rescan repeats the same literal search.

**Evidence:** Given the correct model entity `Alice Smith`, detection, merge, rescan, and tokenization transformed:

```text
Alice Smith signed. Contact Alice
Smith for details.
```

into:

```text
{PERSON_1} signed. Contact Alice
Smith for details.
```

`fullyCovered=true`, `fullyAnchored=true`, and outbound validation passed. This affects the textual edit surface and is separate from finding 3's PDF geometry defect.

Search normalized variants even after an exact hit, with a mapping back to source offsets. Preserve original slices for restoration and handle document breaks explicitly.

### 14. [P2] Direct DOCX inflation bypasses archive resource limits

Location: [DocxXML.swift:96](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxXML.swift:96>) and [DocxXML.swift:180](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxXML.swift:180>).

DOCX import checks compressed input size, but its ZIP reader appends inflated chunks without an actual-byte budget. Rewrite repeats this for untouched members. A small highly compressed document can consume excessive memory; placing it inside a metered ZIP does not limit the later DOCX inflation.

**Evidence:** A 1,294-byte synthetic DOCX imported 65,536 text bytes despite a debug-configured 4,096-byte archive ceiling. The probe deliberately avoided a production-scale allocation attack. The absence of a production read/rewrite bound is established by the source.

Carry the shared import budget through DOCX entry reads and rewrites, meter actual emitted bytes, and preserve the size-limit error instead of converting it into a generic corrupt-file error.

## Legacy Python prototype

These findings affect the Streamlit/Python code and skill bridge, not the native Swift implementation.

### L1. [P1] DOCX tables and headers never reach detection

Location: [core/file_handler.py:65](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/core/file_handler.py:65>).

`_read_docx` reads only `doc.paragraphs`. It omits table cells, headers, footers, and other non-body parts. The writer can replace known values in some of those locations, but values present only there never enter the entity list.

**Evidence:** A synthetic file had a harmless body, an email in a table, and a name in its header. `read_uploaded_file` returned only `Ordinary public terms.`.

Make detection enumerate the same content that export retains, and add package-wide leakage tests.

### L2. [P1] Hyperlink relationships retain redacted email addresses

Location: [core/file_handler.py:165](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/core/file_handler.py:165>) through its package save at [core/file_handler.py:315](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/core/file_handler.py:315>).

The Python writer redacts hyperlink display text but leaves external relationship targets untouched. A displayed email can become `{EMAIL_1}` while the original remains in `word/_rels/document.xml.rels`.

**Evidence:** After replacing `alice@example.com` in a synthetic hyperlink, `pii_in_body=false` and `pii_in_relationship=true`.

Scrub privacy-bearing relationship targets and field instructions as part of the same export operation, including cases where display text differs from the target.

### L3. [P2] A DOCX with zero entities crashes during export

Location: [core/file_handler.py:206](</Users/haotianyi/.codex/worktrees/ed9c/Legal Document Anonymizer/core/file_handler.py:206>).

An empty replacement list makes `_build_replacement_regex` return `None`. A nonempty paragraph still calls `pattern.finditer`, causing `AttributeError: 'NoneType' object has no attribute 'finditer'`.

**Evidence:** Calling `apply_replacements_to_docx` on an ordinary synthetic DOCX with `[]` replacements reproduced the exception.

Handle the no-replacements case explicitly, while still applying any required metadata or hidden-content cleanup.

## Coverage observations and next steps

The test suite is extensive, but isolated happy-path cases miss several composition failures: exact plus wrapped occurrences, restoration under the final mapping union, warning state across cancellation and persistence, and multiple processes writing one store. These should become durable regression tests when the fixes are implemented. Some current tests explicitly allow backend/garbage-output fallback; that contract needs revision alongside finding 1.

US SSN coverage is also absent from the current deterministic national-ID implementation, and `LLMExtractor.keptTypes` discards model-reported `NATIONAL_ID` values. A synthetic `SSN: 123-45-6789` remained undetected even with that model response. This is recorded as a coverage limitation rather than an additional defect in the supported Chinese-ID implementation. The live-model test helper's retired default filename should be updated so ordinary test runs exercise the installed shipping model.

Recommended implementation order: preserve truthful scan/export state (1, 2, 8, 9); close DOCX/PDF leaks and repeated-occurrence gaps (3-6, 13); prevent vault/portfolio loss (7, 10); make final-mapping restoration safe (11, 12); enforce DOCX resource bounds (14). Keep the legacy fixes in a separate scope if that prototype remains in use.

## Reproduction evidence

All evidence uses synthetic documents. Temporary paths below are local and may be removed by system cleanup.

- [Native baseline log](/private/tmp/lda-review-20260906-swift.log)
- [Installed Quick model test log](/private/tmp/lda-review-20260906-live.log)
- [Python baseline log](/private/tmp/lda-review-20260906-python.log)
- [Five document-security probes](/private/tmp/lda-review-document-security/ReviewDocumentSecurityProbeTests.swift) and [their failed safety assertions](/private/tmp/lda-review-document-security/probe-tests.log)
- [Engine reproduction source](/private/tmp/lda-engine-review/main.swift) and [results](/private/tmp/lda-engine-review/results.txt)
- [UI reproduction source](/private/tmp/lda-ui-review-probes.swift) and [results](/private/tmp/lda-ui-review-probes.stdout)
- [Concurrent vault reproduction results](/private/tmp/lda-vault-race-review-y8jhu5lt/repro.json)
- [CLI missing-model output](/private/tmp/lda-review-native-cli/out/source_redacted.txt)

The failed adversarial tests demonstrate confirmed defects; they are separate from the unchanged baseline suite's passing result. Proposed fixes in this report have not been implemented or verified.
