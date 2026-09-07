LDA current-copy fix verification, September 7, 2026

Reviewed commit: `4895760076f615f88de744a9f44fb8dd8e9b61a4`, branch `feat/lda-macos-core`, in the canonical checkout at `/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer`. Its HEAD and clean status were rechecked after validation. The Codex task's older worktree was not mistaken for the current copy: compilation and probes used an exact git archive of the current commit under `/private/tmp/lda-rereview-20260907/source`.

**Result: not fully fixed.** Nine original native findings can be closed for the tested scenarios; five remain partially fixed. This review confirms nine outstanding findings: seven P1 issues and two P2 issues. Five are residual forms of original findings; four concern adjacent behavior or newer functionality. P1 means address before relying on the affected privacy or matter-isolation path. P2 means a concrete correctness defect to fix next.

**Original finding closure**

| Original # | Finding | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Failed or malformed model responses permit release | Partial | Throwing completions, prose output and unavailable models now refuse before creating output. Malformed entity rows still pass, R1. |
| 2 | Source changed after review still exports | Closed | Changed DOCX refused with standing source-changed block. |
| 3 | Exact PDF match hides wrapped repeat | Closed | Current mixed exact/wrapped PDF regression passed. |
| 4 | DOCX retains custom XML containing originals | Closed | Current CLI removes synthetic custom XML member and original value. Separate settings gap is R4. |
| 5 | Split DOCX field target survives scrubbing | Partial | Original split target is clean. Encoded schemes and apostrophe targets leak, R3. |
| 6 | Alternate DOCX namespace prefixes bypass redaction | Partial | Ordinary alternate prefix refused. Equivalent XML encodings still pass, R2. |
| 7 | Concurrent vault registrations lose entries | Closed | Eight concurrent current-CLI stages yielded eight successes, registry entries and objects. |
| 8 | Workspace drops scan-coverage warning | Closed | Failed-scan coverage persists on reopen and remains gated. |
| 9 | Cancelled retry loses prior coverage warning | Closed | Cancellation restores prior did-not-run coverage and warning. |
| 10 | Stale extraction overwrites another portfolio | Closed | Reordered extraction leaves portfolio B and its save identity intact. Separate same-target planning race is R9. |
| 11 | Session/template token collisions corrupt restoration | Partial | Ordinary literals reserved and ordinary seed collision refused. Escaped Markdown literals still corrupt, R6. |
| 12 | Mixed-style restoration cascades into inserted values | Closed | Original company value restores once; genuine carried pseudonyms and escaped brace tokens also restore correctly. |
| 13 | Exact occurrence hides wrapped text repeat | Partial | ASCII example redacts every occurrence and restores exactly. Unicode normalization plus wrapping still leaks, R5. |
| 14 | DOCX inflation lacks a shared actual-byte budget | Closed | All six current archive-budget regressions passed, covering import, rewrite and supplementary/body shared budget. |

The SSN concern is fixed for tested deterministic and model-reported examples. Claude Code explicitly retired the Python prototype and left its three legacy findings unchanged; this review does not describe them as fixed.

**R1 [P1] Malformed entity rows still produce a successful privacy export**

Location: [EntityJSONParser.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/EntityJSONParser.swift:451>) and [type decoding](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/EntityJSONParser.swift:470>).

The parser accepts any nonempty value as a usable entity, including a missing or unrecognized type. The extractor then discards unknown entities while claiming full coverage. A mixed array also passes when one row is valid and another is silently skipped for using an incompatible schema.

With the real `LDAService.anonymize` facade, `{"entities":[{"value":"Alice Smith"}]}` and the unknown type `PER` both yield complete coverage and successfully export the clear name. A valid Alice row followed by `{"text":"Bob Jones","label":"PERSON"}` exports `{PERSON_1} signed with Bob Jones.` without refusing release.

Validate every row and distinguish recognized supported types from unknown schema. Salvaging useful rows must not turn a partly uninterpretable completion into full coverage.

**R2 [P1] Namespace refusal still permits XML representations that hide document text**

Location: [DocxNamespaceGuard.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxNamespaceGuard.swift:51>) and [namespace comparison](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxNamespaceGuard.swift:77>).

