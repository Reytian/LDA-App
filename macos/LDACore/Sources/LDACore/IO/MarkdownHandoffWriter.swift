//
//  MarkdownHandoffWriter.swift
//  LDACore
//
//  The Markdown file that "Export for AI" hands to an external AI tool: the
//  session's combined redacted text, carried verbatim, with a one-line preamble
//  in the token style only. Pure rendering plus one UTF-8 writer, kept in the
//  core so the CLI can reuse it.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Renders and writes the redacted Markdown handoff file.
public enum MarkdownHandoffWriter {

    /// The first line of a token-style export. It describes the placeholder
    /// shape in words only: a literal "{PERSON_1}" here would be restored to a
    /// real name on the way back, and a near-miss shape would be flagged as a
    /// damaged placeholder by the restore-side forensics.
    public static let tokenStylePreamble =
        "Protected values appear as placeholders (a type name and a number in curly braces). "
        + "Keep every placeholder exactly as written."

    /// The body of the file. The combined redacted text is kept byte for byte;
    /// only the token style is prefixed with the preamble, because pseudonyms
    /// and asterisk masks read as ordinary text and need no instruction.
    public static func render(combined: String, style: SubstitutionStyle) -> String {
        guard style == .token else { return combined }
        return tokenStylePreamble + "\n\n" + combined
    }

    /// Write a rendered file as UTF-8. Throws DocumentIOError.unreadable when
    /// the destination cannot be written, matching TextDocumentIO's contract.
    public static func write(_ markdown: String, to url: URL) throws {
        try TextDocumentIO.exportText(markdown, to: url)
    }
}
