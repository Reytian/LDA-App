// Tests/LDACoreTests/ImageRedactionResolverTests.swift
import XCTest
import CoreGraphics
@testable import LDACore

final class ImageRedactionResolverTests: XCTestCase {
    private func obs(_ text: String, _ x: CGFloat = 0) -> ImageTextObservation {
        ImageTextObservation(pageIndex: 0, rect: CGRect(x: x, y: 0, width: 10, height: 10), text: text)
    }

    private func mapping(_ entries: [MappingEntry]) -> Mapping {
        var byToken: [String: MappingEntry] = [:]
        for e in entries { byToken[e.token] = e }
        return Mapping(entries: byToken, createdAtISO8601: "2026-06-09T00:00:00Z", sourceFile: "x.pdf")
    }

    private func person(_ token: String, _ value: String) -> MappingEntry {
        MappingEntry(token: token, value: value, type: .person, surfaceText: value, aliases: [])
    }

    /// Detection finds a PERSON whose surface already exists in the mapping: reuse
    /// the existing token, mint NO new entry.
    func testReusesExistingTokenForKnownSurface() {
        let m = mapping([person("{PERSON_1}", "Daniel Okafor")])
        let detect: (String) -> [Span] = { text in
            [Span(start: 0, end: (text as NSString).length, type: .person,
                  text: "Daniel Okafor", source: .llm, confidence: 0.9, priority: 5)]
        }
        let r = ImageRedactionResolver.resolve(mapping: m, observations: [obs("Daniel Okafor")], detect: detect)
        XCTAssertEqual(r.boxes.map { $0.token }, ["{PERSON_1}"])
        XCTAssertTrue(r.newEntries.isEmpty)
        XCTAssertEqual(r.imageRedactionCount, 1)
    }

    /// Detection finds a NEW person: mint the next per-type token and a redact-only entry.
    func testMintsNewTokenContinuingNumbering() {
        let m = mapping([person("{PERSON_1}", "Jane Mitchell")])
        let detect: (String) -> [Span] = { text in
            [Span(start: 0, end: (text as NSString).length, type: .person,
                  text: "Sarah Whitman", source: .llm, confidence: 0.9, priority: 5)]
        }
        let r = ImageRedactionResolver.resolve(mapping: m, observations: [obs("Sarah Whitman")], detect: detect)
        XCTAssertEqual(r.boxes.map { $0.token }, ["{PERSON_2}"])
        XCTAssertEqual(r.newEntries.count, 1)
        XCTAssertEqual(r.newEntries.first?.token, "{PERSON_2}")
        XCTAssertEqual(r.newEntries.first?.surfaceText, "Sarah Whitman")
        XCTAssertEqual(r.newEntries.first?.type, .person)
    }

    /// Detection finds nothing: conservatively box with a generic token, no entry.
    func testGenericBoxWhenNoDetection() {
        let m = mapping([])
        let detect: (String) -> [Span] = { _ in [] }
        let r = ImageRedactionResolver.resolve(mapping: m, observations: [obs("garbled sig"), obs("more", 20)],
                                               detect: detect)
        XCTAssertEqual(r.boxes.map { $0.token }, ["{REDACTED_1}", "{REDACTED_2}"])
        XCTAssertTrue(r.newEntries.isEmpty)
        XCTAssertEqual(r.imageRedactionCount, 2)
    }
}