The namespace declaration regex only recognizes ASCII prefix names and compares an undecoded attribute value. Both an `x` prefix bound to `http://schemas.openxmlformats.org/wordprocessingml/2006/ma&#105;n` and a Unicode `文` prefix bound to the ordinary namespace bypass refusal. Both fixtures were validated as well-formed XML. The current CLI exits 0, reports zero entities and leaves `client@example.test` in the exported document XML. The ordinary `x` prefix control correctly refuses.

Inspect namespace bindings using XML semantics, including decoded attributes and valid Unicode names. Every unsupported Word text binding must be handled or refused.

**R3 [P1] Field target scrubbing misses encoded schemes and truncates apostrophe addresses**

Location: [DocxMarkupScrub.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxMarkupScrub.swift:69>).

The new field-run assembly fixes the original split case, but scrubbing still matches raw XML with a regex that treats every apostrophe as an address terminator. `HYPERLINK "mail&#116;o:client@example.test"` survives completely. `HYPERLINK "mailto:o'brien@example.test"` becomes `HYPERLINK "about:blank'brien@example.test"`, retaining identifying address text. Both current-CLI exports succeed.

Parse the decoded field instruction, respect its actual quote delimiters and remove the entire target when projecting edits back to XML segments.

**R4 [P1] DOCX document variables retain originals after the visible body is redacted**

Location: [DocxPackagePolicy.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/IO/DocxPackagePolicy.swift:73>).

The policy classifies `word/settings.xml` as content-free and copies it unchanged. A fixture with a visible email and `<w:docVars><w:docVar w:name="ClientEmail" w:val="client@example.test"/></w:docVars>` exports successfully with one detected entity. The visible email is replaced, but the complete original remains in settings XML. No embedded-media or unboxed warning identifies it. Claude Code's fix log acknowledges this follow-up; the current CLI confirms its privacy impact.

Strip or sanitize document-variable values and related field uses, or refuse the unsupported content during privacy export.

**R5 [P1] A normalized wrapped repeat remains visible even after the model identifies the name**

Location: [EntityLocator.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/EntityLocator.swift:162>) and [LLMExtractor.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/LLMExtractor.swift:284>).

The exact search handles canonical equivalence, but the variant regex does not. For `René Martin signed. Contact Rene\u{301}\nMartin for details.`, the model correctly returns `René Martin`. Only the first occurrence anchors, yet coverage and anchoring both report complete. The anonymize facade successfully exports the second full name in decomposed form across the line break. The no-anchor safeguard never runs because the first match exists.

Match whitespace variants with canonical-equivalence support while preserving offsets into the original text, or detect and refuse uncovered equivalent occurrences even when another occurrence anchors.

**R6 [P1] Markdown-escaped source tokens bypass reservation and restore into unrelated text**

Location: [Tokenizer.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/Tokenizer.swift:343>) and [SessionSeamVerifier.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDACore/Engine/SessionSeamVerifier.swift:153>).

Reservation and verification inspect raw text, while restoration decodes escaped token underscores. In a two-document session, Alice mints `{PERSON_1}`; the untouched literal `Fill in {PERSON\_1}.` in the second document subsequently restores as `Fill in Alice.`. No seam, orphan or ambiguity is reported. Both seeded release preflight and a single-document anonymize facade accept the equivalent corruption.

Reserve and verify every spelling restoration decodes, with positions mapped back to the original source. A pre-existing literal must remain literal or produce a clear refusal.

**R7 [P1] An export finishing after a matter switch adopts the previous matter's mapping**

Location: [SessionModel+Workspace.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/SessionModel+Workspace.swift:392>) and [export completion closure](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/SessionModel+Workspace.swift:452>).

Export captures the source and document ID before suspending, but completion builds the default workspace from the live session and unconditionally adopts the mapping. A synthetic DOCX export for matter A was paused at its header-model completion. After switching to matter B and opening B's document, completing A's export inserted A's mapping into B's session. The saved default workspace had A's filename, B's matter label and zero documents.

This crosses the matter boundary and makes A's values available to B's session restoration. Snapshot the workspace payload and matter identity before suspension, and only update the live session if its generation still matches.

**R8 [P2] Restore approval writes different source content from the preview the user approved**

