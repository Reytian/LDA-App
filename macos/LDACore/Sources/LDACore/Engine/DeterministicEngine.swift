//
//  DeterministicEngine.swift
//  LDACore
//
//  The deterministic detection engine. It runs a battery of NSRegularExpression
//  passes over the input text (as NSString, so all ranges are UTF-16 code-unit
//  offsets matching Span.start and Span.end) and emits candidate Spans for the
//  structured PII types that can be matched and validated without an LLM:
//  EMAIL, PHONE, NATIONAL_ID, USCC, BANK_ACCOUNT, DATE, and AMOUNT.
//
//  PERSON, COMPANY, and ADDRESS are intentionally NOT detected here. Those fuzzy
//  entity types are owned by the LLM engine.
//
//  Priority reflects specificity: checksum-validated structured PII gets the
//  highest priority so that, downstream, SpanMerger resolves any overlap in favor
//  of the deterministic detection. The canonical example is a checksum-valid
//  Chinese national ID (身份证), which must beat any DATE or BANK_ACCOUNT span that
//  happens to cover the same run of digits.
//
//  This engine returns ALL valid matches, including overlapping ones. It does not
//  resolve overlaps itself; SpanMerger does that. The only candidates dropped here
//  are those whose trimmed surface text is a known RoleLabels role label, which
//  must never be redacted.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Detects structured, deterministically verifiable PII via regular expressions
/// and checksum validation. Stateless and Sendable: every call to detect is
/// self-contained and reads no shared mutable state.
public struct DeterministicEngine: Sendable {

    public init() {}

    /// Detect deterministic PII candidates in the given text.
    ///
    /// All offsets in the returned spans are UTF-16 code-unit offsets, computed by
    /// running the patterns over the text as an NSString. Slicing the original
    /// text by [start, end) in UTF-16 space reproduces span.text exactly.
    ///
    /// - Parameter text: The source text to scan.
    /// - Returns: Candidate spans with source .deterministic. Overlaps are kept;
    ///   SpanMerger resolves them later. Role-label candidates are dropped.
    public func detect(_ text: String) -> [Span] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var spans: [Span] = []

        // Order is by descending priority for readability only. The engine keeps
        // every valid match regardless of order; SpanMerger applies priority.
        spans.append(contentsOf: detectNationalID(ns, fullRange))
        spans.append(contentsOf: detectUSCC(ns, fullRange))
        spans.append(contentsOf: detectEmail(ns, fullRange))
        spans.append(contentsOf: detectPhone(ns, fullRange))
        spans.append(contentsOf: detectBankAccount(ns, fullRange))
        spans.append(contentsOf: detectAmount(ns, fullRange))
        spans.append(contentsOf: detectDate(ns, fullRange))

