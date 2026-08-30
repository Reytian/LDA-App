//
//  DocumentTypeClassifier.swift
//  LDACore
//
//  Lightweight document-type classification for prompt routing. Pure Swift
//  keyword and structure heuristics, no model calls: the class only steers
//  which extraction prompt variant the LLM pass uses (PromptStore), so a
//  misclassification costs nothing but emphasis. The generic class is the
//  fallback and keeps the exact base prompt.
//
//  The signals are tuned for Chinese legal documents (the production target),
//  with minimal English coverage (Agreement titles, Dear salutations,
//  Complaint captions). Precedence matters: a judgment ABOUT a contract is a
//  judgment, and a disclosure announcing an agreement is a disclosure, so the
//  classes are tested in that order.
//
//  House rules: all comments and strings in English (keyword literals are
//  Chinese by necessity). No em-dash and no en-dash-as-separator anywhere.
//

import Foundation

// MARK: - DocumentClass

/// The document genres the extraction prompt can specialize for.
public enum DocumentClass: String, Codable, Sendable, CaseIterable {
    /// Court judgments, rulings, and mediation statements (裁判文书).
    case judgment
    /// Complaints and other court filings by parties (起诉状 and kin).
    case complaint
    /// Contracts and agreements (合同/协议).
    case contract
    /// Securities disclosures and corporate announcements (信披/公告).
    case disclosure
    /// Letters (律师函, 询证函, correspondence).
    case letter
    /// Everything else; keeps the base extraction prompt.
    case generic
}

// MARK: - DocumentTypeRoute

/// How the LLM extraction path chooses its prompt variant: automatic
/// classification of the document text, or a caller-forced class.
public enum DocumentTypeRoute: Sendable, Equatable {
    /// Classify the document text and route to that class's prompt variant.
    case auto
    /// Use the given class regardless of the text. `.forced(.generic)`
    /// disables routing entirely and keeps the base prompt.
    case forced(DocumentClass)
}

// MARK: - DocumentTypeClassifier

/// Keyword and structure heuristics over the document head (and a few body
/// anchors). Deterministic and cheap: safe to run on every extraction.
public enum DocumentTypeClassifier {

    /// UTF-16 size of the head window the title heuristics look at. Titles,
    /// captions, and disclosure headers all live well inside this range.
    static let headWindowUTF16 = 1500

    /// Classify a document's text into the routing class.
    public static func classify(_ text: String) -> DocumentClass {
        guard !text.isEmpty else { return .generic }

        let ns = text as NSString
        let head = ns.substring(to: min(headWindowUTF16, ns.length))
        // CJK titles are often letter-spaced for ceremony (民 事 判 决 书), so
        // the head keywords are matched with all whitespace folded out.
        let foldedHead = head.filter { !$0.isWhitespace }
        let lowerHead = head.lowercased()

        if isJudgment(foldedHead: foldedHead, text: text) { return .judgment }
        if isComplaint(foldedHead: foldedHead, lowerHead: lowerHead) { return .complaint }
        if isDisclosure(foldedHead: foldedHead) { return .disclosure }
        if isLetter(foldedHead: foldedHead, lowerHead: lowerHead, text: text) { return .letter }
        if isContract(foldedHead: foldedHead, lowerHead: lowerHead, text: text) { return .contract }
        return .generic
    }

    // MARK: - Per-class signals

    /// Judgment: an adjudication title in the head, or the court's own voice
    /// in the body (only tribunals write 本院认为).
    private static func isJudgment(foldedHead: String, text: String) -> Bool {
        let titleMarks = ["判决书", "裁定书", "调解书", "裁决书"]
        if titleMarks.contains(where: { foldedHead.contains($0) }) {
            return true
        }
        let bodyMarks = ["本院认为", "本院经审理", "本院经审查", "审判长"]
        return bodyMarks.contains(where: { text.contains($0) })
    }

    /// Complaint and kin: a party filing title in the head, or the caption
    /// structure of claims against a named defendant.
    private static func isComplaint(foldedHead: String, lowerHead: String) -> Bool {
        let titleMarks = ["起诉状", "起訴狀", "上诉状", "答辩状", "反诉状", "仲裁申请书"]
        if titleMarks.contains(where: { foldedHead.contains($0) }) {
            return true
        }
        if foldedHead.contains("诉讼请求") && foldedHead.contains("被告") {
            return true
        }
        return lowerHead.contains("complaint")
    }

    /// Disclosure: a securities header or a corporate announcement head.
    private static func isDisclosure(foldedHead: String) -> Bool {
        let headerMarks = ["证券代码", "证券简称", "股票代码", "公告编号", "信息披露"]
        if headerMarks.contains(where: { foldedHead.contains($0) }) {
            return true
        }
        return foldedHead.contains("公告")
            && (foldedHead.contains("董事会") || foldedHead.contains("股份"))
    }

    /// Letter: a 函 title line, a recipient line, or a salutation.
    private static func isLetter(foldedHead: String, lowerHead: String, text: String) -> Bool {
        if let title = firstNonEmptyLine(of: text),
           title.count <= 30,
           title.hasSuffix("函") {
            return true
        }
        if foldedHead.contains("致：") || foldedHead.contains("致:") {
            return true
        }
        if foldedHead.contains("敬启者") || foldedHead.contains("尊敬的") {
            return true
        }
        return lowerHead.contains("dear ")
    }

    /// Contract: an agreement title, the party-label pair, or a contract
    /// number in the head.
    private static func isContract(foldedHead: String, lowerHead: String, text: String) -> Bool {
        if foldedHead.contains("合同") || foldedHead.contains("协议") {
            return true
        }
        if lowerHead.contains("agreement") {
            return true
        }
        return text.contains("甲方") && text.contains("乙方")
    }

    /// The first non-empty line, whitespace-trimmed (the title of most legal
    /// documents).
    private static func firstNonEmptyLine(of text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}
