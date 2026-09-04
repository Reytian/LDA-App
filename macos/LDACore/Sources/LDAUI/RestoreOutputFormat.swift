//
//  RestoreOutputFormat.swift
//  LDAUI
//
//  The output container a restore writes, as something the reader can SEE and
//  pick.
//
//  Restoring a Markdown return into a Word document has worked for a long
//  time. It was reachable only by retyping the extension in the save dialog:
//  NSSavePanel filters on allowedContentTypes but shows no format control of
//  its own, the shell had no accessory view, and the suggested name always
//  ended in the input's own extension. A capability nobody can find is not a
//  capability.
//
//  Pure and Foundation only, so the choice can be tested without a panel and
//  without SwiftUI. The mapping from a case to a UTType stays with the panel
//  in DeanonymizeShell, which is the only place that needs it.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// The container the restored document is written into.
public enum RestoreOutputFormat: String, CaseIterable, Sendable {
    /// Markdown, the form the AI handoff is exported in.
    case markdown
    /// Plain text.
    case plainText
    /// A Word package. Formatting is kept when the edit surface was itself a
    /// Word document, and plain when it was text. See
    /// `warnsAboutPlainWordFormatting(inputExtension:format:)`.
    case word

    /// The extension the written file carries. LDAService.restore reads this
    /// off the output URL to decide which writer runs, so the picker's choice
    /// reaches the writer through the file name and nothing else.
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plainText: return "txt"
        case .word: return "docx"
        }
    }

    /// The catalog key for this format's name in the picker.
    var labelKey: String {
        switch self {
        case .markdown: return "Markdown"
        case .plainText: return "Plain text"
        case .word: return "Word document"
        }
    }

    /// The formats offered for an edit surface with this extension, in the
    /// order they are shown.
    ///
    /// A Word edit surface offers only Word: its runs are rewritten in place,
    /// and flattening a formatted document into text would silently throw the
    /// formatting away. A text edit surface offers its own kind first, then
    /// the other text kind, then Word.
    public static func choices(forInputExtension ext: String) -> [RestoreOutputFormat] {
        switch ext.lowercased() {
        case "docx":
            return [.word]
        case "md":
            return [.markdown, .plainText, .word]
        default:
            return [.plainText, .markdown, .word]
        }
    }

    /// The format selected when the sheet opens: the input's own kind, which
    /// is what the flow wrote before there was a choice at all.
    public static func initialChoice(forInputExtension ext: String) -> RestoreOutputFormat {
        choices(forInputExtension: ext).first ?? .plainText
    }

    /// The suggested output name for `file`, keeping the established
    /// "_restored" suffix and taking its extension from this format.
    public func suggestedName(for file: URL) -> String {
        let base = file.deletingPathExtension().lastPathComponent
        return "\(base)_restored.\(fileExtension)"
    }

    /// Whether the plain-formatting sentence applies to this pairing.
    ///
    /// True only for a Word output regenerated from a TEXT edit surface,
    /// where SimpleDocxWriter emits one paragraph per line. A Word input
    /// restored to Word keeps its own formatting, so telling that reader
    /// their formatting will be plain would be false.
    public static func warnsAboutPlainWordFormatting(
        inputExtension ext: String,
        format: RestoreOutputFormat
    ) -> Bool {
        format == .word && ext.lowercased() != "docx"
    }
}
