//
//  DocumentErrorPresentationTests.swift
//  LDACoreTests
//
//  Restore surfaces translate document failures while leaving an unknown
//  system error exactly as received.
//

import Foundation
import XCTest
@testable import LDACore
@testable import LDAUI

final class DocumentErrorPresentationTests: XCTestCase {

    func testKnownDocumentFailureUsesLocalizedAppCopy() {
        let result = DocumentErrorPresentation.describeOrFallback(
            DocumentIOError.ocrUnavailable,
            language: .french
        )

        XCTAssertEqual(
            result,
            "La reconnaissance optique de caractères n’est pas disponible sur ce système."
        )
    }

    func testUnknownFailureRemainsVerbatim() {
        let detail = "NSCocoaErrorDomain 100% 原因"
        let error = NSError(
            domain: "test",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: detail]
        )

        XCTAssertEqual(
            DocumentErrorPresentation.describeOrFallback(
                error,
                language: .traditionalChinese
            ),
            detail
        )
    }
}
