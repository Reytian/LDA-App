//
//  SubstitutionStyling.swift
//  LDACore
//
//  The replacement generators behind the non-token output styles.
//
//  - PseudonymGenerator mints natural-language stand-ins (甲公司, 张某,
//    Company A, Person B) that an external AI treats as names rather than
//    markup, so they survive an AI round trip where brace tokens get
//    rewritten. Uniqueness is the caller's contract: the generator advances
//    through its per-type sequence until the isTaken closure clears a
//    candidate, so a pseudonym never collides with another entity's
//    pseudonym or with a string already present in the document.
//
//  - AsteriskMasking renders the lossy masked forms (张*明, 138****5678)
//    used when a redacted document goes to a human reader, not to an AI.
//    Masking is deterministic per surface, so two different surfaces can
//    mask to the same string; the mapping records both and restore refuses
//    the ambiguous ones (flag, never guess).
//
//  The SubstitutionStyle enum itself lives in Domain/CoreTypes.swift because
//  it is part of the persisted Mapping wire format.
//
//  House rules: all comments and strings in English (generated pseudonyms
//  are Chinese by design). No em-dash and no en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Pseudonym generation

/// Mints per-type, per-script natural-language pseudonyms.
///
/// Pure value type: no clock, no IO. Counters advance per (type, script) so
/// the assignment is deterministic in mint order. The caller supplies the
/// isTaken closure; mint keeps advancing until a candidate clears it, so
/// termination requires the blocked set to be finite (it always is: existing
/// replacements plus substrings of the finite document corpus).
public struct PseudonymGenerator {

    /// The writing system a pseudonym is rendered in, chosen per entity from
    /// its surface text so mixed-language documents read naturally.
    enum Script: String {
        case chinese
        case latin
    }

    /// Next candidate index per "TYPE|script" key.
    private var counters: [String: Int] = [:]

    public init() {}

    /// Mint the next free pseudonym for one entity.
    ///
    /// - Parameters:
    ///   - type: the entity type, which selects the naming scheme.
    ///   - surface: the entity's surface text; its script (CJK or Latin)
    ///     selects the Chinese or English variant of the scheme.
    ///   - isTaken: returns true when a candidate must be skipped (already
    ///     used by another entity, or already occurring in the document).
    public mutating func mint(
        type: EntityType,
        surface: String,
        isTaken: (String) -> Bool
    ) -> String {
        let script = Self.script(for: type, surface: surface)
        let key = "\(type.rawValue)|\(script.rawValue)"
        var index = counters[key] ?? 0
        while true {
            let candidate = Self.candidate(type: type, script: script, index: index)
            index += 1
            if !isTaken(candidate) {
                counters[key] = index
                return candidate
            }
        }
    }

    // MARK: Script selection

    /// Emails are Latin by construction; every other type follows the surface.
    static func script(for type: EntityType, surface: String) -> Script {
        if type == .email {
            return .latin
        }
        return containsCJK(surface) ? .chinese : .latin
    }

    /// True when the string contains at least one CJK ideograph.
    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,  // CJK unified ideographs extension A
                 0x4E00...0x9FFF,  // CJK unified ideographs
                 0xF900...0xFAFF:  // CJK compatibility ideographs
                return true
            default:
                return false
            }
        }
    }

    // MARK: Candidate sequences

    /// The ten heavenly stems, the standard Chinese enumeration for parties.
    private static let heavenlyStems = [
        "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"
    ]

    /// Chinese numerals used for the second through eleventh company cycles.
    private static let chineseNumerals = [
        "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"
    ]

    /// Common Chinese surnames used for person placeholders (surname + 某,
    /// the form PRC judgments use). Fifty distinct persons before the
    /// numbered fallback.
    private static let personSurnames = [
        "张", "李", "王", "赵", "刘", "陈", "杨", "黄", "周", "吴",
        "徐", "孙", "马", "朱", "胡", "郭", "何", "高", "林", "罗",
        "郑", "梁", "谢", "宋", "唐", "许", "韩", "冯", "邓", "曹",
        "彭", "曾", "肖", "田", "董", "潘", "袁", "蔡", "蒋", "余",
        "于", "杜", "叶", "程", "苏", "魏", "吕", "任", "卢", "沈"
    ]

    /// Chinese generic labels per type for the 某<label>N fallback scheme.
    private static let chineseGenericLabels: [EntityType: String] = [
        .phone: "电话",
        .bankAccount: "账户",
        .nationalID: "证件",
        .uscc: "代码",
        .date: "日期",
        .amount: "金额"
    ]

    /// English generic labels per type for the "<Label> N" fallback scheme.
    private static let latinGenericLabels: [EntityType: String] = [
        .phone: "Phone",
        .bankAccount: "Account",
        .nationalID: "ID",
        .uscc: "Code",
        .date: "Date",
        .amount: "Amount"
    ]

    /// The index-th candidate of the (type, script) sequence.
    static func candidate(type: EntityType, script: Script, index: Int) -> String {
        switch type {
        case .email:
            // The IETF-reserved example.com keeps the stand-in undeliverable.
            return "contact\(index + 1)@example.com"
        case .company:
            return script == .chinese
                ? chineseCompany(index)
                : "Company \(letterSequence(index))"
        case .person:
            return script == .chinese
                ? chinesePerson(index)
                : "Person \(letterSequence(index))"
        case .address:
            return script == .chinese
                ? "某地址\(letterSequence(index))"
                : "Address \(letterSequence(index))"
        default:
            if script == .chinese {
                guard let label = chineseGenericLabels[type] else {
                    return "某某\(index + 1)"
                }
                return "某\(label)\(index + 1)"
            }
            let label = latinGenericLabels[type] ?? "Item"
            return "\(label) \(index + 1)"
        }
    }

    /// 甲公司 .. 癸公司, then 甲一公司 .. 癸十公司, then 甲11公司 and so on.
    private static func chineseCompany(_ index: Int) -> String {
        let stem = heavenlyStems[index % heavenlyStems.count]
        let cycle = index / heavenlyStems.count
        if cycle == 0 {
            return "\(stem)公司"
        }
        if cycle <= chineseNumerals.count {
            return "\(stem)\(chineseNumerals[cycle - 1])公司"
        }
        return "\(stem)\(cycle)公司"
    }

    /// 张某 .. (fifty surnames) .. then 人物51, 人物52 and so on.
    private static func chinesePerson(_ index: Int) -> String {
        if index < personSurnames.count {
            return "\(personSurnames[index])某"
        }
        return "人物\(index + 1)"
    }

    /// Spreadsheet-style letter sequence: A .. Z, AA, AB, ...
    static func letterSequence(_ index: Int) -> String {
        var remaining = index
        var result = ""
        repeat {
            let scalar = UnicodeScalar(UInt8(65 + remaining % 26))
            result = String(Character(scalar)) + result
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return result
    }
}

