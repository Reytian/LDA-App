# PDF image-signature redaction (image-PII channel)

- **Status:** Approved (design), pending implementation plan
- **Date:** 2026-06-09
- **Component:** macOS LDA IO module (`macos/LDACore`, branch `feat/io`)
- **Author:** brainstorming session, approved by user

## 1. Problem

The Legal Document Anonymizer (LDA) imports PDFs through `LDAService.importDocument`
(`Sources/LDACore/Service/LDAService.swift`). Routing is binary:

```
PdfImporter().importDocument(url)        // extracts the text layer
guard imported.isScanned else { return imported }   // isScanned == empty text layer
return try PdfOCRImporter().importDocument(url)      // Vision OCR fallback
```

`isScanned` is all-or-nothing: OCR runs only when the **entire** text layer is empty.
A PDF that has a text layer (`isScanned == false`) never gets OCR'd, so any raster
image content on the page is invisible to both detection and visual redaction.

**Confirmed leak (2026-06-09).** A born-digital "executed agreement" PDF with a text
body and two cursive **signature images** ("Sarah Whitman", "Daniel Okafor") was run
through `anonymize`. The typed party names were detected and boxed in the review PDF,
but the signature graphics were left fully exposed. Most executed legal PDFs are this
hybrid (text body + image signature/stamp), so this is a common real-world leak.

The leak has two layers:

1. **Box-location gap (demonstrated):** A name like "Daniel Okafor" is detected from
   the typed text, but visual boxes are located by `PDFDocument.findString` on the
   text layer (`PdfImporter.redactionBoxes`), which cannot find the signature *image*
   of the same name. The image occurrence is never boxed.
2. **Detection gap (latent):** A name appearing only in a signature/stamp, never typed,
   is not in `imported.text` at all, so it is never detected anywhere.

The leak surface is the **review PDF only**. The `.txt` companion edit surface is built
from the text layer (`CompanionWriter.writeText(tokenized.tokenizedText, ...)`), which
contains no signature-image text, so the companion does not leak.

## 2. Goals

- Close the review-PDF leak for hybrid PDFs (text layer + embedded images).
- Catch PII that appears only in images (signatures, stamps), not just image duplicates
  of already-typed names.
- Preserve the existing fast text-layer path for pure-text PDFs.
- Do not disturb the text-layer offset model (`ImportedDocument.text` uses UTF-16
  offsets aligned to engine `Span`s).

## 3. Non-goals (YAGNI)

- **`detect` command stays text-layer-only.** `detect` returns `[Span]` whose offsets
  index into `imported.text`; image entities have no such offsets. Wiring them in would
  force the offset surgery this design explicitly avoids. Possible later extension; out
  of scope here.
- **No merge of image text into `imported.text`** and **no change to the `.txt`
  companion.** Image PII lives in a separate channel.
- **No in-place PDF editing.** Unchanged: PDFs are never edited in place; the review PDF
  is the original with opaque boxes painted over PII regions.

## 4. Approved decisions

1. **Scope of catching image PII:** Detect over image OCR (separate image channel). OCR
   embedded image regions, run the same detection over that recovered text, then box
   those regions in the review PDF AND record them as redact-only mapping entries. The
   text-layer offset model is untouched.
2. **Region strategy:** Gate on embedded images. Only run the image-OCR pass on pages
   that contain embedded raster image XObjects. On those pages, OCR and keep only
   observations the text layer does not already cover (image-origin text). Pure-text
   PDFs keep the fast path.
3. **Redaction policy:** Conservative. Box every image-origin text region regardless of
   whether detection fires. Strongest leak guarantee; works even with no LLM loaded. A
   logo/letterhead rendered as an image is covered too (acceptable, often a firm logo is
   COMPANY PII).

## 5. Architecture

New units are small, isolated, and independently testable. Names are provisional.

### 5.1 `PdfImageInventory` (new)

- **What it does:** Given a PDF URL, returns the zero-based page indices that contain at
  least one embedded raster image.
- **How:** Walks each page's `CGPDFPage` dictionary: `Resources -> XObject`, and for each
  XObject stream checks `Subtype == Image`. Pure inspection, no rendering.
- **Failure handling:** If the resource walk fails or is ambiguous on a page (malformed
  dictionary, unexpected structure), that page is reported as image-bearing so the caller
  conservatively OCRs it rather than risk missing a leak.
