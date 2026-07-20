//
//  MatterMetadataStoreTests.swift
//  LDACoreTests
//
//  Encrypted workspace metadata for reversible archive and rename behavior.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class MatterMetadataStoreTests: XCTestCase {
    private var root: URL!
    private var store: MatterMetadataStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatterMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try MatterMetadataStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testArchiveStateRoundTripsWithoutWritingTheLabelInPlaintext() throws {
        try store.setArchived(
            label: "Acme Privileged Matter",
            isArchived: true,
            protection: .passphrase("pw")
        )

        let resolution = try store.list(protection: .passphrase("pw"))

        XCTAssertEqual(resolution.metadata.count, 1)
        XCTAssertEqual(resolution.metadata.first?.label, "Acme Privileged Matter")
        XCTAssertEqual(resolution.metadata.first?.isArchived, true)
        XCTAssertEqual(resolution.unreadableCount, 0)

        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "Acme Privileged Matter"))
        XCTAssertFalse(file.lastPathComponent.contains("Acme"))
    }

    func testArchiveCanBeReversed() throws {
        try store.setArchived(
            label: "Acme Matter",
            isArchived: true,
            protection: .passphrase("pw")
        )
        try store.setArchived(
            label: "Acme Matter",
            isArchived: false,
            protection: .passphrase("pw")
        )

        let metadata = try store.list(protection: .passphrase("pw")).metadata

        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata.first?.isArchived, false)
    }

    func testRenamePreservesArchiveStateAndCollectsTheOldLabelAsAnAlias() throws {
        try store.setArchived(
            label: "Acme Matter",
            isArchived: true,
            protection: .passphrase("pw")
        )

        try store.rename(
            from: "Acme Matter",
            to: "Acme Transaction",
            protection: .passphrase("pw")
        )

        let metadata = try XCTUnwrap(
            try store.list(protection: .passphrase("pw")).metadata.first
        )
        XCTAssertEqual(metadata.label, "Acme Transaction")
        XCTAssertEqual(metadata.aliases, ["Acme Matter"])
        XCTAssertTrue(metadata.isArchived)
    }

    func testRenameRejectsALabelOwnedByAnotherMatter() throws {
        try store.setArchived(
            label: "Alpha Matter",
            isArchived: false,
            protection: .passphrase("pw")
        )
        try store.setArchived(
            label: "Beta Matter",
            isArchived: false,
            protection: .passphrase("pw")
        )

        XCTAssertThrowsError(
            try store.rename(
                from: "Alpha Matter",
                to: "Beta Matter",
                protection: .passphrase("pw")
            )
        )
    }

    func testListKeepsReadableMetadataWhenOneFileCannotUnlock() throws {
        try store.setArchived(
            label: "Readable Matter",
            isArchived: false,
            protection: .passphrase("pw")
        )
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        let otherStore = try MatterMetadataStore(rootDirectory: otherRoot)
        try otherStore.setArchived(
            label: "Locked Matter",
            isArchived: true,
            protection: .passphrase("other")
        )
        let lockedFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: otherRoot,
                includingPropertiesForKeys: nil
            ).first
        )
        try FileManager.default.moveItem(
            at: lockedFile,
            to: root.appendingPathComponent(lockedFile.lastPathComponent)
        )

        let resolution = try store.list(protection: .passphrase("pw"))

        XCTAssertEqual(resolution.metadata.map(\.label), ["Readable Matter"])
        XCTAssertEqual(resolution.unreadableCount, 1)
    }
}
