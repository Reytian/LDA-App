//
//  LDAServiceResults.swift
//  LDACore
//
//  The result types the service facade returns: AnonymizeResult,
//  RestoreReport, and DetectionSummary. Extracted from LDAService.swift so
//  that file stays inside the size budget while these types carry the
//  documentation their counts need.
//
//  Counting rule, shared by every type here: a "site" is one replacement that
//  was applied to the document. A value mentioned three times is three sites,
//  and a value mentioned once in the body and once in a header is two sites,
//  even though both sites share one token. Sites are what a restore puts
//  back, so counting them is what makes the reported coverage and
//  RestoreReport.restoredCount the same number on a clean round trip.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Results

/// The outcome of an anonymize run.
public struct AnonymizeResult: Sendable {
    /// The edit surface: a docx-run-preserving redacted .docx for docx input, a
    /// companion .docx/.txt for pdf input, or a redacted .txt for text input.
    public var redactedFileURL: URL
    /// The encrypted mapping sidecar (<redactedBaseName>.ldamap).
    public var mappingFileURL: URL
    /// A boxes-over-PII review PDF, present only when the input was a PDF.
    public var visualPdfURL: URL?
    /// A boxes-over-PII redacted PNG, present only when the input was a
    /// standalone image (png / jpg / jpeg). The boxes are destructive, so
    /// this artifact is NOT restorable; the paired redacted text companion
    /// is the round-trip surface.
    public var redactedImageURL: URL?
    /// How many replacement sites this run produced, EVERYWHERE: the body
    /// spans below plus every replacement made in the DOCX parts outside
    /// word/document.xml (headers, footers, footnotes, endnotes, comments).
    /// This is the coverage number a caller should show, and on a clean round
    /// trip it equals RestoreReport.restoredCount.
    ///
    /// Read the asymmetry with `entities` deliberately: this count includes
    /// the supplementary parts, `entities` does not. A reader who took
    /// entities.count for the coverage total once concluded that the header
    /// names had leaked, when in fact they had been redacted and merely never
    /// counted. Use supplementaryEntityCount to show the split.
    public var entityCount: Int
    /// The accepted BODY spans (post-merge) that were tokenized, with their
    /// offsets into the body text.
    ///
    /// Body only, by design. A value found in a header, footer, note, or
    /// comment has no offset into this text, and its offset into its own part
    /// would collide with a body offset if the two lists were flattened, so
    /// supplementary entities are reported as aggregate counts instead of
    /// being given invented positions. entities.count is therefore
    /// entityCount minus supplementaryEntityCount.
    public var entities: [Span]
    /// How many of entityCount were replaced OUTSIDE the body, in the DOCX
    /// text-bearing parts (headers, footers, footnotes, endnotes, comments).
    /// Always 0 for every non-DOCX input and for a DOCX with no such parts.
    ///
    /// Counts sites, not distinct values: a header that repeats a body name
    /// reuses the body token and mints no new mapping entry, but it is still
    /// a replacement that the redacted file carries and a restore puts back.
    public var supplementaryEntityCount: Int
    /// The entity types of those supplementary replacements and how many of
    /// each. Sums to supplementaryEntityCount. Empty when that count is 0.
    public var supplementaryCountsByType: [EntityType: Int]
    /// How many image-origin regions were redacted (signatures, stamps). 0 unless
    /// the input was a PDF with an image-PII channel pass.
    public var imageRedactionCount: Int
    /// How many embedded media files (word/media/...) were copied verbatim into
    /// a redacted DOCX without being scanned for PII. Wet-ink signature scans
    /// and stamps live there; a non-zero count must be surfaced to the user as
    /// a warning. Always 0 for non-DOCX input.
    public var embeddedMediaCount: Int
    /// How many tokenized values could not be given a redaction box in the
    /// review PDF. Always 0 for non-PDF input.
    ///
    /// A non-zero count MUST be surfaced to the user as a warning, for the same
    /// reason as embeddedMediaCount: the value IS tokenized in the edit surface
    /// and the mapping, so the round trip is correct, but the review PDF still
    /// shows it. A lawyer who forwards that PDF believing it redacted is the
    /// failure this count exists to prevent. Flag, never guess: no box is
    /// invented for a value whose position could not be established.
    public var unboxedTokenCount: Int
    /// How many red-region seal CANDIDATE boxes were merged into the redacted
    /// image's coverage. Candidates only, never certain seal detections; the
    /// UI can surface "N seal candidates boxed". Always 0 for non-image input
    /// and when includeSealCandidates is false.
    public var sealCandidateCount: Int
    /// How many detected OCCURRENCES the caller's exclusions (spanFilter and
    /// excludedTypes) left visible, on every channel, and how many DISTINCT
    /// values those occurrences carry. Excluding one occurrence of a value
    /// excludes every occurrence of it, so these counts, not the size of the
    /// caller's exclusion list, are what the output discloses. 0 when none.
    public var excludedEntityCount: Int
    public var excludedValueCount: Int
    /// DOCX only: how many tracked-change containers the body carries (see
    /// ImportedDocument.trackedChangeCount). A non-zero count should be
    /// surfaced as a warning: "This document carries tracked changes; accept
    /// all changes before redacting for an exact round trip." Always 0 for
    /// non-DOCX input.
    public var trackedChangeCount: Int

