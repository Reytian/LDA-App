//
//  RedactedOutputFormat.swift
//  LDACore
//
//  The format a redacted document is written in, as a person chooses it:
//  Markdown, the default, or the source's own format with its layout kept.
//
//  One value, carried from the app's export, the batch window, `lda batch`
//  and the batch report down to RedactedOutputWriter, which is the only place
//  that turns it into files. RestoreOutputFormat is the same idea on the way
//  back.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// The file format of a redacted document.
public enum RedactedOutputFormat: String, Codable, Sendable, CaseIterable {
    /// One Markdown file per document: the redacted text exactly as Export
    /// for AI renders a single document (MarkdownHandoffWriter).
    case markdown
    /// The source's own type with its layout kept: a Word document keeps its
    /// formatting, text keeps its extension and its lines, a PDF keeps its
    /// pages with every replaced value covered, an image keeps its type.
    case original

    /// The format written when nobody chose one.
    public static let `default`: RedactedOutputFormat = .markdown
}