- **Depends on:** CoreGraphics (`CGPDFDocument`/`CGPDFPage`), PDFKit (to resolve the page).

### 5.2 `PdfOCRImporter.imageOriginObservations(in:pages:)` (new function on the existing type)

- **What it does:** For the given page indices, renders each page, runs the existing
  Vision OCR, and returns the observations that the text layer does NOT already cover,
  as `(pageIndex, rect, text)` triples in PDF/CoreGraphics page coordinates.
- **How:** Reuses the existing private `render(page:)` and `pageRect(fromNormalized:mediaBox:)`
  in `PdfOCRImporter.swift`. For each OCR observation, maps its normalized box to page
  coordinates, then checks `PDFPage.selection(for: rect)?.string`. If that selection text
  is empty/whitespace, the observation is image-origin and is kept; otherwise it is
  text-layer text already handled by `findString` and is dropped.
- **Dedup by text content, not geometry:** to decide whether the text layer already
  covers an observation, inset the observation rect by ~20%, read
  `PDFPage.selection(for: insetRect)?.string`, normalize both strings (trim, case-fold,
  collapse internal whitespace), and drop the observation ONLY if the selection text
  contains the observation's OCR text. Otherwise keep it. This biases toward keeping,
  which is correct given the asymmetry: wrongly dropping a signature observation is a
  leak, while wrongly keeping a text-layer observation is just one redundant box over
  already-boxed text. A purely geometric overlap threshold gets this backwards near
  boundaries (a signature rect grazing a neighboring caption would be dropped on overlap
  alone); content matching only drops when the text layer genuinely holds that text. The
  ~20% inset keeps a neighbor's sliver from poisoning the selection lookup.
- **Coordinate consistency:** image-origin rects are produced in the same mediaBox-relative,
  bottom-left space that `PdfRedactor.renderRedactedPDF` and the existing text-box path
  (`PDFSelection.bounds(for:)`) already assume, so the two box sources compose without a
  transform. The integration test (section 8) asserts an image box lands on the signature
  region, which is the concrete guard against any coordinate mismatch.
- **Depends on:** PDFKit, Vision, CoreGraphics (all already imported by this file).

### 5.3 `ImageRedactionResolver` (new)

- **What it does:** Turns image-origin observations into redaction boxes and any new
  mapping entries, applying the conservative policy and token rules (section 6).
- **Inputs:** the existing `Mapping` from the main tokenization, the image-origin
  observations, and a detection closure `(_ text: String) -> [Span]` (so the resolver is
  pure and testable without loading a model).
- **Outputs:** `[RedactionBox]` and `[MappingEntry]` (additions to merge into the mapping).
- **Depends on:** Domain types only (`Mapping`, `MappingEntry`, `Span`, `EntityType`,
  `RedactionBox`, `TokenGrammar`). No IO, no OCR.

### 5.4 `LDAService.anonymize` (wiring only)

After the existing tokenization and before rendering the review PDF, for `pdf && !isScanned`:

1. `pages = PdfImageInventory.pagesWithImages(input)`; if empty, behavior is unchanged.
2. `observations = PdfOCRImporter().imageOriginObservations(in: input, pages: pages)`.
3. Run detection over the concatenated observation text using the same seam already used
   for the main pass (`DeterministicEngine().detect` merged with `llmSpans(for:modelPath:)`).
4. `(imageBoxes, newEntries) = ImageRedactionResolver.resolve(mapping:, observations:, detect:)`.
5. Concatenate `imageBoxes` with the existing `findString` boxes before
   `PdfRedactor.renderRedactedPDF` ("union" here means appending the two lists; image and
   text boxes have different rects and are never equal, so no set-dedup is intended).
6. Merge `newEntries` into `tokenized.mapping` before `MappingStore.save`.

`entityCount`/`entities` in `AnonymizeResult` continue to mean exactly what they mean
today: text-layer spans with real UTF-16 offsets. They are NOT changed, because
`entities: [Span]` requires offsets that image entities do not have, and the LDAUI sidebar
renders from `entities`. Instead, `AnonymizeResult` gains one additive field
`imageRedactionCount: Int` (defaults to 0; nonzero only for PDFs with image-channel
redactions) so the image redactions are reported honestly without conflating them with
text PII or breaking the `entityCount == entities.count` invariant. This count feeds the
existing trust/completeness affordance and should match the number of image boxes painted.

## 6. Conservative boxing and token rules

