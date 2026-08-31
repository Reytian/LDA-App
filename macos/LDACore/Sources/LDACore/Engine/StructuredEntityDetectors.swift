//
//  StructuredEntityDetectors.swift
//  LDACore
//
//  The deterministic detectors added after the V1 battery: CASE_NUMBER,
//  LICENSE_PLATE, WECHAT_ID, and URL (the 2026-08-29 roadmap), plus SEAL
//  (organization seal names). They live in their own file so
//  DeterministicEngine.swift stays within the file-size house rule; the
//  engine's detect() calls them like any other per-type detector, and the
//  shared enumerate/makeSpan helpers plus the Pri/Conf tables stay in the main
//  file as the single ordering authority.
//
//  Design rule carried over from the Chinese-address incident: no variable
//  length CJK run is ever nested inside another quantifier. Every quantifier
//  in this file is bounded, and every alternation is anchored by a literal or
//  a required character class transition (CJK to digit, cue to ASCII ID), so
//  matching stays linear on adversarial input. Each detector has a
//  pathological-input test.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

extension DeterministicEngine {

    // MARK: - CASE_NUMBER (PRC court case numbers)

    /// New-format (2016 and later) PRC court case numbers, for example
    /// （2026）粤03民初12345号 or (2019)最高法民申1234号. A case number is the
    /// single most identifying string in a Chinese judgment: the public
    /// judgment portal resolves it back to every party, so redacting names
    /// while leaving the case number is not redacting at all.
    ///
    /// Structure, every part bounded:
    ///   1. A year in fullwidth or halfwidth parentheses (mixed accepted,
    ///      since OCR and copy-paste produce both).
    ///   2. A court code: 最高法, or a province abbreviation optionally
    ///      followed by 兵/兵团 (XPCC courts), or bare 兵团/军, then up to four
    ///      digits for the intermediate or basic court.
    ///   3. A case-type code of one to four characters from the closed
    ///      character set used by the official type codes (民初, 刑终, 执恢,
    ///      民辖终, 破申, 财保 and the like). The set deliberately excludes
    ///      ordinary prose characters such as 案 and 函, so government
    ///      document numbers like 国办发（2016）12号 never match: they carry
    ///      no court plus type code between the year and the serial.
    ///   4. A serial of one to eight digits and the terminal 号, plus an
    ///      optional sub-case suffix (之二).
    ///
    /// Old-format (pre-2016) case numbers such as （2014）沪二中民二（民）终字
    /// 第1234号 follow a different grammar (court division words, 字第) and
    /// are deliberately out of scope; they remain LLM territory.
    ///
    /// Digits accept the fullwidth forms because scanned filings carry them.
    func detectCaseNumber(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []
        enumerate(Self.caseNumberPattern, in: ns, range: range) { match in
            out.append(
                self.makeSpan(
                    ns,
                    range: match.range,
                    type: .caseNumber,
                    confidence: Conf.caseNumber,
                    priority: Pri.caseNumber
                )
            )
        }
        return out
    }

    /// Province abbreviations used in court codes. Both 贵 and 黔 are listed
    /// for Guizhou because filings are inconsistent; a slightly wider set is
    /// acceptable where a miss is a leak.
    private static let courtProvinceChars =
        "京津冀晋蒙辽吉黑沪苏浙皖闽赣鲁豫鄂湘粤桂琼渝川黔贵云藏陕甘青宁新"

    /// The closed character set the official case-type codes draw from. Kept
    /// to code characters only: adding prose characters (案, 函, 议) would
    /// open the government-document false-positive class.
    private static let caseTypeChars =
        "民刑行执赔委破财保申再初终监辖催督他撤特认异复恢协准更医救司知港澳台提减假强清"

    /// The assembled case-number pattern. Built once; detect runs per chunk.
    static let caseNumberPattern: String = {
        let digit = "[0-9０-９]"
        let year = "[12１２]" + digit + "{3}"
        let court = "(?:最高法|(?:[" + courtProvinceChars + "]兵?团?|兵团?|军)" + digit + "{0,4})"
        let caseType = "[" + caseTypeChars + "]{1,4}"
        let serial = digit + "{1,8}"
        let subCase = "(?:之[一二三四五六七八九十]{1,3})?"
        return "[（(]" + year + "[）)]" + court + caseType + serial + "号" + subCase
    }()

