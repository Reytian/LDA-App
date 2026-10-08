//
//  TinyPIIRuntimeTests.swift
//  LDACoreTests
//
//  Unit tests of the TinyPII target, the runtime of the built-in LDA V4
//  tagger, carried over from the tiny-PII reference package. The
//  normalization, decoding and windowing cases pin behaviour the Python
//  reference pipeline has; the precedent cases are the same as
//  datagen/tests/test_precedent_rule.py. The tokenizer parity test runs when
//  TINYPII_ASSETS and TINYPII_GOLDEN point at exported assets and a golden file.
//
//  This file imports TinyPII only: TinyPII and LDACore both declare Span and
//  Tokenizer, and a file that imported both would have to qualify every use.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import XCTest
@testable import TinyPII

final class TinyPIINormalizedStringTests: XCTestCase {
    // HF tokenizers' own test (normalizers/precompiled.rs): an expansion followed by a removal.
    func testExpansionFollowedByRemoval() {
        var n = NormalizedString("\u{2122}\u{1E}g")
        n.transform([("T", 0), ("M", 1), ("g", -1)].map { (Unicode.Scalar($0.0)!, $0.1) }, initialOffset: 0)
        XCTAssertEqual(String(decoding: n.normalized, as: Unicode.UTF8.self), "TMg")
    }

    func testReplaceAlignsToTheLastMatchedByte() {
        var n = NormalizedString("a   b")
        n.replace(matches: [1..<4], with: " ")
        XCTAssertEqual(String(decoding: n.normalized, as: Unicode.UTF8.self), "a b")
        XCTAssertEqual(n.alignments[1].0, 3)
        XCTAssertEqual(n.alignments[1].1, 4)
    }
}

final class TinyPIIDecodeTests: XCTestCase {
    func testPythonSumIsCompensated() {
        XCTAssertEqual(pythonSum([Double](repeating: 0.1, count: 10)), 1.0)  // CPython 3.12: sum([0.1]*10) == 1.0
        XCTAssertNotEqual([Double](repeating: 0.1, count: 10).reduce(0, +), 1.0)
    }

    func testViterbiTiesGoToTheLowestLabelIndex() {
        let names = ["O", "B-PERSON", "I-PERSON", "E-PERSON", "S-PERSON"]
        let decoder = Decoder(labelNames: names)
        XCTAssertEqual(decoder.viterbi([[Double]](repeating: [0, 0, 0, 0, 0], count: 3)), [0, 0, 0])
        // A B must be followed by I/E of its type and the path must end on O/E/S.
        XCTAssertEqual(decoder.viterbi([[-9, 0, -9, -9, -9], [-9, -9, -9, 0, -9]]), [1, 3])
    }

    func testWindowsStepByCapacityMinusStride() throws {
        let tokens = (0..<600).map { Token(id: 5, start: $0, end: $0 + 1, start16: $0, end16: $0 + 1) }
        let tables = try JSONDecoder().decode(CharTables.self, from: Data(#"{"space":[[32,32]],"han_or_punct":[],"py_space":[[32,32]]}"#.utf8))
        let windows = makeWindows(tokens: tokens, text: String(repeating: "x", count: 601), tables: tables, maxLength: 256,
                                  stride: 64, cls: 0, sep: 2)
        XCTAssertEqual(windows.map { $0.inputIds.count - 2 }, [254, 254, 220])  // [0,254), [190,444), [380,600)
        XCTAssertEqual(windows.map { $0.offsets[1].0 }, [0, 190, 380])
        XCTAssertEqual(windows.last?.isLast, true)
    }
}

/// Exact parity with the Python tokenizer, when TINYPII_ASSETS and TINYPII_GOLDEN point at exported assets and a
/// golden file from runtime/golden_tokenize.py.
final class TinyPIITokenizerParityTests: XCTestCase {
    func testGoldenTokens() throws {
        let env = ProcessInfo.processInfo.environment
        guard let assets = env["TINYPII_ASSETS"], let golden = env["TINYPII_GOLDEN"] else { throw XCTSkip("set TINYPII_ASSETS and TINYPII_GOLDEN") }
        let tokenizer = try Tokenizer(assets: URL(fileURLWithPath: assets))
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: golden))) as! [[String: Any]]
        var mismatched: [String] = []
        for row in rows {
            let tokens = tokenizer.encode(row["text"] as! String)
            let ids = row["ids"] as! [Int], offsets = row["offsets"] as! [[Int]]
            if tokens.map({ $0.id }) != ids || tokens.map({ [$0.start, $0.end] }) != offsets { mismatched.append(row["id"] as! String) }
        }
        XCTAssertEqual(mismatched, [], "\(mismatched.count) of \(rows.count) texts differ")
    }
}

