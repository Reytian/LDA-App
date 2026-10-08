import Foundation

/// LDA-side rule for a published precedent's own parties (round 4, 2026-10-08): a port of `datagen/precedent_rule.py`.
///
/// The user's rule keeps a published precedent's own parties visible, in its title and body. The tagger redacts every
/// name; LDA runs this rule on the whole document. `caption(of:)` is deliberately conservative (nil when in doubt), and
/// LDA should show the caption it found for the user to confirm, or pass a caption the user typed. `keepParties`
/// releases every PERSON or COMPANY span whose text (2+ characters) is in the caption, and every other mention of the
/// same text; witnesses, judges and counsel stay redacted. Offsets are UTF-16 (`DocumentSpan.start16`/`end16`).
public enum PrecedentRule {
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    static let guidingNumber = regex("指导(?:性)?案例\\s*第?\\s*\\d+\\s*号|检例\\s*第\\s*\\d+\\s*号")
    static let guidingBody = regex("【?关键词|【?裁判要点|【?要旨|【?基本案情")
    static let notPublished = regex("not\\s+for\\s+(?:official\\s+)?publication|\\bunpublished\\b|non-?precedential|not\\s+precedential",
                                    .caseInsensitive)
    static let opinionMarker = regex("\\bOPINION\\b|\\bPER CURIAM\\b|delivered the opinion|\\bCircuit Judges?\\b|\\bBefore\\b[^\\n]{0,80}\\bJudges?\\b"
                                     + "|\\bJUSTICE\\b|\\bChief Judge\\b", .caseInsensitive)
    static let enCaption = regex("^(?:In re\\s+\\S.{1,120}|[A-Z][^\\n]{1,120}?\\s+v\\.?\\s+[A-Z][^\\n]{1,120})$")
    static let reporterCite = regex("\\b\\d{1,4}\\s+(?:[A-Z][A-Za-z.]*\\s?){1,4}\\d?d?\\s+\\d{1,5}\\b")
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

    /// The caption of a published precedent, or nil.
    public static func caption(of text: String) -> String? {
        let head = prefix(text, 3000)
        if found(guidingNumber, in: prefix(head, 200)) != nil {
            let ns = head as NSString
            let cut = found(guidingBody, in: head)
            let block = cut.map { ns.substring(to: $0.location) } ?? prefix(head, 600)
            let caption = block.trimmingCharacters(in: .whitespacesAndNewlines)
            return caption.isEmpty ? nil : caption
        }
        if found(notPublished, in: head) != nil || found(opinionMarker, in: head) == nil { return nil }
        for raw in head.split(separator: "\n", omittingEmptySubsequences: false).prefix(25) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = line.last, last == "," || last == ";" { line.removeLast() }
            let count = line.unicodeScalars.count
            if count >= 5, count <= 200, found(enCaption, in: line) != nil, found(reporterCite, in: line) == nil {
                return line
            }
        }
        return nil
    }

    /// (spans to keep redacted, spans released as the precedent's own parties).
    public static func keepParties(text: String, spans: [DocumentSpan], caption: String?)
        -> (kept: [DocumentSpan], released: [DocumentSpan]) {
        guard let caption else { return (spans, []) }
        let ns = text as NSString
        let folded = caption.lowercased()
        func surface(_ s: DocumentSpan) -> String {
            ns.substring(with: NSRange(location: s.start16, length: s.end16 - s.start16))
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let names = Set(spans.filter { partyLabels.contains($0.span.label) }.map(surface))
        let party = names.filter { $0.unicodeScalars.count >= 2 && folded.contains($0) }
        var kept: [DocumentSpan] = [], released: [DocumentSpan] = []
        for s in spans {
            if partyLabels.contains(s.span.label) && party.contains(surface(s)) { released.append(s) } else { kept.append(s) }
        }
        return (kept, released)
    }
}
