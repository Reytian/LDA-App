//
//  DocxLeakAudit.swift
//  LDACore
//
//  The last check a redacted .docx passes before it is moved into place: no
//  value the export replaced may remain anywhere in the package.
//
//  Review 2026-11-11 (F5). The export redacted what it knew to look at (w:t
//  and w:delText runs, the docProps fields on a list, mailto: and tel:
//  targets) and copied everything else through. Originals rode out in a
//  hyperlink relationship whose visible text read {URL_1}, in field
//  instructions, in a content control's alias, tag and list items, in a VML
//  watermark's string attribute and in metadata fields nobody had listed.
//  Each carrier fixed one at a time leaves the next one open, so this audit
//  inverts the default: every XML member of the output is parsed, every
//  character data run and attribute value is searched for every replaced
//  value, and a hit refuses the export. A carrier LDA does not handle yet
//  becomes a refusal instead of a leak.
//
//  Reading. XMLParser resolves namespaces and decodes the predefined entities
//  and character references, so "mail&#116;o:" and "J&#111;rdan" are read as
//  a consumer reads them. External entities are never resolved. Relationship
//  targets and every attribute value holding a percent escape are also read
//  percent-decoded. The run text of the w:t parts is also read concatenated,
//  with a newline between paragraphs, so a value Word split across runs is
//  still one string.
//
//  Matching. Text and values are folded: lowercased, and every run of
//  characters that are neither letters nor digits becomes one space, so
//  "Jordan Ellis", "jordan.ellis" and "jordan-ellis" are one string. A value
//  in Latin script must stand between word boundaries ("Ellis" is not in
//  "Ellison"); a value with a CJK character is matched as written. A value
//  shorter than EntityRescan's minimum needle (two CJK characters, four
//  Latin, three for an acronym) is too ambiguous to search for, and so is a
//  single Latin word that LegalBoilerplate takes for boilerplate.
//
//  Not read: the font table and the theme parts, and the font attributes of
//  w:rFonts and DrawingML typefaces. Font names are not document content,
//  and a company called after a font family or a word processor would
//  otherwise refuse every export.
//
//  A finding names the member and the element, never the value.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum DocxLeakAudit {

    /// Where a replaced value was found.
    struct Finding: Equatable {
        /// The package member, for example "word/document.xml".
        let member: String
        /// The qualified name of the element whose text or attribute holds it.
        let element: String
    }

    /// The refusal a finding turns into. Names the member and the element;
    /// the value never appears.
    static func refusal(for finding: Finding) -> DocumentIOError {
        DocumentIOError.unsupportedFormat(
            "a replaced value is still present in \(finding.member) (\(finding.element)), in a place LDA "
                + "cannot clean yet, so the redacted copy was not written. Remove that content in Word and "
                + "export again."
        )
    }

    /// The first place in the package at `url` that holds one of `values`,
    /// or nil when there is none. Throws when a member cannot be read: a
    /// member the audit could not read is a member it could not clear.
    static func firstFinding(
        inPackage url: URL,
        values: [(String, EntityType)],
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> Finding? {
        let needles = needles(from: values)
        guard !needles.isEmpty else { return nil }
        for path in DocxParts.memberPaths(in: url) where isXMLMember(path) {
            let data = try DocxZip.readEntry(path, from: url, budget: budget)
            if let finding = try firstFinding(inMember: path, data: data, needles: needles) {
                return finding
            }
        }
        return nil
    }

    // MARK: - Needles

    struct Needle {
        /// The folded value.
        let folded: String
        /// True when the value holds a CJK character: matched as written.
        let isCJK: Bool
    }

    /// The values worth searching for, folded and deduplicated. A value that
    /// folds to digits only needs `minimumDigits` of them: the audit keeps
    /// minimumAuditedDigits, a hyperlink target needs none (the second
    /// independent review of F5 found ".../docket/21-843.html" kept in the
    /// rels part once the audit's floor applied to links too; a link
    /// neutralized for a short number costs a link, not a refusal).
    static func needles(from values: [(String, EntityType)], minimumDigits: Int = minimumAuditedDigits) -> [Needle] {
        var seen = Set<String>()
        var needles: [Needle] = []
        for (value, type) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let isCJK = DefinedTermScanner.containsCJK(trimmed)
            if isCJK {
                guard trimmed.count >= EntityRescan.minimumCJKNeedleCharacters else { continue }
            } else {
                let isAcronym = trimmed.count >= EntityRescan.minimumAcronymNeedleCharacters
                    && trimmed.allSatisfy { $0.isUppercase || $0.isNumber }
                guard trimmed.count >= EntityRescan.minimumLatinNeedleCharacters || isAcronym else { continue }
                if !trimmed.contains(where: { $0.isWhitespace }), LegalBoilerplate.shouldDrop(trimmed, type: type) {
                    continue
                }
            }
            let folded = fold(trimmed)
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            // A value that folds to a short number ("$100" is "100") is too
            // generic to audit: it matched Word's own w:zoom w:percent="100"
            // and w:spacing w:after="160", and would match "100 units"
            // anywhere, refusing ordinary documents (independent review of
            // F5). Six digits and more stay audited.
            if !folded.contains(where: { $0.isLetter }),
               folded.filter(\.isNumber).count < minimumDigits {
                continue
            }
            needles.append(Needle(folded: folded, isCJK: isCJK))
        }
        return needles
    }

    /// Digits a value made of digits only must have to be audited.
    static let minimumAuditedDigits = 6

    // MARK: - Folding and matching

    /// Lowercased, with every run of characters that are neither letters nor
    /// digits folded to one space, trimmed.
    static func fold(_ text: String) -> String {
        String(decoding: folded(text).units, as: UTF16.self)
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
            || CharacterSet.nonBaseCharacters.contains(scalar)
    }

    /// The folded UTF-16 units of `text`, and for each the range of `text`
    /// it came from (a folded space covers the run of separators it stands
    /// for).
    static func folded(_ text: String) -> (units: [UInt16], origins: [NSRange]) {
        var units: [UInt16] = []
        var origins: [NSRange] = []
        var separatorStart: Int?
        var previousWasCJK: Bool?
        var index = 0
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            if isWordScalar(scalar) {
                let isCJK = DefinedTermScanner.containsCJK(String(scalar))
                if let start = separatorStart, !units.isEmpty {
                    units.append(0x20)
                    origins.append(NSRange(location: start, length: index - start))
                } else if let previousWasCJK, previousWasCJK != isCJK {
                    // A change of script is a word boundary: a Latin name
                    // written against Chinese text ("由Jordan Ellis签署") is
                    // a word of its own (independent review of F5).
                    units.append(0x20)
                    origins.append(NSRange(location: index, length: 0))
                }
                previousWasCJK = isCJK
                separatorStart = nil
                for unit in String(scalar).lowercased().utf16 {
                    units.append(unit)
                    origins.append(NSRange(location: index, length: width))
                }
            } else if separatorStart == nil {
                separatorStart = index
            }
            index += width
        }
        return (units, origins)
    }

    /// The ranges of `text` where `value` is written once both are folded:
    /// case aside, any run of separators standing for any other ("Jordan
    /// Ellis" is found in "jordan.ellis" and "jordan-ellis"), between word
    /// boundaries for a Latin value, as written for a CJK one.
    static func foldedRanges(of value: String, in text: String) -> [NSRange] {
        let needle = folded(value.trimmingCharacters(in: .whitespacesAndNewlines)).units
        guard !needle.isEmpty else { return [] }
        let isCJK = DefinedTermScanner.containsCJK(value)
        let (units, origins) = folded(text)
        guard units.count >= needle.count else { return [] }
        var ranges: [NSRange] = []
        var position = 0
        while position + needle.count <= units.count {
            if units[position] == needle[0], Array(units[position ..< position + needle.count]) == needle {
                let end = position + needle.count
                let bounded = isCJK || ((position == 0 || units[position - 1] == 0x20)
                    && (end == units.count || units[end] == 0x20))
                if bounded {
                    let first = origins[position]
                    let last = origins[end - 1]
                    ranges.append(NSRange(location: first.location, length: last.location + last.length - first.location))
                    position = end
                    continue
                }
            }
            position += 1
        }
        return ranges
    }

    /// True when `text` holds one of `needles`.
    static func holds(_ text: String, _ needles: [Needle]) -> Bool {
        let folded = fold(text)
        guard !folded.isEmpty else { return false }
        let bounded = " " + folded + " "
        return needles.contains { needle in
            needle.isCJK ? folded.contains(needle.folded) : bounded.contains(" " + needle.folded + " ")
        }
    }

    // MARK: - Members

    /// The members whose content is XML: parts, relationships, content
    /// types. Media and embedded binaries are not text.
    static func isXMLMember(_ path: String) -> Bool {
        let lower = path.lowercased()
        guard lower.hasSuffix(".xml") || lower.hasSuffix(".rels") || lower.hasSuffix(".vml") else { return false }
        return lower != "word/fonttable.xml" && !lower.hasPrefix("word/theme/")
    }

    /// Elements whose attributes name fonts, and attributes that name a font
    /// wherever they appear.
    static let fontElements: Set<String> = ["w:rFonts", "w:font"]
    static let fontAttributes: Set<String> = ["typeface", "panose", "w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"]

    private static func firstFinding(inMember path: String, data: Data, needles: [Needle]) throws -> Finding? {
        let reader = Reader(needles: needles)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        if let element = reader.hit {
            return Finding(member: path, element: element)
        }
        guard parsed else {
            throw DocumentIOError.corrupt("the redacted copy could not be checked: \(path) is not well-formed XML")
        }
        // A value Word split across runs is one string only in the run text.
        if path.hasPrefix("word/"), let layout = try? DocxDocumentXML.parse(data), holds(layout.text, needles) {
            return Finding(member: path, element: "w:t")
        }
        return nil
    }

    /// Collects character data per element and checks every attribute value.
    private final class Reader: NSObject, XMLParserDelegate {
        let needles: [Needle]
        /// The first element found holding a value.
        var hit: String?
        /// The open elements and the character data collected for each.
        private var stack: [(name: String, text: String)] = []

        init(needles: [Needle]) { self.needles = needles }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let name = qualifiedName ?? elementName
            if !fontElements.contains(name) {
                for (attribute, value) in attributes where !fontAttributes.contains(attribute) && check(value) {
                    record(name, parser)
                    return
                }
            }
            stack.append((name, ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName name: String?) {
            guard let open = stack.popLast() else { return }
            if check(open.text) {
                record(open.name, parser)
            }
        }

        /// A value is checked as written and, when it holds a percent
        /// escape, percent-decoded.
        private func check(_ value: String) -> Bool {
            if holds(value, needles) { return true }
            if value.contains("%"), let decoded = value.removingPercentEncoding, decoded != value {
                return holds(decoded, needles)
            }
            return false
        }

        private func record(_ element: String, _ parser: XMLParser) {
            guard hit == nil else { return }
            hit = element
            parser.abortParsing()
        }
    }
}
