# PDF Image-Signature Redaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the confirmed PII leak where image-rendered content (signatures, stamps) on a PDF that has a text layer is never OCR'd, by adding an image-PII channel to `LDAService.anonymize` that OCRs embedded-image regions, conservatively redacts them in the review PDF, and records classified PII in the mapping.

**Architecture:** A gated, separate image channel that never touches the text-layer offset model. For a non-scanned PDF, detect pages with embedded image XObjects (gate), OCR those pages, keep only observations the text layer does not already cover (dedup), run the existing detection seam once over that text, then produce redaction boxes (conservative: box every image-origin observation) plus redact-only mapping entries for classified PII. Boxes are concatenated with the existing `findString` boxes; new entries are merged into the mapping.

**Tech Stack:** Swift, PDFKit, Vision, CoreGraphics (CGPDF), XCTest. Package is `macos/LDACore` (Swift Package), branch `feat/io`.

**Spec:** `docs/superpowers/specs/2026-06-09-pdf-image-signature-redaction-design.md`

**Working directory:** `~/Developer/lda-worktrees/io/macos/LDACore` (run all `swift` commands here). Commit with `git -c commit.gpgsign=false ...` (1Password agent workaround).

---

## File Structure

**Create:**
- `Sources/LDACore/Domain/TextMatching.swift` — shared normalization + significant-word overlap used by both the dedup and the token-reuse match. One responsibility: text comparison primitives.
- `Sources/LDACore/IO/PdfImageInventory.swift` — the gate. Reports which pages contain embedded raster image XObjects. CGPDF inspection only.
- `Sources/LDACore/IO/ImageRedactionResolver.swift` — the policy core. Turns image-origin observations into redaction boxes and redact-only mapping entries (reuse / mint / generic). Pure; no IO, no OCR.
- `Tests/LDACoreTests/TextMatchingTests.swift`
- `Tests/LDACoreTests/PdfImageInventoryTests.swift`
- `Tests/LDACoreTests/ImageRedactionResolverTests.swift`

**Modify:**
- `Sources/LDACore/IO/IOTypes.swift` — add the `ImageTextObservation` value type.
- `Sources/LDACore/IO/PdfOCRImporter.swift` — add `imageOriginObservations(in:pages:)`.
- `Sources/LDACore/Service/LDAService.swift` — load the LLM engine once and expose a `detectAll` closure; add `imageRedactionCount` to `AnonymizeResult`; wire the image pass into the pdf branch of `anonymize`.
- `Sources/LDACLI/CLI.swift` — add `imageRedactionCount` to `AnonymizeSummaryJSON`.
- `Tests/LDACoreTests/PdfOCRImporterTests.swift` — add image-origin observation tests (or a sibling file `PdfOCRImporterImageOriginTests.swift`).
- `Tests/LDACoreTests/LDAServiceTests.swift` — add the hybrid (text + image signature) integration test.

**Baseline check before starting:**

Run: `swift build` then `swift test 2>&1 | tail -5`
Expected: build succeeds; all existing tests pass (the suite is ~213 tests green per project memory). Record the count; every task below must keep it green.

---

## Task 1: TextMatching primitives

**Files:**
- Create: `Sources/LDACore/Domain/TextMatching.swift`
- Test: `Tests/LDACoreTests/TextMatchingTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LDACoreTests/TextMatchingTests.swift
import XCTest
@testable import LDACore

final class TextMatchingTests: XCTestCase {
    func testNormalizeCollapsesCaseAndWhitespace() {
        XCTAssertEqual(TextMatching.normalize("  Daniel   OKAFOR \n"), "daniel okafor")
    }

    func testSignificantWordsKeepsOnlyFourPlusAlnum() {
        XCTAssertEqual(
            TextMatching.significantWords("By: Sarah Whitman, CEO"),
            ["sarah", "whitman"]
        )
    }

    func testSharesSignificantWordTrueOnCommonWord() {
        XCTAssertTrue(
            TextMatching.sharesSignificantWord("CONSULTING SERVICES AGREEMENT",
                                               "lting services agr")
        )
    }

    func testSharesSignificantWordFalseWhenDisjoint() {
        XCTAssertFalse(
            TextMatching.sharesSignificantWord("Sarah Whitman", "")
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TextMatchingTests 2>&1 | tail -15`
Expected: FAIL to build with "cannot find 'TextMatching' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/LDACore/Domain/TextMatching.swift
//
//  TextMatching.swift
//  LDACore
//
//  Shared text-comparison primitives used by the image-PII channel: the dedup
//  that separates image-origin OCR text from text-layer text, and the token-reuse
//  match that ties a re-detected surface back to an existing mapping token.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation

