//
//  CuedValueDetectors.swift
//  LDACore
//
//  Identifiers, account numbers and docket numbers whose shape alone is too
//  common to redact, found by the label written in front of them, plus the
//  few shapes distinctive enough to stand alone.
//
//  Review 2026-11-11 (F8). A passport number (E12345678), a Hong Kong or
//  Taiwan identity card number, a travel-permit number, an ITIN, an SSN
//  written with spaces, a 15-digit legacy resident ID, a short account number
//  and a foreign docket number all stayed in clear, and an IBAN was replaced
//  only from its first long digit run (GB29 NWBK {BANKACCOUNT}). A 15-digit
//  legacy ID was typed BANK_ACCOUNT and an 18-digit one with a wrong check
//  digit after a 身份证 label was typed USCC.
//
//  The label decides. "E12345678" after 护照号码 is a passport number; the
//  same characters after 订单号 are not touched. Distinctive shapes need no
//  label: a Hong Kong identity card number with its bracketed check digit
//  (A123456(7)), a US federal docket number (1:24-cv-01234), a Hong Kong
//  action number (HCA 1234/2023), and an IBAN that passes its mod-97 check.
//
//  Every quantifier is bounded, so each scan is linear in the text.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

extension DeterministicEngine {

    /// Gap between a label and its value: optional spaces and one colon or
    /// hash, ASCII or full width, or a copula ("passport number is", 护照号码
    /// 为, 是). The independent review of F8 found "passport number is
    /// X12345678" left in clear.
    private static let labelGap = #"[ \t　]{0,2}(?:[:：#]|(?:is|was)(?=[ \t　])|为|是)?[ \t　]{0,2}"#

