//
//  RelatedSidecarAccessTests.swift
//  LDACoreTests
//
//  Under App Sandbox a Powerbox grant covers the file the user chose, not its
//  neighbours. The .ldamap sidecar next to a chosen file is reachable only as
//  a declared related item, accessed through NSFileCoordinator with a presenter
//  that names the chosen file as its primary. These tests prove the helper
//  really goes through coordination (another presenter on the same sidecar is
//  asked to relinquish) and that the sidecar round-trips through it. The
//  sandbox itself cannot be exercised from XCTest.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class RelatedSidecarAccessTests: XCTestCase {

    private var workDir: URL!
    private var primary: URL!
    private var sidecar: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelatedSidecarAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        primary = workDir.appendingPathComponent("Redacted for AI.md")
        try Data("# Document 1\n\nMail {EMAIL_1}.".utf8).write(to: primary)
        sidecar = SessionModel.sidecarURL(for: primary)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func mapping(_ source: String) -> Mapping {
        Mapping(entries: [:], createdAtISO8601: "2026-09-02T00:00:00Z", sourceFile: source)
    }

    // MARK: - Round trip

    func testWriteThenReadBackThroughTheCoordinator() throws {
        let expected = mapping("coordinated")

        try RelatedSidecarAccess.write(sidecar: sidecar, primary: primary) { url in
            try MappingStore.save(expected, to: url, protection: .passphrase("pw"))
        }

        XCTAssertTrue(RelatedSidecarAccess.sidecarExists(sidecar, primary: primary))
        let loaded = try RelatedSidecarAccess.read(sidecar: sidecar, primary: primary) { url in
            try MappingStore.load(from: url, protection: .passphrase("pw"))
        }
        XCTAssertEqual(loaded, expected)
        XCTAssertFalse(
            RelatedSidecarAccess.sidecarExists(
                workDir.appendingPathComponent("other.ldamap"),
                primary: primary
            )
        )
    }

    func testTheWriteReplacesAnEarlierSidecar() throws {
        try RelatedSidecarAccess.write(sidecar: sidecar, primary: primary) { url in
            try MappingStore.save(mapping("first"), to: url, protection: .passphrase("pw"))
        }
        try RelatedSidecarAccess.write(sidecar: sidecar, primary: primary) { url in
            try MappingStore.save(mapping("second"), to: url, protection: .passphrase("pw"))
        }

        let loaded = try RelatedSidecarAccess.read(sidecar: sidecar, primary: primary) { url in
            try MappingStore.load(from: url, protection: .passphrase("pw"))
        }
        XCTAssertEqual(loaded.sourceFile, "second")
    }

    // MARK: - The presenter

    func testThePresenterNamesTheSidecarAndItsPrimaryOffTheMainQueue() {
        let presenter = RelatedSidecarPresenter(sidecar: sidecar, primary: primary)

        XCTAssertEqual(presenter.presentedItemURL, sidecar)
        XCTAssertEqual(presenter.primaryPresentedItemURL, primary)
        XCTAssertEqual(presenter.presentedItemOperationQueue.maxConcurrentOperationCount, 1)
        XCTAssertFalse(
            presenter.presentedItemOperationQueue === OperationQueue.main,
            "coordinating from the main thread must never wait on the main queue"
        )
    }

    // MARK: - Coordination really happens

    func testTheWriteIsCoordinatedSoAnotherPresenterOfTheSidecarIsAskedToRelinquish() throws {
        let asked = expectation(description: "the other presenter is asked to relinquish to the writer")
        asked.assertForOverFulfill = false
        let observer = RecordingPresenter(url: sidecar, onRelinquishToWriter: { asked.fulfill() })
        NSFileCoordinator.addFilePresenter(observer)
        defer { NSFileCoordinator.removeFilePresenter(observer) }

        try RelatedSidecarAccess.write(sidecar: sidecar, primary: primary) { url in
            try Data("sealed bytes".utf8).write(to: url)
        }

        wait(for: [asked], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("sealed bytes".utf8))
    }

    func testAnInjectedFakePresenterStillRunsTheBodyInsideCoordination() throws {
        let fake = RecordingPresenter(url: sidecar, onRelinquishToWriter: {})
        var bodyRan = false

        let value = try RelatedSidecarAccess.write(sidecar: sidecar, primary: primary, presenter: fake) { url in
            bodyRan = true
            try Data("via fake".utf8).write(to: url)
            return 42
        }

        XCTAssertTrue(bodyRan)
        XCTAssertEqual(value, 42)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "via fake")
    }

    // MARK: - Errors

    func testABodyErrorPropagatesUnchanged() {
        XCTAssertThrowsError(
            try RelatedSidecarAccess.read(sidecar: sidecar, primary: primary) { _ -> Mapping in
                throw DocumentIOError.decryptionFailed
            }
        ) { error in
            guard case DocumentIOError.decryptionFailed? = error as? DocumentIOError else {
                return XCTFail("expected decryptionFailed, got \(error)")
            }
        }
    }
}

/// A presenter that records the coordinator's relinquish request, standing in
/// for another process or window holding the sidecar.
private final class RecordingPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onRelinquishToWriter: () -> Void

    init(url: URL, onRelinquishToWriter: @escaping () -> Void) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        self.onRelinquishToWriter = onRelinquishToWriter
    }

    func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) {
        onRelinquishToWriter()
        writer(nil)
    }

    func relinquishPresentedItem(toReader reader: @escaping ((() -> Void)?) -> Void) {
        reader(nil)
    }
}
