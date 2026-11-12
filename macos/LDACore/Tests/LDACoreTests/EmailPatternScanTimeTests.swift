//
//  EmailPatternScanTimeTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, T3. The email pattern was quadratic on a long unbroken
//  run: every start position inside the run consumed the rest of it looking
//  for "@" and gave it all back (10,000 characters took 0.9 s, 40,000 took
//  13.9 s). A run of that length is ordinary in a pasted base64 attachment or
//  a hash list.
//
//  A match can only start where a run of local-part characters starts, so
//  the pattern now says so, and the domain and top-level domain are bounded
//  (house regex rules). The addresses found are unchanged.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EmailPatternScanTimeTests: XCTestCase {

    private func emails(_ text: String) -> [String] {
        DeterministicEngine().detect(text).filter { $0.type == .email }.map(\.text)
    }

    func testALongRunWithNoAtSignScansInLinearTime() {
        let run = String(repeating: "a", count: 40_000)
        let text = "Attachment: " + run + " and mail jo@example.com."
        let started = Date()
        let found = emails(text)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(found, ["jo@example.com"])
        XCTAssertLessThan(elapsed, 1.0, "40,000 characters took \(elapsed) s")
    }

    func testALongDottedRunScansInLinearTime() {
        let run = String(repeating: "ab.", count: 15_000)
        let started = Date()
        _ = emails("Hashes: " + run + " end.")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.0, "45,000 characters took \(elapsed) s")
    }

    func testTheAddressesFoundAreUnchanged() {
        let text = "Write to first.last+tag@mail.example.co.uk, (jo@acme.example) or 邮箱wang@example.cn; not a@b or @example.com."
        XCTAssertEqual(emails(text), ["first.last+tag@mail.example.co.uk", "jo@acme.example", "wang@example.cn"])
    }
}