    func detectCuedValues(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []
        func emit(_ range: NSRange, _ type: EntityType, _ confidence: Double, _ priority: Int) {
            guard range.location != NSNotFound, range.length > 0 else { return }
            out.append(makeSpan(ns, range: range, type: type, confidence: confidence, priority: priority))
        }

        // Passports, travel permits, Hong Kong, Macau and Taiwan identity cards.
        let documentLabels = "(?:护照(?:号码|号)?|(?:往来)?港澳通行证(?:号码|号)?|(?:往来)?台湾通行证(?:号码|号)?"
            + "|香港身份证(?:号码|号)?|澳门身份证(?:号码|号)?|台湾身[分份]证(?:号码|号|字号)?"
            + #"|passport(?:\s{1,2}(?:no\.?|number|#))?|travel\s{1,2}document(?:\s{1,2}(?:no\.?|number))?"#
            + #"|HKID(?:\s{1,2}(?:no\.?|number))?)"#
        let documentNumber = #"([A-Z]{1,2}\d{6,9}(?:\([0-9A]\))?)(?![A-Za-z0-9])"#
        enumerate(documentLabels + Self.labelGap + documentNumber, options: [.caseInsensitive], in: ns, range: range) {
            emit($0.range(at: 1), .nationalID, 0.9, Pri.nationalID)
        }
        // A Hong Kong identity card number carries its check digit in brackets.
        enumerate(#"(?<![A-Za-z0-9])[A-Z]{1,2}\d{6}\([0-9A]\)"#, in: ns, range: range) {
            emit($0.range, .nationalID, 0.9, Pri.nationalID)
        }

        // A mainland resident ID after its label: the 15-digit legacy form, or
        // 18 characters whose check digit is wrong (a typo still identifies).
        let residentLabels = "(?:居民身份证|公民身份号码|身份证|身分证|身份号码)(?:号码|号)?"
        enumerate(residentLabels + Self.labelGap + #"(\d{17}[0-9Xx]|\d{15})(?![0-9A-Za-z])"#, in: ns, range: range) {
            emit($0.range(at: 1), .nationalID, 0.95, Pri.nationalID)
        }

        // US taxpayer numbers after their label.
        enumerate(#"(?<![A-Za-z])ITIN"# + Self.labelGap + #"(9\d{2}[- ]?\d{2}[- ]?\d{4})(?!\d)"#, in: ns, range: range) {
            emit($0.range(at: 1), .nationalID, 0.9, Pri.usSSN)
        }
        let ssnLabels = #"(?<![A-Za-z])(?:SSN|social\s{1,2}security(?:\s{1,2}(?:no\.?|number))?)"#
        enumerate(ssnLabels + Self.labelGap + #"(\d{3}[- ]?\d{2}[- ]?\d{4})(?!\d)"#, options: [.caseInsensitive], in: ns, range: range) { match in
            let digits = ns.substring(with: match.range(at: 1)).filter(\.isNumber)
            let hyphenated = "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(2))-\(digits.suffix(4))"
            guard Self.isValidUSSSN(hyphenated) else { return }
            emit(match.range(at: 1), .nationalID, 0.9, Pri.usSSN)
        }

        // Short account numbers after their label; twelve digits and more are
        // the unlabelled BANK_ACCOUNT rule's.
        let accountLabels = "(?:银行账号|银行帐号|账号|帐号|账户|帐户|卡号|"
            + #"account\s{1,2}(?:no\.?|number|#)|acct\.?\s{0,2}(?:no\.?|#))"#
        enumerate(accountLabels + Self.labelGap + #"(\d{6,11})(?!\d)"#, options: [.caseInsensitive], in: ns, range: range) {
            emit($0.range(at: 1), .bankAccount, 0.85, Pri.bankAccount)
        }

        // IBAN: country, check digits, then up to 30 characters, validated by
        // mod 97 on the longest prefix that passes.
        enumerate(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Za-z0-9])"#, in: ns, range: range) { match in
            if let valid = Self.longestValidIBAN(ns, match.range) {
                emit(valid, .bankAccount, 0.95, Pri.bankAccount)
            }
        }

        // Docket numbers. A US federal number and a Hong Kong action number
        // stand alone; anything else needs its label.
        enumerate(#"(?<![\w:])\d{1,2}:\d{2}-[a-z]{2,4}-\d{3,6}(?:-[A-Z]{1,4})?(?![\w-])"#, in: ns, range: range) {
            emit($0.range, .caseNumber, 0.95, Pri.caseNumber)
        }
        let hongKongCourts = "HCA|HCMP|HCCW|HCAL|HCB|HCCT|HCPI|HCMA|HCCC|HCAJ|HCMC|CACV|CACC|CAMP|FACV|FACC|FAMV|FAMC"
            + "|DCCJ|DCPI|DCEC|DCMP|DCCC|LBTC|CAAR|FCMC"
        enumerate(#"(?<![A-Za-z])(?:"# + hongKongCourts + #")\s{0,2}\d{1,6}/\d{4}(?!\d)"#, in: ns, range: range) {
            emit($0.range, .caseNumber, 0.95, Pri.caseNumber)
        }
        let docketLabels = #"(?<![A-Za-z])(?:(?:case|index|docket|cause|claim|appeal|petition|civil\s{1,2}action|C\.A\.)"#
            + #"\s{1,2}(?:no\.?|number|#)?|no\.)"#
        let docketValue = #"([A-Z]{0,3}-?\d{1,7}(?:[-/:][A-Za-z0-9]{1,6}){1,4})(?![\w/-])"#
        enumerate(docketLabels + #"\s{0,2}"# + docketValue, options: [.caseInsensitive], in: ns, range: range) {
            emit($0.range(at: 1), .caseNumber, 0.9, Pri.caseNumber)
        }
        return out
    }

    /// The longest prefix of the IBAN-shaped run at `range` (spaces ignored)
    /// that passes the mod-97 check, at least 15 characters long.
    static func longestValidIBAN(_ ns: NSString, _ range: NSRange) -> NSRange? {
        let raw = ns.substring(with: range)
        var end = raw.count
        let characters = Array(raw)
        while end > 0 {
            let candidate = String(characters[..<end])
            let compact = candidate.filter { !$0.isWhitespace }
            if compact.count >= 15, isValidIBAN(compact) {
                return NSRange(location: range.location, length: (candidate as NSString).length)
            }
            // Drop the last group (and the space before it).
            guard let space = candidate.lastIndex(of: " ") else { break }
            end = candidate.distance(from: candidate.startIndex, to: space)
        }
        return nil
    }

    /// ISO 13616 check: move the first four characters to the end, letters to
    /// numbers (A = 10), and the whole number mod 97 must be 1.
    static func isValidIBAN(_ iban: String) -> Bool {
        let upper = iban.uppercased()
        guard upper.count >= 15, upper.count <= 34, upper.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return false
        }
        let rearranged = upper.dropFirst(4) + upper.prefix(4)
        var remainder = 0
        for character in rearranged {
            let value = character.isNumber ? Int(String(character))! : Int(character.asciiValue! - 55)
            for digit in String(value) {
                remainder = (remainder * 10 + Int(String(digit))!) % 97
            }
        }
        return remainder == 1
    }
}
