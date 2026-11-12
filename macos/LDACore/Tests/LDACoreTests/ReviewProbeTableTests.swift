//
//  ReviewProbeTableTests.swift
//  LDACoreTests
//
//  The probes of both independent reviews of the 2026-11-11 fixes, as one
//  table. Twice a fix passed its own reproduction and broke the case next to
//  it: the EUC-KR fix read short GBK Chinese as Korean, the hyphen join glued
//  "SSN -" to the number after it, the audit's short-number floor left a
//  docket number in a link target, and the full-width comma fix lost amounts
//  written after "1，000，". Every row is a fictional input and the
//  properties its export must have, never the whole expected output, so an
//  ordinary change does not have to edit the table: what must be gone, what
//  must stay, one placeholder per person, an exact restore, an export that is
//  not refused. Every follow-up is committed with the whole table passing.
//
//  The inputs are the reviewers' probe texts (shared notes,
//  independent-review-2026-11-11-probes, and the review's
//  2026-11-11-lda2-review-probes inputs); the Word and PDF probes are built
//  here. Rows that need the LDA V4 tagger run when LDA_V4_MODEL_DIR names a
//  model folder and are skipped otherwise, as in LDAV4ExtractorTests.
//
//  Every name, number and address below is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreText
@testable import LDACore

final class ReviewProbeTableTests: XCTestCase {

    // MARK: - The table

    enum Source {
        /// Plain text written in `encoding`.
        case text(String, String.Encoding)
        /// One page with one line of text per element.
        case pdf([String])
        /// A Word package: the body's paragraph XML, extra parts and extra
        /// document relationships.
        case docx(body: String, parts: [(String, String)], relationships: [String])
    }

    enum Property {
        /// The export is refused, nothing written.
        case refuses
        /// The export succeeds.
        case exports
        /// The importer reads the input as exactly this text.
        case importsAs(String)
        /// None of these strings is anywhere in the output (every member of a
        /// Word package, XML references decoded).
        case absent([String])
        /// Each of these strings is still in the redacted text.
        case kept([String])
        /// No digit is left in the redacted text outside placeholders.
        case noDigits
        /// Each of these strings is the value of a mapping entry of its own.
        case mappedValues([String])
        /// Exactly one mapping entry holds this value.
        case onePlaceholder(String)
        /// Restoring the redacted output gives the input's text back exactly.
        case roundTrips
        /// The rules alone read the text within this many seconds.
        case detectsWithin(Double)
    }

