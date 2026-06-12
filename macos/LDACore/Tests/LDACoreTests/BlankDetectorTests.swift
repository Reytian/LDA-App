//
//  BlankDetectorTests.swift
//  LDACoreTests
//
//  Deterministic blank detection: every supported convention, label
//  normalization, context windows, overlap resolution, and offsets.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class BlankDetectorTests: XCTestCase {

    private func labels(_ text: String) -> [String] {
        BlankDetector.detect(in: text).map(\.label)
    }

    func testBracketedLabel() {
        let text = "between [Company Name], a company incorporated in [Jurisdiction]"
        let blanks = BlankDetector.detect(in: text)
        XCTAssertEqual(blanks.map(\.label), ["Company Name", "Jurisdiction"])
        guard case .textSpan(let start, let end) = blanks[0].location else {
            return XCTFail("expected textSpan")
        }
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: start, length: end - start)), "[Company Name]")
    }

    func testBracketedDotAndUnderscoreContentsNormalizeToEmptyLabel() {
        XCTAssertEqual(labels("on [●] and [•] and [___]"), ["", "", ""])
    }

    func testUnderscoreRunsTwoOrMore() {
        let blanks = BlankDetector.detect(in: "this ___ day of ____, 20__")
        XCTAssertEqual(blanks.count, 3)
        XCTAssertEqual(blanks.map(\.label), ["", "", ""])
        // Pin the first blank's raw offsets: the surface text must be "___".
        guard case .textSpan(let start, let end) = blanks[0].location else {
            return XCTFail("expected textSpan for first blank")
        }
        XCTAssertEqual(("this ___ day of ____, 20__" as NSString).substring(with: NSRange(location: start, length: end - start)), "___")
    }

    func testSingleUnderscoreIgnored() {
        XCTAssertEqual(BlankDetector.detect(in: "a_b and snake_case").count, 0)
    }

    func testBareDotPlaceholders() {
        XCTAssertEqual(BlankDetector.detect(in: "the sum of ●● dollars and • cents").count, 2)
    }

    func testHandlebarsAndGuillemets() {
        XCTAssertEqual(labels("{{company_name}} and «IncorporationDate»"), ["company_name", "IncorporationDate"])
    }

    func testHandlebarsUnderscoreDoesNotDoubleReport() {
        // The underscores inside {{company_name}} must not surface as a second
        // underscore-run blank.
        XCTAssertEqual(BlankDetector.detect(in: "{{company_name}}").count, 1)
    }

    func testBracketContentsLongerThanSixtyCharsIgnored() {
        let long = String(repeating: "x", count: 80)
        XCTAssertEqual(BlankDetector.detect(in: "see [\(long)] there").count, 0)
    }

    func testBracketAcrossNewlineIgnored() {
        XCTAssertEqual(BlankDetector.detect(in: "see [Section\n4.2] there").count, 0)
    }

    func testContextWindowSurroundsBlank() {
        let prefix = String(repeating: "a", count: 300)
        let suffix = String(repeating: "b", count: 300)
        let blanks = BlankDetector.detect(in: prefix + " [Company Name] " + suffix)
        XCTAssertEqual(blanks.count, 1)
        XCTAssertTrue(blanks[0].context.contains("[Company Name]"))
        XCTAssertLessThanOrEqual((blanks[0].context as NSString).length, 240 + ("[Company Name]" as NSString).length + 2)
    }

    func testCJKContextOffsetsAreUTF16Safe() {
        let text = "本公司（下称「公司」）于 [成立日期] 注册成立。emoji 😀 tail [Company Name] end"
        let blanks = BlankDetector.detect(in: text)
        XCTAssertEqual(blanks.map(\.label), ["成立日期", "Company Name"])
        for blank in blanks {
            guard case .textSpan(let start, let end) = blank.location else { return XCTFail() }
            let surface = (text as NSString).substring(with: NSRange(location: start, length: end - start))
            XCTAssertTrue(surface.hasPrefix("[") && surface.hasSuffix("]"))
        }
    }

    func testBlanksSortedByPosition() {
        let blanks = BlankDetector.detect(in: "[B] then ___ then {{c}}")
        let starts: [Int] = blanks.compactMap {
            if case .textSpan(let start, _) = $0.location { return start } else { return nil }
        }
        XCTAssertEqual(starts, starts.sorted())
    }

    /// Regression guard: 1000 bare underscore blanks plus 50 bracketed labels
    /// (to exercise the suppression path) must resolve in under 1 second.
    /// Without the two-phase O(n log n) algorithm this was ~30 s on 33k candidates.
    func testDenseBlankDocumentCompletesQuickly() {
        // Build a string with 50 delimited labels followed by 1000 bare blanks.
        let delimitedPart = (0 ..< 50).map { "[Label\($0)] " }.joined()
        let barePart = (0 ..< 1000).map { _ in "__ " }.joined()
        let text = delimitedPart + barePart

        let start = DispatchTime.now()
        let blanks = BlankDetector.detect(in: text)
        let end = DispatchTime.now()

        // 50 delimited + 1000 bare (none of the bare fall inside a delimited span).
        XCTAssertEqual(blanks.count, 1050)

        let elapsedNs = end.uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedSeconds = Double(elapsedNs) / 1_000_000_000
        XCTAssertLessThan(elapsedSeconds, 1.0, "detect() took \(elapsedSeconds)s; expected < 1s")
    }
}
