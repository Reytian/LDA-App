//
//  TextEncodingDetectionTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F4. A plain-text file that was not UTF-8 was decoded as
//  ISO Latin-1, which accepts every byte sequence, so the UTF-16 and other
//  fallbacks never ran. A GB18030 file came out as mojibake with six
//  structured values replaced and every name recoverable by re-encoding; a
//  UTF-16 file with a byte-order mark and a Big5 file were exported whole
//  with nothing detected.
//
//  The importer now honours byte-order marks, recognises UTF-16 without one,
//  tries GB18030 and Big5 and keeps a decoding only when it is plausible
//  text, keeps Windows-1252 and Latin-1 for text that is plausibly Western,
//  and refuses with a clear error when nothing fits. Mojibake is never
//  written as a redacted file.
//
//  Every name below is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TextEncodingDetectionTests: XCTestCase {

    static let simplified = """
    （虚构示例文件，人物与公司均为杜撰）

    股权转让协议

    甲方（转让方）：北京星河云图科技有限公司（以下简称“星河云图”）
    法定代表人：王建国
    联系电话：13800138000，电子邮箱：ouyang.ruolan@example.cn
    乙方（受让方）：欧阳若兰，于二〇二六年十一月三十日前付款。
    """

    static let traditional = "（虛構示例）陳立明律師與歐陽若蘭於香港中環皇后大道中99號會面，電話 13800138000，電郵 chan@example.hk。"

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5.rawValue)))

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextEncodingDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func write(_ data: Data, _ name: String = "document.txt") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func imported(_ data: Data) throws -> String {
        try TextDocumentIO().importDocument(try write(data)).text
    }

    private func encoded(_ text: String, _ encoding: String.Encoding) throws -> Data {
        try XCTUnwrap(text.data(using: encoding), "fixture must encode in \(encoding)")
    }

    // MARK: - Chinese legacy encodings

    func testGB18030TextIsDecodedAsChinese() throws {
        XCTAssertEqual(try imported(try encoded(Self.simplified, Self.gb18030)), Self.simplified)
    }

    func testBig5TextIsDecodedAsChinese() throws {
        XCTAssertEqual(try imported(try encoded(Self.traditional, Self.big5)), Self.traditional)
    }

    /// The independent review of F4 (probe e6_euckr.txt): EUC-KR Korean was
    /// read as GB18030, whose common hanzi rows hold the Hangul bytes, and
    /// the mojibake was exported. Korean read as CP949 is nearly all Hangul;
    /// Chinese read that way is not.
    static let korean = "(가상) 김민준 변호사는 서울특별시 강남구 테헤란로 152에 있다. 전화 010-1234-5678, 이메일 kim@example.kr."

    func testEUCKRKoreanIsDecodedAsKoreanNotAsChinese() throws {
        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        XCTAssertEqual(try imported(try encoded(Self.korean, cp949)), Self.korean)
    }

    func testChineseIsNotTakenForKorean() throws {
        XCTAssertEqual(try imported(try encoded(Self.simplified, Self.gb18030)), Self.simplified)
    }

    static let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))

    /// The second independent review of F4 (probes t04a to t04c): short GBK
    /// Chinese whose characters all sit in GB2312 rows 0xB0 to 0xC8 reads as
    /// nothing but Hangul in CP949, so "Korean first" exported it as Korean
    /// mojibake. Big5 text of any length often reads as CP949 too. Both
    /// readings are now weighed by how common their characters are.
    func testShortGBKChineseIsNotTakenForKorean() throws {
        for text in [
            "被告：刘建国，电话：13812345678",
            "被告人陈国华",
            "离婚纠纷",
            "被告人",
            "陈国华",
            "李娜",
            "林晓梅",
            "借款合同",
            "王芳签字。",
            "乙方逾期交货的，应按日向甲方支付违约金。",
        ] {
            XCTAssertEqual(try imported(try encoded(text, Self.gb18030)), text)
        }
    }

    func testBig5ChineseIsNotTakenForKorean() throws {
        for text in [
            "張家豪",
            "離婚事件",
            "民事判決",
            "王小明",
            "借款契約",
            "上訴人之上訴駁回。第二審訴訟費用由上訴人負擔。",
            "甲方應於簽約後五個工作日內支付頭期款。",
        ] {
            XCTAssertEqual(try imported(try encoded(text, Self.big5)), text)
        }
    }

    /// Found while checking the above on Big5 strings: two-byte text of even
    /// length with no ASCII character reads as UTF-16 without a mark too,
    /// whose characters are then plausible CJK, so short Big5 came out as
    /// other hanzi ("登入" as two rare ones). A UTF-16 reading with no ASCII
    /// is now weighed against the Chinese reading.
    func testShortBig5AndGBKAreNotTakenForUTF16() throws {
        for text in ["登入", "下一步", "前一週", "同意", "每年", "土星"] {
            XCTAssertEqual(try imported(try encoded(text, Self.big5)), text)
        }
        // UTF-16 without a mark and without ASCII still reads as UTF-16.
        for text in ["股权转让协议", "王建国"] {
            XCTAssertEqual(try imported(try encoded(text, .utf16LittleEndian)), text)
        }
    }

    /// The second independent review of F4 (probe t04d): Korean that glosses
    /// its terms in Hanja fell below the Hangul share and was read as
    /// GB18030.
    func testKoreanWithHanjaIsDecodedAsKorean() throws {
        for text in [
            "피고(被告) 박서준(朴瑞俊)은 원고(原告)에게 금 10,000,000원을 지급하라.",
            "본 계약(契約)의 효력(效力)은 서명일(署名日)로부터 발생한다.",
            "대법원(大法院) 2020다12345 판결(判決) 참조.",
        ] {
            XCTAssertEqual(try imported(try encoded(text, Self.eucKR)), text)
        }
    }

    func testShortKoreanStaysKorean() throws {
        for text in [
            "김민준",
            "이서연",
            "최지우",
            "손해배상",
            "소유권이전등기",
            "계약서",
            "이혼 및 위자료 청구 사건",
            "원고의 청구를 기각한다. 소송비용은 원고가 부담한다.",
            "임차인은 임대인의 동의 없이 임차물을 전대할 수 없다.",
        ] {
            XCTAssertEqual(try imported(try encoded(text, Self.eucKR)), text)
        }
    }

    // MARK: - Unicode with and without a byte-order mark

    func testUTF16LittleEndianWithABOMIsHonoured() throws {
        var data = Data([0xFF, 0xFE])
        data.append(try encoded(Self.simplified, .utf16LittleEndian))
        XCTAssertEqual(try imported(data), Self.simplified)
    }

    func testUTF16BigEndianWithABOMIsHonoured() throws {
        var data = Data([0xFE, 0xFF])
        data.append(try encoded(Self.simplified, .utf16BigEndian))
        XCTAssertEqual(try imported(data), Self.simplified)
    }

    func testUTF16WithoutABOMIsRecognised() throws {
        XCTAssertEqual(try imported(try encoded(Self.simplified, .utf16LittleEndian)), Self.simplified)
        let english = "Jordan Ellis signed for Northwind Traders on 3 November 2026."
        XCTAssertEqual(try imported(try encoded(english, .utf16LittleEndian)), english)
        XCTAssertEqual(try imported(try encoded(english, .utf16BigEndian)), english)
    }

    func testUTF32WithABOMIsHonoured() throws {
        var data = Data([0xFF, 0xFE, 0x00, 0x00])
        data.append(try encoded(Self.simplified, .utf32LittleEndian))
        XCTAssertEqual(try imported(data), Self.simplified)
    }

    func testAUTF8BOMIsStillStripped() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(Self.simplified.utf8))
        XCTAssertEqual(try imported(data), Self.simplified)
    }

    // MARK: - Western text keeps working

    func testLatin1FrenchTextIsDecoded() throws {
        let french = "R\u{E9}sum\u{E9} du contrat sign\u{E9} \u{E0} Paris par Fran\u{E7}oise Lef\u{E8}vre."
        XCTAssertEqual(try imported(try encoded(french, .isoLatin1)), french)
    }

    func testWindows1252QuotesAndEuroAreDecoded() throws {
        let text = "The fee is \u{20AC}2,500 \u{2013} payable on \u{201C}signing\u{201D}."
        XCTAssertEqual(try imported(try encoded(text, .windowsCP1252)), text)
    }

    // MARK: - Nothing fits: refuse, never mojibake

    func testBytesThatAreNoPlausibleTextAreRefused() throws {
        // High bytes in no pattern any of the encodings reads as text.
        var bytes: [UInt8] = []
        for index in 0..<400 { bytes.append(UInt8(0x80 + (index * 37) % 0x7F)) }
        XCTAssertThrowsError(try imported(Data(bytes))) { error in
            guard case DocumentIOError.unreadable(let detail) = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
            XCTAssertTrue(detail.contains("UTF-8"), "the error says what to do: \(detail)")
        }
    }

    func testABOMThatDoesNotMatchTheBytesIsRefused() throws {
        // A UTF-16 BOM followed by an odd number of bytes cannot be UTF-16.
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: [0x41, 0x00, 0x42])
        XCTAssertThrowsError(try imported(data))
    }

    // MARK: - Through the service: no mojibake is ever exported

    func testAGB18030DocumentIsRedactedAsChinese() throws {
        struct Reports: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                #"{"entities":[{"value":"北京星河云图科技有限公司","type":"COMPANY"},{"value":"王建国","type":"PERSON"},{"value":"欧阳若兰","type":"PERSON"}],"redacted_text":""}"#
            }
        }
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: Reports()) }
        let input = try write(try encoded(Self.simplified, Self.gb18030), "agreement.txt")
        let result = try LDAService.anonymize(
            input: input,
            outputDir: tempDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("encoding-detection"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: tempDir.appendingPathComponent("model.gguf").path
        )
        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertTrue(redacted.contains("股权转让协议"), "the output is Chinese, not mojibake: \(redacted)")
        for value in ["北京星河云图科技有限公司", "王建国", "欧阳若兰", "13800138000", "ouyang.ruolan@example.cn"] {
            XCTAssertFalse(redacted.contains(value), "\(value) stayed in clear: \(redacted)")
        }
    }
}
