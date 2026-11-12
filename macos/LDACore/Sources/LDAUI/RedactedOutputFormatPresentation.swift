//
//  RedactedOutputFormatPresentation.swift
//  LDAUI
//
//  The words around the output format choice (RedactedOutputFormat): the
//  picker labels, the sentence under the Save Redacted picker for the open
//  document's kind, and the sentence under the Settings choice for batches.
//  Pure and Foundation only, so every sentence can be tested without a
//  window, the way RestoreOutputFormat is.
//
//  Every value returned is a catalog key; the caller localizes it.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

enum RedactedOutputFormatPresentation {

    /// The picker label for a format.
    static func labelKey(_ format: RedactedOutputFormat) -> String {
        switch format {
        case .markdown: return "Markdown"
        case .original: return "Original format"
        }
    }

    /// What Save Redacted will write for a document with this extension, in
    /// one sentence under the picker.
    static func saveExplanationKey(_ format: RedactedOutputFormat, sourceExtension ext: String) -> String {
        let kind = Kind(sourceExtension: ext)
        switch (format, kind) {
        case (.markdown, .word):
            return "One Markdown file with the body text, as Export for AI writes it. Headers, footers, notes and comments are left out."
        case (.markdown, _):
            return "One Markdown file with the redacted text, as Export for AI writes it."
        case (.original, .word):
            return "A Word document with its formatting kept: fonts, styles, tables, numbering, headers, footers and notes."
        case (.original, .pdf):
            return "A PDF with the same pages and every value covered, and its redacted text beside it as a .txt file."
        case (.original, .image):
            return "The image in its own format with every value covered, and its redacted text beside it as a .txt file."
        case (.original, .text):
            return "The same kind of text file, line for line."
        }
    }

    /// The sentence under the Settings choice: what a batch writes.
    static func batchExplanationKey(_ format: RedactedOutputFormat) -> String {
        switch format {
        case .markdown:
            return "Batch Anonymize writes one Markdown file per document."
        case .original:
            return "Batch Anonymize writes each document in its own format: Word keeps its formatting, text keeps its lines, and a PDF or an image keeps its pages with every value covered and its redacted text beside it."
        }
    }

    /// Why the original format refused a document, in the interface
    /// language; nil for any other error.
    static func refusal(_ error: Error, language: AppLanguage? = nil) -> String? {
        switch error as? RedactedOutputError {
        case .valuesNotCovered(let count)?:
            return String(
                format: L10n.string(
                    "Values that could not be found on the page to cover: %lld. A copy in the original format would still show them, so nothing was saved. Choose Markdown for this document.",
                    language: language
                ),
                Int64(count)
            )
        case .sourceNotReviewed?:
            return L10n.string(
                "The PDF shows text the review did not read, such as a scanned page, so a copy in the original format would show it unredacted. Nothing was saved. Choose Markdown for this document: it holds only the reviewed text.",
                language: language
            )
        case nil:
            return nil
        }
    }

    /// The kind of document the sentence speaks about.
    enum Kind: Equatable {
        case word
        case pdf
        case image
        case text

        init(sourceExtension ext: String) {
            switch ext.lowercased() {
            case "docx": self = .word
            case "pdf": self = .pdf
            case let other where ImageTextExtractor.supportedExtensions.contains(other): self = .image
            default: self = .text
            }
        }
    }
}