        return spans.filter { !RoleLabels.isRoleLabel($0.text) }
    }

    // MARK: - Priority and confidence constants

    private enum Pri {
        static let nationalID = 100
        static let uscc = 95
        static let email = 80
        static let phone = 60
        static let bankAccount = 50
        static let amount = 45
        static let date = 40
    }

    private enum Conf {
        static let nationalID = 1.0
        static let uscc = 0.98
        static let email = 0.99
        static let phone = 0.9
        static let bankAccount = 0.85
        static let amount = 0.8
        static let date = 0.8
    }

    // MARK: - Generic matcher

    /// Compile a pattern once and enumerate its matches over the given range,
    /// invoking the body with each match. Failures to compile are swallowed and
    /// produce no spans; a bad literal pattern should never crash detection.
    private func enumerate(
        _ pattern: String,
        options: NSRegularExpression.Options = [],
        in ns: NSString,
        range: NSRange,
        body: (NSTextCheckingResult) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }
        regex.enumerateMatches(in: ns as String, options: [], range: range) { match, _, _ in
            guard let match else { return }
            body(match)
        }
    }

    /// Build a span from an NSRange and a type, slicing the surface text out of the
    /// NSString so the text is exactly the UTF-16 substring the offsets describe.
    private func makeSpan(
        _ ns: NSString,
        range: NSRange,
        type: EntityType,
        confidence: Double,
        priority: Int
    ) -> Span {
        let surface = ns.substring(with: range)
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: surface,
            source: .deterministic,
            confidence: confidence,
            priority: priority
        )
    }

    // MARK: - EMAIL

    /// Standard RFC-ish email address. Deliberately practical, not a full RFC 5322
    /// grammar: local part allows common atoms plus dot, the domain is one or more
    /// dot-separated labels, and the TLD is at least two letters.
    private func detectEmail(_ ns: NSString, _ range: NSRange) -> [Span] {
        let pattern = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        var out: [Span] = []
        enumerate(pattern, in: ns, range: range) { match in
            out.append(
                makeSpan(
                    ns,
                    range: match.range,
                    type: .email,
                    confidence: Conf.email,
                    priority: Pri.email
                )
            )
        }
        return out
    }

    // MARK: - PHONE

    /// Phone numbers across three common shapes:
    ///   1. International with explicit country code: +CC followed by 4 to 14
    ///      digits, optionally grouped by spaces or dashes.
    ///   2. Chinese mainland mobile: 1 followed by 3-9 then 9 more digits, with a
    ///      digit boundary so it does not bite into a longer run.
    ///   3. Common US or international grouped forms, for example
    ///      (212) 555-0147 or 212-555-0147.
    ///
    /// Each shape is matched separately and all matches are returned. Overlaps
    /// between shapes are tolerated; SpanMerger collapses them.
    private func detectPhone(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        // International with a leading plus and country code.
        let intl = #"\+\d{1,3}[\s\-]?(?:\d[\s\-]?){4,14}\d"#

        // Chinese mainland mobile, not embedded in a longer digit run.
        let cnMobile = #"(?<!\d)1[3-9]\d{9}(?!\d)"#

        // US or international grouped form: optional area code in parentheses or
        // bare, then 3-4 split by space or dash, not embedded in a longer run.
        let grouped = #"(?<![\d+])\(?\d{3}\)?[\s\-]\d{3,4}[\s\-]\d{4}(?!\d)"#

        for pattern in [intl, cnMobile, grouped] {
            enumerate(pattern, in: ns, range: range) { match in
                out.append(
                    self.makeSpan(
                        ns,
                        range: match.range,
                        type: .phone,
                        confidence: Conf.phone,
                        priority: Pri.phone
                    )
                )
            }
        }
        return out
    }

    // MARK: - NATIONAL_ID (Chinese 身份证, 18 characters)

    /// Chinese resident identity card number: 6-digit region code, 8-digit
    /// birthdate YYYYMMDD, 3-digit sequence, and a final check character that is a
    /// digit or X (case-insensitive).
    ///
    /// A candidate is emitted ONLY when the ISO-7064 mod-11-2 checksum is valid.
    /// This is the key "deterministic wins" anchor at priority 100.
    private func detectNationalID(_ ns: NSString, _ range: NSRange) -> [Span] {
        // 17 digits followed by a digit or X/x, not embedded in a longer run.
        let pattern = #"(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])"#
        var out: [Span] = []
        enumerate(pattern, in: ns, range: range) { match in
            let candidate = ns.substring(with: match.range)
            if Self.isValidChineseID(candidate) {
                out.append(
                    self.makeSpan(
                        ns,
                        range: match.range,
                        type: .nationalID,
                        confidence: Conf.nationalID,
                        priority: Pri.nationalID
                    )
                )
            }
        }
        return out
    }

    /// ISO-7064 mod-11-2 validation for an 18-character Chinese ID.
    ///
    /// Weights are applied to the first 17 digits, summed mod 11, and the result
    /// indexes into "10X98765432" to yield the expected 18th character. The check
    /// character X is treated case-insensitively.
    static func isValidChineseID(_ id: String) -> Bool {
        let chars = Array(id)
        guard chars.count == 18 else { return false }

        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checkCodes = Array("10X98765432")

        var sum = 0
        for index in 0..<17 {
            guard let digit = chars[index].wholeNumberValue, chars[index].isNumber else {
                return false
            }
            // wholeNumberValue would accept non-ASCII digits; the regex already
            // constrained these to ASCII 0-9, but guard defensively anyway.
            guard digit >= 0 && digit <= 9 else { return false }
            sum += digit * weights[index]
        }

        let expected = checkCodes[sum % 11]
        let actual = chars[17]

        if expected == "X" {
            return actual == "X" || actual == "x"
        }
        return actual == expected
    }

    // MARK: - USCC (统一社会信用代码, 18 characters)

    /// Unified Social Credit Code: 18 characters from the GB 32100-2015 alphabet.
    /// Structure is two leading code characters, six digits (the registration
    /// authority body), then ten more code characters. The alphabet excludes the
    /// confusable letters I, O, S, Z.
    ///
    /// Structure match is required. ISO-7064 mod-31 checksum validation is optional
    /// but preferred, so a structurally valid code is emitted; when the checksum is
    /// also valid we keep the full confidence, otherwise we keep the candidate but
    /// at a slightly reduced confidence to reflect structure-only certainty.
    private func detectUSCC(_ ns: NSString, _ range: NSRange) -> [Span] {
        let alpha = "0-9A-HJ-NPQRTUWXY"
        let pattern = "(?<![0-9A-Za-z])[\(alpha)]{2}\\d{6}[\(alpha)]{10}(?![0-9A-Za-z])"
        var out: [Span] = []
        enumerate(pattern, in: ns, range: range) { match in
            let candidate = ns.substring(with: match.range)
            let confidence = Self.isValidUSCC(candidate) ? Conf.uscc : 0.9
            out.append(
                self.makeSpan(
                    ns,
                    range: match.range,
                    type: .uscc,
                    confidence: confidence,
                    priority: Pri.uscc
                )
            )
        }
        return out
    }

    /// ISO-7064 mod-31 (MOD 31-3) checksum validation for an 18-character USCC.
    ///
    /// The GB 32100-2015 alphabet maps each character to a value 0..30. The first
    /// 17 characters are weighted by powers, accumulated mod 31, and the resulting
    /// check character must equal the 18th character.
    static func isValidUSCC(_ code: String) -> Bool {
        let alphabet = Array("0123456789ABCDEFGHJKLMNPQRTUWXY")
        guard code.count == 18 else { return false }

        // Map each character to its index in the alphabet.
        func value(of c: Character) -> Int? {
            return alphabet.firstIndex(of: c)
        }

        // Weights are 3^i mod 31 for i = 0...16, per GB 32100-2015.
        let weights = [1, 3, 9, 27, 19, 26, 16, 17, 20, 29, 25, 13, 8, 24, 10, 30, 28]
        let chars = Array(code)

        var sum = 0
        for index in 0..<17 {
            guard let v = value(of: chars[index]) else { return false }
            sum += v * weights[index]
        }

        let remainder = sum % 31
        let checkValue = (31 - remainder) % 31

        guard checkValue >= 0 && checkValue < alphabet.count else { return false }
        return chars[17] == alphabet[checkValue]
    }

    // MARK: - BANK_ACCOUNT

    /// A run of 12 to 19 digits, optionally grouped by single spaces or dashes
    /// between digit groups. The run must not be embedded in a longer digit
    /// sequence. Counting digits only (not separators) keeps the 12 to 19 bound
    /// meaningful for grouped forms.
    private func detectBankAccount(_ ns: NSString, _ range: NSRange) -> [Span] {
        // A digit, then 11 to 18 more "separator-then-digit" units, bounded so it
        // does not start or end in the middle of a longer digit run.
        let pattern = #"(?<!\d)\d(?:[\s\-]?\d){11,18}(?!\d)"#
        var out: [Span] = []
        enumerate(pattern, in: ns, range: range) { match in
            let surface = ns.substring(with: match.range)
            let digitCount = surface.filter { $0.isNumber }.count
            guard digitCount >= 12 && digitCount <= 19 else { return }
            out.append(
                self.makeSpan(
                    ns,
                    range: match.range,
                    type: .bankAccount,
                    confidence: Conf.bankAccount,
                    priority: Pri.bankAccount
                )
            )
        }
        return out
    }

    // MARK: - DATE

    /// Dates in three shapes:
    ///   1. ISO: YYYY-MM-DD.
    ///   2. Slashed: YYYY/MM/DD or M/D/YYYY style numeric dates.
    ///   3. Chinese: YYYY年M月D日, allowing one- or two-digit month and day.
    private func detectDate(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        let iso = #"(?<!\d)\d{4}-\d{1,2}-\d{1,2}(?!\d)"#
        let slashed = #"(?<!\d)\d{1,4}/\d{1,2}/\d{1,4}(?!\d)"#
        let chinese = #"\d{4}年\d{1,2}月\d{1,2}日"#

        for pattern in [iso, slashed, chinese] {
            enumerate(pattern, in: ns, range: range) { match in
                out.append(
                    self.makeSpan(
                        ns,
                        range: match.range,
                        type: .date,
                        confidence: Conf.date,
                        priority: Pri.date
                    )
                )
            }
        }
        return out
    }

    // MARK: - AMOUNT

    /// Currency amounts in two shapes:
    ///   1. Symbol- or code-prefixed: ¥, $, €, RMB, USD, 人民币 before the number.
    ///   2. Number followed by a Chinese magnitude unit 万 or 亿, optionally with a
    ///      trailing 元.
    ///
    /// Numbers may use thousands separators (commas) and a decimal point. The two
    /// shapes are matched separately so a value like "人民币 1,250,000.50" and a
    /// value like "500万" are both captured.
    private func detectAmount(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        // Prefixed by a currency symbol or code, then a number with optional
        // thousands separators and decimals, then an optional Chinese unit.
        let prefixed =
            #"(?:¥|\$|€|RMB|USD|人民币)\s?\d{1,3}(?:,\d{3})*(?:\.\d+)?(?:[万亿])?(?:元)?"#

        // A number that is suffixed by a Chinese magnitude unit and optional 元.
        let suffixed = #"(?<![\d.])\d{1,3}(?:,\d{3})*(?:\.\d+)?[万亿](?:元)?"#

        for pattern in [prefixed, suffixed] {
            enumerate(
                pattern,
                options: [.caseInsensitive],
                in: ns,
                range: range
            ) { match in
                out.append(
                    self.makeSpan(
                        ns,
                        range: match.range,
                        type: .amount,
                        confidence: Conf.amount,
                        priority: Pri.amount
                    )
                )
            }
        }
        return out
    }
}