// MARK: - Asterisk masking

/// Per-type masking rules for the asterisk output style, following the
/// conventions PRC courts and regulators use for published documents.
public enum AsteriskMasking {

    /// The mask character.
    public static let maskCharacter: Character = "*"

    /// Phone numbers keep the first three and last four characters
    /// (13812345678 becomes 138****5678).
    public static let phoneKeepPrefix = 3
    public static let phoneKeepSuffix = 4

    /// ID numbers keep the first three and last two characters.
    public static let idKeepPrefix = 3
    public static let idKeepSuffix = 2

    /// Generic strings keep this fraction of characters on each side and
    /// mask the middle (0.2 on each side masks the middle 60 percent).
    public static let genericKeepFraction = 0.2

    /// Mask one surface according to its entity type. The result always
    /// differs from the input (at least one character is masked) for any
    /// non-empty surface.
    public static func mask(_ surface: String, type: EntityType) -> String {
        guard !surface.isEmpty else {
            return surface
        }
        switch type {
        case .person:
            return maskPerson(surface)
        case .phone:
            return maskKeepingEnds(
                surface,
                keepPrefix: phoneKeepPrefix,
                keepSuffix: phoneKeepSuffix
            )
        case .nationalID:
            return maskKeepingEnds(
                surface,
                keepPrefix: idKeepPrefix,
                keepSuffix: idKeepSuffix
            )
        default:
            return maskMiddle(surface)
        }
    }

    // MARK: Person names

    /// CJK names follow the PRC convention: keep the first character, mask
    /// the middle, keep the last character of three-or-more character names
    /// (张三 becomes 张*, 张伟明 becomes 张*明). Latin names keep the first
    /// letter of each word and mask the rest (John Smith becomes J*** S****).
    private static func maskPerson(_ surface: String) -> String {
        if PseudonymGenerator.containsCJK(surface) {
            let characters = Array(surface)
            switch characters.count {
            case 1:
                return String(maskCharacter)
            case 2:
                return String(characters[0]) + String(maskCharacter)
            default:
                return String(characters[0])
                    + String(repeating: String(maskCharacter), count: characters.count - 2)
                    + String(characters[characters.count - 1])
            }
        }
        return surface
            .components(separatedBy: " ")
            .map { word -> String in
                let characters = Array(word)
                switch characters.count {
                case 0:
                    return ""
                case 1:
                    return String(maskCharacter)
                default:
                    return String(characters[0])
                        + String(repeating: String(maskCharacter), count: characters.count - 1)
                }
            }
            .joined(separator: " ")
    }

    // MARK: Shared shapes

    /// Keep a fixed prefix and suffix, mask everything between with one mask
    /// character per hidden character. Surfaces too short to keep both ends
    /// AND hide something fall back to the generic middle mask.
    private static func maskKeepingEnds(
        _ surface: String,
        keepPrefix: Int,
        keepSuffix: Int
    ) -> String {
        let characters = Array(surface)
        guard characters.count > keepPrefix + keepSuffix else {
            return maskMiddle(surface)
        }
        let masked = characters.count - keepPrefix - keepSuffix
        return String(characters.prefix(keepPrefix))
            + String(repeating: String(maskCharacter), count: masked)
            + String(characters.suffix(keepSuffix))
    }

    /// Keep genericKeepFraction of the characters on each side and mask the
    /// middle, one mask character per hidden character. Short strings mask
    /// entirely; at least one character is always masked.
    private static func maskMiddle(_ surface: String) -> String {
        let characters = Array(surface)
        let count = characters.count
        let keep = Int(Double(count) * genericKeepFraction)
        let masked = count - keep - keep
        return String(characters.prefix(keep))
            + String(repeating: String(maskCharacter), count: masked)
            + String(characters.suffix(keep))
    }
}