    // MARK: - LICENSE_PLATE (mainland vehicle plates)

    /// Mainland vehicle plates: a province character, an org letter, an
    /// optional interpunct, then a tail of four to six alphanumerics with an
    /// optional trailing special-use character (学 driving school, 警 police,
    /// 挂 trailer, 领 consular).
    ///
    /// Per GA36 the letters I and O never appear (they read as 1 and 0), so
    /// both the org letter and the tail exclude them; that also keeps 京O
    /// administrative sequences out. Plates are printed uppercase, so the
    /// pattern is case-sensitive on purpose: a lowercase run is prose, not a
    /// plate. Both ends are guarded so the plate is never carved out of a
    /// longer alphanumeric run (asset tags, serial numbers).
    func detectLicensePlate(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []
        enumerate(Self.licensePlatePattern, in: ns, range: range) { match in
            out.append(
                self.makeSpan(
                    ns,
                    range: match.range,
                    type: .licensePlate,
                    confidence: Conf.licensePlate,
                    priority: Pri.licensePlate
                )
            )
        }
        return out
    }

    /// Province characters that can open a plate.
    private static let plateProvinceChars =
        "京津沪渝冀豫云辽黑湘皖鲁新苏浙赣鄂桂甘晋蒙陕吉闽贵粤青藏川宁琼"

    /// The assembled plate pattern. Built once; detect runs per chunk.
    static let licensePlatePattern: String =
        "(?<![A-Za-z0-9])[" + plateProvinceChars + "][A-HJ-NP-Z][·・]?"
        + "[A-HJ-NP-Z0-9]{4,6}[学警挂领]?(?![0-9A-Za-z])"

    // MARK: - WECHAT_ID (cue-gated WeChat account IDs)

    /// WeChat account IDs. The bare ID grammar (six to twenty characters,
    /// letter first, alphanumerics with underscore and hyphen) is far too
    /// generic to match on its own: any English word of that length
    /// qualifies. Detection therefore requires a contextual cue immediately
    /// before the candidate, and only the ID itself is captured, never the
    /// cue.
    ///
    /// Cue rules, each covered by a test:
    ///   - CJK-ending cues (微信号, 微信ID, 微信账号, 微信, V信) take zero to
    ///     three separator characters (：, :, whitespace) or one connector
    ///     word (是, 为): the CJK-to-ASCII transition is itself a boundary, so
    ///     加微信abc123ok works with no separator at all.
    ///   - Latin cues (WeChat, weixin, vx) REQUIRE a separator, or the cue
    ///     would carve an ID out of an ordinary word (VXSeries2000,
    ///     wechatpay). They also require a non-alphanumeric on their left for
    ///     the same reason.
    ///   - The connector path (微信是/微信为) can absorb a following English
    ///     word as an ID (over-redaction); that is accepted, because the
    ///     inverse rule would leave 我的微信是zhangsan99 in cleartext and a
    ///     miss is a leak while over-redaction is cosmetic.
    ///
    /// The auto-generated wxid_ form is self-identifying and matches with no
    /// cue at all.
    func detectWechatID(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []

        // Cue-gated: the ID is capture group 1; the emitted span covers the
        // group only, so the cue and separators stay in cleartext.
        enumerate(
            Self.wechatCuedPattern,
            options: [.caseInsensitive],
            in: ns,
            range: range
        ) { match in
            let idRange = match.range(at: 1)
            guard idRange.location != NSNotFound else { return }
            out.append(
                self.makeSpan(
                    ns,
                    range: idRange,
                    type: .wechatID,
                    confidence: Conf.wechatID,
                    priority: Pri.wechatID
                )
            )
        }

        // wxid_ form: the whole match is the span.
        enumerate(
            Self.wechatWxidPattern,
            options: [.caseInsensitive],
            in: ns,
            range: range
        ) { match in
            out.append(
                self.makeSpan(
                    ns,
                    range: match.range,
                    type: .wechatID,
                    confidence: Conf.wechatID,
                    priority: Pri.wechatID
                )
            )
        }
        return out
    }

