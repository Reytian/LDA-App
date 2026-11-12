//
//  RedactedOutputWriter.swift
//  LDACore
//
//  Writes one redacted document to disk. The only place that turns a
//  RedactedOutputFormat into files: LDAService.anonymize (`lda batch`, the
//  app's batch window, `lda anonymize`, MCP) and the app's Save Redacted both
//  call it, so which writer runs for which source exists once.
//
//  The layouts:
//  - Markdown: `<base>.md`, the redacted text exactly as Export for AI renders
//    a single document, for every source type. A Word document contributes
//    its body, as it does to Export for AI.
//  - Original: the source's own type with its layout kept. A Word document is
//    rewritten run by run (DocxRedactor), so fonts, styles, tables,
//    numbering, headers, footers and notes stay, and each placeholder takes
//    the formatting of the first run of the text it replaces. Text keeps its
//    extension and its lines. A PDF is re-rendered page by page with every
//    replaced value boxed (PdfRedactor): the same pages at the same sizes,
//    and no text layer, so nothing under a box can be extracted. An image is
//    boxed and written in its own type with no metadata but its layout.
//    A PDF or an image that would still show a replaced value is refused,
//    because in this layout the picture IS the deliverable.
//  - Edit surfaces: what `lda anonymize` and the MCP tools have always
//    written and read back, and what every batch wrote before there was a
//    choice. The redacted .docx for Word, a .txt for everything else, and
//    beside a PDF the boxed review copy `<stem>_review.pdf` (with the base
//    name's counter, OutputNames), beside an image the boxed PNG. A value the
//    review copy or the PNG could not box is counted, not refused: the .txt
//    is the deliverable there.
//
//  Two things are left to the caller. The mapping sidecar, because its
//  sealing and its scope differ (a batch seals every mapping, Save Redacted
//  writes one only on request and narrowed to the document). And the base
//  name, so an interactive export can probe for collisions first
//  (artifactExtensions).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Errors