/// Pure text-comparison helpers. No IO, no clock.
public enum TextMatching {
    /// Lowercased, trimmed, internal whitespace collapsed to single spaces.
    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The set of "significant" words: alphanumeric-only, length >= 4, case-folded.
    /// Short words and punctuation are dropped so the overlap test is not fooled by
    /// stopwords, OCR-truncated word ends, or stray symbols.
    public static func significantWords(_ s: String) -> Set<String> {
        var words: Set<String> = []
        for raw in normalize(s).components(separatedBy: " ") {
            let alnum = String(raw.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            if alnum.count >= 4 { words.insert(alnum) }
        }
        return words
    }

    /// True when the two strings share at least one significant word.
    public static func sharesSignificantWord(_ a: String, _ b: String) -> Bool {
        !significantWords(a).isDisjoint(with: significantWords(b))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TextMatchingTests 2>&1 | tail -15`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=false add Sources/LDACore/Domain/TextMatching.swift Tests/LDACoreTests/TextMatchingTests.swift
git -c commit.gpgsign=false commit -m "feat: TextMatching primitives for image-PII dedup and token reuse"
```

---

## Task 2: PdfImageInventory (the gate)

The CGPDF XObject walk below is verified working against the real fixtures
(`docA` text-only -> no image pages; `docB` -> page 0; `docC` scanned -> all pages;
encrypted PDFs with an empty user password open fine via `CGPDFDocument`).

**Files:**
- Create: `Sources/LDACore/IO/PdfImageInventory.swift`
- Test: `Tests/LDACoreTests/PdfImageInventoryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LDACoreTests/PdfImageInventoryTests.swift
import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import LDACore

final class PdfImageInventoryTests: XCTestCase {
    private var created: [URL] = []
    override func tearDownWithError() throws {
        for u in created { try? FileManager.default.removeItem(at: u) }
        created.removeAll()
    }

    func testTextOnlyPdfHasNoImagePages() throws {
        let url = try makePdf(drawImage: false)
        XCTAssertEqual(PdfImageInventory.pagesWithImages(url), [])
    }

    func testImageBearingPdfReportsThePage() throws {
        let url = try makePdf(drawImage: true)
        XCTAssertEqual(PdfImageInventory.pagesWithImages(url), [0])
    }

    /// One-page PDF with a real text layer (CTLineDraw) and, optionally, an
    /// embedded raster image XObject (context.draw(image:)).
    private func makePdf(drawImage: Bool) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv-\(UUID().uuidString).pdf")
        created.append(url)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("no PDF context")
        }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attr = NSAttributedString(string: "TYPED TEXT LAYER",
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        if drawImage, let img = Self.solidImage() {
            ctx.draw(img, in: CGRect(x: 72, y: 400, width: 200, height: 80))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func solidImage() -> CGImage? {
        guard let c = CGContext(data: nil, width: 200, height: 80, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
        return c.makeImage()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PdfImageInventoryTests 2>&1 | tail -15`
Expected: FAIL with "cannot find 'PdfImageInventory' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/LDACore/IO/PdfImageInventory.swift
//
//  PdfImageInventory.swift
//  LDACore
//
//  The gate for the image-PII channel: reports which pages of a PDF contain at
//  least one embedded raster image XObject. Pure CGPDF inspection, no rendering,
//  so pure-text PDFs pay almost nothing and keep the fast text-layer path.
//
//  Conservative on uncertainty: if a page's resource structure cannot be walked,
//  the page is reported as image-bearing so the caller OCRs it rather than risk
//  missing image PII.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation
import CoreGraphics

/// Reports pages that contain embedded raster image XObjects.
public enum PdfImageInventory {
    /// Zero-based indices of pages that contain at least one image XObject.
    public static func pagesWithImages(_ url: URL) -> [Int] {
        guard let doc = CGPDFDocument(url as CFURL) else { return [] }
        let total = doc.numberOfPages
        guard total > 0 else { return [] }
        var pages: [Int] = []
        for i in 1...total {  // CGPDF pages are 1-based
            guard let page = doc.page(at: i) else {
                pages.append(i - 1)  // unreadable page: be conservative
                continue
            }
            guard let dict = page.dictionary else {
                pages.append(i - 1)
                continue
            }
            if pageHasImage(dict) { pages.append(i - 1) }
        }
        return pages
    }

    private static func pageHasImage(_ pageDict: CGPDFDictionaryRef) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources),
              let resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects else { return false }

        var found = false
        withUnsafeMutablePointer(to: &found) { foundPtr in
            CGPDFDictionaryApplyFunction(xobjects, { (_, object, info) in
                let foundPtr = info!.assumingMemoryBound(to: Bool.self)
                if foundPtr.pointee { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let streamDict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype {
                    if String(cString: subtype) == "Image" { foundPtr.pointee = true }
                }
            }, foundPtr)
        }
        return found
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PdfImageInventoryTests 2>&1 | tail -15`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=false add Sources/LDACore/IO/PdfImageInventory.swift Tests/LDACoreTests/PdfImageInventoryTests.swift
git -c commit.gpgsign=false commit -m "feat: PdfImageInventory gates the image-PII pass on embedded image XObjects"
```

---

## Task 3: ImageTextObservation + imageOriginObservations

The dedup logic (vertical-only inset + significant-word overlap) is verified
against `docB`: every body-text line drops, the signature band returns an empty
selection and is kept.

**Files:**
- Modify: `Sources/LDACore/IO/IOTypes.swift` (add the type)
- Modify: `Sources/LDACore/IO/PdfOCRImporter.swift` (add the function)
- Test: `Tests/LDACoreTests/PdfOCRImporterImageOriginTests.swift`

- [ ] **Step 1: Add the value type to IOTypes.swift**

Insert after the `RedactionBox` definition (around line 102) in `Sources/LDACore/IO/IOTypes.swift`:

```swift
// MARK: - Image-origin observation

/// A piece of text recovered by OCR from an embedded image region (not the text
/// layer). rect is in PDF/CoreGraphics page coordinates; pageIndex is zero-based.
public struct ImageTextObservation: Sendable, Equatable {
    public var pageIndex: Int
    public var rect: CGRect
    public var text: String

    public init(pageIndex: Int, rect: CGRect, text: String) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.text = text
    }
}
```

- [ ] **Step 2: Write the failing test**

```swift
// Tests/LDACoreTests/PdfOCRImporterImageOriginTests.swift
import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import LDACore

final class PdfOCRImporterImageOriginTests: XCTestCase {
    private var created: [URL] = []
    override func tearDownWithError() throws {
        for u in created { try? FileManager.default.removeItem(at: u) }
        created.removeAll()
    }

    /// A PDF with a real text layer ("TYPED CONTRACT BODY") plus an image-only word
    /// ("ZZSIGNATUREZZ"). The image-origin pass must return the image word and must
    /// NOT return the typed words.
    func testReturnsImageWordAndFiltersTextLayer() throws {
        let url = try makeHybridPdf(typed: "TYPED CONTRACT BODY",
                                    imageWord: "ZZSIGNATUREZZ")
        let pages = PdfImageInventory.pagesWithImages(url)
        XCTAssertEqual(pages, [0], "fixture must have an image page")

        let obs = PdfOCRImporter().imageOriginObservations(in: url, pages: pages)

        let joined = obs.map { $0.text }.joined(separator: " ").lowercased()
        XCTAssertFalse(obs.isEmpty,
            "OCR returned no image-origin observations; Vision may be unavailable here.")
        XCTAssertTrue(joined.contains("signature"),
            "image-only word was not recovered. Observations: \(joined)")
        XCTAssertFalse(joined.contains("typed"),
            "text-layer word leaked into image-origin observations: \(joined)")
        for o in obs {
            XCTAssertEqual(o.pageIndex, 0)
            XCTAssertGreaterThan(o.rect.width, 0)
            XCTAssertGreaterThan(o.rect.height, 0)
        }
    }

    private func makeHybridPdf(typed: String, imageWord: String) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-\(UUID().uuidString).pdf")
        created.append(url)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("no PDF context")
        }
        ctx.beginPDFPage(nil)
        // Text layer near the top.
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
        let attr = NSAttributedString(string: typed,
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        // Image-only word lower down, well clear of the text line.
        if let img = Self.wordImage(imageWord) {
            ctx.draw(img, in: CGRect(x: 72, y: 300, width: 360, height: 90))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func wordImage(_ word: String) -> CGImage? {
        let w = 720, h = 180
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attr = NSAttributedString(string: word,
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        c.textPosition = CGPoint(x: 20, y: 50)
        CTLineDraw(CTLineCreateWithAttributedString(attr), c)
        return c.makeImage()
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PdfOCRImporterImageOriginTests 2>&1 | tail -15`
Expected: FAIL with "value of type 'PdfOCRImporter' has no member 'imageOriginObservations'".

- [ ] **Step 4: Write minimal implementation**

Add to `Sources/LDACore/IO/PdfOCRImporter.swift` inside `public struct PdfOCRImporter` (it already has the private `render(page:)`, `recognize(in:)`, and `pageRect(fromNormalized:mediaBox:)` helpers this reuses):

```swift
    // MARK: - Image-origin observations (hybrid text + image PDFs)

    /// Default vertical inset (fraction of rect height) trimmed off the top and
    /// bottom before the text-layer lookup, so the lookup does not bleed into the
    /// line above or below. Width is barely trimmed so the full line text is read.
    private static let dedupVerticalInset: CGFloat = 0.30
    private static let dedupHorizontalInset: CGFloat = 0.05

    /// OCR the given pages and return only the observations the text layer does NOT
    /// already cover, in PDF page coordinates. Used by the image-PII channel for
    /// PDFs that have a text layer but also embed raster images (signatures, stamps).
    ///
    /// Text-layer coverage is decided per observation: inset the observation rect
    /// vertically, read PDFPage.selection(for:)?.string at that rect, and treat the
    /// observation as text-layer (skip) when that selection is non-empty AND shares
    /// a significant word with the OCR text. Otherwise it is image-origin and kept.
    public func imageOriginObservations(in url: URL, pages: [Int]) -> [ImageTextObservation] {
        guard !pages.isEmpty, let document = PDFDocument(url: url) else { return [] }
        var result: [ImageTextObservation] = []

        for pageIndex in pages {
            guard pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex),
                  let image = try? Self.render(page: page),
                  let observations = try? Self.recognize(in: image) else { continue }

            let mediaBox = page.bounds(for: .mediaBox)
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let rect = Self.pageRect(fromNormalized: observation.boundingBox, mediaBox: mediaBox)
                if Self.textLayerCovers(text: text, rect: rect, page: page) { continue }
                result.append(ImageTextObservation(pageIndex: pageIndex, rect: rect, text: text))
            }
        }
        return result
    }

    /// True when the page's text layer already holds this observation's text.
    private static func textLayerCovers(text: String, rect: CGRect, page: PDFPage) -> Bool {
        let inset = rect.insetBy(dx: rect.width * dedupHorizontalInset,
                                 dy: rect.height * dedupVerticalInset)
        let lookup = inset.isNull || inset.isEmpty ? rect : inset
        guard let selection = page.selection(for: lookup)?.string,
              !TextMatching.normalize(selection).isEmpty else { return false }
        return TextMatching.sharesSignificantWord(text, selection)
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PdfOCRImporterImageOriginTests 2>&1 | tail -15`
Expected: PASS (1 test). If Vision is unavailable in the runner it fails loudly (by design), not silently.

- [ ] **Step 6: Commit**

```bash
git -c commit.gpgsign=false add Sources/LDACore/IO/IOTypes.swift Sources/LDACore/IO/PdfOCRImporter.swift Tests/LDACoreTests/PdfOCRImporterImageOriginTests.swift
git -c commit.gpgsign=false commit -m "feat: imageOriginObservations recovers image text and filters the text layer"
```

---

## Task 4: ImageRedactionResolver (boxes + entries)

Pure unit: no OCR, no IO. Detection is an injected closure so production passes the
real deterministic+LLM seam and tests pass a stub.

**Files:**
- Create: `Sources/LDACore/IO/ImageRedactionResolver.swift`
- Test: `Tests/LDACoreTests/ImageRedactionResolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/LDACoreTests/ImageRedactionResolverTests.swift
import XCTest
import CoreGraphics
@testable import LDACore

final class ImageRedactionResolverTests: XCTestCase {
    private func obs(_ text: String, _ x: CGFloat = 0) -> ImageTextObservation {
        ImageTextObservation(pageIndex: 0, rect: CGRect(x: x, y: 0, width: 10, height: 10), text: text)
    }

    private func mapping(_ entries: [MappingEntry]) -> Mapping {
        var byToken: [String: MappingEntry] = [:]
        for e in entries { byToken[e.token] = e }
        return Mapping(entries: byToken, createdAtISO8601: "2026-06-09T00:00:00Z", sourceFile: "x.pdf")
    }

    private func person(_ token: String, _ value: String) -> MappingEntry {
        MappingEntry(token: token, value: value, type: .person, surfaceText: value, aliases: [])
    }

    /// Detection finds a PERSON whose surface already exists in the mapping: reuse
    /// the existing token, mint NO new entry.
    func testReusesExistingTokenForKnownSurface() {
        let m = mapping([person("{PERSON_1}", "Daniel Okafor")])
        let detect: (String) -> [Span] = { text in
            [Span(start: 0, end: (text as NSString).length, type: .person,
                  text: "Daniel Okafor", source: .llm, confidence: 0.9, priority: 5)]
        }
        let r = ImageRedactionResolver.resolve(mapping: m, observations: [obs("Daniel Okafor")], detect: detect)
        XCTAssertEqual(r.boxes.map { $0.token }, ["{PERSON_1}"])
        XCTAssertTrue(r.newEntries.isEmpty)
        XCTAssertEqual(r.imageRedactionCount, 1)
    }

    /// Detection finds a NEW person: mint the next per-type token and a redact-only entry.
    func testMintsNewTokenContinuingNumbering() {
        let m = mapping([person("{PERSON_1}", "Jane Mitchell")])
        let detect: (String) -> [Span] = { text in
            [Span(start: 0, end: (text as NSString).length, type: .person,
                  text: "Sarah Whitman", source: .llm, confidence: 0.9, priority: 5)]
        }
        let r = ImageRedactionResolver.resolve(mapping: m, observations: [obs("Sarah Whitman")], detect: detect)
        XCTAssertEqual(r.boxes.map { $0.token }, ["{PERSON_2}"])
        XCTAssertEqual(r.newEntries.count, 1)
        XCTAssertEqual(r.newEntries.first?.token, "{PERSON_2}")
        XCTAssertEqual(r.newEntries.first?.surfaceText, "Sarah Whitman")
        XCTAssertEqual(r.newEntries.first?.type, .person)
    }

    /// Detection finds nothing: conservatively box with a generic token, no entry.
    func testGenericBoxWhenNoDetection() {
        let m = mapping([])
        let detect: (String) -> [Span] = { _ in [] }
        let r = ImageRedactionResolver.resolve(mapping: m, observations: [obs("garbled sig"), obs("more", 20)],
                                               detect: detect)
        XCTAssertEqual(r.boxes.map { $0.token }, ["{REDACTED_1}", "{REDACTED_2}"])
        XCTAssertTrue(r.newEntries.isEmpty)
        XCTAssertEqual(r.imageRedactionCount, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ImageRedactionResolverTests 2>&1 | tail -15`
Expected: FAIL with "cannot find 'ImageRedactionResolver' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/LDACore/IO/ImageRedactionResolver.swift
//
//  ImageRedactionResolver.swift
//  LDACore
//
//  Policy core of the image-PII channel. Turns image-origin OCR observations into
//  redaction boxes (conservative: one box per observation) plus redact-only mapping
//  entries for the observations that detection classifies as PII.
//
//  Token rules (see the spec): reuse an existing token when the detected surface is
//  already in the mapping (matched on normalized surface text and aliases); mint the
//  next {TYPE_N}, continuing the mapping's per-type numbering, for a new entity; use
//  a generic {REDACTED_N} label with no mapping entry when detection finds nothing.
//
//  Pure: no IO, no OCR, no clock. Detection is injected so it is testable and so the
//  caller can load the LLM engine once and reuse it.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation
import CoreGraphics

public enum ImageRedactionResolver {
    public struct Result: Sendable, Equatable {
        public var boxes: [RedactionBox]
        public var newEntries: [MappingEntry]
        public var imageRedactionCount: Int
    }

    /// Resolve observations into boxes and redact-only entries.
    ///
    /// - Parameters:
    ///   - mapping: the mapping from the text-layer tokenization (read-only here).
    ///   - observations: image-origin OCR observations, in document order.
    ///   - detect: detection over arbitrary text (deterministic + optional LLM).
    public static func resolve(
        mapping: Mapping,
        observations: [ImageTextObservation],
        detect: (String) -> [Span]
    ) -> Result {
        guard !observations.isEmpty else {
            return Result(boxes: [], newEntries: [], imageRedactionCount: 0)
        }

        // Build one combined text so detection runs once. Track each observation's
        // UTF-16 range so detected spans can be attributed back to an observation.
        var combined = ""
        var ranges: [Range<Int>] = []
        for (i, obs) in observations.enumerated() {
            let start = combined.utf16.count
            combined += obs.text
            ranges.append(start..<combined.utf16.count)
            if i < observations.count - 1 { combined += "\n" }
        }
        let spans = detect(combined)

        // Reuse index: normalized surface (and aliases) -> existing token.
        var tokenByNormSurface: [String: String] = [:]
        for entry in mapping.entries.values {
            tokenByNormSurface[TextMatching.normalize(entry.surfaceText)] = entry.token
            for alias in entry.aliases {
                tokenByNormSurface[TextMatching.normalize(alias)] = entry.token
            }
        }

        // Per-type counters seeded from the existing mapping token keys.
        var counters = perTypeMaxIndices(in: mapping.entries.keys)

        var boxes: [RedactionBox] = []
        var newEntries: [MappingEntry] = []

        for (i, obs) in observations.enumerated() {
            let range = ranges[i]
            // The dominant span fully inside this observation's range, longest first.
            let dominant = spans
                .filter { $0.start >= range.lowerBound && $0.end <= range.upperBound }
                .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })

            let token: String
            if let span = dominant {
                let norm = TextMatching.normalize(span.text)
                if let existing = tokenByNormSurface[norm] {
                    token = existing  // reuse, no new entry
                } else {
                    let typeToken = TokenGrammar.sanitizeType(span.type.rawValue)
                    let n = (counters[typeToken] ?? 0) + 1
                    counters[typeToken] = n
                    token = "{\(typeToken)_\(n)}"
                    tokenByNormSurface[norm] = token
                    newEntries.append(MappingEntry(token: token, value: span.text,
                                                   type: span.type, surfaceText: span.text, aliases: []))
                }
            } else {
                let n = (counters["REDACTED"] ?? 0) + 1
                counters["REDACTED"] = n
                token = "{REDACTED_\(n)}"  // generic label, no mapping entry
            }
            boxes.append(RedactionBox(pageIndex: obs.pageIndex, rect: obs.rect, token: token))
        }

        return Result(boxes: boxes, newEntries: newEntries, imageRedactionCount: boxes.count)
    }

    /// Max N per TYPE across canonical "{TYPE_N}" mapping keys. Scans keys only, so a
    /// surface text that happens to look like a token cannot perturb numbering.
    private static func perTypeMaxIndices<S: Sequence>(in keys: S) -> [String: Int]
    where S.Element == String {
        var maxima: [String: Int] = [:]
        for key in keys {
            guard key.hasPrefix("{"), key.hasSuffix("}") else { continue }
            let inner = key.dropFirst().dropLast()  // e.g. PERSON_1
            guard let underscore = inner.lastIndex(of: "_") else { continue }
            let type = String(inner[..<underscore])
            guard let n = Int(inner[inner.index(after: underscore)...]) else { continue }
            maxima[type] = max(maxima[type] ?? 0, n)
        }
        return maxima
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ImageRedactionResolverTests 2>&1 | tail -15`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=false add Sources/LDACore/IO/ImageRedactionResolver.swift Tests/LDACoreTests/ImageRedactionResolverTests.swift
git -c commit.gpgsign=false commit -m "feat: ImageRedactionResolver assigns boxes and redact-only entries"
```

---

## Task 5: Load the LLM engine once + add imageRedactionCount field

Avoids loading the 2.7 GB GGUF twice (main pass + image pass). Keep all existing
LDAService tests green.

**Files:**
- Modify: `Sources/LDACore/Service/LDAService.swift`
- Modify: `Sources/LDACLI/CLI.swift`

- [ ] **Step 1: Add `imageRedactionCount` to `AnonymizeResult`**

In `Sources/LDACore/Service/LDAService.swift`, add a stored property (default 0) to `AnonymizeResult` and its initializer:

```swift
    /// How many image-origin regions were redacted (signatures, stamps). 0 unless
    /// the input was a PDF with an image-PII channel pass.
    public var imageRedactionCount: Int
```

Add `imageRedactionCount: Int = 0` as the final initializer parameter and `self.imageRedactionCount = imageRedactionCount` in the body. (The default keeps every existing construction call valid.)

- [ ] **Step 2: Run the existing suite to confirm nothing broke**

Run: `swift test 2>&1 | tail -5`
Expected: same green count as baseline (the new field has a default).

- [ ] **Step 3: Refactor detection to load the engine once**

Replace the private `llmSpans(for:modelPath:)` usage with a once-loaded engine. Add:

```swift
    /// Build a detection closure that loads the LLM engine at most once and reuses
    /// it for every call (main text pass and image-PII pass). When modelPath is nil
    /// or the model fails to load, detection is deterministic-only and never throws.
    private static func makeDetector(modelPath: String?) -> (String) -> [Span] {
        let extractor: LLMExtractor? = {
            guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else { return nil }
            guard let engine = try? LLMEngine(config: .init(modelPath: modelPath)) else { return nil }
            return LLMExtractor(completer: engine)
        }()
        return { text in
            let llm = (try? extractor?.extract(from: text)) ?? [] ?? []
            return SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
        }
    }
```

Note: `(try? extractor?.extract(...)) ?? [] ?? []` flattens `LLMExtractor?` + throwing into `[Span]`. If the optional-chaining double-`??` reads awkwardly in review, expand it to an explicit `if let extractor` block returning `[]` on any failure (behavior identical to the current graceful fallback).

Then in `anonymize` and `detect`, replace the inline `SpanMerger.merge(deterministic:llm: llmSpans(...))` with a single detector:

```swift
        let detect = makeDetector(modelPath: llmModelPath)
        let spans = detect(imported.text)
```

Keep the old `llmSpans` private function only if something else uses it; otherwise delete it (grep first: `grep -n llmSpans Sources/LDACore/Service/LDAService.swift`).

- [ ] **Step 4: Run the LLM + service tests**

Run: `swift test --filter LDAService 2>&1 | tail -10`
Expected: `LDAServiceTests` and `LDAServiceLLMTests` pass unchanged.

- [ ] **Step 5: Add the field to the CLI summary**

In `Sources/LDACLI/CLI.swift`, extend `AnonymizeSummaryJSON`:

```swift
    public let imageRedactionCount: Int
```
and in its `init(result:)`: `self.imageRedactionCount = result.imageRedactionCount`.

Then grep for any MCP-side summary that mirrors this and add the same field:
Run: `grep -rn "entityCount" Sources/LDAMCP Sources/LDACLI`
If the MCP server builds its own anonymize summary, add `imageRedactionCount` there too.

- [ ] **Step 6: Run CLI + MCP tests**

Run: `swift test --filter "CLITests|MCPTests" 2>&1 | tail -10`
Expected: PASS (update any summary-shape assertion to include the new field if one exists).

- [ ] **Step 7: Commit**

```bash
git -c commit.gpgsign=false add Sources/LDACore/Service/LDAService.swift Sources/LDACLI/CLI.swift
git -c commit.gpgsign=false commit -m "refactor: load LLM engine once; add imageRedactionCount to anonymize result"
```

---

## Task 6: Wire the image-PII pass into anonymize

**Files:**
- Modify: `Sources/LDACore/Service/LDAService.swift` (the `case "pdf":` branch)

- [ ] **Step 1: Implement the wiring**

In `anonymize`, in the `case "pdf":` branch, after the existing `boxes` are built from
`findString`/`ocrBoxes`, add the image-PII pass (only for non-scanned PDFs). Replace:

```swift
            let pairs = surfaceTokenPairs(mapping: tokenized.mapping)
            let boxes: [RedactionBox] = imported.isScanned
                ? PdfOCRImporter.ocrBoxes(in: input, matching: pairs)
                : PdfImporter.redactionBoxes(in: input, surfaceTexts: pairs)

            let reviewURL = outputDir.appendingPathComponent("\(baseName)_review.pdf")
            try PdfRedactor.renderRedactedPDF(original: input, boxes: boxes, to: reviewURL)
            visualPdfURL = reviewURL
```

with:

```swift
            let pairs = surfaceTokenPairs(mapping: tokenized.mapping)
            var boxes: [RedactionBox] = imported.isScanned
                ? PdfOCRImporter.ocrBoxes(in: input, matching: pairs)
                : PdfImporter.redactionBoxes(in: input, surfaceTexts: pairs)

            // Image-PII channel: a non-scanned PDF can still embed raster images
            // (signatures, stamps) the text layer cannot see. OCR those regions,
            // conservatively box them, and record classified PII in the mapping.
            if !imported.isScanned {
                let imagePages = PdfImageInventory.pagesWithImages(input)
                if !imagePages.isEmpty {
                    let observations = PdfOCRImporter().imageOriginObservations(in: input, pages: imagePages)
                    let resolved = ImageRedactionResolver.resolve(
                        mapping: tokenized.mapping,
                        observations: observations,
                        detect: detect
                    )
                    boxes += resolved.boxes
                    for entry in resolved.newEntries {
                        tokenized.mapping.entries[entry.token] = entry
                    }
                    imageRedactionCount = resolved.imageRedactionCount
                }
            }

            let reviewURL = outputDir.appendingPathComponent("\(baseName)_review.pdf")
            try PdfRedactor.renderRedactedPDF(original: input, boxes: boxes, to: reviewURL)
            visualPdfURL = reviewURL
```

Two supporting changes in `anonymize`:
- `tokenized` must be mutable: change `let tokenized = Tokenizer.tokenize(...)` to `var tokenized = ...` (so `tokenized.mapping.entries` can take new entries). `Mapping.entries` is a `var` already.
- Declare `var imageRedactionCount = 0` next to `var visualPdfURL: URL?`, and pass it into the returned `AnonymizeResult(... imageRedactionCount: imageRedactionCount)`.

`detect` is the closure from Task 5 (`let detect = makeDetector(modelPath: llmModelPath)`), already in scope.

- [ ] **Step 2: Build and run the whole suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -8`
Expected: builds; all prior tests still green (this task adds no test yet, only wiring; the integration test is Task 7).

- [ ] **Step 3: Commit**

```bash
git -c commit.gpgsign=false add Sources/LDACore/Service/LDAService.swift
git -c commit.gpgsign=false commit -m "feat: wire image-PII channel into anonymize for hybrid PDFs"
```

---

## Task 7: Integration test (hybrid text + image signature)

**Files:**
- Modify: `Tests/LDACoreTests/LDAServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `LDAServiceTests` (deterministic-only, no model: the conservative policy must
still box the signature). The fixture has a typed body plus an image-only signature
word that appears nowhere in the text layer, so any box over it proves the image
channel ran. Assert (a) `imageRedactionCount >= 1`, (b) a review-PDF box exists in the
lower signature band, and (c) a pure-text PDF yields `imageRedactionCount == 0`.

```swift
    func testAnonymizeBoxesImageOnlySignatureOnHybridPdf() throws {
        let pdf = try makeHybridSignaturePdf()  // helper below
        let result = try LDAService.anonymize(
            input: pdf, outputDir: workDir, protection: .none,
            createdAtISO8601: Self.createdAt, llmModelPath: nil)

        XCTAssertGreaterThanOrEqual(result.imageRedactionCount, 1,
            "image-only signature was not redacted")
        XCTAssertNotNil(result.visualPdfURL)
        // The review PDF must exist and be openable.
        let review = try XCTUnwrap(result.visualPdfURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.path))
    }

    func testAnonymizeTextOnlyPdfHasNoImageRedactions() throws {
        let pdf = try makeTextOnlyPdf()  // helper below
        let result = try LDAService.anonymize(
            input: pdf, outputDir: workDir, protection: .none,
            createdAtISO8601: Self.createdAt, llmModelPath: nil)
        XCTAssertEqual(result.imageRedactionCount, 0)
    }
```

Add fixture helpers to the test file (reuse the CGPDF + CTLineDraw + image technique
from `PdfOCRImporterImageOriginTests`; the signature image word should be a unique
string like `"ZZSIGNZZ"` that does not occur in the typed body).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "LDAServiceTests/testAnonymizeBoxesImageOnlySignatureOnHybridPdf" 2>&1 | tail -15`
Expected: FAIL only if wiring is wrong; if Tasks 1-6 are correct it should already pass. If it fails because Vision is unavailable, it fails loudly (acceptable, documents the environment requirement).

- [ ] **Step 3: Run the full suite**

Run: `swift test 2>&1 | tail -8`
Expected: all green, count = baseline + new tests.

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=false add Tests/LDACoreTests/LDAServiceTests.swift
git -c commit.gpgsign=false commit -m "test: hybrid PDF integration proves image-signature is redacted"
```

---

## Task 8: Manual verification against the real demonstrated leak

**Files:** none (verification only)

- [ ] **Step 1: Build the CLI**

Run: `swift build 2>&1 | tail -3`

- [ ] **Step 2: Re-run anonymize on the original leak fixture**

Run:
```bash
.build/debug/lda anonymize \
  --input ~/Developer/lda-ocr-test/docB_secured.pdf \
  --output-dir ~/Developer/lda-ocr-test/outB_fixed \
  --model ~/Developer/lda-models/lda-v2-Q4_K_M.gguf
```
Expected JSON includes `"imageRedactionCount"` >= 1.

- [ ] **Step 3: Render the fixed review PDF page 1 and eyeball the signatures**

Run:
```bash
pdftoppm -r 120 -png -f 1 -l 1 ~/Developer/lda-ocr-test/outB_fixed/docB_secured_review.pdf ~/Developer/lda-ocr-test/revB_fixed
```
Open `~/Developer/lda-ocr-test/revB_fixed-1.png`. Expected: the two cursive signatures
("Sarah Whitman", "Daniel Okafor") are now covered by opaque boxes, and the body text is
NOT over-redacted (only detected PII + the signature band are boxed).

- [ ] **Step 4: Confirm the fast path is intact for a text-only PDF**

Run:
```bash
time .build/debug/lda anonymize --input ~/Developer/lda-ocr-test/docA_born_digital.pdf \
  --output-dir ~/Developer/lda-ocr-test/outA_fixed
```
Expected: `imageRedactionCount` is 0 and latency stays in the sub-second range (no OCR ran).

- [ ] **Step 5: Final full suite + merge note**

Run: `swift test 2>&1 | tail -5`
Expected: all green. This branch (`feat/io`) merges back into `feat/lda-macos-core`
(solo-merge, no PR) per project convention.

---

## Notes for the implementer

- **House rules (enforced in this repo):** all comments and strings in English; never use the em-dash or en-dash-as-separator characters anywhere in code, comments, or test strings.
- **Vision dependency:** the OCR-backed tests require Vision to be available in the test runner, exactly like the existing `PdfOCRImporterTests`. They fail loudly (never silently pass) when OCR returns nothing.
- **Coordinate space:** image-origin rects come from `PdfOCRImporter.pageRect(fromNormalized:mediaBox:)`, the same mediaBox-relative space `PdfRedactor` and `PDFSelection.bounds(for:)` use, so boxes from both sources compose without a transform.
- **Conservative boxing depends on accurate dedup.** A false "keep" paints black over real body text, so do not loosen `textLayerCovers`; the vertical-only inset + significant-word overlap was tuned against the real fixture for exactly this reason.