    /// Cue-gated WeChat ID pattern. Group 1 is the ID. Built once.
    static let wechatCuedPattern: String = {
        let cueCJK = "(?:微信号|微信ID|微信账号|微信|V信)"
        let cueLatin = "(?<![A-Za-z0-9])(?:WeChat|weixin|vx)"
        let sep = "[：:\\s]"
        let candidate = "([A-Za-z][A-Za-z0-9_\\-]{5,19})(?![A-Za-z0-9_\\-])"
        return "(?:" + cueCJK + "(?:" + sep + "{0,3}|[是为])|"
            + cueLatin + sep + "{1,3})" + candidate
    }()

    /// The self-identifying wxid_ form. Built once.
    static let wechatWxidPattern: String =
        "(?<![A-Za-z0-9_\\-])wxid_[A-Za-z0-9_\\-]{6,20}(?![A-Za-z0-9_\\-])"

    // MARK: - SEAL (organization seal names)

    /// Organization seal names: 公章 and the specialized 专用章 family. The
    /// seal wording itself is contract boilerplate; the PII is the
    /// organization name stamped into the seal, so a span is emitted ONLY
    /// when the anchor is immediately preceded by a payload ending in an
    /// organization suffix. "加盖公章后生效" yields nothing, while
    /// "北京某某科技有限公司合同专用章" is one SEAL span over the whole string.
    ///
    /// Detection follows the regex-core-plus-bounded-walk architecture of the
    /// address detector (the single-big-CJK-regex approach caused a confirmed
    /// multi-minute backtracking hang there):
    ///   1. A regex matches only the closed literal anchor set, so the scan
    ///      is trivially linear.
    ///   2. Code checks that the text immediately before the anchor ends with
    ///      an organization suffix, then walks the payload backwards over
    ///      contiguous CJK ideographs, bounded to maxSealPayloadLength UTF-16
    ///      units, stopping at punctuation, whitespace, and non-CJK.
    ///
    /// Precision choices, each covered by a test:
    ///   - No payload suffix means no span: 甲方公章, 办公章程, and a seal
    ///     word opening a line all stay clear.
    ///   - The walk deliberately has NO prose stop list: trimming at prose
    ///     connectors would truncate organization names that contain them
    ///     (华为 contains 为, 经贸 contains 经), and leaving the head of a
    ///     name in cleartext is a leak while absorbing a leading 加盖 is
    ///     cosmetic over-capture. Over-covering is the accepted direction.
    ///     This is also why 经办部门为总公司公章 over-captures the boilerplate
    ///     lead-in: every candidate stop character there is a legal name
    ///     character somewhere else, so tightening it means under-capturing
    ///     some real name, and an under-captured name is a leak.
    ///   - Latin letters and digits ARE part of the payload: registered names
    ///     beginning with them are ordinary (ABC科技有限公司, 3M中国有限公司).
    ///     Stopping the walk there truncated the span, and SpanMerger then let
    ///     the truncated span evict the wider LLM COMPANY span, leaving the
    ///     initial in cleartext. SpanMerger now absorbs rather than evicts, so
    ///     a payload the walk cannot reach (a name longer than the bound, or
    ///     one broken by punctuation) stays covered by the COMPANY span.
    func detectSeal(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []
        enumerate(Self.sealAnchorPattern, in: ns, range: range) { match in
            guard let start = self.sealPayloadStart(ns, anchorStart: match.range.location) else {
                // A seal word with no organization payload is boilerplate.
                return
            }
            let full = NSRange(
                location: start,
                length: match.range.location + match.range.length - start
            )
            out.append(
                self.makeSpan(
                    ns,
                    range: full,
                    type: .seal,
                    confidence: Conf.seal,
                    priority: Pri.seal
                )
            )
        }
        return out
    }

    /// The closed anchor set: literal alternation only, no quantifier, so
    /// matching cannot backtrack. Built once; detect runs per chunk.
    static let sealAnchorPattern =
        "(?:财务专用章|合同专用章|发票专用章|业务专用章|人事专用章|公章)"

