import Foundation

/// LDA-side rule for a published precedent's own parties (round 4, 2026-10-08): first a port of
/// `datagen/precedent_rule.py`, made stricter after the 2026-11-11 review (F1).
///
/// The user's rule keeps a published precedent's own parties visible, in its title and body. The tagger redacts every
/// name; LDA runs this rule on the whole document. `caption(of:)` is deliberately conservative (nil when in doubt), and
/// LDA should show the caption it found for the user to confirm, or pass a caption the user typed. `keepParties`
/// releases every PERSON or COMPANY span whose text (2+ characters) the caption names, and every other mention of the
/// same text; witnesses, judges and counsel stay redacted. Offsets are UTF-16 (`DocumentSpan.start16`/`end16`).
///
/// The reference rule accepted any line shaped "X v. Y" once the word "opinion" or "justice" appeared anywhere in the
/// first 3,000 characters, and any mention of a guiding case's number near the top. A memo with a "Re: X v. Y" line
/// that says "In our opinion", an email whose subject names a case, a draft brief that mentions "the interests of
/// justice" and a Chinese legal opinion titled after the guiding case it relies on all released their parties' names.
/// A memo, letter, email, brief or pleading is not a published precedent, so the rule now asks for the shape of one:
///
/// - Chinese: the document's own heading is the title block of an SPC or SPP guiding case, that is a line that begins
///   with its number (指导案例96号, 检例第1号), the case name ending in 案 and optionally the issuing line, followed by
///   the first body heading (关键词, 裁判要点, 要旨, 基本案情). Any other line in that block refuses.
/// - English: a court header, then the caption, then an opinion heading (OPINION, PER CURIAM, a panel or authoring
///   judge line). A memo, email or letter header field, a salutation, a privilege or draft legend, or the title of a
///   brief or pleading anywhere near the top refuses.
///
/// A Latin-script party value must also be a whole word sequence of the caption ("Ann" is not released by "Annabel");
/// CJK has no word boundaries, so a CJK value is matched as written.
public enum PrecedentRule {
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // MARK: Chinese guiding cases

    /// A guiding case's number at the start of a line, optionally bracketed and preceded by the issuing body.
    static let guidingNumberLine = regex(
        "^[【〔（(\\[]?\\s{0,2}(?:最高人民法院|最高人民检察院)?\\s{0,2}"
            + "(?:指导(?:性)?案例\\s{0,2}第?\\s{0,2}\\d{1,4}\\s{0,2}号|检例\\s{0,2}第\\s{0,2}\\d{1,4}\\s{0,2}号)"
    )
    /// The first body heading of a guiding case, which ends its title block.
    static let guidingBodyLine = regex("^[【\\[]?\\s{0,2}(?:关键词|关键字|裁判要点|要旨|基本案情)")
    /// The issuing line under an SPC title: （最高人民法院审判委员会讨论通过 2018年6月20日发布）.
    static let issuanceLine = regex("^[（(][^）)\\n]{0,80}(?:讨论通过|发布|印发)[^）)\\n]{0,40}[）)]$")
    /// What may separate a guiding number from the case name on the same line.
    static let numberSeparators = CharacterSet(charactersIn: "：:，,、 \u{3000}\t）)】〕]")

    // MARK: Published US opinions

    static let notPublished = regex("not\\s+for\\s+(?:official\\s+)?publication|\\bunpublished\\b|non-?precedential|not\\s+precedential",
                                    .caseInsensitive)
    /// A caption line: "In re X" or "X v. Y".
    static let enCaption = regex("^(?:In re\\s+\\S.{1,120}|[A-Z][^\\n]{1,120}?\\s+v\\.?\\s+[A-Z][^\\n]{1,120})$")
    static let reporterCite = regex("\\b\\d{1,4}\\s+(?:[A-Z][A-Za-z.]*\\s?){1,4}\\d?d?\\s+\\d{1,5}\\b")
    /// An opinion heading, a panel line or an authoring line. Case-sensitive: "In our opinion" and "the interests of
    /// justice" are ordinary prose.
    static let opinionHeading = regex(
        "^(?:OPINION|PER CURIAM|MEMORANDUM OPINION|OPINION AND ORDER|MEMORANDUM OPINION AND ORDER|MEMORANDUM AND OPINION"
            + "|OPINION OF THE COURT|OPINION OF THE COURT BY [A-Z .,'\\-]{2,60})[.:]?$"
            + "|^Before:?\\s[^\\n]{1,160}\\bJudges?\\b"
            + "|^[A-Z][A-Za-z.'\\-]{1,30}(?:\\s[A-Z][A-Za-z.'\\-]{1,30}){0,3},\\s(?:Chief\\s|Senior\\s)?"
            + "(?:Circuit\\s|District\\s|Magistrate\\s|Bankruptcy\\s)?Judge[.:]"
            + "|\\bdelivered the opinion of the [Cc]ourt\\b"
    )
    /// A line that only a memo, email, letter, brief or pleading carries. Header fields and salutations are matched at
    /// the start of a line; legends and titles are matched in capitals, as they are printed.
    static let notAnOpinion = regex(
        "^(?:To|TO|From|FROM|Re|RE|Subject|SUBJECT|Cc|CC|Bcc|BCC|Sent|SENT|Attn|ATTN|Attention)\\s{0,3}:"
            + "|^Dear\\s"
            + "|^(?:MEMORANDUM|MEMO)$"
            + "|\\b(?:PRIVILEGED|ATTORNEY[- ]CLIENT|WORK PRODUCT|DRAFT|MEMORANDUM OF LAW|MEMORANDUM OF POINTS AND AUTHORITIES"
            + "|NOTICE OF MOTION|COMPLAINT)\\b"
            + "|(?<!ON )\\bBRIEF\\b"
            + "|^Respectfully submitted"
    )

