//
//  ParkedSessionStoreTests.swift
//  LDACoreTests
//
//  Encrypted parked round-trip context, including its optional matter label.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class ParkedSessionStoreTests: XCTestCase {

    func testStateRoundTripsWithoutWritingTheMatterLabelInPlaintext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParkedSessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("parked.ldaparked")
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: "2026-07-18T00:00:00Z",
            sourceFile: "Acme Privileged Matter"
        )
        let state = ParkedSessionState(
            mapping: mapping,
            clientLabel: "Acme Privileged Matter"
        )

        try ParkedSessionStore.save(
            state,
            to: url,
            protection: .passphrase("pw")
        )

        XCTAssertEqual(
            try ParkedSessionStore.load(from: url, protection: .passphrase("pw")),
            state
        )
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "Acme Privileged Matter"))
    }
}
