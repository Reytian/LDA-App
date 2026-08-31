//
//  SessionTokenizer.swift
//  LDACore
//
//  Multi-document session tokenization (R12): tokenize N documents against ONE
//  shared mapping by folding the seeded Tokenizer over the document list. The
//  same surface value carries the same placeholder in every document of the
//  session, and the single union mapping restores the whole set.
//
//  Pure: no clock reads, no I/O. The caller supplies the timestamp and an
//  optional seed mapping (a client profile's stored mapping, or a previous
//  session being extended).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// One document entering a session tokenization: its display name, its full
/// text, and the (already overlap-resolved, user-reviewed) spans to tokenize.
public struct SessionDocument: Sendable {
    public var name: String
    public var text: String
    public var spans: [Span]

    public init(name: String, text: String, spans: [Span]) {
        self.name = name
        self.text = text
        self.spans = spans
    }
}

/// One document leaving a session tokenization: its name and its tokenized
/// text (the redacted Markdown intermediate handed to the external AI).
public struct SessionTokenizedDocument: Sendable {
    public var name: String
    public var tokenizedText: String

    public init(name: String, tokenizedText: String) {
        self.name = name
        self.tokenizedText = tokenizedText
    }
}

/// The session result: every tokenized document plus the ONE shared mapping
/// that restores all of them.
public struct SessionTokenizeResult: Sendable {
    public var documents: [SessionTokenizedDocument]
    public var mapping: Mapping

    public init(documents: [SessionTokenizedDocument], mapping: Mapping) {
        self.documents = documents
        self.mapping = mapping
    }
}

/// Folds the seeded Tokenizer over a document list so the whole session shares
/// one mapping.
public enum SessionTokenizer {
    /// Tokenize the documents in order against one shared mapping.
    ///
    /// Each document is tokenized with the accumulated mapping as its seed, so
    /// a value first seen in document 1 keeps its token in documents 2..N and
    /// per-type counters never collide across the set.
    ///
    /// - Parameters:
    ///   - documents: the session's documents, in tray order.
    ///   - sourceLabel: the label recorded as the mapping's sourceFile (for
    ///     example a session or client name; the mapping spans many files).
    ///   - createdAtISO8601: caller-supplied ISO-8601 timestamp.
    ///   - seedMapping: optional starting mapping (client profile or a prior
    ///     session) whose identities the session must keep using. A seed built
    ///     in a different style contributes restore entries only; its
    ///     replacements are not re-emitted (see Tokenizer).
    ///   - style: how replacements are rendered across the whole session.
    /// - Returns: the tokenized documents plus the shared union mapping.
    public static func tokenize(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle = .token
    ) -> SessionTokenizeResult {
        tokenizeCore(
            documents: documents,
            sourceLabel: sourceLabel,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            overrides: [:]
        )
    }

    /// Tokenize a session with caller-forced replacement text for specific
    /// surfaces (pseudonym style only).
    ///
    /// See the override contract on Tokenizer.tokenize(overrides:). The
    /// session variant validates the override set ONCE against every
    /// document's text plus the seed mapping, then folds with the same
    /// shared-mapping semantics as the plain entry point. Validating against
    /// the full corpus up front is what makes the fold safe: every override
    /// is reserved in every document before minting, so a pseudonym minted
    /// in document 1 can never collide with an override whose surface
    /// appears only in document 2.
    ///
    /// - Throws: PseudonymOverrideError when any override is rejected.
    public static func tokenize(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle,
        overrides: [String: String]
    ) throws -> SessionTokenizeResult {
        try PseudonymOverrideValidator.validate(
            overrides: overrides,
            style: style,
            corpus: documents.map { $0.text },
            existingEntries: seedMapping?.entries ?? [:]
        )
        return tokenizeCore(
            documents: documents,
            sourceLabel: sourceLabel,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style,
            overrides: overrides
        )
    }

    /// Shared fold behind both entry points. Overrides must already be
    /// validated against every document of the session (see the throwing
    /// entry point); the fold passes them into every per-document call.
    private static func tokenizeCore(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping?,
        style: SubstitutionStyle,
        overrides: [String: String]
    ) -> SessionTokenizeResult {
        var mapping = seedMapping ?? Mapping(
            entries: [:],
            createdAtISO8601: createdAtISO8601,
            sourceFile: sourceLabel,
            style: style
        )
        var tokenized: [SessionTokenizedDocument] = []

        // A pseudonym minted for document K must not occur naturally in ANY
        // document of the session: the shared mapping restores every document
        // with one literal scan, so a natural occurrence in a companion
        // document would be indistinguishable from a substitution site.
        let allTexts = documents.map { $0.text }

        for (index, document) in documents.enumerated() {
            var corpus = allTexts
            corpus.remove(at: index)
            let result = Tokenizer.tokenizeCore(
                text: document.text,
                spans: document.spans,
                sourceFile: sourceLabel,
                createdAtISO8601: createdAtISO8601,
                seedMapping: mapping,
                style: style,
                uniquenessCorpus: corpus,
                overrides: overrides
            )
            mapping = result.mapping
            tokenized.append(
                SessionTokenizedDocument(
                    name: document.name,
                    tokenizedText: result.tokenizedText
                )
            )
        }

        // Normalize the mapping header: entries accumulated across documents,
        // but the session is one unit with one label and one timestamp.
        mapping.sourceFile = sourceLabel
        mapping.createdAtISO8601 = createdAtISO8601
        mapping.style = style

        return SessionTokenizeResult(documents: tokenized, mapping: mapping)
    }
}
