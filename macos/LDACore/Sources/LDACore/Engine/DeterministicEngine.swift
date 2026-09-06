//
//  DeterministicEngine.swift
//  LDACore
//
//  The deterministic detection engine. It runs a battery of NSRegularExpression
//  passes over the input text (as NSString, so all ranges are UTF-16 code-unit
//  offsets matching Span.start and Span.end) and emits candidate Spans for the
//  structured PII types that can be matched and validated without an LLM:
//  EMAIL, PHONE, NATIONAL_ID, USCC, BANK_ACCOUNT, DATE, AMOUNT, CASE_NUMBER,
//  LICENSE_PLATE, WECHAT_ID, URL, SEAL, and the high-precision Chinese
//  street-address shape of ADDRESS. The four types added for the 2026-08-29
//  roadmap (CASE_NUMBER, LICENSE_PLATE, WECHAT_ID, URL) and SEAL live in
//  StructuredEntityDetectors.swift; this file remains the ordering and
//  priority authority.
//
//  PERSON and COMPANY are intentionally NOT detected here; those fuzzy entity
//  types are owned by the LLM engine. ADDRESS is split by shape: Chinese street
//  addresses (admin division + road + street number) follow a structure precise
//  enough for a deterministic pattern, and live recall testing on 2026-08-27
//  showed the v2 model does not extract them, so this engine owns that shape.
//  All other address forms (English, fuzzy, road-only) remain LLM territory.
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
        spans.append(contentsOf: detectUSSocialSecurityNumber(ns, fullRange))
        spans.append(contentsOf: detectUSCC(ns, fullRange))
        spans.append(contentsOf: detectCaseNumber(ns, fullRange))
        spans.append(contentsOf: detectLicensePlate(ns, fullRange))
        spans.append(contentsOf: detectEmail(ns, fullRange))
        spans.append(contentsOf: detectURL(ns, fullRange))
        spans.append(contentsOf: detectPhone(ns, fullRange))
        spans.append(contentsOf: detectWechatID(ns, fullRange))
        spans.append(contentsOf: detectSeal(ns, fullRange))
        spans.append(contentsOf: detectChineseAddress(ns, fullRange))
        spans.append(contentsOf: detectBankAccount(ns, fullRange))
        spans.append(contentsOf: detectAmount(ns, fullRange))
        spans.append(contentsOf: detectDate(ns, fullRange))

        return spans.filter { !RoleLabels.isRoleLabel($0.text) }
    }

    // MARK: - Priority and confidence constants

    /// Overlap-resolution priorities for every deterministic type, kept in one
    /// table so relative order is auditable. CASE_NUMBER and LICENSE_PLATE sit
    /// just below the checksum-validated types because their structure is
    /// nearly as unambiguous. URL sits above PHONE so a phone-shaped digit run
    /// inside a URL path resolves to the URL. WECHAT_ID sits below EMAIL so a
    /// local part never beats the email that contains it. Internal (not
    /// private) because the detectors in StructuredEntityDetectors.swift read
    /// this table.
    enum Pri {
        static let nationalID = 100
        static let uscc = 95
        // US SSN sits below the two CHECKSUMMED identifiers and above
        // CASE_NUMBER: its nine digits have structural rules but no check
        // digit, so it must not outrank a value the engine can actually
        // verify, yet it must beat PHONE and DATE, which would otherwise
        // swallow "123-45-6789" as a phone-shaped run.
        static let usSSN = 92
        static let caseNumber = 90
        static let licensePlate = 85
        static let email = 80
        static let url = 75
        static let phone = 60
        static let wechatID = 58
        // SEAL sits between WECHAT_ID and ADDRESS: its anchor is a closed
        // literal set and its payload must end in an organization suffix, so
        // it is more anchored than the address walk, and any deterministic
        // priority already beats the LLM COMPANY spans it overlaps.
        static let seal = 56
        static let address = 55
        static let bankAccount = 50
        static let amount = 45
        static let date = 40
    }

    /// Detection confidences per type. Internal for the same reason as Pri.
    enum Conf {
        static let nationalID = 1.0
        static let uscc = 0.98
        // Structure only, no checksum: never 1.0.
        static let usSSN = 0.9
        static let caseNumber = 0.99
        static let licensePlate = 0.95
        static let email = 0.99
        static let url = 0.9
        static let phone = 0.9
        static let wechatID = 0.9
        static let seal = 0.9
        static let address = 0.9
        static let bankAccount = 0.85
        static let amount = 0.8
        static let date = 0.8
    }

    // MARK: - Generic matcher

    /// Compile a pattern once and enumerate its matches over the given range,
    /// invoking the body with each match. Failures to compile are swallowed and
    /// produce no spans; a bad literal pattern should never crash detection.
    /// Internal (not private) so the detectors in
    /// StructuredEntityDetectors.swift share it.
    func enumerate(
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
    /// Internal (not private) so the detectors in
    /// StructuredEntityDetectors.swift share it.
    func makeSpan(
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
    ///   1. International with explicit country code: +CC followed by 2 to 5 groups
    ///      of digits, grouped by spaces, dots, or dashes, with an optional
    ///      parenthesized area code. The +CC is kept as part of the match.
    ///   2. Chinese mainland mobile: 1 followed by 3-9 then 9 more digits, with a
    ///      digit boundary so it does not bite into a longer run.
    ///   3. Common US or international grouped forms, for example
    ///      (212) 555-0147, 212-555-0147, 212.555.0147, or (212)555-0147. The
    ///      separators include the dot, and a parenthesized area code may have no
    ///      separator before the next group, while a bare area code still requires
    ///      a separator so section/version/date/ratio strings are not matched.
    ///
    /// Each shape is matched separately and all matches are returned. Overlaps
    /// between shapes are tolerated; SpanMerger collapses them and keeps the longer
    /// span (so the +CC form wins over its inner grouped match).
    private func detectPhone(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        // International: keep the full +CC; allow the dot as a group separator and
        // an optional parenthesized area code.
        let intl = #"\+\d{1,3}[\s.\-]?(?:\(?\d{2,4}\)?[\s.\-]?){2,5}\d{2,4}"#

        // Chinese mainland mobile, not embedded in a longer digit run.
        let cnMobile = #"(?<!\d)1[3-9]\d{9}(?!\d)"#

        // US or international grouped form, two alternatives. A parenthesized area
        // code may have NO following separator; a bare area code keeps a required
        // separator. The dot is now an allowed separator. Neither alternative may
        // be embedded in a longer digit run.
        let grouped = #"(?<![\d+])\(\d{3}\)[\s.\-]?\d{3,4}[\s.\-]\d{4}(?!\d)|(?<![\d+])\d{3}[\s.\-]\d{3,4}[\s.\-]\d{4}(?!\d)"#

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

    // MARK: - NATIONAL_ID (US Social Security number, 9 digits)

    /// United States Social Security number in its canonical hyphenated form,
    /// AAA-GG-SSSS. Emitted as NATIONAL_ID, the same type as 身份证, because
    /// that is what it is to a reviewer: a government identifier that must
    /// never leave the document. Added when the product owner brought US
    /// documents into scope; LLMExtractor.keptTypes stops discarding
    /// model-reported NATIONAL_ID values in the same change.
    ///
    /// There is no check digit, so the filter is the SSA's own structural
    /// rules and nothing more: an area of 000 or 666 or 900 and above is never
    /// issued, a group of 00 is never issued, a serial of 0000 is never
    /// issued. Anything passing those is emitted; the reviewer sees it as a
    /// typed candidate and can reject it. The unhyphenated nine-digit form is
    /// deliberately NOT matched: without the hyphens it is indistinguishable
    /// from a bank account fragment or a case number, and a false NATIONAL_ID
    /// at priority 92 would outrank the correct BANK_ACCOUNT.
    ///
    /// The lookbehind and lookahead exclude a hyphen as well as alphanumerics,
    /// so a longer hyphenated run such as a phone number written 555-123-45-6789
    /// cannot yield an SSN from its tail. Every quantifier is bounded.
    private func detectUSSocialSecurityNumber(_ ns: NSString, _ range: NSRange) -> [Span] {
        let pattern = #"(?<![0-9A-Za-z-])\d{3}-\d{2}-\d{4}(?![0-9A-Za-z-])"#
        var out: [Span] = []
        enumerate(pattern, in: ns, range: range) { match in
            let candidate = ns.substring(with: match.range)
            if Self.isValidUSSSN(candidate) {
                out.append(
                    self.makeSpan(
                        ns,
                        range: match.range,
                        type: .nationalID,
                        confidence: Conf.usSSN,
                        priority: Pri.usSSN
                    )
                )
            }
        }
        return out
    }

    /// The SSA structural rules for a hyphenated SSN. Pure, so the tests can
    /// pin each rule on its own.
    static func isValidUSSSN(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 3, parts[1].count == 2, parts[2].count == 4,
              let area = Int(parts[0]), let group = Int(parts[1]), let serial = Int(parts[2])
        else { return false }
        if area == 0 || area == 666 || area >= 900 { return false }
        if group == 0 { return false }
        if serial == 0 { return false }
        return true
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

    // MARK: - ADDRESS (Chinese street address)

    /// High-precision Chinese street addresses, added after live recall testing
    /// on 2026-08-27 showed the v2 model does not extract them (verified on
    /// both the pre-fence and fenced builds, so it is model recall, not a
    /// prompt regression).
    ///
    /// The shape is one or more administrative or area segments (name + a
    /// suffix such as 省 市 区 县 街道 园区), then a road (name + 路 街 道 巷),
    /// an optional Shanghai-style lane (N弄), a required street number (N号),
    /// and optional building, unit, floor, and room suffixes led by digits or
    /// building letters (3号楼, 2单元, 801室, A座).
    ///
    /// Detection runs in two stages, and the split is a correctness requirement
    /// rather than a style choice. Expressing the whole shape as one regular
    /// expression means a quantified name run nested inside a quantified segment
    /// chain, and a Chinese character can serve as both a name character and an
    /// administrative suffix (市). A run of such characters therefore partitions
    /// exponentially many ways, and on text that never completes the shape every
    /// partition is explored: a 200-character run of 市 did not finish in three
    /// minutes. Documents here are untrusted, so that is a hang. Instead:
    ///
    ///   1. A regex matches only the unambiguous core, road through street
    ///      number. Every quantifier is bounded and singly nested, so the scan
    ///      is linear in the length of the text.
    ///   2. The left boundary is then walked backwards in code over the
    ///      characters that can belong to an address, bounded to
    ///      maxAddressPrefixLength characters.
    ///
    /// Precision choices, each covered by a test:
    ///   - The road name excludes boundary characters, so it cannot absorb
    ///     administrative text and leave the walk starting mid-name. It is also
    ///     allowed to be EMPTY, because a road marker often follows a boundary
    ///     character directly (小湾村路, 建国门外街道建国路) and demanding a name
    ///     there loses the address entirely.
    ///   - The walk is a bounded scan rather than a segment-by-segment parse.
    ///     Administrative names legitimately contain and abut boundary
    ///     characters (青岛市市南区, 建国门外街道), and a parse that demands a name
    ///     character before every boundary dead-ends on exactly those, which
    ///     costs whole addresses. A scan cannot know where a place name starts
    ///     without a lexicon, so the left edge is pinned by punctuation, by a
    ///     prose connector, or by the length bound instead.
    ///   - The walk stops at the connector characters that introduce an address
    ///     in legal prose (注册地址为, 住所, 位于), so a label is never absorbed.
    ///   - A true administrative marker (省 市 区 县 镇 乡 村 州 盟 旗) must
    ///     appear in the walked prefix. A bare road and number with no such
    ///     context (沿建国路88号) stays LLM territory.
    ///   - A street number or a lane number is required, so a city mention with
    ///     no road (本协议适用上海市有关法规) and regulation numbers
    ///     (上海市人民政府令第52号) never match.
    ///   - Building tails must be led by digits or A-Z/甲乙丙丁, so the pattern
    ///     never swallows following prose through a loose 楼/室 suffix.
    private func detectChineseAddress(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []
        enumerate(Self.chineseAddressCorePattern, in: ns, range: range) { match in
            guard !self.isGenericWay(ns, roadRange: match.range(at: 1)) else {
                // A footpath or a tunnel is not a street address.
                return
            }
            guard let start = self.addressPrefixStart(ns, coreStart: match.range.location) else {
                // A core with no administrative context is not an address.
                return
            }
            let full = NSRange(location: start, length: match.range.location + match.range.length - start)
            out.append(
                self.makeSpan(
                    ns,
                    range: full,
                    type: .address,
                    confidence: Conf.address,
                    priority: Pri.address
                )
            )
        }
        return out
    }

    /// Characters that end an administrative or area segment. The road name
    /// excludes these so a core match never starts inside administrative text.
    /// Road markers are included because area names ending in one
    /// (建国门外街道) sit between the administrative segments and the road.
    private static let segmentBoundaryCharacters = "省市区县镇乡村州盟旗路街道巷"

    /// Administrative markers proper. At least one must appear in the walked
    /// prefix for the core to count as an address.
    private static let adminMarkers: Set<Character> = Set("省市区县镇乡村州盟旗")

    /// Characters that never belong to a place name, so the walk stops at them.
    /// These are the prose connectors that introduce an address in legal
    /// Chinese (注册地址为, 住所, 位于, 系).
    private static let nameStopCharacters = "为于在是的系址所住处至及之等从由"

    /// Number and unit markers. A road name never contains one, so excluding
    /// them stops a greedy road name from reaching back across a preceding
    /// number or unit word.
    private static let structuralMarkerCharacters = "号弄线座楼室栋幢层"

    /// The unambiguous core of a Chinese street address: the road, then a lane
    /// or a street number, then any unit tail. Built once, because detect runs
    /// per chunk.
    ///
    /// The road is a capture group so the generic-way filter can inspect it.
    /// Its name characters are CJK minus the boundary characters (which keeps
    /// the match from starting inside administrative text), minus the prose
    /// connectors, and minus the structural markers (which keeps a greedy name
    /// from reaching back across a preceding number or unit word, so
    /// 地铁2号线碧波路690号 starts the span at 碧波路 rather than at 号线). The
    /// name may be empty, because a road marker often follows a boundary
    /// character directly (小湾村路).
    ///
    /// The trailing bare building letter (690号甲, the convention for No. 690-A)
    /// is taken only when it does not start a party label, since 甲方 and 乙方
    /// are everywhere in Chinese contracts. It sits after the unit tail so a
    /// letter belonging to a unit (甲栋) is still read as one.
    private static let chineseAddressCorePattern: String = {
        let digit = #"[0-9０-９]"#
        let roadName = #"(?:(?!["# + segmentBoundaryCharacters
            + nameStopCharacters + structuralMarkerCharacters + #"])[一-龥])"#
        let road = "(" + roadName + "{0,12}" + #"(?:路|街|道|巷))"#
        let number = "(?:" + digit + "{1,5}弄(?:" + digit + "{1,5}号)?|" + digit + "{1,5}号)"
        let units = "(?:[0-9０-９A-Za-z甲乙丙丁]{1,5}(?:号楼|单元|栋|幢|座|楼|层|室))*"
        let buildingLetter = #"(?:[甲乙丙丁](?!方))?"#
        return road + number + units + buildingLetter
    }()

    /// How far left the walk may reach. Real administrative prefixes run long
    /// (内蒙古自治区呼和浩特市赛罕区 is 13 characters, 郑州航空港经济综合实验区
    /// is 12), and this also bounds how much prose can be absorbed when nothing
    /// separates the address from the sentence around it.
    private static let maxAddressPrefixLength = 30

    /// How far left to look for administrative context when the contiguous walk
    /// is interrupted. Larger than the walk bound because it only decides
    /// whether the core is an address, never where the span starts.
    private static let maxAddressContextLength = 40

    /// Generic ways: a road token ending in one of these is infrastructure or a
    /// facility, not a street address. Real road types that end in the same
    /// character (大道, 公路 as in the Shanghai address 沪南公路2000号) are
    /// deliberately absent, and so is 街道, which is also an administrative
    /// unit and can carry a street number.
    private static let genericWayWords = [
        "人行道", "车行道", "机动车道", "非机动车道", "车道", "隧道", "通道", "甬道",
        "跑道", "河道", "轨道", "便道", "匝道", "引道", "坡道", "廊道", "管道",
        "渠道", "步道", "过道", "走道",
    ]

    /// True when the matched road token names a generic way rather than a
    /// street. The check is a suffix match because the road name is greedy and
    /// absorbs whatever precedes it (地下停车库机动车道).
    private func isGenericWay(_ ns: NSString, roadRange: NSRange) -> Bool {
        guard roadRange.location != NSNotFound else { return false }
        let token = ns.substring(with: roadRange)
        return Self.genericWayWords.contains { token.hasSuffix($0) }
    }

    /// Walk backwards from a core match to the start of the address, returning
    /// nil when there is no administrative context anywhere nearby.
    ///
    /// Two questions are answered separately, and conflating them was a bug that
    /// dropped whole addresses. Where the span STARTS is decided by a contiguous
    /// scan: it takes every preceding character that can belong to a Chinese
    /// address and stops at the first one that cannot, which is any non-CJK
    /// character (punctuation, a space, a Latin letter, a digit) or a prose
    /// connector. WHETHER the core is an address is decided by looking for an
    /// administrative marker, and that look is allowed to cross the interruption
    /// the contiguous scan stopped at, because a digit or a letter routinely
    /// sits between the district and the road (地铁2号线碧波路690号, A座建国路88号)
    /// and demanding an unbroken run there left the road and street number in
    /// cleartext.
    ///
    /// When the marker is only reachable across an interruption, the span is the
    /// core alone. The interrupted text is not a place name, so absorbing it
    /// would redact prose, and the road with its street number is the
    /// identifying part.
    ///
    /// Both scans are bounded by a constant, which is what keeps detection
    /// linear. A newline stops the context look so an address never borrows
    /// context from another paragraph.
    ///
    /// A supplementary-plane character ends the contiguous scan rather than
    /// being consumed: Unicode.Scalar of a lone surrogate code unit is nil, so
    /// the boundary can never land inside a surrogate pair and break offset
    /// integrity.
    private func addressPrefixStart(_ ns: NSString, coreStart: Int) -> Int? {
        var left = coreStart
        var sawAdminMarker = false
        var walked = 0

        while walked < Self.maxAddressPrefixLength, left > 0 {
            guard let scalar = Unicode.Scalar(ns.character(at: left - 1)),
                  scalar.value >= 0x4E00, scalar.value <= 0x9FA5 else { break }

            let character = Character(scalar)
            guard !Self.nameStopCharacters.contains(character) else { break }

            left -= 1
            walked += 1
            sawAdminMarker = sawAdminMarker || Self.adminMarkers.contains(character)
        }

        if sawAdminMarker {
            return left
        }
        return hasAdminContext(ns, before: coreStart) ? coreStart : nil
    }

    /// Look for an administrative marker to the left of a core match, crossing
    /// characters the contiguous scan would stop at. Bounded by
    /// maxAddressContextLength and by the start of the line.
    private func hasAdminContext(_ ns: NSString, before coreStart: Int) -> Bool {
        let lowerBound = max(0, coreStart - Self.maxAddressContextLength)
        var index = coreStart

        while index > lowerBound {
            index -= 1
            guard let scalar = Unicode.Scalar(ns.character(at: index)) else { continue }
            if scalar == "\n" || scalar == "\r" { return false }
            if Self.adminMarkers.contains(Character(scalar)) { return true }
        }
        return false
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

    /// Dates across numeric, Chinese, and English written forms:
    ///   - Numeric: ISO YYYY-MM-DD, slashed YYYY/MM/DD or M/D/YYYY, and European
    ///     dotted DD.MM.YYYY.
    ///   - Chinese: YYYY年M月D日, allowing one- or two-digit month and day.
    ///   - English month-first: "January 5, 2026", "Jan. 5th 2026".
    ///   - English day-first: "5 January 2026", "5th Jan 2026".
    ///   - English month-and-year: "January 2026", "Sep. 2027".
    ///   - English legal recital: "5th day of January, 2026", "5th of January 2026".
    ///
    /// Every form that carries a day REQUIRES a four-digit year, and the dotted
    /// form does too, so bare month words (including "may", "march", "august") and
    /// clause references like "5.1.2" are never matched. Two-digit years are
    /// deliberately out of scope to keep precision high; DATE is deterministic-only,
    /// so the design trades recall on common written dates against false positives
    /// on prose.
    ///
    /// All patterns run case-insensitively. The numeric and Chinese shapes contain
    /// no ASCII letters, so the flag is a no-op for them and affects only the
    /// English month names. Month-and-year deliberately overlaps the day-bearing
    /// English forms (it sub-matches "January 2026" inside "5 January 2026");
    /// SpanMerger keeps the longer span, so the day is never dropped.
    private func detectDate(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        let iso = #"(?<!\d)\d{4}-\d{1,2}-\d{1,2}(?!\d)"#
        let slashed = #"(?<!\d)\d{1,4}/\d{1,2}/\d{1,4}(?!\d)"#
        let dotted = #"(?<!\d)\d{1,2}\.\d{1,2}\.\d{4}(?!\d)"#
        // A Chinese date tolerates whitespace around its unit characters, the
        // way every English form below does. Converting a PDF to text routinely
        // inserts those spaces, and a Chinese editor inserts the ideographic
        // space (U+3000), so the gap class is the Unicode space separators plus
        // the tab. Two deliberate limits: each run is BOUNDED, because an
        // unbounded whitespace quantifier beside another quantifier is the
        // backtracking shape this engine has stalled on before, and newlines
        // are excluded, so a date can never span a line break (a span that did
        // would have to be split again before it could be written back).
        let gap = #"[\p{Zs}\t]{0,4}"#
        let chinese = #"\d{4}"# + gap + #"年"# + gap + #"\d{1,2}"# + gap
            + #"月"# + gap + #"\d{1,2}"# + gap + #"日"#

        // English month names: full names, three-letter abbreviations, the "Sept"
        // variant, and an optional trailing period. The day takes an optional
        // ordinal suffix and the comma is optional.
        let month = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"#
        let ordinal = #"(?:st|nd|rd|th)?"#
        let monthFirst = #"(?<![A-Za-z])"# + month + #"\.?\s+\d{1,2}"# + ordinal + #",?\s+\d{4}(?!\d)"#
        let dayFirst = #"(?<!\d)\d{1,2}"# + ordinal + #"\s+"# + month + #"\.?,?\s+\d{4}(?!\d)"#
        let monthYear = #"(?<![A-Za-z])"# + month + #"\.?\s+\d{4}(?!\d)"#
        let dayOf = #"(?<!\d)\d{1,2}"# + ordinal + #"\s+(?:day\s+of|of)\s+"# + month + #"\.?,?\s+\d{4}(?!\d)"#

        for pattern in [iso, slashed, dotted, chinese, monthFirst, dayFirst, monthYear, dayOf] {
            enumerate(pattern, options: [.caseInsensitive], in: ns, range: range) { match in
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
    ///   1. Symbol- or code-prefixed: a currency symbol (¥ ￥ $ € £), the word
    ///      人民币, or a major ISO 4217 code (GBP, USD, EUR, CNY, ...) before
    ///      the number. Added for the 2026-08-27 live recall gap where
    ///      "GBP 45,000.00" stayed in cleartext.
    ///   2. Number followed by a Chinese magnitude unit 万 or 亿, optionally with a
    ///      trailing 元.
    ///
    /// Numbers may be comma-grouped with a decimal dot, dot-grouped with a
    /// decimal comma (European style), or a plain digit run with one decimal
    /// separator. The two shapes are matched separately so a value like
    /// "人民币 1,250,000.50" and a value like "500万" are both captured.
    ///
    /// Precision choices, each covered by a test:
    ///   - ISO codes that read as English words in prose (ALL, TRY, TOP, CUP,
    ///     PEN, COP, GEL, SAR, PHP, RON, and the verbs MOP and RUB) are
    ///     deliberately omitted because the pattern runs case-insensitively;
    ///     including them would redact phrases like "TRY 3 times", "PHP 8.1",
    ///     or "mop 3 floors".
    ///   - A letter must not immediately precede a code, so USD never anchors
    ///     inside a longer token such as BUSD.
    private func detectAmount(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        // Currency designators. Symbols take no boundary (US$ is a valid
        // prefix); code words require a non-letter on their left.
        let symbols = #"[¥￥$€£]"#
        let codes = #"(?<![A-Za-z])(?:人民币|RMB|USD|EUR|GBP|CNY|JPY|HKD|TWD|SGD|MYR|THB|IDR|VND|INR|KRW|AUD|NZD|CAD|CHF|SEK|NOK|DKK|PLN|CZK|HUF|BGN|UAH|ILS|AED|QAR|KWD|BHD|OMR|JOD|EGP|ZAR|NGN|KES|BRL|MXN|CLP)"#
        let currency = "(?:" + symbols + "|" + codes + ")"

        // A formatted number: comma-grouped thousands with optional decimal
        // dot, dot-grouped thousands with optional decimal comma, or a plain
        // digit run with one optional decimal separator.
        let number =
            #"(?:\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d{1,3}(?:\.\d{3})+(?:,\d+)?|\d+(?:[.,]\d+)?)"#

        // Prefixed by a currency designator, then a formatted number, then an
        // optional Chinese magnitude unit and 元.
        let prefixed = currency + #"\s?"# + number + #"(?:[万亿])?(?:元)?"#

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
