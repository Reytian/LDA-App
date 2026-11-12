import AppKit
import XCTest
@testable import LDAUI

@MainActor
final class ExportFlowTests: XCTestCase {
    /// A successful save remembers its format, so every flow here keeps it
    /// in a suite of its own rather than the shared defaults domain.
    private let suiteName = TestNamespace.suiteName("export-flow")

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeFlow() -> ExportFlowModel {
        ExportFlowModel(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func result(image: URL? = nil) -> ExportResult {
        ExportResult(redactedURL: URL(fileURLWithPath: "/tmp/synthetic-save/document_redacted.docx"),
                     mappingURL: nil, tokenCount: 1, redactedImageURL: image)
    }

    func testSaveKeepsProgressVisibleAndRejectsDuplicateRequestsUntilFinished() async {
        let flow = makeFlow()
        flow.pendingExportDir = URL(fileURLWithPath: "/tmp/synthetic-save")
        flow.isPromptingPassphrase = true
        flow.wantsSidecar = true
        flow.passphrase = "synthetic-passphrase"
        flow.confirmation = flow.passphrase
        var resumeSave: CheckedContinuation<Void, Never>?
        let started = expectation(description: "Save started")
        let expected = result()

        let task = Task {
            await flow.save {
                await withCheckedContinuation { continuation in
                    resumeSave = continuation
                    started.fulfill()
                }
                return expected
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(flow.isSaving)
        XCTAssertTrue(flow.isPromptingPassphrase)
        XCTAssertTrue(flow.isBusy)
        XCTAssertNotNil(flow.pendingExportDir)
        XCTAssertNil(flow.savedExport)
        XCTAssertFalse(flow.isShowingSuccess)
        flow.requestExport()
        XCTAssertEqual(flow.requestToken, 0)
        await flow.save {
            XCTFail("A second click must not write a second file")
            return expected
        }

        resumeSave?.resume()
        let output = await task.value
        XCTAssertEqual(output, expected)
        XCTAssertFalse(flow.isSaving)
        XCTAssertFalse(flow.isPromptingPassphrase)
        XCTAssertTrue(flow.isBusy, "Do not open a new picker while the success prompt is pending")
        XCTAssertFalse(flow.isShowingSuccess, "The save sheet must dismiss first")
        XCTAssertEqual(flow.savedExport, expected)
        XCTAssertNil(flow.pendingExportDir)
        XCTAssertTrue(flow.passphrase.isEmpty)
        flow.saveSheetDismissed()
        XCTAssertTrue(flow.isShowingSuccess)
        flow.requestExport()
        XCTAssertEqual(flow.requestToken, 0)
        flow.dismissSuccess()
        XCTAssertNil(flow.savedExport)
        XCTAssertFalse(flow.isBusy)
        flow.requestExport()
        XCTAssertEqual(flow.requestToken, 1)
    }

    func testFailureRemainsVisibleAndCanBeRetried() async {
        struct SaveFailure: LocalizedError {
            var errorDescription: String? { "Synthetic destination is unavailable" }
        }
        let flow = makeFlow()
        let destination = URL(fileURLWithPath: "/tmp/synthetic-save")
        flow.pendingExportDir = destination
        flow.isPromptingPassphrase = true
        flow.wantsSidecar = true
        flow.passphrase = "synthetic-passphrase"
        flow.confirmation = flow.passphrase

        await flow.save { throw SaveFailure() }
        XCTAssertFalse(flow.isSaving)
        XCTAssertTrue(flow.isPromptingPassphrase)
        XCTAssertEqual(flow.pendingExportDir, destination)
        XCTAssertEqual(flow.passphrase, "synthetic-passphrase")
        XCTAssertTrue(flow.saveError?.contains("Synthetic destination is unavailable") == true)
        XCTAssertNil(flow.savedExport)
        XCTAssertFalse(flow.isShowingSuccess)

        await flow.save {
            XCTAssertTrue(flow.isSaving)
            XCTAssertNil(flow.saveError)
            return result()
        }
        XCTAssertFalse(flow.isPromptingPassphrase)
        XCTAssertNil(flow.saveError)
        XCTAssertTrue(flow.passphrase.isEmpty)
        flow.saveSheetDismissed()
        XCTAssertTrue(flow.isShowingSuccess)
    }

    func testCancelDoesNotShowASuccessPrompt() {
        let flow = makeFlow()
        flow.saveSheetDismissed()
        XCTAssertFalse(flow.isShowingSuccess)
        XCTAssertTrue(flow.savedFiles.isEmpty)
    }

    func testSuccessPromptIncludesTheImageCompanionAndResetsBeforeTheNextSave() async {
        let flow = makeFlow()
        let image = URL(fileURLWithPath: "/tmp/synthetic-save/image_redacted.png")
        let first = result(image: image)
        await flow.save { first }
        flow.saveSheetDismissed()
        XCTAssertEqual(flow.savedFiles, [first.redactedURL, image])
        flow.dismissSuccess()
        XCTAssertTrue(flow.savedFiles.isEmpty)

        let next = result()
        await flow.save { next }
        flow.saveSheetDismissed()
        XCTAssertTrue(flow.isShowingSuccess)
        XCTAssertEqual(flow.savedFiles, [next.redactedURL])
    }
}