/// Why a document was not written in the layout asked for.
public enum RedactedOutputError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The boxed PDF or image would still show replaced values: the page
    /// geometry gave no place to put a box over them. Nothing was written.
    case valuesNotCovered(count: Int)
    /// The PDF, read now, holds text the caller's review did not: a scanned
    /// page the review never read, for example. Reprinting its pages would
    /// show that text with nothing boxed on it. Nothing was written.
    case sourceNotReviewed

    public var description: String {
        switch self {
        case .valuesNotCovered(let count):
            return "\(count) replaced value(s) could not be found on the page to cover, so a copy in "
                + "the original format would still show them. Nothing was written for this "
                + "document. Write it as Markdown instead."
        case .sourceNotReviewed:
            return "The PDF holds text the review did not read, such as a scanned page, so a copy in "
                + "the original format would show it unredacted. Nothing was written for this "
                + "document. Write it as Markdown instead, which holds only the reviewed text."
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Writer

public enum RedactedOutputWriter {

    /// Which files a document becomes.
    public enum Layout: Equatable, Sendable {
        /// The deliverable in a chosen format. `textCompanion` also writes
        /// the redacted text as `<base>.txt` beside a boxed PDF or image,
        /// which carry no text of their own.
        case format(RedactedOutputFormat, textCompanion: Bool)
        /// The edit-surface layout of `lda anonymize`, MCP, and every batch
        /// written before there was a choice. See the file header.
        case editSurfaces

        /// The layout a chosen format writes, with the product's rule for
        /// the text companion applied in one place.
        public static func chosen(_ format: RedactedOutputFormat) -> Layout {
            .format(format, textCompanion: true)
        }
    }

    /// What one document needs written, whatever the layout.
    public struct Document {
        /// The source file. Read again for a Word rewrite and for a boxed
        /// PDF or image. Nil for text with no file behind it (a pasted note),
        /// which is written as text.
        public var source: URL?
        /// The source's import result, for the scanned pages of a PDF. Nil
        /// imports the PDF again when the layout needs it.
        public var imported: ImportedDocument?
        /// The redacted body text and the mapping that produced it.
        public var tokenizedText: String
        public var mapping: Mapping
        /// The body spans that were replaced, as offsets into the source
        /// text, for covering an image.
        public var spans: [Span]
        /// The run edits for a Word rewrite.
        public var replacements: [Replacement]
        /// The output style, for the Markdown preamble.
        public var style: SubstitutionStyle
        /// The OCR lines of a standalone image when the caller already read
        /// them. Nil reads the image again.
        public var imageLines: [ImageTextLine]?
        /// Box red-region seal candidates in a standalone image too.
        public var includeSealCandidates: Bool
        /// Detection over the Word parts outside the body (headers, footers,
        /// notes, comments). It throws when a part cannot be scanned under
        /// the body's gates, which refuses the document.
        public var detectWordParts: (String) throws -> [Span]
        /// Detection over the text read from images inside a PDF.
        public var detectImageText: (String) -> [Span]
        /// The text the caller's review covered, when it read the source on
        /// its own rather than handing `imported` in. A PDF re-rendered whole
        /// reprints every page, so it is refused unless reading the source
        /// now gives exactly this text.
        public var reviewedText: String?

        public init(
            source: URL?,
            imported: ImportedDocument?,
            tokenizedText: String,
            mapping: Mapping,
            spans: [Span],
            replacements: [Replacement],
            style: SubstitutionStyle,
            imageLines: [ImageTextLine]? = nil,
            includeSealCandidates: Bool = true,
            detectWordParts: @escaping (String) throws -> [Span],
            detectImageText: @escaping (String) -> [Span],
            reviewedText: String? = nil
        ) {
            self.source = source
            self.imported = imported
            self.tokenizedText = tokenizedText
            self.mapping = mapping
            self.spans = spans
            self.replacements = replacements
            self.style = style
            self.imageLines = imageLines
            self.includeSealCandidates = includeSealCandidates
            self.detectWordParts = detectWordParts
            self.detectImageText = detectImageText
            self.reviewedText = reviewedText
        }
    }

    /// What was written, and what the caller reports and folds into the
    /// mapping before saving it.
    public struct Written: Sendable {
        /// The redacted file a restore reads: the Markdown, the redacted
        /// .docx or text, or the redacted text beside a boxed PDF or image.
        /// (A boxed copy written with no text beside it is the only file and
        /// stands here too.)
        public var redactedURL: URL
        /// The boxed copy of a PDF: the review copy in the edit surfaces,
        /// the document itself in the original format.
        public var boxedPDFURL: URL?
        /// The boxed copy of an image: a PNG in the edit surfaces, the
        /// image's own type in the original format.
        public var boxedImageURL: URL?
        /// Tokens minted outside the body text (Word headers and notes,
        /// images inside a PDF). The caller must add them to the mapping it
        /// saves, or those sites cannot be restored.
        public var newEntries: [MappingEntry] = []
        /// What the Word parts outside the body received.
        public var supplementary: DocxSupplementaryCoverage = .none
        /// Word only: embedded images copied without scanning.
        public var embeddedMediaCount = 0
        /// Boxes painted over an image, or image regions boxed in a PDF.
        public var imageRedactionCount = 0
        /// Replaced occurrences no box covers. Always 0 for a boxed PDF or
        /// image in the original format, which is refused instead.
        public var unboxedOccurrenceCount = 0
        /// Seal candidates included in an image's boxes.
        public var sealCandidateCount = 0
    }

    /// What kind of writer a source needs.
    enum SourceKind: Equatable {
        case word(URL)
        case pdf(URL)
        case image(URL, ImageRedactor.OutputType)
        /// Text, with the extension the original format keeps.
        case text(String)
    }

    static func kind(of source: URL?) -> SourceKind {
        guard let source else { return .text("txt") }
        let ext = source.pathExtension.lowercased()
        if ImageTextExtractor.shouldTreatAsImage(source, extension: ext) {
            return .image(source, ImageRedactor.OutputType(of: source))
        }
        switch ext {
        case "docx": return .word(source)
        case "pdf": return .pdf(source)
        case "": return .text("txt")
        default: return .text(ext)
        }
    }

    /// The extensions a layout writes for `source` under the caller's base
    /// name, the redacted file's first, so a caller can probe for names that
    /// are already taken. The edit-surface review PDF is named after the
    /// source instead and is not listed.
    public static func artifactExtensions(for source: URL?, layout: Layout) -> [String] {
        switch layout {
        case .format(.markdown, _):
            return ["md"]
        case .format(.original, let textCompanion):
            let companion = textCompanion ? ["txt"] : []
            switch kind(of: source) {
            case .word: return ["docx"]
            case .pdf: return ["pdf"] + companion
            case .image(let url, let type): return [imageExtension(type, source: url)] + companion
            case .text(let ext): return [ext]
            }
        case .editSurfaces:
            switch kind(of: source) {
            case .word: return ["docx"]
            case .image: return ["txt", "png"]
            case .pdf, .text: return ["txt"]
            }
        }
    }

    /// Every file name `write` creates for `source` in `layout` under
    /// `baseName`, the edit-surface review PDF included, so a caller can
    /// keep from writing over any of them. The caller's mapping sidecar is
    /// not among them.
    public static func artifactNames(for source: URL?, layout: Layout, baseName: String) -> [String] {
        var names = artifactExtensions(for: source, layout: layout).map { "\(baseName).\($0)" }
        if case .editSurfaces = layout, case .pdf(let url) = kind(of: source) {
            let reviewBase = OutputNames.reviewBaseName(
                sourceBase: url.deletingPathExtension().lastPathComponent,
                redactedBase: baseName
            )
            names.append("\(reviewBase).pdf")
        }
        return names
    }

    /// Writes `document` in `layout` into `outputDir` as `<baseName>.<ext>`.
    public static func write(
        _ document: Document,
        layout: Layout,
        to outputDir: URL,
        baseName: String
    ) throws -> Written {
        func url(_ ext: String) -> URL {
            outputDir.appendingPathComponent("\(baseName).\(ext)")
        }
        let kind = kind(of: document.source)
        switch layout {
        case .format(.markdown, _):
            let markdownURL = url("md")
            try MarkdownHandoffWriter.write(
                MarkdownHandoffWriter.render(combined: document.tokenizedText, style: document.style),
                to: markdownURL
            )
            return Written(redactedURL: markdownURL)

        case .format(.original, let textCompanion):
            let companionURL = textCompanion ? url("txt") : nil
            switch kind {
            case .word(let source):
                return try writeWord(document, source: source, to: url("docx"))
            case .pdf(let source):
                return try writeBoxedPDF(
                    document,
                    source: source,
                    to: url("pdf"),
                    companion: companionURL,
                    refuseUncovered: true
                )
            case .image(let source, let type):
                return try writeBoxedImage(
                    document,
                    source: source,
                    type: type,
                    to: url(imageExtension(type, source: source)),
                    companion: companionURL,
                    refuseUncovered: true
                )
            case .text(let ext):
                let textURL = url(ext)
                try CompanionWriter.writeText(document.tokenizedText, to: textURL)
                return Written(redactedURL: textURL)
            }

        case .editSurfaces:
            switch kind {
            case .word(let source):
                return try writeWord(document, source: source, to: url("docx"))
            case .pdf(let source):
                let reviewBase = OutputNames.reviewBaseName(
                    sourceBase: source.deletingPathExtension().lastPathComponent,
                    redactedBase: baseName
                )
                let reviewURL = outputDir.appendingPathComponent("\(reviewBase).pdf")
                return try writeBoxedPDF(
                    document,
                    source: source,
                    to: reviewURL,
                    companion: url("txt"),
                    refuseUncovered: false
                )
            case .image(let source, _):
                return try writeBoxedImage(
                    document,
                    source: source,
                    type: .png,
                    to: url("png"),
                    companion: url("txt"),
                    refuseUncovered: false
                )
            case .text:
                let textURL = url("txt")
                try CompanionWriter.writeText(document.tokenizedText, to: textURL)
                return Written(redactedURL: textURL)
            }
        }
    }

    // MARK: Writers

    /// The Word document rewritten run by run, every text-bearing part
    /// redacted and its metadata scrubbed (DocxRedactor.redact).
    private static func writeWord(_ document: Document, source: URL, to wordURL: URL) throws -> Written {
        let embeddedMediaCount = DocxRedactor.embeddedMediaCount(in: source)
        let outcome = try DocxRedactor.redact(
            original: source,
            replacements: document.replacements,
            to: wordURL,
            nonBody: (mapping: document.mapping, detect: document.detectWordParts)
        )
        var written = Written(redactedURL: wordURL)
        written.newEntries = outcome.newEntries
        written.supplementary = outcome.coverage
        written.embeddedMediaCount = embeddedMediaCount
        return written
    }

    /// The PDF re-rendered with every located value boxed on every channel
    /// (text layer, page OCR, images inside the page), plus the redacted
    /// text beside it when asked. With `refuseUncovered`, an occurrence no
    /// box covers refuses the document before anything is written.
    private static func writeBoxedPDF(
        _ document: Document,
        source: URL,
        to pdfURL: URL,
        companion companionURL: URL?,
        refuseUncovered: Bool
    ) throws -> Written {
        let imported = try document.imported
            ?? LDAService.importDocument(source, extension: "pdf")
        // Every page is reprinted, so the text read now must be the text the
        // review covered. A page the review never read (the scanned page of a
        // mixed PDF, when the review read only the text layer) would
        // otherwise come back with nothing boxed on it.
        if let reviewed = document.reviewedText, imported.text != reviewed {
            throw RedactedOutputError.sourceNotReviewed
        }
        if let companionURL, !refuseUncovered {
            // The edit-surface layout writes its .txt first, as it always has.
            try CompanionWriter.writeText(document.tokenizedText, to: companionURL)
        }
        // Every replaced occurrence is counted against the sites the text
        // replaced (F6), so a value the page shows more often than the text
        // replaced it still has to be covered everywhere.
        let surface = PdfReviewSurface.locate(
            in: source,
            imported: imported,
            mapping: document.mapping,
            sitesByToken: document.replacements.reduce(into: [:]) { counts, replacement in
                counts[replacement.token, default: 0] += 1
            },
            detect: document.detectImageText
        )
        if refuseUncovered, surface.unboxedOccurrenceCount > 0 {
            throw RedactedOutputError.valuesNotCovered(count: surface.unboxedOccurrenceCount)
        }
        try PdfRedactor.renderRedactedPDF(original: source, boxes: surface.boxes, to: pdfURL)
        if let companionURL, refuseUncovered {
            try CompanionWriter.writeText(document.tokenizedText, to: companionURL)
        }
        var written = Written(redactedURL: companionURL ?? pdfURL)
        written.boxedPDFURL = pdfURL
        written.newEntries = surface.newEntries
        written.imageRedactionCount = surface.imageRedactionCount
        written.unboxedOccurrenceCount = surface.unboxedOccurrenceCount
        return written
    }

    /// The image with every OCR line that holds a replaced value boxed, and
    /// the seal candidates when asked, plus the redacted text beside it when
    /// asked. With `refuseUncovered`, a replaced value no line holds refuses
    /// the document before anything is written.
    private static func writeBoxedImage(
        _ document: Document,
        source: URL,
        type: ImageRedactor.OutputType,
        to imageURL: URL,
        companion companionURL: URL?,
        refuseUncovered: Bool
    ) throws -> Written {
        if let companionURL, !refuseUncovered {
            try CompanionWriter.writeText(document.tokenizedText, to: companionURL)
        }
        let lines = try document.imageLines ?? ImageTextExtractor().extract(source).lines
        let coverage = ImageRedactor.coverage(
            lines: lines,
            replacedRanges: document.spans.map { $0.start..<$0.end }
        )
        if refuseUncovered, coverage.unlocatedRangeCount > 0 {
            throw RedactedOutputError.valuesNotCovered(count: coverage.unlocatedRangeCount)
        }
        let sealCandidates = document.includeSealCandidates
            ? try SealCandidateDetector.candidates(inImageAt: source)
            : []
        let render: ImageRedactor.RenderedRedaction
        if refuseUncovered {
            render = try ImageRedactor.renderRedactedImage(
                originalImageAt: source,
                covering: coverage.coveredLines,
                sealCandidates: sealCandidates,
                as: type,
                to: imageURL
            )
            if let companionURL {
                try CompanionWriter.writeText(document.tokenizedText, to: companionURL)
            }
        } else {
            // The edit-surface PNG stays exactly what it always was.
            render = try ImageRedactor.renderRedactedPNG(
                originalImageAt: source,
                covering: coverage.coveredLines,
                sealCandidates: sealCandidates,
                to: imageURL
            )
        }
        var written = Written(redactedURL: companionURL ?? imageURL)
        written.boxedImageURL = imageURL
        written.imageRedactionCount = render.paintedBoxCount
        written.unboxedOccurrenceCount = coverage.unlocatedRangeCount
        written.sealCandidateCount = render.sealCandidateCount
        return written
    }

    /// The extension a boxed image is written under: the source's own when
    /// it names the type ("jpeg" stays "jpeg"), otherwise the type's usual
    /// one.
    private static func imageExtension(_ type: ImageRedactor.OutputType, source: URL) -> String {
        let ext = source.pathExtension.lowercased()
        switch type {
        case .png: return "png"
        case .jpeg: return ext == "jpeg" ? "jpeg" : "jpg"
        }
    }
}
