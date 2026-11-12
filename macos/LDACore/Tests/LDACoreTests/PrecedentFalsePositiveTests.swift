//
//  PrecedentFalsePositiveTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F1. The published-precedent rule released the parties'
//  names of ordinary documents: a memo whose "Re:" line reads "X v. Y" and
//  which says "In our opinion" anywhere, an email whose subject names a case,
//  a draft brief that mentions "the interests of justice", and a Chinese legal
//  opinion that cites a guiding case by number in its title. A memo, letter,
//  email, brief or pleading is not a published precedent. Genuine ones (an SPC
//  or SPP guiding case whose title block is the document's own heading, a
//  published US opinion with a court header and an opinion heading) keep
//  working, and whenever names are released every headless path says so.
//
//  The two memos are the review's probe documents (inputs/v/t1_memo.txt and
//  t1_zh.txt), verbatim. Every name in them is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import TinyPII
@testable import LDACLI
@testable import LDAMCP
@testable import LDAUI
@testable import LDACore

final class PrecedentFalsePositiveTests: XCTestCase {

    // MARK: - Fixtures

    static let memo = """
    PRIVILEGED AND CONFIDENTIAL (fictional test memo)

    MEMORANDUM

    To: File
    From: A. Reviewer
    Re: Whitfield v. Harborline Logistics Inc. - settlement strategy

    In our opinion, Daniel Whitfield has a strong wrongful-termination claim against Harborline Logistics Inc. \
    Mr. Whitfield was employed by Harborline from 2019 to 2024. Harborline's general counsel, Priya Raman, has \
    offered USD 250,000. We recommend that Whitfield reject the offer. Daniel may be reached at \
    daniel.whitfield@example.com.

    """

    static let memoEntities = #"""
    {"entities":[{"value":"Daniel Whitfield","type":"PERSON"},{"value":"Whitfield","type":"PERSON"},{"value":"Harborline Logistics Inc.","type":"COMPANY"},{"value":"Harborline","type":"COMPANY"},{"value":"Priya Raman","type":"PERSON"},{"value":"Daniel","type":"PERSON"}],"redacted_text":""}
    """#

    static let zhMemo = """
    关于参照指导案例24号处理本案的法律意见（虚构示例）

    致：林晓梅女士
    自：周启明律师

    林晓梅委托本所就其与海川物流有限公司的劳动争议出具意见。周启明律师认为，海川物流有限公司应当支付赔偿金。

    基本案情
    林晓梅于2019年入职海川物流有限公司，2024年被辞退。林晓梅的联系电话为13800138000。

    """

    static let zhMemoEntities = #"""
    {"entities":[{"value":"林晓梅","type":"PERSON"},{"value":"周启明","type":"PERSON"},{"value":"海川物流有限公司","type":"COMPANY"}],"redacted_text":""}
    """#

    static let email = """
    From: A. Reviewer
    To: Litigation team
    Subject: Okafor v. Brightline Capital - draft opinion letter

    Team, the opinion letter for Samuel Okafor is attached. Brightline Capital has not answered yet. In my opinion we \
    should file next week.
    """

    static let brief = """
    UNITED STATES DISTRICT COURT
    SOUTHERN DISTRICT OF NEW YORK

    Jordan Ellis v. Brightline Capital LLC

    DRAFT PLAINTIFF'S MEMORANDUM OF LAW IN SUPPORT OF A STAY

    The interests of justice favor a stay. Jordan Ellis asks the Court to stay the action while Brightline Capital LLC \
    answers the complaint.
    """

    /// The same brief with no title at all: a court header and a caption are
    /// what every pleading starts with, so they alone do not make an opinion.
    static let untitledBrief = """
    UNITED STATES DISTRICT COURT
    SOUTHERN DISTRICT OF NEW YORK

    Jordan Ellis v. Brightline Capital LLC

