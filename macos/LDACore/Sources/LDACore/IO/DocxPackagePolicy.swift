//
//  DocxPackagePolicy.swift
//  LDACore
//
//  What the privacy export is allowed to do with each MEMBER of a .docx
//  package, and the reference cleanup that keeps the package valid when a
//  member is removed.
//
//  Why this file exists. The export used to redact a fixed set of text parts
//  and copy every other member through byte for byte. That is a leak with a
//  clean bill of health attached: a content control bound to a custom XML data
//  store (customXml/item*.xml) keeps the ORIGINAL value in that store, so the
//  body showed {EMAIL_1} while anyone who unzipped the "redacted" copy read
//  the client's address. The same is true of a rendered docProps thumbnail,
//  which is a picture of the unredacted first page.
//
//  So every member is classified, and there are only three answers:
//   - handled: the export produces this member's bytes (body, headers,
//     footers, notes, comments, docProps, relationships, content types), or
//     the member is structural or presentational and carries no free-form
//     user content (styles, settings, theme, fonts, embedded media, which is
//     separately surfaced to the user as an unscanned-images warning).
//   - dropped: the member carries user content this app cannot redact and the
//     package is valid without it, so it is removed along with every
//     reference to it.
//   - unsupported: the member carries user content this app can neither
//     redact nor drop (SmartArt data, chart caches, embedded workbooks, a
//     glossary document). The export REFUSES. Copying it through while
//     reporting a clean redaction is the failure mode this whole file exists
//     to remove.
//
//  A new part type therefore fails closed: unrecognized means refused, never
//  copied.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxPackagePolicy {

    // MARK: - Classification

    /// What the privacy export does with one member of the source package.
    enum Disposition: Equatable {
        /// The export produces this member's bytes, or the member is known to
        /// carry no free-form user content.
        case handled
        /// Removed from the package, with its references.
        case dropped
        /// Neither redactable nor droppable: the export refuses.
        case unsupported
    }

    /// Members removed from the redacted package.
    ///
    /// customXml: the data store behind bound content controls. The bound text
    /// is redacted in the body, but the store keeps the original, and there is
    /// no schema this app can redact inside an arbitrary customer XML tree.
    /// Word opens a document whose store is gone; the control simply stops
    /// being bound (see the w:dataBinding removal below).
    ///
    /// docProps/thumbnail: a rendered raster of the first page, generated
    /// before redaction. There is nothing to redact in a picture, so it goes.
    private static let droppedPrefixes = ["customxml/", "docprops/thumbnail"]

    /// Structural or presentational members with no free-form user content.
    /// Everything here copies through unchanged.
    private static let copiedThroughPaths: Set<String> = [
        "word/styles.xml",
        "word/stylesWithEffects.xml",
        "word/settings.xml",
        "word/webSettings.xml",
        "word/fontTable.xml",
        "word/numbering.xml",
        "word/commentsExtended.xml",
        "word/commentsIds.xml",
        "word/commentsExtensible.xml"
    ]

    /// Folders whose members copy through: themes and font subsets carry no
    /// user text, and word/media is the embedded-image channel the caller
    /// already reports as unscanned (DocxParts.embeddedMediaPaths).
    private static let copiedThroughPrefixes = ["word/theme/", "word/fonts/", "word/media/"]

    /// The disposition of one member path.
    static func disposition(for path: String) -> Disposition {
        let lowered = path.lowercased()
        if droppedPrefixes.contains(where: { lowered.hasPrefix($0) }) { return .dropped }
        if lowered.hasSuffix(".rels") { return .handled }
        if path == "[Content_Types].xml" { return .handled }
        if path == docxMainPartPath { return .handled }
        if DocxParts.isTextBearingPart(path) { return .handled }
        if path == DocxMarkupScrub.peoplePartPath { return .handled }
        if path == docxCorePropsPath || path == docxAppPropsPath || path == docxCustomPropsPath {
            return .handled
        }
        if copiedThroughPaths.contains(path) { return .handled }
        if copiedThroughPrefixes.contains(where: { lowered.hasPrefix($0) }) { return .handled }
        return .unsupported
    }

    /// Split member paths into the ones the export removes and the ones that
    /// make it refuse.
    static func classify(paths: [String]) -> (dropped: [String], unsupported: [String]) {
        var dropped: [String] = []
        var unsupported: [String] = []
        for path in paths {
            switch disposition(for: path) {
            case .handled: continue
            case .dropped: dropped.append(path)
            case .unsupported: unsupported.append(path)
            }
        }
        return (dropped.sorted(), unsupported.sorted())
    }

    /// The refusal a package with unsupported members earns.
    ///
    /// The count, never the paths: a part path can itself be PII, and the
    /// examples below are schema names rather than anything read from the
    /// document.
    static func unsupportedPartsError(count: Int) -> DocumentIOError {
        let noun = count == 1 ? "part" : "parts"
        return DocumentIOError.unsupportedFormat(
            "\(count) \(noun) of this document hold content the redactor cannot clean "
                + "(SmartArt, a chart, an embedded workbook, or a glossary entry), "
                + "so the redacted copy was not written. Remove that content in Word "
                + "and export again."
        )
    }

    // MARK: - Reference cleanup

    /// A data binding element, which is empty by the schema but is matched in
    /// the paired spelling too so a hand-built or tool-built package cannot
    /// leave a dangling pointer behind.
    private static let dataBindingRegex = try? NSRegularExpression(
        pattern: #"<w:dataBinding\b[^>]*(?:/>|>\s*</w:dataBinding>)"#
    )

    /// Remove every w:dataBinding from a text part. The data store it names is
    /// gone, so the binding has nothing to resolve against; the content
    /// control itself, and the redacted text inside it, both stay.
    ///
    /// Destructive with nothing to restore, exactly like the author and field
    /// target scrubs it sits beside in DocxMarkupScrub.
    static func removeDataBindings(_ xml: String) -> String {
        guard let dataBindingRegex else { return xml }
        let ns = xml as NSString
        return dataBindingRegex.stringByReplacingMatches(
            in: xml,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    /// One relationship element, self-closing or paired.
    private static let relationshipRegex = try? NSRegularExpression(
        pattern: #"<Relationship\b[^>]*>(?:\s*</Relationship>)?"#
    )

    /// One content-type override element.
    private static let overrideRegex = try? NSRegularExpression(
        pattern: #"<Override\b[^>]*>(?:\s*</Override>)?"#
    )

    /// Drop every Relationship whose target is a member the export removed, so
    /// the package carries no reference to a part that is not there.
    ///
    /// Targets are relative to the folder holding the .rels part, so a body
    /// relationship spells the store "../customXml/item1.xml" and the package
    /// relationship spells the thumbnail "docProps/thumbnail.jpeg". Both
    /// normalize to the same prefix test.
    static func removeDroppedRelationships(_ xml: String) -> String {
        removeElements(matching: relationshipRegex, in: xml) { element in
            guard let target = DocxAttributes.value("Target", in: element) else { return false }
            return refersToDroppedMember(target)
        }
    }

    /// Drop every content-type Override for a member the export removed. The
    /// Extension Defaults stay: they name no part.
    static func removeDroppedOverrides(_ xml: String) -> String {
        removeElements(matching: overrideRegex, in: xml) { element in
            guard let partName = DocxAttributes.value("PartName", in: element) else { return false }
            return refersToDroppedMember(partName)
        }
    }

    /// True when a relationship target or a part name points at a dropped
    /// member. Leading "/" and "../" segments are stripped so a package-level
    /// and a part-level spelling of the same member both match.
    private static func refersToDroppedMember(_ reference: String) -> Bool {
        var normalized = reference.lowercased()
        while normalized.hasPrefix("../") || normalized.hasPrefix("/") {
            normalized = String(normalized.dropFirst(normalized.hasPrefix("/") ? 1 : 3))
        }
        return droppedPrefixes.contains { normalized.hasPrefix($0) }
    }

    /// Rebuild `xml` without the matches of `regex` that `shouldRemove`
    /// accepts. Everything else, whitespace included, is copied verbatim.
    private static func removeElements(
        matching regex: NSRegularExpression?,
        in xml: String,
        shouldRemove: (String) -> Bool
    ) -> String {
        guard let regex else { return xml }
        let ns = xml as NSString
        var result = ""
        var cursor = 0
        regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let element = ns.substring(with: match.range)
            guard shouldRemove(element) else { return }
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
}

// MARK: - Attribute reading

/// Reading one attribute out of one XML start tag.
///
/// Every attribute is read quote-agnostically. XML gives the two quote styles
/// equal standing (AttValue accepts either), and while Word writes double
/// quotes, LibreOffice, python-docx variants, XML tooling, and hand-edited
/// packages emit single-quoted attributes. Matching only double quotes left
/// such values in place, so a real mailto:/tel: address once rode out of the
/// app inside a "redacted" package.
enum DocxAttributes {

    /// The unescaped value of `name` in `element`, or nil when absent.
    ///
    /// The two quote styles are separate alternatives rather than one [^"']
    /// character class so that a value keeps whichever quote it did not open
    /// with: an apostrophe in an email local part (o'brien@example.com) is
    /// both legal and real, and a matcher that ended the value at the first
    /// quote of EITHER style would read only the opening fragment. The name is
    /// anchored to a preceding space so it matches a whole attribute name
    /// only, never the tail of a longer one ("Mode" must not match inside
    /// "TargetMode").
    static func value(_ name: String, in element: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?<=\\s)\(escaped)=(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = element as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: element, range: full) else { return nil }
        // Exactly one of the two quote alternatives participates in a match.
        for group in 1 ... 2 where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
    }
}
