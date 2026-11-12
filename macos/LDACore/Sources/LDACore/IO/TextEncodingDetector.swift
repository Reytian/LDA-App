//
//  TextEncodingDetector.swift
//  LDACore
//
//  Works out the encoding of a plain-text file, or says that it cannot.
//
//  Review 2026-11-11 (F4): the importer tried UTF-8 and then ISO Latin-1,
//  which accepts every byte sequence, so the UTF-16 and other fallbacks never
//  ran. A GB18030 contract came out as mojibake in which only a few
//  structured values were found (every name could be recovered by
//  re-encoding the redacted file), and a UTF-16 or Big5 file was exported
//  whole with nothing detected. Redacting text the engine cannot read is
//  worse than refusing it, so every decoding below must also be plausible
//  text, and when none is the file is refused.
//
//  Order:
//  1. A byte-order mark decides (UTF-8, UTF-16 or UTF-32, either byte order).
//     Bytes that do not decode under their own mark are refused.
//  2. Strict UTF-8, unless it holds a NUL: ASCII text in UTF-16 without a
//     mark is valid UTF-8 with a NUL after every letter.
//  3. UTF-16 without a mark, either byte order, when the result is plausible
//     text (letters, digits, CJK, punctuation; no control characters). UTF-8
//     with a NUL that is not plausible UTF-16 is kept as UTF-8.
//  4. GB18030 and Big5. Both read most of each other's bytes without error,
//     so each reading is scored by how many of its two-byte characters fall
//     in that encoding's block of frequently used characters (GB2312 level 1
//     and the punctuation rows; Big5's 常用字 and punctuation row). A wrong
//     reading lands mostly on rare characters, kana and bopomofo. The higher
//     score wins when it is at least `minimumCommonShare`.
//  5. Windows-1252, then ISO Latin-1, only for text that is plausibly
//     Western: accented letters and typographic punctuation among mostly
//     ASCII, never a long run of high characters (which is what CJK bytes
//     look like in a Western code page) and never a C1 control character.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum TextEncodingDetector {

    /// The error detail when no encoding fits. Names what to do and carries
    /// no document text and no path.
    public static let refusal = "The file is not in a text encoding LDA can read reliably (UTF-8, UTF-16, "
        + "UTF-32, GB18030, Big5, EUC-KR, Windows-1252 or Latin-1). Nothing was written. Save it as UTF-8 and try again."

    /// The least share of frequently used characters a GB18030 or Big5
    /// reading needs. Chinese prose in the right encoding scores above 0.9.
    static let minimumCommonShare = 0.6

    /// The most Western text may hold of non-ASCII characters among its
    /// visible ones, and the longest run of them.
    static let maximumWesternShare = 0.3
    static let maximumWesternRun = 3

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
    /// CP949 (Windows-949), the superset of EUC-KR.
    static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    /// The least share of Hangul among the non-ASCII letters of a CP949
    /// reading for it to be taken as Korean when no Chinese reading of the
    /// same bytes stands beside it.
    static let minimumHangulShare = 0.9

    /// The least share of Hangul syllables among the non-ASCII letters of a
    /// CP949 reading (jamo aside) for it to be weighed against a Chinese
    /// reading at all. Korean that glosses its terms in Hanja stays above it.
    static let minimumSyllableShare = 0.5

    /// The text of `data`, or nil when no encoding gives plausible text.
    public static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if let (marked, unit) = byteOrderMarkEncoding(bytes) {
            guard bytes.count % unit == 0, let text = String(data: data, encoding: marked),
                  !hasControlCharacters(text) else { return nil }
            return text
        }
        let utf8 = String(data: data, encoding: .utf8)
        // ASCII text in UTF-16 without a mark is valid UTF-8 too, one NUL
        // after every letter. A NUL is never prose, so such text is tried as
        // UTF-16 first.
        if let utf8, !utf8.unicodeScalars.contains("\u{0}") {
            return utf8
        }
        if bytes.count % 2 == 0 {
            for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                if let text = String(data: data, encoding: encoding), isPlausibleUnicode(text) {
                    // Two-byte Chinese of even length with no ASCII at all
                    // reads as UTF-16 CJK too: weigh the two (review
                    // 2026-11-11, F4). UTF-16 text with any ASCII in it has
                    // zero bytes, which no legacy reading accepts.
                    if !text.unicodeScalars.contains(where: \.isASCII),
                       let chinese = chineseReading(data, bytes),
                       meanHanziBits(chinese) < meanHanziBits(text) {
                        return chinese
                    }
                    return text
                }
            }
        }
        if let utf8 {
            return utf8
        }
        let korean = koreanReading(data)
        let chinese = chineseReading(data, bytes)
        if let korean, let chinese, korean.syllableShare >= minimumSyllableShare {
            return prefersKorean(korean.text, over: chinese) ? korean.text : chinese
        }
        if let korean, chinese == nil, korean.hangulShare >= minimumHangulShare {
            return korean.text
        }
        if let chinese {
            return chinese
        }
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), isPlausiblyWestern(text) {
                return text
            }
        }
        return nil
    }

    // MARK: - Byte-order marks

    /// The encoding a byte-order mark announces and its code unit size in
    /// bytes, or nil when there is no mark. The decoders keep the mark as
    /// U+FEFF, which TextDocumentIO.normalize strips.
    static func byteOrderMarkEncoding(_ bytes: [UInt8]) -> (String.Encoding, Int)? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 1) }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    // MARK: - Plausibility

    /// True when the text holds a control character other than tab, line
    /// feed, form feed or carriage return, or U+FFFD.
    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D: return false
            case 0x00...0x1F, 0x7F...0x9F, 0xFFFD: return true
            default: return false
            }
        }
    }

    /// True when a UTF-16 reading without a mark is text: no control
    /// characters, and at least 95 percent of its visible characters in the
    /// scripts LDA's documents are written in. Bytes of another encoding read
    /// as UTF-16 land in surrogates, private use, Yi and Hangul instead.
    static func isPlausibleUnicode(_ text: String) -> Bool {
        guard !hasControlCharacters(text) else { return false }
        var visible = 0
        var known = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            visible += 1
            if isDocumentScalar(scalar) { known += 1 }
        }
        return visible == 0 || Double(known) >= Double(visible) * 0.95
    }

    static func isDocumentScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20...0x7E,       // ASCII
             0xA0...0x24F,      // Latin-1 supplement, Latin Extended A and B
             0x2000...0x206F,   // general punctuation
             0x20A0...0x20CF,   // currency
             0x2100...0x218F,   // letterlike symbols, number forms
             0x3000...0x303F,   // CJK symbols and punctuation
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xFEFF,            // a stray byte-order mark
             0xFF00...0xFFEF:   // full-width forms
            return true
        default:
            return false
        }
    }

    /// True when a Western reading is plausibly Western text.
    static func isPlausiblyWestern(_ text: String) -> Bool {
        guard !hasControlCharacters(text) else { return false }
        var visible = 0
        var high = 0
        var run = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                run = 0
                continue
            }
            visible += 1
            guard scalar.value >= 0x80 else {
                run = 0
                continue
            }
            high += 1
            run += 1
            if run > maximumWesternRun { return false }
        }
        return visible == 0 || Double(high) <= Double(visible) * maximumWesternShare
    }

    // MARK: - Korean

    /// A CP949 reading and how much of it is Korean.
    struct KoreanReading {
        let text: String
        /// Hangul (syllables and jamo) among the non-ASCII letters.
        let hangulShare: Double
        /// Hangul syllables among the non-ASCII letters other than jamo.
        let syllableShare: Double
    }

    /// The CP949 reading of `data` with its Hangul shares, or nil when the
    /// bytes are not CP949 or the reading holds no Hangul syllable.
    ///
    /// The independent review of F4 (probe e6_euckr.txt): EUC-KR Korean was
    /// read as GB18030, whose common hanzi rows (lead 0xB0 to 0xD7) hold the
    /// Hangul syllables (lead 0xB0 to 0xC8), and the mojibake was exported.
    /// The first fix took this reading whenever it was nearly all Hangul,
    /// which the second review found wrong the other way: short GBK Chinese
    /// whose characters all sit in rows 0xB0 to 0xC8 is nothing but Hangul
    /// in CP949 too (probes t04a to t04c), and Big5 text of any length often
    /// reads as CP949. The bytes alone cannot tell these apart, so decode
    /// weighs this reading against the Chinese one (prefersKorean).
    static func koreanReading(_ data: Data) -> KoreanReading? {
        guard let text = String(data: data, encoding: cp949), !hasControlCharacters(text) else { return nil }
        var syllables = 0
        var jamo = 0
        var other = 0
        for scalar in text.unicodeScalars where !scalar.isASCII && CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0xAC00...0xD7A3: syllables += 1
            case 0x1100...0x11FF, 0x3130...0x318F: jamo += 1
            default: other += 1
            }
        }
        guard syllables > 0 else { return nil }
        return KoreanReading(
            text: text,
            hangulShare: Double(syllables + jamo) / Double(syllables + jamo + other),
            syllableShare: Double(syllables) / Double(syllables + other)
        )
    }

    /// Whether `korean`, a CP949 reading, is likelier text than `chinese`, a
    /// GB18030 or Big5 reading of the same bytes: whether its characters
    /// cost fewer bits on average (CJKCharacterCosts). Hangul syllables are
    /// weighed by how common they are in Korean, a Hanja in the Korean
    /// reading at the unknown syllable cost (a Chinese file read as CP949
    /// lands on Hanja rows at random), and the Chinese reading's characters
    /// by how common they are in Chinese. A private-use character costs the
    /// unknown cost in either reading: the decoders map the user-defined rows
    /// of all three code tables there, and a document of the right encoding
    /// does not use them. Measured on about 475,000 Korean,
    /// Simplified and Traditional strings of each kind, this reads Korean of
    /// six syllables or more and Chinese of six characters or more right in
    /// all but a handful of cases, where "Korean first" misread one Big5
    /// string in eight.
    static func prefersKorean(_ korean: String, over chinese: String) -> Bool {
        var koreanBits = 0
        var koreanCount = 0
        for scalar in korean.unicodeScalars {
            if (0xAC00...0xD7A3).contains(scalar.value) {
                koreanBits += CJKCharacterCosts.hangulCost(scalar)
                koreanCount += 1
            } else if isHanzi(scalar) || isPrivateUse(scalar) {
                koreanBits += CJKCharacterCosts.unknownHangulCost
                koreanCount += 1
            }
        }
        var chineseBits = 0
        var chineseCount = 0
        for scalar in chinese.unicodeScalars {
            if isHanzi(scalar) {
                chineseBits += CJKCharacterCosts.hanziCost(scalar)
                chineseCount += 1
            } else if isPrivateUse(scalar) {
                chineseBits += CJKCharacterCosts.unknownHanziCost
                chineseCount += 1
            }
        }
        guard chineseCount > 0 else { return true }
        guard koreanCount > 0 else { return false }
        // koreanBits / koreanCount < chineseBits / chineseCount, in integers.
        return koreanBits * chineseCount < chineseBits * koreanCount
    }

    /// The average cost in bits of the Chinese characters of `text`, a
    /// private-use character at the unknown cost; the unknown cost when it
    /// holds none.
    static func meanHanziBits(_ text: String) -> Double {
        var bits = 0
        var count = 0
        for scalar in text.unicodeScalars where isHanzi(scalar) || isPrivateUse(scalar) {
            bits += isHanzi(scalar) ? CJKCharacterCosts.hanziCost(scalar) : CJKCharacterCosts.unknownHanziCost
            count += 1
        }
        return count == 0 ? Double(CJKCharacterCosts.unknownHanziCost) : Double(bits) / Double(count)
    }

    static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value)
    }

    /// CJK unified ideographs, extension A and the compatibility block.
    static func isHanzi(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    // MARK: - GB18030 and Big5

    /// The better of the GB18030 and Big5 readings, or nil when neither
    /// decodes cleanly with enough frequently used characters.
    static func chineseReading(_ data: Data, _ bytes: [UInt8]) -> String? {
        var best: (share: Double, text: String)?
        let readings: [(String.Encoding, ([UInt8]) -> Double?)] = [
            (gb18030, commonShareGB18030),
            (big5, commonShareBig5),
        ]
        for (encoding, score) in readings {
            guard let share = score(bytes), share >= minimumCommonShare,
                  let text = String(data: data, encoding: encoding), !hasControlCharacters(text) else { continue }
            if best == nil || share > best!.share {
                best = (share, text)
            }
        }
        return best?.text
    }

    /// GB18030: the share of multi-byte characters that are GB2312 level-1
    /// hanzi (lead 0xB0 to 0xD7) or GB2312 punctuation and full-width forms
    /// (lead 0xA1 or 0xA3), trail 0xA1 to 0xFE. Nil when the bytes are not
    /// GB18030 at all or hold no multi-byte character.
    static func commonShareGB18030(_ bytes: [UInt8]) -> Double? {
        var index = 0
        var total = 0
        var common = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            guard (0x81...0xFE).contains(lead), index + 1 < bytes.count else { return nil }
            let trail = bytes[index + 1]
            total += 1
            if (0x30...0x39).contains(trail) {
                // A four-byte sequence: rare characters, never common.
                index += 4
                continue
            }
            if (0xA1...0xFE).contains(trail), (0xB0...0xD7).contains(lead) || lead == 0xA1 || lead == 0xA3 {
                common += 1
            }
            index += 2
        }
        return total == 0 ? nil : Double(common) / Double(total)
    }

    /// Big5: the share of two-byte characters in the frequently used block
    /// (lead 0xA4 to 0xC6) or the punctuation row (lead 0xA1). Nil when the
    /// bytes are not Big5 at all or hold no two-byte character.
    static func commonShareBig5(_ bytes: [UInt8]) -> Double? {
        var index = 0
        var total = 0
        var common = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
                continue
            }
            guard (0x81...0xFE).contains(lead), index + 1 < bytes.count else { return nil }
            total += 1
            if (0xA4...0xC6).contains(lead) || lead == 0xA1 {
                common += 1
            }
            index += 2
        }
        return total == 0 ? nil : Double(common) / Double(total)
    }
}