    public init(
        redactedFileURL: URL,
        mappingFileURL: URL,
        visualPdfURL: URL?,
        entityCount: Int,
        entities: [Span],
        imageRedactionCount: Int = 0,
        embeddedMediaCount: Int = 0,
        unboxedTokenCount: Int = 0,
        sealCandidateCount: Int = 0,
        redactedImageURL: URL? = nil,
        excludedEntityCount: Int = 0,
        excludedValueCount: Int = 0,
        trackedChangeCount: Int = 0,
        supplementaryEntityCount: Int = 0,
        supplementaryCountsByType: [EntityType: Int] = [:]
    ) {
        self.redactedFileURL = redactedFileURL
        self.mappingFileURL = mappingFileURL
        self.visualPdfURL = visualPdfURL
        self.redactedImageURL = redactedImageURL
        self.trackedChangeCount = trackedChangeCount
        self.entityCount = entityCount
        self.entities = entities
        self.imageRedactionCount = imageRedactionCount
        self.embeddedMediaCount = embeddedMediaCount
        self.unboxedTokenCount = unboxedTokenCount
        self.sealCandidateCount = sealCandidateCount
        self.excludedEntityCount = excludedEntityCount
        self.excludedValueCount = excludedValueCount
        self.supplementaryEntityCount = supplementaryEntityCount
        self.supplementaryCountsByType = supplementaryCountsByType
    }
}

/// The outcome of a restore run.
public struct RestoreReport: Sendable {
    /// Where the restored document was written.
    public var outputURL: URL
    /// How many tokens were restored to their values.
    public var restoredCount: Int
    /// Tokens present in the edited file but absent from (or broken in) the
    /// mapping, as reported by the orphan guard.
    public var orphanTokens: [String]
    /// Near-miss placeholder shapes flagged by the forensics scan (an external
    /// AI may have mangled a placeholder); never substituted, only reported.
    public var suspectPlaceholders: [String]
    /// Asterisk style only: masked forms shared by several entities. Their
    /// sites were left verbatim because substituting one would be a guess.
    public var ambiguousReplacements: [String]

    public init(
        outputURL: URL,
        restoredCount: Int,
        orphanTokens: [String],
        suspectPlaceholders: [String] = [],
        ambiguousReplacements: [String] = []
    ) {
        self.outputURL = outputURL
        self.restoredCount = restoredCount
        self.orphanTokens = orphanTokens
        self.suspectPlaceholders = suspectPlaceholders
        self.ambiguousReplacements = ambiguousReplacements
    }
}

/// What a detect-only pass would find, including the coverage a plain span
/// list cannot express.
///
/// LDAService.detect answers "which values are where in the body", which is
/// what a caller that draws boxes or assigns ids needs. It cannot answer "how
/// much will this run redact", because a DOCX also redacts its headers,
/// footers, notes, and comments, and those hits have no body offsets. This
/// type answers the second question without inventing positions for the first.
public struct DetectionSummary: Sendable {
    /// Exactly what LDAService.detect returns: the body spans with their body
    /// offsets, in detection order.
    public var bodySpans: [Span]
    /// How many replacements the DOCX parts outside word/document.xml would
    /// receive. 0 for every non-DOCX input.
    public var supplementaryEntityCount: Int
    /// Those replacements' types and how many of each. Sums to
    /// supplementaryEntityCount.
    public var supplementaryCountsByType: [EntityType: Int]

    /// The preview of AnonymizeResult.entityCount: body sites plus
    /// supplementary sites.
    ///
    /// A lower bound, never an over-estimate: anonymize splits a value that
    /// straddles a line break or a tab into one token per part, so a document
    /// carrying such a value redacts a little MORE than this predicts. Every
    /// other case predicts the run exactly.
    public var entityCount: Int { bodySpans.count + supplementaryEntityCount }

    public init(
        bodySpans: [Span],
        supplementaryEntityCount: Int = 0,
        supplementaryCountsByType: [EntityType: Int] = [:]
    ) {
        self.bodySpans = bodySpans
        self.supplementaryEntityCount = supplementaryEntityCount
        self.supplementaryCountsByType = supplementaryCountsByType
    }
}