Location: [RestorePreviewModel.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/RestorePreviewModel.swift:242>); writer: [SessionModel+RestoreFile.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/SessionModel+RestoreFile.swift:155>).

The approval step receives the preview but uses it only to amend the mapping. The writer rereads the original URL without checking whether it still contains the previewed source. The real preview/approval/write path was exercised with `Pay {PERSON_1} USD 100.`, followed by a source edit while the preview was pending. The result was:

```text
Preview: Pay Alice USD 100.
Outcome: written
Written: Pay Alice USD 999.
```

Retain the approved source snapshot or fingerprint and refuse a changed input until the preview is refreshed. This probe used real production restoration and no Keychain access.

**R9 [P2] Replanning the same target lets an older plan overwrite the newer one**

Location: [FillModelAsyncIntents.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/FillModelAsyncIntents.swift:209>) and [FillModel.swift](</Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer/macos/LDACore/Sources/LDAUI/FillModel.swift:544>).

Planning freshness compares only editor generation and target URL. Back to Profile changes neither. Returning to the profile while planning, updating it and selecting the same target permits both requests to remain current. Releasing the newer request first and the older request second results in `final=["Old Plan"]`, replacing newer suggestions and review decisions.

Use a per-request planning revision, invalidate it on Back to Profile and check it for successful, failed and display-text completions.

**Validation and limits**

- Fresh build of the exact current commit succeeded.
- The full native suite exercised 2,413 tests with no test skips. It initially reported six failure assertions in three MCP fill tests because their relative `fake-model.gguf` path resolved inside the temporary snapshot, outside the allowed roots.
- All 12 MCP fill tests then passed using the same compiled bundle from the canonical project directory with the same Keychain access as the full run. An intermediate sandboxed rerun passed the three path-dependent tests but hit a Keychain access error in another test; the final approved rerun passed all 12. No product source was altered to obtain passing results.
- All 2,413 individual tests therefore have passing evidence across the full run and corrected targeted rerun. This is not a claim that the initial full command exited successfully.
- Existing tests do not cover the nine reproduced defects above. Probes used current compiled production code, synthetic files, deterministic model completions where appropriate, and isolated temporary persistence. The full suite also exercised the local model.
- The PDF mixed-match test and all six DOCX budget tests passed independently. The independent eight-process vault race also passed.
- No app source, real matter documents, production libraries or user preferences were changed. The canonical checkout remained clean. This report is stored in the Codex task's older worktree.
- The packaged, signed app and actual Touch ID interactions were not exercised. Keychain and packaging changes were inspected in source and through the available tests. The result does not certify live-model recall or every possible OOXML document.

**Reproduction evidence**

All evidence paths below contain synthetic data. Temporary paths can be removed by system cleanup, so the concrete inputs and outcomes are also recorded above.

- [Full native test log](/private/tmp/lda-rereview-20260907/full-suite.log)
- [Successful targeted MCP rerun](/private/tmp/lda-rereview-20260907/mcp-fill-rerun-approved.log)
- [Engine results](/private/tmp/lda-rereview-20260907/engine-probe-results.txt), [engine probe](/private/tmp/lda-rereview-20260907/engine-probe.swift)
- [DOCX results](/private/tmp/lda-rereview-20260907/io-probes/docx-results.json), [DOCX probe](/private/tmp/lda-rereview-20260907/io-probes/probe_docx.py)
- [PDF and archive-budget closure tests](/private/tmp/lda-rereview-20260907/io-probes/closure-tests.log)
- [Vault concurrency results](/private/tmp/lda-rereview-20260907/io-probes/vault-race/results.json)
- [UI closure and planning results](/private/tmp/lda-rereview-ui-probes.stdout)
- [Matter-switch export results](/private/tmp/lda-rereview-mapping-race.stdout), [probe](/private/tmp/lda-rereview-mapping-race.swift)
- [Restore preview results](/private/tmp/lda-rereview-20260907/restore-preview-evidence.txt), [probe](/private/tmp/lda-rereview-20260907/restore-preview-probe.swift)

Knowledge capture was evaluated. The verified reproductions and snapshot-path test workaround are retained here; no new remediation skill was created because the remaining fixes have not been implemented and validated.