    The interests of justice favor a stay. Jordan Ellis asks the Court to stay the action while Brightline Capital LLC \
    answers the complaint.
    """

    /// A genuine SPC guiding case (the shape PrecedentPartyRuleTests pins).
    static let guiding = """
    指导案例96号：宋文军诉西安市大华餐饮有限公司股东资格确认纠纷案
    （最高人民法院审判委员会讨论通过 2018年6月20日发布）
    关键词 民事/股东资格确认
    基本案情
    原告宋文军诉称，西安市大华餐饮有限公司（以下简称大华公司）未向其返还出资。证人李明出庭作证。
    """

    static let guidingEntities = #"""
    {"entities":[{"value":"宋文军","type":"PERSON"},{"value":"西安市大华餐饮有限公司","type":"COMPANY"},{"value":"大华公司","type":"COMPANY"},{"value":"李明","type":"PERSON"}],"redacted_text":""}
    """#

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String { output }
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrecedentFalsePositiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    private func useExtractor(reporting json: String) {
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: FixedCompleter(output: json)) }
    }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private var fakeModelPath: String { workDir.appendingPathComponent("fixture-model.gguf").path }

    // MARK: - What is not a published precedent

    func testTheReviewMemoWithACaseInItsReLineIsNotAPublishedPrecedent() {
        XCTAssertNil(PrecedentRule.caption(of: Self.memo))
    }

    func testTheChineseOpinionCitingAGuidingCaseInItsTitleIsNotAPublishedPrecedent() {
        XCTAssertNil(PrecedentRule.caption(of: Self.zhMemo))
    }

    func testAnEmailWhoseSubjectNamesACaseIsNotAPublishedPrecedent() {
        XCTAssertNil(PrecedentRule.caption(of: Self.email))
    }

    func testADraftBriefThatMentionsTheInterestsOfJusticeIsNotAPublishedPrecedent() {
        XCTAssertNil(PrecedentRule.caption(of: Self.brief))
        XCTAssertNil(PrecedentRule.caption(of: Self.untitledBrief), "a court header and a caption alone are not an opinion")
    }

    func testAMemoTitledAfterAGuidingCaseIsNotTheGuidingCase() {
        let analysis = """
        指导案例24号的适用分析

        致：林晓梅女士
        林晓梅与海川物流有限公司的争议可以参照该案处理。
        基本案情
        林晓梅于2019年入职海川物流有限公司。
        """
        XCTAssertNil(PrecedentRule.caption(of: analysis))
    }

    func testAGuidingCaseHeadingFollowedByALetterIsNotACaption() {
        // The heading looks right, but the block before the body marker holds
        // a letter, so the document is not the guiding case itself.
        let letter = """
        指导案例96号
        宋文军诉西安市大华餐饮有限公司股东资格确认纠纷案
        致：林晓梅女士
        林晓梅委托本所出具意见。
        基本案情
        原告宋文军诉称。
        """
        XCTAssertNil(PrecedentRule.caption(of: letter))
    }

    // MARK: - Genuine ones keep working

    func testAGuidingCaseWithItsNumberOnALineOfItsOwnIsStillRecognized() throws {
        let text = """
        指导案例96号
        宋文军诉西安市大华餐饮有限公司股东资格确认纠纷案
        （最高人民法院审判委员会讨论通过 2018年6月20日发布）
        关键词 民事/股东资格确认
        基本案情
        原告宋文军诉称，西安市大华餐饮有限公司未向其返还出资。
        """
        let caption = try XCTUnwrap(PrecedentRule.caption(of: text))
        XCTAssertTrue(caption.contains("宋文军诉西安市大华餐饮有限公司"))
        XCTAssertFalse(caption.contains("关键词"))
    }

    func testAnSPPGuidingCaseWhoseNumberFollowsItsTitleIsStillRecognized() throws {
        let text = """
        施某某等17人聚众斗殴案
        （检例第1号）
        【要旨】
        检察机关办理群体性事件引发的犯罪案件。
        【基本案情】
        被告人施某某，男，1945年出生。
        """
        let caption = try XCTUnwrap(PrecedentRule.caption(of: text))
        XCTAssertTrue(caption.hasPrefix("施某某等17人聚众斗殴案"))
    }

    func testAPublishedOpinionWithACourtHeaderAndAnOpinionHeadingIsStillRecognized() {
        let text = """
        UNITED STATES COURT OF APPEALS FOR THE FIFTH CIRCUIT

        Parker v. Highland Park, Inc.

        Before SMITH, JONES and DAVIS, Circuit Judges.

        OPINION

        Parker sued Highland Park, Inc. for fraud.
        """
        XCTAssertEqual(PrecedentRule.caption(of: text), "Parker v. Highland Park, Inc.")
    }

    // MARK: - Release by value, not by substring

    func testALatinNameInsideALongerWordOfTheCaptionIsNotReleased() throws {
        let text = """
        UNITED STATES COURT OF APPEALS FOR THE SECOND CIRCUIT

