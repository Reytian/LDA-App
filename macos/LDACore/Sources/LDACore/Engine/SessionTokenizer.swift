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
    ///     session) whose identities the session must keep using.
    /// - Returns: the tokenized documents plus the shared union mapping.
    public static func tokenize(
        documents: [SessionDocument],
        sourceLabel: String,
        createdAtISO8601: String,
        seedMapping: Mapping? = nil
    ) -> SessionTokenizeResult {
        var mapping = seedMapping ?? Mapping(
            entries: [:],
            createdAtISO8601: createdAtISO8601,
            sourceFile: sourceLabel
        )
        var tokenized: [SessionTokenizedDocument] = []

        for document in documents {
            let result = Tokenizer.tokenize(
                text: document.text,
                spans: document.spans,
                sourceFile: sourceLabel,
                createdAtISO8601: createdAtISO8601,
                seedMapping: mapping
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

        return SessionTokenizeResult(documents: tokenized, mapping: mapping)
    }
}
