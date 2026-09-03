//
//  PatternOnlyRecallClaimTests.swift
//  LDACoreTests
//
//  The evidence behind the one number the model ask quotes: "a scan with no
//  model left 32 of the 36 names, companies, and addresses in place, and
//  matched the other 4 only in part".
//
//  This is the only test in the suite that reaches outside the package, into
//  bench/fulldocs. The coupling is deliberate. That copy is a product claim
//  about the ABSENCE of a model, made to a lawyer who is deciding whether to
//  hand a document to an AI tool, and a claim like that must not ship without
//  its measurement in the same checkout. So a missing corpus is an XCTFail
//  rather than a skip: an unverifiable claim is the failure, not an excuse.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest
@testable import LDAUI
import LDACore

final class PatternOnlyRecallClaimTests: XCTestCase {

    /// The repository root, five levels up from this file
    /// (Tests/LDACoreTests -> Tests -> LDACore -> macos -> repo).
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private struct Fixture: Decodable {
        let text: String
        let gold: [Gold]

        struct Gold: Decodable {
            let value: String
            let type: String
        }
    }

    /// How a gold value fared against a deterministic-only scan.
    private struct Recall {
        var gold = 0
        var untouched = 0
        var partial = 0
        var exact = 0
    }

    private func fixture(_ name: String) throws -> Fixture {
        let url = Self.repositoryRoot
            .appendingPathComponent("bench/fulldocs")
            .appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            XCTFail(
                "\(name) is missing at \(url.path). The ask quotes a measured "
                    + "number from this corpus, so the claim must not ship "
                    + "without it."
            )
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// Classify every PERSON, COMPANY and ADDRESS gold value in one fixture
    /// against the spans a deterministic-only pass produces.
    private func measure(_ fixture: Fixture) -> Recall {
        let spans = DeterministicEngine().detect(fixture.text)
        let text = fixture.text as NSString
        var recall = Recall()

        for gold in fixture.gold where ["PERSON", "COMPANY", "ADDRESS"].contains(gold.type) {
            recall.gold += 1
            var overlapped = false
            var exact = false

            var searchFrom = 0
            while searchFrom < text.length {
                let found = text.range(
                    of: gold.value,
                    options: [],
                    range: NSRange(location: searchFrom, length: text.length - searchFrom)
                )
                guard found.location != NSNotFound else { break }
                let start = found.location
                let end = found.location + found.length
                for span in spans where span.start < end && span.end > start {
                    overlapped = true
                    if span.start == start, span.end == end { exact = true }
                }
                searchFrom = found.location + max(found.length, 1)
            }

            if exact {
                recall.exact += 1
            } else if overlapped {
                recall.partial += 1
            } else {
                recall.untouched += 1
            }
        }
        return recall
    }

    func testPatternOnlyScanLeaves32OfThe36NamesCompaniesAndAddresses() throws {
        var total = Recall()
        for name in ["full-cn-agreement.json", "full-en-agreement.json"] {
            let measured = measure(try fixture(name))
            total.gold += measured.gold
            total.untouched += measured.untouched
            total.partial += measured.partial
            total.exact += measured.exact
        }

        XCTAssertEqual(total.gold, 36, "the corpus must still hold 36 gold values")
        XCTAssertEqual(
            total.untouched, 32,
            "32 values must have no overlapping span at all: they are left in "
                + "the document verbatim"
        )
        XCTAssertEqual(
            total.partial, 4,
            "the four Chinese street addresses are matched but truncated at "
                + "the street number, so the building name and floor stay in "
                + "cleartext"
        )
        XCTAssertEqual(
            total.exact, 0,
            "not one name, company or address is redacted exactly without a model"
        )
    }

    func testTheEvidenceSentenceMatchesTheMeasurement() {
        // The copy cannot drift from the corpus in either direction: a change
        // to the detectors that improves the number fails here until the
        // sentence is rewritten, and a rewritten sentence fails until the
        // measurement agrees.
        //
        // The measured evidence moved from the ask's last paragraph to the
        // wizard's defer ("Not Now") row (wizard spec section 4B, #28), where
        // the decision it informs actually is; the new sentence states the
        // 32-of-36 miss and drops the "4 in part" detail that used to follow
        // it, which is why only two numbers are expected here. The
        // four-partial-match figure is still verified above, against the
        // corpus directly.
        let sentence = ModelSetupPresentation.deferConsequenceLine(language: .english)
        let numbers = sentence
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap(Int.init)
        XCTAssertEqual(
            numbers, [32, 36],
            "the defer row's evidence sentence must quote the measured 32 of "
                + "36: \(sentence)"
        )
    }
}