/// The same cases as datagen/tests/test_precedent_rule.py.
final class TinyPIIPrecedentRuleTests: XCTestCase {
    let guiding = "指导案例96号：宋文军诉西安市大华餐饮有限公司股东资格确认纠纷案\n（最高人民法院审判委员会讨论通过 2018年6月20日发布）\n"
        + "关键词 民事/股东资格确认\n基本案情\n原告宋文军诉称，西安市大华餐饮有限公司（以下简称大华公司）未向其返还出资。证人李明出庭作证。"
    let us = "UNITED STATES COURT OF APPEALS FOR THE FIFTH CIRCUIT\n\nParker v. Highland Park, Inc.\n\n"
        + "Before SMITH, JONES and DAVIS, Circuit Judges.\n\nOPINION\n\nParker sued Highland Park, Inc. for fraud. "
        + "Judge Lindsay found that Parker had no claim. See Smith v. Jones, 123 F.3d 456 (5th Cir. 1997)."

    func spans(_ text: String, _ items: [(String, String)]) -> [DocumentSpan] {
        let ns = text as NSString
        var out: [DocumentSpan] = []
        for (surface, label) in items {
            var from = 0
            while true {
                let r = ns.range(of: surface, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                out.append(DocumentSpan(span: Span(start: r.location, end: r.location + r.length, label: label, score: 1),
                                        start16: r.location, end16: r.location + r.length))
                from = r.location + r.length
            }
        }
        return out.sorted { $0.start16 < $1.start16 }
    }

    func texts(_ text: String, _ s: [DocumentSpan]) -> [String] {
        s.map { (text as NSString).substring(with: NSRange(location: $0.start16, length: $0.end16 - $0.start16)) }
    }

    func testGuidingCaseCaptionAndParties() {
        let caption = PrecedentRule.caption(of: guiding)
        XCTAssertTrue(caption?.hasPrefix("指导案例96号：宋文军诉") == true)
        XCTAssertFalse(caption?.contains("关键词") ?? true)
        let all = spans(guiding, [("宋文军", "PERSON"), ("西安市大华餐饮有限公司", "COMPANY"), ("李明", "PERSON"), ("大华公司", "COMPANY")])
        let (kept, released) = PrecedentRule.keepParties(text: guiding, spans: all, caption: caption)
        XCTAssertEqual(Set(texts(guiding, released)), ["宋文军", "西安市大华餐饮有限公司"])
        XCTAssertEqual(Set(texts(guiding, kept)), ["大华公司", "李明"])
    }

    func testUSPublishedOpinionKeepsPartiesNotTheJudge() {
        let caption = PrecedentRule.caption(of: us)
        XCTAssertEqual(caption, "Parker v. Highland Park, Inc.")
        let all = spans(us, [("Parker", "PERSON"), ("Highland Park, Inc.", "COMPANY"), ("Lindsay", "PERSON")])
        let (kept, released) = PrecedentRule.keepParties(text: us, spans: all, caption: caption)
        XCTAssertEqual(Set(texts(us, released)), ["Parker", "Highland Park, Inc."])
        XCTAssertEqual(texts(us, kept), ["Lindsay"])
    }

    func testConservativeDetection() {
        XCTAssertNil(PrecedentRule.caption(of: us.replacingOccurrences(of: "OPINION", with: "NOT FOR PUBLICATION\n\nOPINION")))
        XCTAssertNil(PrecedentRule.caption(of: "MEMORANDUM\n\nParker v. Highland Park, Inc.\n\nThe parties agree that the lease ends."))
        XCTAssertNil(PrecedentRule.caption(of: "Smith v. Jones, 123 F.3d 456 (5th Cir. 1997), held that OPINION testimony is inadmissible."))
        XCTAssertNil(PrecedentRule.caption(of: "原告宋文军诉称，被告未返还出资。"))
        let one = spans(guiding, [("宋文军", "PERSON")])
        let (kept, released) = PrecedentRule.keepParties(text: guiding, spans: one, caption: nil)
        XCTAssertEqual(kept.count, one.count)
        XCTAssertTrue(released.isEmpty)
    }
}
