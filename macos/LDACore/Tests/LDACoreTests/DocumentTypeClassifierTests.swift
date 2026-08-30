//
//  DocumentTypeClassifierTests.swift
//  LDACoreTests
//
//  Tests for the keyword/structure document-type classifier that routes the
//  extraction prompt. No model involved: pure heuristics over the text.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocumentTypeClassifierTests: XCTestCase {

    // MARK: - Judgments

    func testJudgmentTitleClassifies() {
        let text = """
        浙江省杭州市中级人民法院
        民事判决书
        （2025）浙01民终1234号
        上诉人（原审被告）：杭州快帆科技有限公司。
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .judgment)
    }

    func testLetterSpacedJudgmentTitleClassifies() {
        let text = """
        浙江省杭州市中级人民法院
        民 事 判 决 书
        （2025）浙01民终1234号
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .judgment)
    }

    func testCourtOpinionBodySignalClassifiesAsJudgment() {
        let text = """
        关于本案的处理意见

        经审查全部证据材料，本院认为，双方签订的合同合法有效。
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .judgment)
    }

    func testJudgmentAboutAContractStaysAJudgment() {
        let text = """
        民事判决书
        原告与被告买卖合同纠纷一案，本院受理后依法审理。
        甲方与乙方的合同关系成立。
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .judgment)
    }

    func testRulingTitleClassifies() {
        let text = "民事裁定书\n（2025）沪0105民初998号\n本院立案审查。"
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .judgment)
    }

    // MARK: - Complaints

    func testComplaintTitleClassifies() {
        let text = """
        民事起诉状
        原告：张三，男，1980年1月1日出生。
        被告：杭州快帆科技有限公司。
        诉讼请求：
        一、判令被告支付货款人民币100万元；
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .complaint)
    }

    func testClaimsPlusDefendantHeadClassifiesAsComplaint() {
        let text = """
        诉讼请求：
        一、判令被告返还借款本金；
        二、本案诉讼费由被告承担。
        事实与理由：
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .complaint)
    }

    // MARK: - Contracts

    func testContractTitleClassifies() {
        let text = """
        股权转让协议

        甲方：杭州快帆科技有限公司
        乙方：张三
        鉴于甲方持有目标公司股权。
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .contract)
    }

    func testEnglishAgreementClassifiesAsContract() {
        let text = """
        SHARE PURCHASE AGREEMENT

        This Agreement is entered into by and between the parties below.
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .contract)
    }

    func testPartyLabelsAloneClassifyAsContract() {
        let text = "经友好协商，甲方同意向乙方交付设备，乙方按期付款。"
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .contract)
    }

    // MARK: - Disclosures

    func testStockHeaderClassifiesAsDisclosure() {
        let text = """
        证券代码：600000    证券简称：快帆股份    公告编号：2026-018

        杭州快帆科技股份有限公司关于对外投资的公告
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .disclosure)
    }

    func testBoardAnnouncementClassifiesAsDisclosure() {
        let text = """
        杭州快帆科技股份有限公司董事会公告

        本公司董事会及全体董事保证本公告内容不存在虚假记载。
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .disclosure)
    }

    // MARK: - Letters

    func testLawyerLetterClassifies() {
        let text = """
        律师函

        致：杭州快帆科技有限公司
        本所受张三委托，就贵司拖欠货款事宜致函如下。
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .letter)
    }

    func testDearSalutationClassifiesAsLetter() {
        let text = """
        Dear Mr. King,

        We write on behalf of our client regarding the outstanding invoice.
        """
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .letter)
    }

    func testJingQiZheClassifiesAsLetter() {
        let text = "敬启者：\n兹通知贵司，合作事项已获批准。"
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .letter)
    }

    // MARK: - Generic

    func testPlainProseIsGeneric() {
        let text = "会议纪要：与会人员讨论了下季度的产品发布安排，并确定了时间表。"
        XCTAssertEqual(DocumentTypeClassifier.classify(text), .generic)
    }

    func testEmptyTextIsGeneric() {
        XCTAssertEqual(DocumentTypeClassifier.classify(""), .generic)
    }
}