    /// Organization suffixes a seal payload must end with, longest first so
    /// a longer suffix is checked before a shorter one it contains.
    ///
    /// The bare forms 所, 会, 学, and 处 are deliberately ABSENT: 所有, 所以,
    /// 本所, 开会, 法学, and 盖章处 are ordinary words and boilerplate, so a bare
    /// suffix would mint seal spans over text carrying no organization name at
    /// all. Each is admitted only in an unambiguous compound (事务所 / 研究所 /
    /// 派出所, 协会 / 商会 / 工会 / 学会 / 基金会 / 联合会, 大学 / 中学 / 小学 /
    /// 学校, 办事处). The single-unit entries that remain (局, 厅, 厂, 院, 社) do
    /// not read as common standalone words in the only position this check
    /// looks at, which is immediately before a seal word.
    private static let sealOrgSuffixes = [
        "委员会", "事务所", "研究所", "派出所", "办事处", "基金会", "联合会",
        "公司", "银行", "分行", "支行", "中心", "集团", "政府",
        "协会", "商会", "工会", "学会", "大学", "中学", "小学", "学校",
        "局", "厅", "厂", "院", "社"
    ]

    /// How far left the payload walk may reach, in UTF-16 units, suffix
    /// included and anchor excluded. Full PRC organization names run long
    /// (registered names regularly exceed 15 characters), and the constant
    /// bound is what keeps detection linear on adversarial input.
    private static let maxSealPayloadLength = 30

    /// Walk backwards from a seal anchor to the start of its organization
    /// payload. Returns nil when the text immediately before the anchor does
    /// not end with an organization suffix (the boilerplate case).
    ///
    /// The walk absorbs contiguous name characters, so punctuation,
    /// whitespace, and symbols pin the left edge. A supplementary-plane
    /// character ends the walk rather than being consumed: Unicode.Scalar of a
    /// lone surrogate code unit is nil, so the boundary can never land inside
    /// a surrogate pair.
    private func sealPayloadStart(_ ns: NSString, anchorStart: Int) -> Int? {
        guard let suffixLength = Self.sealOrgSuffixLength(ns, endingAt: anchorStart) else {
            return nil
        }

        var left = anchorStart - suffixLength
        var walked = suffixLength
        while walked < Self.maxSealPayloadLength, left > 0 {
            guard let scalar = Unicode.Scalar(ns.character(at: left - 1)),
                  Self.isSealPayloadScalar(scalar) else { break }
            left -= 1
            walked += 1
        }
        return left
    }

    /// CJK ideographs, the bulk of any PRC registered name.
    private static let cjkIdeographs: ClosedRange<UInt32> = 0x4E00...0x9FA5
    /// ASCII digits, uppercase, and lowercase.
    private static let asciiDigits: ClosedRange<UInt32> = 0x30...0x39
    private static let asciiUppercase: ClosedRange<UInt32> = 0x41...0x5A
    private static let asciiLowercase: ClosedRange<UInt32> = 0x61...0x7A

    /// Characters the payload walk absorbs: CJK ideographs plus ASCII letters
    /// and digits.
    ///
    /// The Latin and digit part is load-bearing, not a convenience. Latin or
    /// digit initial registered names are ordinary (ABC科技有限公司,
    /// 3M中国有限公司, TCL集团股份有限公司), and stopping the walk at the initial
    /// emitted a span covering only the CJK tail. That truncated span then
    /// evicted the wider LLM COMPANY span in SpanMerger and the initial
    /// survived into the redacted output in cleartext.
    private static func isSealPayloadScalar(_ scalar: Unicode.Scalar) -> Bool {
        cjkIdeographs.contains(scalar.value)
            || asciiDigits.contains(scalar.value)
            || asciiUppercase.contains(scalar.value)
            || asciiLowercase.contains(scalar.value)
    }

    /// The length of the organization suffix ending exactly at `end`, or nil
    /// when none of the closed set does. Each comparison is a fixed-length
    /// substring check, so the lookup is constant time.
    private static func sealOrgSuffixLength(_ ns: NSString, endingAt end: Int) -> Int? {
        for suffix in sealOrgSuffixes {
            let length = (suffix as NSString).length
            guard end - length >= 0 else { continue }
            let candidate = ns.substring(with: NSRange(location: end - length, length: length))
            if candidate == suffix {
                return length
            }
        }
        return nil
    }

    // MARK: - URL (web addresses)

