import XCTest
@testable import LDACore

final class MCPWorkspaceBridgeTests: XCTestCase {
    func testOnlyOpaqueAssociationRoundTrips() throws {
        let request = MCPWorkspaceRequest(handle: "doc_aaaaaaaaaaaa", currentWorkspaceID: UUID())
        let decoded = try XCTUnwrap(MCPWorkspaceRequest(url: request.url))
        XCTAssertEqual(request.url.scheme, "lda-mcp")
        XCTAssertEqual(request.url.host, "choose-workspace")
        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.handle, request.handle)
        XCTAssertEqual(decoded.currentWorkspaceID, request.currentWorkspaceID)
        XCTAssertFalse(request.url.absoluteString.contains("label"))
    }

    func testExpiredRequestCannotBeConfirmedOrReopenedAndFreshRetryWorks() {
        let request = MCPWorkspaceRequest(handle: "red_aaaaaaaaaaaa", currentWorkspaceID: nil)
        XCTAssertFalse(request.isExpired(at: request.createdAt.addingTimeInterval(MCPWorkspaceRequest.lifetime - 1)))
        // URL conversion crosses Foundation date epochs and can round by a fraction of a microsecond.
        let later = request.createdAt.addingTimeInterval(MCPWorkspaceRequest.lifetime + 1)
        XCTAssertTrue(request.isExpired(at: later))
        XCTAssertNil(MCPWorkspaceRequest(url: request.url, now: later))
        let retry = MCPWorkspaceRequest(handle: request.handle, currentWorkspaceID: nil)
        XCTAssertNotEqual(retry.id, request.id)
        XCTAssertFalse(retry.isExpired())
        XCTAssertNotNil(MCPWorkspaceRequest(url: retry.url))
    }

    func testDuplicateUnknownAndMalformedFieldsAreRefused() throws {
        let request = MCPWorkspaceRequest(handle: "doc_aaaaaaaaaaaa", currentWorkspaceID: nil)
        for extra in ["handle=doc_bbbbbbbbbbbb", "label=PrivateMatter", "current=invalid"] {
            XCTAssertNil(MCPWorkspaceRequest(url: try XCTUnwrap(URL(string: request.url.absoluteString + "&" + extra))))
        }
        var components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        components.scheme = "https"
        XCTAssertNil(MCPWorkspaceRequest(url: try XCTUnwrap(components.url)))
        components.scheme = "lda-mcp"
        components.path = "/extra" + components.path
        XCTAssertNil(MCPWorkspaceRequest(url: try XCTUnwrap(components.url)))
        XCTAssertNil(MCPWorkspaceRequest(url: request.url, now: request.createdAt.addingTimeInterval(-10)))
    }
}