    static let partyLabels: Set<String> = ["PERSON", "COMPANY"]

    /// The first `n` Unicode scalars, as Python slices code points.
    static func prefix(_ text: String, _ n: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(n))
        return String(scalars)
    }

    static func found(_ re: NSRegularExpression, in text: String) -> NSRange? {
        let range = re.rangeOfFirstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        return range.location == NSNotFound ? nil : range
    }

    /// The document's lines, trimmed, with blank lines dropped.
    static func headLines(_ head: String, limit: Int) -> [String] {
        Array(head.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(limit))
    }

    /// The caption of a published precedent, or nil.
    public static func caption(of text: String) -> String? {
        let head = prefix(text, 3000)
        if let guiding = guidingCaption(head) { return guiding }
        return opinionCaption(head)
    }

    /// The title block of an SPC or SPP guiding case that heads the document, or nil.
    static func guidingCaption(_ head: String) -> String? {
        var heading: [String] = []
        var reachedBody = false
        for line in headLines(head, limit: 8) {
            if found(guidingBodyLine, in: line) != nil {
                reachedBody = true
                break
            }
            heading.append(line)
        }
        guard reachedBody, (1...4).contains(heading.count),
              let numberIndex = heading.firstIndex(where: { found(guidingNumberLine, in: $0) != nil }) else {
            return nil
        }
        // Every line of the block is the number line, the issuing line, or a part of the case name.
        var nameParts: [String] = []
        for (index, line) in heading.enumerated() {
            if index == numberIndex {
                let ns = line as NSString
                let match = found(guidingNumberLine, in: line)!
                let rest = ns.substring(from: match.location + match.length)
                // The name follows the number after a separator, or on another line. A title that runs on from the
                // number ("指导案例24号的适用分析") is about the case, not the case.
                if let first = rest.unicodeScalars.first, !numberSeparators.contains(first) { return nil }
                let name = rest.trimmingCharacters(in: numberSeparators)
                if !name.isEmpty { nameParts.append(name) }
            } else if found(issuanceLine, in: line) != nil {
                continue
            } else {
                nameParts.append(line)
            }
        }
        let name = nameParts.joined()
        guard (4...150).contains(name.unicodeScalars.count), name.hasSuffix("案") else { return nil }
        return heading.joined(separator: "\n")
    }

    /// The caption of a published US opinion: a court header, then the caption, then an opinion heading. Nil for
    /// anything that carries a memo, email, letter, brief or pleading marker near the top.
    static func opinionCaption(_ head: String) -> String? {
        if found(notPublished, in: head) != nil { return nil }
        let lines = headLines(head, limit: 40)
        if lines.contains(where: { found(notAnOpinion, in: $0) != nil }) { return nil }
        for (index, raw) in lines.prefix(25).enumerated() {
            var line = raw
            while let last = line.last, last == "," || last == ";" { line.removeLast() }
            let count = line.unicodeScalars.count
            guard count >= 5, count <= 200, found(enCaption, in: line) != nil, found(reporterCite, in: line) == nil else {
                continue
            }
            let before = lines[..<index]
            let after = lines[(index + 1)...].prefix(15)
            guard before.contains(where: isCourtHeader),
                  after.contains(where: { found(opinionHeading, in: $0) != nil }) else {
                return nil
            }
            return line
        }
        return nil
    }

    /// A heading that names a court: the word COURT (or Court) in a line where every word of four or more letters is
    /// capitalized, as in "UNITED STATES COURT OF APPEALS FOR THE FIFTH CIRCUIT" or "Supreme Court of the United
    /// States". "The Court finds that" is prose.
    static func isCourtHeader(_ line: String) -> Bool {
        guard line.unicodeScalars.count <= 160 else { return false }
        let words = line.split { !$0.isLetter }
        guard words.contains(where: { $0 == "COURT" || $0 == "Court" }) else { return false }
        return words.filter { $0.count >= 4 }.allSatisfy { $0.first?.isUppercase == true }
    }

    // MARK: Matching a value against the caption

    /// True when the caption names `value`. A value with a CJK character is matched as written, with whitespace
    /// ignored (a caption may wrap a name across lines). A Latin-script value must be a whole word sequence of the
    /// caption, case aside, with any run of whitespace between its words.
    public static func caption(_ caption: String, names value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count >= 2 else { return false }
        if trimmed.unicodeScalars.contains(where: isCJK) {
            return compact(caption).contains(compact(trimmed))
        }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return found(re, in: caption) != nil
    }

    /// Lowercased with every whitespace character removed.
    static func compact(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        ))
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    /// (spans to keep redacted, spans released as the precedent's own parties).
    public static func keepParties(text: String, spans: [DocumentSpan], caption: String?)
        -> (kept: [DocumentSpan], released: [DocumentSpan]) {
        guard let caption else { return (spans, []) }
        let ns = text as NSString
        func surface(_ s: DocumentSpan) -> String {
            ns.substring(with: NSRange(location: s.start16, length: s.end16 - s.start16))
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let names = Set(spans.filter { partyLabels.contains($0.span.label) }.map(surface))
        let party = names.filter { self.caption(caption, names: $0) }
        var kept: [DocumentSpan] = [], released: [DocumentSpan] = []
        for s in spans {
            if partyLabels.contains(s.span.label) && party.contains(surface(s)) { released.append(s) } else { kept.append(s) }
        }
        return (kept, released)
    }
}