        Annabel Lee v. Northwind Traders Inc.

        OPINION

        Annabel Lee sued Northwind Traders Inc. A witness, Ann, testified for the defense.
        """
        let ns = text as NSString
        func span(_ value: String, _ type: EntityType) -> LDACore.Span {
            let range = ns.range(of: value, options: .backwards)
            return LDACore.Span(start: range.location, end: range.location + range.length, type: type, text: value,
                        source: .llm, confidence: 0.9, priority: 30)
        }
        let release = try XCTUnwrap(PrecedentPartyRule.release(
            text: text,
            spans: [span("Annabel Lee", .person), span("Northwind Traders Inc.", .company), span("Ann", .person)]
        ))
        XCTAssertEqual(Set(release.values), ["Annabel Lee", "Northwind Traders Inc."])
        XCTAssertFalse(release.normalizedValues.contains(TextMatching.normalize("Ann")),
                       "a witness whose name is only a piece of a party's word stays redacted")
    }

    // MARK: - Through the service

    func testTheMemoIsFullyRedactedThroughTheService() throws {
        useExtractor(reporting: Self.memoEntities)
        let input = try write(Self.memo, "t1_memo.txt")
        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("precedent-false-positive"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: fakeModelPath
        )
        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        for name in ["Whitfield", "Harborline", "Priya", "Raman", "Daniel"] {
            XCTAssertFalse(redacted.contains(name), "\(name) stayed in clear: \(redacted)")
        }
        XCTAssertEqual(result.precedentReleasedValueCount, 0)
    }

    func testTheChineseMemoIsFullyRedactedThroughTheService() throws {
        useExtractor(reporting: Self.zhMemoEntities)
        let input = try write(Self.zhMemo, "t1_zh.txt")
        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("precedent-false-positive"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: fakeModelPath
        )
        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        for name in ["林晓梅", "周启明", "海川物流有限公司"] {
            XCTAssertFalse(redacted.contains(name), "\(name) stayed in clear: \(redacted)")
        }
        XCTAssertEqual(result.precedentReleasedValueCount, 0)
    }

    // MARK: - Every headless path reports a release

    func testAnonymizeReportsTheReleaseInTheResultTheSummaryJSONAndOnStderr() throws {
        useExtractor(reporting: Self.guidingEntities)
        let input = try write(Self.guiding, "guiding.txt")
        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("precedent-false-positive"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: fakeModelPath
        )
        XCTAssertEqual(result.precedentReleasedValueCount, 2)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try CLIJSON.encode(AnonymizeSummaryJSON(result: result)).utf8)
        ) as? [String: Any])
        XCTAssertEqual(json["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(json["precedentPartiesReleased"] as? Bool, true)

        let notice = try XCTUnwrap(LDACLI.precedentReleaseNotice(count: result.precedentReleasedValueCount))
        XCTAssertTrue(notice.contains("2"), notice)
        XCTAssertTrue(notice.contains("published precedent"), notice)
        for name in ["宋文军", "西安市大华餐饮有限公司"] {
            XCTAssertFalse(notice.contains(name), "the notice must not carry a value")
        }
        XCTAssertNil(LDACLI.precedentReleaseNotice(count: 0))
    }

    func testAnOlderSummaryWithoutTheReleaseFieldsStillDecodes() throws {
        let old = #"{"embeddedMediaCount":0,"entityCount":1,"imageRedactionCount":0,"mappingFileURL":"/m","redactedFileURL":"/r","unboxedTokenCount":0}"#
        let decoded = try JSONDecoder().decode(AnonymizeSummaryJSON.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.precedentReleasedValueCount, 0)
        XCTAssertFalse(decoded.precedentPartiesReleased)
    }

    func testDetectReportsTheRelease() throws {
        useExtractor(reporting: Self.guidingEntities)
        let input = try write(Self.guiding, "guiding.txt")
        let summary = try LDAService.detectSummary(input: input, llmModelPath: fakeModelPath)
        XCTAssertEqual(summary.precedentReleasedValueCount, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try CLIJSON.encode(DetectSummaryJSON(summary: summary)).utf8)
        ) as? [String: Any])
        XCTAssertEqual(json["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(json["precedentPartiesReleased"] as? Bool, true)
    }

    func testTheBatchReportCarriesTheReleaseInJSONTextAndProgress() throws {
        useExtractor(reporting: Self.guidingEntities)
        let source = workDir.appendingPathComponent("source", isDirectory: true)
        let output = workDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(Self.guiding.utf8).write(to: source.appendingPathComponent("guiding.txt"))

        let report = try BatchAnonymizer.run(
            sourceFolder: source,
            outputFolder: output,
            options: BatchOptions(
                modelPath: fakeModelPath,
                protectionLabel: "passphrase",
                protection: { _ in .passphrase("precedent-false-positive") }
            )
        )
        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(item.precedentReleasedValueCount, 2)
        XCTAssertTrue(item.precedentPartiesReleased)
        XCTAssertEqual(report.precedentReleasedValueCount, 2)

        let stored = try Data(contentsOf: output.appendingPathComponent(BatchReport.fileName))
        let storedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let storedItem = try XCTUnwrap((storedJSON["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(storedItem["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(storedItem["precedentPartiesReleased"] as? Bool, true)

        let text = try String(contentsOf: output.appendingPathComponent(BatchReport.summaryFileName), encoding: .utf8)
        XCTAssertTrue(text.contains("published precedent"), text)
        XCTAssertFalse(text.contains("宋文军"), "the report never carries document text")

        let progress = BatchProgress(index: 1, total: 1, source: item.source, item: item)
        XCTAssertTrue(Batch.progressLine(progress, item).contains("published precedent"))

        let problems = BatchAnonymizeModel.problems(in: report, language: .english)
        XCTAssertEqual(problems.first?.lines.contains { $0.contains("published judgment") && $0.contains("2") }, true,
                       "the batch window lists the release too")

        let summaryJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try CLIJSON.encode(BatchSummaryJSON(report: report, outputFolder: output)).utf8)
        ) as? [String: Any])
        XCTAssertEqual(summaryJSON["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(summaryJSON["precedentPartiesReleased"] as? Bool, true)
    }

    func testAnOlderBatchReportLineWithoutTheReleaseFieldsStillDecodes() throws {
        let old = #"{"autoProtectedValueCount":0,"embeddedMediaCount":0,"replacedCount":1,"seconds":0.1,"source":"a.txt","sourceModified":1,"sourceSize":1,"status":"done","trackedChangeCount":0,"unboxedTokenCount":0}"#
        let decoded = try JSONDecoder().decode(BatchItem.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.precedentReleasedValueCount, 0)
        XCTAssertFalse(decoded.precedentPartiesReleased)
    }

    func testTheMCPToolsReportTheRelease() throws {
        useExtractor(reporting: Self.guidingEntities)
        let vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        let server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        let vault = VaultTestSupport.vault(root: vaultDir)
        let handle = try vault.stage(fileURL: try write(Self.guiding, "guiding.txt"),
                                     stagedAtISO8601: "2026-11-11T00:00:00Z").handle

        func summary(_ tool: String, _ arguments: [String: Any]) throws -> [String: Any] {
            let payload = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments]
            ])
            let response = try XCTUnwrap(JSONSerialization.jsonObject(
                with: try XCTUnwrap(server.handle(payload))
            ) as? [String: Any])
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
            XCTAssertFalse((result["isError"] as? Bool) ?? false, "\(tool) failed: \(text)")
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }

        let detected = try summary("detect_entities", ["handle": handle, "modelPath": fakeModelPath])
        XCTAssertEqual(detected["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(detected["precedentPartiesReleased"] as? Bool, true)

        let anonymized = try summary("anonymize", [
            "handle": handle, "modelPath": fakeModelPath, "passphrase": "precedent-false-positive"
        ])
        XCTAssertEqual(anonymized["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(anonymized["precedentPartiesReleased"] as? Bool, true)

        let session = try summary("anonymize_session", [
            "handles": [handle], "modelPath": fakeModelPath, "passphrase": "precedent-false-positive"
        ])
        let document = try XCTUnwrap((session["documents"] as? [[String: Any]])?.first)
        XCTAssertEqual(document["precedentReleasedValueCount"] as? Int, 2)
        XCTAssertEqual(session["precedentPartiesReleased"] as? Bool, true)
    }
}
