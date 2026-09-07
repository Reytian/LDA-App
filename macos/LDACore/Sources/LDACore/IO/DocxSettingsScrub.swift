//
//  DocxSettingsScrub.swift
//  LDACore
//
//  word/settings.xml is not content-free, and the privacy export used to copy
//  it through on that assumption.
//
//  What it holds. Word keeps DOCUMENT VARIABLES in the settings part, and a
//  document variable holds whatever a template author or a macro put in it.
//  Review R4's fixture is one line long:
//
//    <w:docVars><w:docVar w:name="ClientEmail" w:val="client@example.test"/></w:docVars>
//
//  It exported successfully with one detected entity. The visible email was
//  replaced, the complete original stayed in the settings part, and no
//  unboxed-token or embedded-media warning named it. A lawyer who unzipped
//  the "redacted" copy read the client's address.
//
//  w:mailMerge is the same channel with a second edge. It carries the merge
//  QUERY, which quotes the values it selects on, and a data source reference
//  whose relationship Target is a path. A PRC matter's recipient list is
//  named after the parties, so the path identifies them before anyone opens
//  the file. Stripping the block and leaving the relationship would leave
//  that path in the package, so both go.
//
//  The redacted copy needs neither block and the package stays valid without
//  them. This runs on the privacy export only: filling a form is not a
//  privacy export, and the document the user keeps stays whole.
//
//  Fails closed. If a removal pattern leaves either element name behind, the
//  export REFUSES rather than shipping a part it could not clean. Copying a
//  member through while reporting a clean redaction is the failure mode this
//  file exists to remove.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxSettingsScrub {

    /// The fixed path of the settings part.
    static let settingsPartPath = "word/settings.xml"

    /// The elements the redacted copy does not carry.
    static let removedElements = ["w:docVars", "w:mailMerge"]

    /// Relationship types a removed w:mailMerge named. Matched on the type's
    /// last segment so the Office and the strict-OOXML namespaces both hit.
    static let mailMergeRelationshipTypes = ["mailMergeSource", "mailMergeHeaderSource"]

    // MARK: - The settings part

    /// The bytes the export writes for the settings part of `url`, keyed by
    /// path, or an empty dictionary when the package has no settings part or
    /// the part needs no change. An unchanged member is left out so it copies
    /// through byte for byte.
    ///
    /// `paths` is the member listing the caller already enumerated, so a
    /// package without a settings part costs no read.
    static func replacementParts(
        in url: URL,
        paths: [String],
        budget: ArchiveBudget
    ) throws -> [String: Data] {
        guard paths.contains(settingsPartPath) else { return [:] }
        let data = try DocxZip.readEntry(settingsPartPath, from: url, budget: budget)
        guard let xml = String(data: data, encoding: .utf8) else {
            throw unreadableSettingsError
        }
        let cleaned = try sanitized(xml)
        guard cleaned != xml else { return [:] }
        return [settingsPartPath: Data(cleaned.utf8)]
    }

    /// `xml` without the elements the redacted copy does not carry.
    ///
    /// Throws when either element name survives the removal, which means the
    /// part uses a shape these patterns do not cover.
    static func sanitized(_ xml: String) throws -> String {
        let cleaned = removedElements.reduce(xml) { removing($1, from: $0) }
        for element in removedElements where cleaned.contains("<" + element) {
            throw uncleanableSettingsError
        }
        return cleaned
    }

    /// `xml` without every `element`, self-closing or paired, content and all.
    private static func removing(_ element: String, from xml: String) -> String {
        let name = NSRegularExpression.escapedPattern(for: element)
        // (?s) so a pretty-printed part with newlines inside the element is
        // covered too. The content group is lazy: these elements never nest.
        guard let regex = try? NSRegularExpression(
            pattern: #"(?s)<"# + name + #"\b[^>]*(?:/>|>.*?</"# + name + #">)"#
        ) else { return xml }
        let ns = xml as NSString
        return regex.stringByReplacingMatches(
            in: xml,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    // MARK: - The data source relationship

    /// One relationship element, self-closing or paired. The same shape
    /// DocxPackagePolicy matches, for the same reason.
    private static let relationshipRegex = try? NSRegularExpression(
        pattern: #"<Relationship\b[^>]*>(?:\s*</Relationship>)?"#
    )

    /// Drop every relationship a removed w:mailMerge pointed at, so the
    /// package carries no path to a recipient list it no longer merges.
    static func removeMailMergeSources(_ xml: String) -> String {
        guard let relationshipRegex else { return xml }
        let ns = xml as NSString
        var result = ""
        var cursor = 0
        relationshipRegex.enumerateMatches(
            in: xml,
            range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let element = ns.substring(with: match.range)
            guard namesAMailMergeSource(element) else { return }
            if match.range.location > cursor {
                result += ns.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    private static func namesAMailMergeSource(_ element: String) -> Bool {
        guard let type = DocxAttributes.value("Type", in: element) else { return false }
        let segment = type.split(separator: "/").last.map(String.init) ?? type
        return mailMergeRelationshipTypes.contains { $0.caseInsensitiveCompare(segment) == .orderedSame }
    }

    // MARK: - Refusals

    /// The refusals name the part and never its content: a document variable
    /// value IS the client's data, and an error string travels into logs.
    private static var unreadableSettingsError: DocumentIOError {
        DocumentIOError.unsupportedFormat(
            "the document settings part is not UTF-8 text, so the redactor cannot clean the "
                + "document variables it may hold and the redacted copy was not written."
        )
    }

    private static var uncleanableSettingsError: DocumentIOError {
        DocumentIOError.unsupportedFormat(
            "the document settings part holds document variables or a mail merge in a shape "
                + "the redactor cannot remove, so the redacted copy was not written. Remove "
                + "them in Word and export again."
        )
    }
}
