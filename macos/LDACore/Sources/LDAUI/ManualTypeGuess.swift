//
//  ManualTypeGuess.swift
//  LDAUI
//
//  Guesses the entity kind of a text selection so the Protect chooser can
//  preselect it. Evaluation order, first hit wins:
//
//  1. The deterministic engine, with the same rules the scan uses, through
//     DominantEntityType: a detection counts only when it covers at least 90
//     percent of the trimmed selection, so an ID buried in a longer drag does
//     not name the whole selection. SpanSplitter names the parts of a split
//     span with the same rule.
//  2. Cheap word-shape fallbacks: an at sign says EMAIL; a scheme, "www." or a
//     TLD-like suffix says URL; a corporate marker (Chinese or a Latin suffix
//     such as Ltd or GmbH) says COMPANY; two or more address markers (Chinese
//     admin and structural characters, or English way words, with a digit run
//     counting as one more) say ADDRESS.
//  3. PERSON. It is the most common manual addition and the safest wrong guess,
//     because a person token restores identically to any other.
//
//  The guess only preselects; the user always sees it before it applies.
//
//  House rules: English only (marker literals are data, not prose). No
//  em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

enum ManualTypeGuess {

    /// The kind to preselect for a selection. Never fails: PERSON is the floor.
    static func guess(for selection: String) -> EntityType {
        let value = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .person }
        if let structured = DominantEntityType.of(value) { return structured }
        if value.contains("@") { return .email }
        if looksLikeURL(value) { return .url }
        if looksLikeCompany(value) { return .company }
        if looksLikeAddress(value) { return .address }
        return .person
    }

    // MARK: - Shape fallbacks

    private static let urlSuffixes = [".com", ".cn", ".org", ".net", ".io", ".gov", ".edu", ".co", ".hk"]

    private static func looksLikeURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return true
        }
        guard !lower.contains(" ") else { return false }
        return urlSuffixes.contains { suffix in
            lower.hasSuffix(suffix) || lower.contains(suffix + "/")
        }
    }

    private static let chineseCompanyMarkers = [
        "公司", "有限", "集团", "事务所", "银行", "中心", "协会", "合伙"
    ]

    private static let latinCompanySuffixes: Set<String> = [
        "ltd", "ltd.", "limited", "inc", "inc.", "incorporated", "llc", "llp", "lp",
        "co", "co.", "corp", "corp.", "corporation", "company", "plc",
        "gmbh", "ag", "s.a.", "sa", "sarl", "s.a.r.l.", "b.v.", "n.v.",
        "pte", "pte.", "pty", "kk", "k.k."
    ]

    private static func looksLikeCompany(_ value: String) -> Bool {
        if chineseCompanyMarkers.contains(where: { value.contains($0) }) { return true }
        let words = value.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
        guard words.count >= 2, let last = words.last else { return false }
        return latinCompanySuffixes.contains(last)
    }

    private static let chineseAddressMarkers: Set<Character> = Set("省市区县镇乡村路街道巷号楼室栋幢座层")

    private static let latinAddressWords: Set<String> = [
        "road", "street", "avenue", "district", "floor", "room", "lane",
        "boulevard", "suite", "building", "tower", "block", "unit", "drive",
        "highway", "plaza", "county", "province", "city"
    ]

    /// Two or more distinct markers are required so a single way word inside
    /// a name ("Wall Street", "建国路") does not flip the guess; a digit run
    /// alongside a marker counts as one more signal ("Room 1204").
    private static func looksLikeAddress(_ value: String) -> Bool {
        var score = Set(value.filter { chineseAddressMarkers.contains($0) }).count
        let words = value.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        score += Set(words.filter { latinAddressWords.contains($0) }).count
        guard score > 0 else { return false }
        if value.contains(where: { $0.isNumber }) { score += 1 }
        return score >= 2
    }
}