    /// Web addresses in three shapes: scheme-prefixed (http:// and https://),
    /// www-prefixed hosts, and bare domains ending in an allowlisted TLD,
    /// each with an optional port, path, and query.
    ///
    /// Precision choices, each covered by a test:
    ///   - Bare domains require a TLD from a closed list, so file names
    ///     (example.docx), version strings (v2.5.1), and clause references
    ///     (第5.2条) never match. Two-letter TLDs that read as English words
    ///     (in, it, is, at, be, no, so, do) are deliberately absent because a
    ///     missing space after a sentence period would otherwise mint a URL.
    ///   - The www and bare shapes must not start inside another token: the
    ///     lookbehind excludes alphanumerics, dots, hyphens, underscores, @
    ///     (so the domain of user@example.com is never re-reported as a URL;
    ///     EMAIL keeps it), and / (so the host inside a scheme-prefixed match
    ///     is not re-reported, though SpanMerger would drop the shorter span
    ///     anyway).
    ///   - Sentence punctuation that the greedy path class absorbs (a
    ///     trailing period or comma, an unbalanced closing bracket) is walked
    ///     back off the end in code, mirroring the regex-core-plus-bounded-
    ///     walk architecture used by the address detector.
    func detectURL(_ ns: NSString, _ range: NSRange) -> [Span] {
        var out: [Span] = []
        for pattern in [Self.urlSchemePattern, Self.urlWwwPattern, Self.urlBareDomainPattern] {
            enumerate(pattern, options: [.caseInsensitive], in: ns, range: range) { match in
                let trimmed = Self.trimTrailingPunctuation(ns, range: match.range)
                guard trimmed.length > 0 else { return }
                out.append(
                    self.makeSpan(
                        ns,
                        range: trimmed,
                        type: .url,
                        confidence: Conf.url,
                        priority: Pri.url
                    )
                )
            }
        }
        return out
    }

    /// Unreserved and reserved URI characters allowed in a port, path, or
    /// query. A single character class, so repetition cannot backtrack.
    private static let uriTailChars = "[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]"

    /// Optional port and path tail shared by all three shapes.
    private static let urlTail = "(?::[0-9]{1,5})?(?:/" + uriTailChars + "*)?"

    /// Scheme-prefixed URLs. The host must start with an alphanumeric so a
    /// bare "http://." in prose never yields a degenerate match. Built once.
    static let urlSchemePattern: String =
        "https?://[A-Za-z0-9][A-Za-z0-9.\\-]{0,252}" + urlTail

    /// www-prefixed hosts without a scheme. The final label must be
    /// alphabetic; the www prefix is cue enough that the TLD list is not
    /// applied here. Built once.
    static let urlWwwPattern: String =
        "(?<![A-Za-z0-9.\\-@_/])www\\.(?:[A-Za-z0-9\\-]{1,63}\\.){0,5}[A-Za-z]{2,24}" + urlTail

    /// The TLD allowlist for bare domains, longest first. Multi-label
    /// endings (.com.cn, .gov.cn) fall out naturally: the leading labels
    /// match as labels and the final one must be listed.
    private static let bareTLDs =
        "(?:info|com|net|org|gov|edu|biz|top|xyz|cn|hk|mo|tw|jp|kr|sg|us|uk|de|fr|eu|io|co|ai|me|cc|tv)"

    /// Bare domains with an allowlisted TLD. Built once.
    static let urlBareDomainPattern: String =
        "(?<![A-Za-z0-9.\\-@_/])(?:[A-Za-z0-9\\-]{1,63}\\.){1,5}" + bareTLDs
        + "(?![A-Za-z0-9\\-])" + urlTail

    /// Walk trailing sentence punctuation back off a URL match. Periods,
    /// commas, and the like always come off; a closing bracket comes off only
    /// while unbalanced, so a URL whose path legitimately ends in (b) keeps
    /// it. The walk is bounded by the match itself and each step is O(span),
    /// so the trim stays linear.
    static func trimTrailingPunctuation(_ ns: NSString, range: NSRange) -> NSRange {
        let alwaysTrim: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\""]
        let start = range.location
        var end = range.location + range.length

        while end > start {
            guard let scalar = Unicode.Scalar(ns.character(at: end - 1)) else { break }
            let ch = Character(scalar)

            if alwaysTrim.contains(ch) {
                end -= 1
                continue
            }

            if ch == ")" || ch == "]" {
                let opener: Character = (ch == ")") ? "(" : "["
                let sub = ns.substring(with: NSRange(location: start, length: end - start))
                let opens = sub.filter { $0 == opener }.count
                let closes = sub.filter { $0 == ch }.count
                if closes > opens {
                    end -= 1
                    continue
                }
            }

            break
        }

        return NSRange(location: start, length: end - start)
    }
}