    struct Probe {
        let id: String
        let source: Source
        var model = false
        var autoProtect = false
        let properties: [Property]
    }

    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    static let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.big5.rawValue)))
    static let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))

    static func encoded(_ id: String, _ text: String, _ encoding: String.Encoding, _ more: [Property] = []) -> Probe {
        Probe(id: id, source: .text(text, encoding), properties: [.exports, .importsAs(text)] + more)
    }

    static let hyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    static let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#

    static let probes: [Probe] = [
        // F4: legacy encodings (first review e6, second review t04a to t04d
        // and k01 to k07, the review's t6 files).
        encoded("F4 e6 EUC-KR Korean", "(가상) 김민준 변호사는 서울특별시 강남구에 있다.", eucKR),
        encoded("F4 k07 EUC-KR Korean", "(가상) 원고 김민준은 피고 주식회사 한빛물산을 상대로 대금 5,000,000원의 지급을 청구하였다. 원고의 주소는 서울특별시 강남구 테헤란로 123이다.", eucKR),
        encoded("F4 t04d Korean glossed in Hanja", "피고(被告) 김민준(金敏俊)은 원고(原告)에게 금 10,000,000원을 지급하라.", eucKR),
        encoded("F4 t04a short GBK", "被告：刘建国，电话：13812345678", gb18030, [.absent(["13812345678"])]),
        encoded("F4 t04b short GBK", "被告人陈国华", gb18030),
        encoded("F4 t04c short GBK", "离婚纠纷", gb18030),
        encoded("F4 k01 short GBK", "王芳签字。", gb18030),
        encoded("F4 k02 GBK name only", "林晓梅", gb18030),
        encoded("F4 k03 GBK legal", "（虚构）原告张建国诉被告海川物流有限公司买卖合同纠纷一案，本院于2025年3月1日立案后，依法适用简易程序，公开开庭进行了审理。原告的诉讼请求：判令被告支付货款人民币8000元。", gb18030, [.absent(["2025年3月1日", "8000元"])]),
        encoded("F4 k04 GB18030 four-byte", "（虚构）申请人：㛃丽，住所：北京市海淀区中关村大街1号，联系电话：13800138000。", gb18030, [.absent(["13800138000"])]),
        encoded("F4 k05 Big5 legal", "（虛構）原告陳大文訴被告長青貿易有限公司，請求判令被告給付新臺幣伍拾萬元。", big5),
        encoded("F4 k06 GBK numbers", "第一条 甲方：海川物流有限公司；乙方：周启明；金额：50000元；日期：2026年11月3日。", gb18030, [.absent(["50000元", "2026年11月3日"])]),
        encoded("F4 short Big5", "登入", big5),
        encoded("F4 short Big5 three", "下一步", big5),
        encoded("F4 t6 UTF-16 without a mark", "（虚构示例）股权转让协议。联系电话：13800138000。", .utf16LittleEndian, [.absent(["13800138000"])]),

        // F5: Word packages (first review p22, p23; second review t02).
        Probe(id: "F5 t02 docket in a link target", source: .docx(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("(Fictional) Case No. 21-843 is set for argument.")),
            parts: [],
            relationships: [#"<Relationship Id="rId90" Type="\#(hyperlink)" Target="https://court.example/docket/21-843.html" TargetMode="External"/>"#]
        ), properties: [.exports, .absent(["21-843"]), .roundTrips]),
        Probe(id: "F5 p22 zoom 100 beside $100", source: .docx(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("(Fictional) The fee is $100 per hour, payable monthly.")),
            parts: [("word/settings.xml", "<w:settings \(w)><w:zoom w:percent=\"100\"/></w:settings>")],
            relationships: []
        ), properties: [.exports, .absent(["$100"]), .roundTrips]),
        Probe(id: "F5 p23 styles beside $24 and $160", source: .docx(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("(Fictional) A filing fee of $24 and a courier fee of $160.")),
            parts: [("word/styles.xml", "<w:styles \(w)><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val=\"24\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"160\"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>")],
            relationships: []
        ), properties: [.exports, .absent(["$24", "$160"]), .roundTrips]),

        // F6: PDF line breaks (first review p19, p20; second review t01;
        // the review's en_wrap).
        Probe(id: "F6 p20 values broken at their hyphen", source: .pdf([
            "(Fictional) The tenant may be reached on the main office line, which is 212-555-",
            "0148, and  the  landlord  may be reached on the second line, which is 646-555-",
            "0199. Under the lease the tenant's social security number is listed as 123-45-",
            "6789 and  the  related matter in the federal court is docketed as No. 1:24-cv-",
            "01234 in  the  Southern  District.  For  the  keys  please  contact  Mr. Jean-",
            "Pierre Dupont  at  the  front  desk  of  the  building  on  any  business day.",
            "Nothing else  in  this  note  is  confidential  and  it  may be shared freely.",
        ]), properties: [.exports, .absent(["0148", "0199", "6789", "01234"])]),
        Probe(id: "F6 p19 short lines broken at a hyphen", source: .pdf([
            "(Fictional) The tenant may be reached on the main office line, which is 212-555-",
            "0148, or on the mobile line +1 646-555-",
            "0199. The tenant's SSN is 123-45-",
            "6789 and the docket is No. 1:24-cv-",
            "01234 in the Southern District. Contact Jean-",
            "Pierre Dupont for the keys.",
        ]), properties: [.exports, .absent(["0148", "0199", "6789", "01234"])]),
        Probe(id: "F6 t01 a dash set off by a space", source: .pdf([
            "(Fictional) Under  the  lease the tenant must report all changes. Tenant SSN -",
            "123-45-6789 and the landlord may be reached at the office line, which is Tel -",
            "010-62551234 during business hours. The parties signed the lease on 3 May 2026",
            "and agreed  that the deposit is held by the landlord until the lease is ended.",
        ]), properties: [.exports, .absent(["6789", "62551234"])]),
        Probe(id: "F6 en_wrap words keep their space", source: .pdf([
            "This Consulting Agreement is made by and between Willowcrest Studio LLC and",
            "Jordan Ellis, who accept each and every one of the terms of this Agreement,",
            "and it shall remain in force until the goods listed in Schedule One arrive.",
            "The costs of carriage and insurance are to be borne by the Buyer and/or",
            "the Seller in equal parts; questions are to go to jordan.ellis@example.com",
            "for the attention of the General Counsel, who replies within ten days.",
        ]), properties: [
            .exports, .absent(["jordan.ellis@example.com", "Agreement,and", "and/orthe"]),
            .kept(["} for the attention of the General Counsel"]),
        ]),

        // F7: amounts (first review p09; second review t05 and q03).
        Probe(id: "F7 p09 full-width thousands", source: .text("""
        （虚构示例）第一条 租金为人民币5，000元整，押金为1，250，000.00元，违约金为人民币50，000元，首付款为￥12，000元。
        第二条 半角对照：租金为人民币5,000元整，押金为1,250,000.00元，违约金为人民币50,000元，首付款为￥12,000元。
        第三条 全角对照：租金为人民币５，０００元整，押金为１，２５０，０００．００元。
        第四条 其他写法：价款为RMB 5，000，000元，USD 3，000，000，港币20，000元，5，000万元。
        """, .utf8), properties: [.exports, .noDigits, .roundTrips]),
        Probe(id: "F7 t05 amounts enumerated after a comma", source: .text(
            "（虚构）罚款分别为1，000，2，000元。违约金为500，1，500元。", .utf8
        ), properties: [.exports, .noDigits, .mappedValues(["1，000", "2，000元", "500", "1，500元"]), .roundTrips]),
        Probe(id: "F7 q03 enumerations and near misses", source: .text("""
        （虚构示例）价格分别为100，200，300元，另付5，10，20元。依据第1，2，3条，年度为2019，2020，2021年。
        本合同涉及金额为1，250，000.00元；保证金为人民币50，000元整，计12，500股，比例为12．5%。
        编号1，2，3的附件共5，000页，面积1，200平方米。
        """, .utf8), properties: [
            .exports,
            .mappedValues(["100", "200", "300元", "5", "10", "20元", "1，250，000.00元", "人民币50，000元整"]),
            .kept(["依据第1，2，3条", "年度为2019，2020，2021年", "计12，500股", "比例为12．5%", "编号1，2，3的附件共5，000页", "面积1，200平方米"]),
            .roundTrips,
        ]),

        // F8: identifiers (first review p04; second review q04, q05). In p04
        // the full-width email and the Tokyo landline are not detected yet
        // (recorded as follow-ups); the row holds what F8 covers.
        Probe(id: "F8 p04 full-width forms", source: .text(
            "（虚构示例）①联系电话：０１０－６２５５１２３４；②身份证号：１１０１０１１９９００３０７１２３４；③金额：５，０００元；"
                + "④㈱山田商事 Tel ０３－１２３４－５６７８；⑤邮箱 ｊｏｒｄａｎ＠ｅｘａｍｐｌｅ．ｃｏｍ；⑥张伟的手机：１３８００１３８０００。",
            .utf8
        ), properties: [.exports, .absent(["６２５５１２３４", "１１０１０１１９９００３０７１２３４", "５，０００", "１３８００１３８０００"]), .roundTrips]),
        Probe(id: "F8 q04 copula in English", source: .text("""
        (Fictional) The passport number is valid until 2030. The account number is pending with the bank.
        His ID number is the same as before. Her passport is X12345678 and his passport number was E98765432.
        The SSN is 123-45-6789. The account number is 12345678. The tax number is not yet assigned.
        """, .utf8), properties: [
            .exports, .absent(["X12345678", "E98765432", "123-45-6789", "12345678"]),
            .kept(["valid until 2030", "pending with the bank", "the same as before", "not yet assigned"]),
            .roundTrips,
        ]),
        Probe(id: "F8 q05 copula in Chinese", source: .text(
            "护照号码为E12345678，护照号是G12345678，身份证号码是110101199003071234，账号为6222021234567890123，账号为待定。", .utf8
        ), properties: [.exports, .absent(["E12345678", "G12345678", "110101199003071234", "6222021234567890123"]), .kept(["账号为待定"]), .roundTrips]),

        // T3: the email pattern on a long run (2.0 took 13.9 s at 40,000).
        Probe(id: "T3 a 40,000-character run", source: .text(String(repeating: "QUJD", count: 10_000), .utf8),
              properties: [.detectsWithin(2)]),

        // T1: names glued to a neighbour (first review p01, p10, p11, p17;
        // second review t03). The LDA V4 tagger reports their places.
        Probe(id: "T1 p01 glued, default", source: .text(ReviewProbeTableTests.p01, .utf8), model: true, properties: [.refuses]),
        Probe(id: "T1 p01 glued, auto-protect", source: .text(ReviewProbeTableTests.p01, .utf8), model: true, autoProtect: true, properties: [
            .exports, .onePlaceholder("Marek Okafor"), .onePlaceholder("Dana Whitfield"),
            .absent(["Okafor", "Whitfield"]), .roundTrips,
        ]),
        Probe(id: "T1 p10 only glued", source: .text(
            "(Fictional) The settlement letter was signed byMarek Okafor2 on 3 May 2026 and sent to the court.", .utf8
        ), model: true, properties: [.refuses]),
        Probe(id: "T1 p11 cut inside Ashdown", source: .text(
            "(Fictional) Mr. Mateo Ashdown will deliver the certificate. Counsel for Mr. Mateo Ashdown agreed.", .utf8
        ), model: true, properties: [.exports, .absent(["Ashdown", "Mateo"]), .roundTrips]),
        Probe(id: "T1 p17 footnote marker, auto-protect", source: .text(
            "(Fictional) The claimant, Marek Okafor, gave evidence on 3 May 2026. Cross-examination of Marek Okafor2 followed on 4 May 2026, and Marek Okafor was released.", .utf8
        ), model: true, autoProtect: true, properties: [.exports, .onePlaceholder("Marek Okafor"), .absent(["Okafor"]), .roundTrips]),
        Probe(id: "T1 t03 glued right and in capitals, default", source: .text(ReviewProbeTableTests.t03, .utf8), model: true, properties: [.refuses]),
        Probe(id: "T1 t03 glued right and in capitals, auto-protect", source: .text(ReviewProbeTableTests.t03, .utf8), model: true, autoProtect: true, properties: [
            .exports, .onePlaceholder("Marek Okafor"), .absent(["Okafor", "OKAFOR"]), .roundTrips,
        ]),

        // F1 and F2: names in memos the tagger located (the review's t1 and
        // t5 files, first review p06, p07).
        Probe(id: "F1 t1_memo citing a case", source: .text("""
        MEMORANDUM (fictional test memo)

        Re: Whitfield v. Harborline Logistics Inc. - settlement strategy

        In our opinion, Daniel Whitfield has a strong wrongful-termination claim against Harborline Logistics Inc. Mr. Whitfield was employed by Harborline from 2019 to 2024. Harborline's general counsel, Priya Raman, has offered USD 250,000. Daniel may be reached at daniel.whitfield@example.com.
        """, .utf8), model: true, properties: [.exports, .absent(["Daniel Whitfield", "Priya Raman", "daniel.whitfield@example.com", "250,000"]), .roundTrips]),
        Probe(id: "F1 t1_zh opinion citing a guiding case", source: .text("""
        关于参照指导案例24号处理本案的法律意见（虚构示例）

        林晓梅委托本所就其与海川物流有限公司的劳动争议出具意见。周启明律师认为，海川物流有限公司应当支付赔偿金。林晓梅的联系电话为13800138000。
        """, .utf8), model: true, properties: [.exports, .absent(["林晓梅", "周启明", "海川物流有限公司", "13800138000"]), .roundTrips]),
        Probe(id: "F2 t5_law short and lowercase names", source: .text(
            "(Fictional) Hartwell Law LLP (\"Hartwell Law\") represents Jordan Ellis. Hartwell Law will file the motion on Monday. "
                + "Messages from sam okafor and dana whitford were exported from the chat.", .utf8
        ), model: true, properties: [.exports, .absent(["Hartwell", "Jordan Ellis", "sam okafor", "dana whitford"]), .roundTrips]),
        Probe(id: "F1 p06 a witness in a US opinion", source: .text("""
        UNITED STATES COURT OF APPEALS FOR THE SECOND CIRCUIT

        JORDAN WHITFIELD, Plaintiff-Appellant, v. HARBORLINE LOGISTICS INC., Defendant-Appellee.

        No. 23-1234

        OPINION

        Plaintiff Jordan Whitfield appeals from a judgment of the district court dismissing her claims against Harborline Logistics Inc. We affirm. Her supervisor, Corin Ashby, recommended her termination.
        """, .utf8), model: true, properties: [.exports, .absent(["Corin Ashby"])]),
        Probe(id: "F1 p07 a witness in a guiding case", source: .text("""
        指导案例999号

        林晓梅诉周启明、海川物流有限公司机动车交通事故责任纠纷案

        基本案情
        原告林晓梅诉称：2025年2月10日，被告周启明驾驶的车辆与其相撞。证人王建国、李秀英到庭作证。
        """, .utf8), model: true, properties: [.exports, .absent(["王建国", "李秀英"])]),
        Probe(id: "F5 p21 a company name broken by a soft hyphen", source: .docx(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("(Fictional) Jordan Ellis signed for Harborline Logistics Inc. on 3 May 2026."))
                + DocxTestPackage.paragraph(runs: [
                    DocxTestPackage.run("Harbor"), "<w:r><w:softHyphen/></w:r>",
                    DocxTestPackage.run("line Logistics Inc. will deliver the goods."),
                ])
                + DocxTestPackage.paragraph(DocxTestPackage.run("Questions go to Jordan Ellis.")),
            parts: [],
            relationships: []
        ), model: true, properties: [.exports, .absent(["Jordan Ellis", "Harborline", "line Logistics"])]),
    ]

    static let p01 = "(Fictional) The settlement letter was signed byMarek Okafor2 on 3 May 2026. Marek Okafor later confirmed the terms by email.\n"
        + "Counsel for Dana Whitfield1 wrote to Dana Whitfield again on 5 May 2026."

    static let t03 = "(Fictional) The letter was signed by Marek Okaforand witnessed by Jane Doe. Marek Okafor confirmed it.\n"
        + "SIGNED BYMAREK OKAFOR ON 3 MAY 2026. Marek Okafor will attend."

    // MARK: - Running it

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewProbeTableTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    func testEveryProbeThatNeedsNoModel() throws {
        for probe in Self.probes where !probe.model {
            try check(probe, modelPath: nil)
        }
    }

    func testEveryProbeThatNeedsTheTagger() throws {
        guard let folder = ProcessInfo.processInfo.environment["LDA_V4_MODEL_DIR"] else {
            throw XCTSkip("set LDA_V4_MODEL_DIR to an LDA V4 model folder to run the tagger's probes")
        }
        for probe in Self.probes where probe.model {
            try check(probe, modelPath: folder)
        }
    }

    func testEveryProbeHasADistinctId() {
        XCTAssertEqual(Set(Self.probes.map(\.id)).count, Self.probes.count)
    }

    private static let protection = MappingProtection.passphrase("review-probe-table")

    private func check(_ probe: Probe, modelPath: String?) throws {
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try write(probe.source, in: folder)
        let id = probe.id

        for property in probe.properties {
            if case .importsAs(let expected) = property {
                XCTAssertEqual(try importedText(input), expected, "\(id): the input reads as another text")
            }
            if case .detectsWithin(let seconds) = property, case .text(let text, _) = probe.source {
                let started = Date()
                _ = DeterministicEngine().detect(text)
                XCTAssertLessThan(Date().timeIntervalSince(started), seconds, "\(id): detection is too slow")
            }
        }
        let wantsExport = probe.properties.contains {
            switch $0 {
            case .importsAs, .detectsWithin: return false
            default: return true
            }
        }
        guard wantsExport else { return }

        let output = folder.appendingPathComponent("out", isDirectory: true)
        let result: AnonymizeResult
        do {
            result = try LDAService.anonymize(
                input: input,
                outputDir: output,
                protection: Self.protection,
                createdAtISO8601: "2026-11-11T00:00:00Z",
                llmModelPath: modelPath,
                unlocatedPolicy: probe.autoProtect ? .protect : .refuse
            )
        } catch {
            XCTAssertTrue(probe.properties.contains { if case .refuses = $0 { return true }; return false },
                          "\(id): the export was refused (\(type(of: error)))")
            return
        }
        if probe.properties.contains(where: { if case .refuses = $0 { return true }; return false }) {
            XCTFail("\(id): the export was written although it must be refused")
            return
        }
        let redacted = try redactedText(result.redactedFileURL)
        let members = try outputMembers(result.redactedFileURL)
        let mapping = try MappingStore.load(from: result.mappingFileURL, protection: Self.protection)
        let values = mapping.entries.values.map(\.value)

        for property in probe.properties {
            switch property {
            case .absent(let strings):
                for string in strings {
                    for (member, text) in members where text.contains(string) {
                        XCTFail("\(id): \(string.debugDescription) is still in \(member)")
                    }
                }
            case .kept(let strings):
                for string in strings {
                    XCTAssertTrue(redacted.contains(string), "\(id): \(string.debugDescription) is gone from: \(redacted)")
                }
            case .noDigits:
                let outsideTokens = redacted.replacingOccurrences(
                    of: #"\{[A-Z_]+_[0-9]+\}"#, with: "", options: .regularExpression
                )
                XCTAssertFalse(outsideTokens.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) },
                               "\(id): a digit is left in: \(redacted)")
            case .mappedValues(let expected):
                for value in expected {
                    XCTAssertTrue(values.contains(value), "\(id): \(value.debugDescription) is not a value of its own in \(values.sorted())")
                }
            case .onePlaceholder(let value):
                XCTAssertEqual(values.filter { $0 == value }.count, 1, "\(id): \(value.debugDescription) in \(values.sorted())")
                XCTAssertFalse(values.contains { $0 != value && $0.contains(value) },
                               "\(id): \(value.debugDescription) is also part of another value: \(values.sorted())")
            case .roundTrips:
                let restoredURL = folder.appendingPathComponent("restored." + result.redactedFileURL.pathExtension)
                _ = try LDAService.restore(
                    editedRedacted: result.redactedFileURL,
                    mapping: result.mappingFileURL,
                    protection: Self.protection,
                    output: restoredURL
                )
                XCTAssertEqual(try redactedText(restoredURL), try importedText(input), "\(id): the restore differs from the input")
            case .refuses, .exports, .importsAs, .detectsWithin:
                break
            }
        }
    }

    // MARK: - Inputs and outputs

    private func write(_ source: Source, in folder: URL) throws -> URL {
        switch source {
        case .text(let text, let encoding):
            let url = folder.appendingPathComponent("probe.txt")
            try XCTUnwrap(text.data(using: encoding), "the probe must encode").write(to: url)
            return url
        case .pdf(let lines):
            let url = folder.appendingPathComponent("probe.pdf")
            try Self.makePDF(lines, at: url)
            return url
        case .docx(let body, let parts, let relationships):
            return try DocxTestPackage.write(
                body: body,
                extraParts: parts,
                extraDocumentRelationships: relationships,
                to: folder.appendingPathComponent("probe.docx")
            )
        }
    }

    /// The text an import of `url` reads, by its extension.
    private func importedText(_ url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "docx": return try DocxImporter().importDocument(url).text
        case "pdf": return try PdfImporter().importDocument(url).text
        default: return try TextDocumentIO().importDocument(url).text
        }
    }

    /// The redacted text: the companion of a text or PDF input, the body of
    /// a Word package.
    private func redactedText(_ url: URL) throws -> String {
        url.pathExtension.lowercased() == "docx"
            ? try DocxImporter().importDocument(url).text
            : try String(contentsOf: url, encoding: .utf8)
    }

    /// Every place an output holds text: the companion, or each member of a
    /// Word package with XML references and percent escapes decoded.
    private func outputMembers(_ url: URL) throws -> [(String, String)] {
        guard url.pathExtension.lowercased() == "docx" else {
            return [(url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))]
        }
        return try DocxParts.memberPaths(in: url).compactMap { path in
            guard let raw = String(data: try DocxZip.readEntry(path, from: url), encoding: .utf8) else { return nil }
            let decoded = raw
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            return (path, decoded.removingPercentEncoding ?? decoded)
        }
    }

    private static func makePDF(_ lines: [String], at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw XCTSkip("no PDF context") }
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        context.beginPage(mediaBox: &box)
        var y: CGFloat = 720
        for line in lines {
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), context)
            y -= 11 * 1.6
        }
        context.endPage()
        context.closePDF()
    }
}