Every kept image-origin observation produces exactly one box. Token assignment:

- **Reuse:** If detection over the image text yields an entity whose surface text matches
  one already in `Mapping` (the demonstrated case: signature "Daniel Okafor" duplicates the
  typed name), reuse that existing token (for example `{PERSON_1}`). No duplicate mapping
  entry is created. **Match key:** normalized surface text (trimmed, case-folded,
  internal whitespace collapsed) compared against each entry's `surfaceText` and its
  `aliases`. Exact byte equality is not required, because OCR rarely reproduces the typed
  surface character-for-character (case, punctuation, spacing). The plan must pin the exact
  normalization.
- **Mint:** If detection yields a new entity (a signature-only name), mint the next
  `{TYPE_N}` token and add a redact-only `MappingEntry` whose `value` and `surfaceText` are
  the OCR'd text. Recorded for audit; not restorable (see 7).
- **Generic fallback:** If detection fires on nothing (a stylized logo, OCR noise), still
  box the region with a generic `{REDACTED_N}` label and create NO mapping entry. The box
  alone closes the leak. `{REDACTED_N}` is only a `RedactionBox.token` display string; it
  is never a mapping key and never needs to be a valid `EntityType`.

**Token minting mechanism.** `Tokenizer.tokenize` builds its per-type counters fresh inside
one call, so there is no shared utility that mints against an existing `Mapping`. The
resolver derives the next index per type by scanning the existing `Mapping.entries` **keys**
(which are always canonical `{TYPE_N}` tokens) for that type and taking `max(N) + 1`. Only
entry keys are scanned, never values or surface texts, so a surface that happens to look
like a token cannot perturb numbering. This guarantees image tokens never collide with
text-layer tokens.

## 7. Error handling and edge cases

- **No model loaded:** Detection over image text is deterministic-only, so signature
  *names* (PERSON/COMPANY) will not classify, but conservative boxing still covers them
  with `{REDACTED_N}`. No leak in either mode. This is the central reason conservative
  boxing was chosen over precise.
- **Restore safety:** New entries are redact-only. Image tokens never appear in the `.txt`
  edit surface, so `Restorer`'s orphan guard never trips on them and restore simply never
  substitutes them. No change to the restore path.
- **Performance:** Pure-text PDFs run only the inventory walk (cheap, no render) and skip
  OCR entirely, preserving the fast path. OCR cost (~0.5 to 1s per page) is paid only on
  image-bearing pages.
- **OCR unavailable / page render failure:** The image pass fails soft. If OCR throws or a
  page cannot render, the image pass for that page is skipped and the main text-layer
  anonymization still completes (consistent with the existing graceful-degradation
  posture of `llmSpans`). It must not fail the whole `anonymize` operation.
- **Scanned PDFs (`isScanned == true`) are unaffected:** they already OCR the whole page;
  this design only adds a branch for the non-scanned case.

## 8. Testing strategy

Mirror the hermetic, fail-loud, tolerance-based style of `PdfOCRImporterTests` (synthesize
fixtures in the temporary directory; never assert exact OCR equality; fail loudly if Vision
returns nothing).

- **`ImageRedactionResolver` (pure unit, no OCR):** feed synthetic observations plus a stub
  detector. Assert: (a) token reuse when the surface already exists in the mapping, (b)
  new-entry minting with continued numbering for a signature-only entity, (c) generic
  `{REDACTED_N}` box and no mapping entry when detection returns nothing.
- **`imageOriginObservations` (unit):** build a programmatic PDF that has a real text layer
  (drawn with `CTLineDraw` into a `CGPDFContext`) plus an image-only word (drawn with
  `context.draw(image:)`). Assert the image-only word is returned and the text-layer words
  are filtered out.
- **`PdfImageInventory` (unit):** assert a text-only PDF reports no image pages and a PDF
  with an embedded image reports the right page index.
- **Integration (`LDAService.anonymize`):** the demonstrated case. Typed body plus a
  signature image whose name appears nowhere in the typed text. Assert a redaction box
  lands in the signature region and, with a detector available, the signature name is
  covered. Assert a pure-text PDF produces byte-identical output to the pre-change behavior
  (no regression, no spurious boxes).

## 9. Open items for the plan

- Final unit names and file placement under `Sources/LDACore/IO/`.
- The exact normalization function shared by the dedup content-match (5.2) and the
  token-reuse match key (6), so they stay consistent.
