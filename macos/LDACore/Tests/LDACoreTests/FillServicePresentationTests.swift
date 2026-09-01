import Foundation
import XCTest
@testable import LDAUI
import LDACore

final class FillServicePresentationTests: XCTestCase {
    func testStableFillServiceReasonsMapToHumanDisplayCopy() {
        let expected = [
            "duplicate location": "Duplicate field location",
            "confirmed without a value": "Confirmed without a value",
            "rejected by reviewer": "Rejected during review",
            "no matching field": "No matching portfolio field",
            "not confirmed": "Not confirmed",
            "manual widget type": "Requires manual input"
        ]

        for (rawReason, displayCopy) in expected {
            let skipped = SkippedBlank(
                label: "Field",
                locationDescription: "field Field",
                reason: rawReason
            )

            XCTAssertEqual(
                FillServicePresentation.skippedReason(
                    skipped.reason,
                    language: .english
                ),
                displayCopy
            )
            XCTAssertEqual(
                skipped.reason,
                rawReason,
                "Presentation must not mutate the stable report reason."
            )
        }
    }

    func testUnknownServiceReasonsAndRealSourceNamesRemainVerbatim() {
        let systemFailure = "The file could not be opened (code 257)."
        XCTAssertEqual(
            FillServicePresentation.sourceFailureReason(
                systemFailure,
                language: .french
            ),
            systemFailure
        )
        XCTAssertEqual(
            FillServicePresentation.sourceDocumentName(
                for: profileField(
                    sourceDocument: "contrat-client.pdf",
                    sourceSnippet: "Client name"
                ),
                language: .simplifiedChinese
            ),
            "contrat-client.pdf"
        )
        XCTAssertEqual(
            FillServicePresentation.sourceDocumentName(
                for: profileField(
                    sourceDocument: "manual entry",
                    sourceSnippet: "Text from the real extensionless source file"
                ),
                language: .french
            ),
            "manual entry",
            "A real source file that matches the sentinel must remain verbatim."
        )
        XCTAssertEqual(
            FillServicePresentation.locationDescription(
                "page 2 annotation",
                language: .french
            ),
            "page 2 annotation"
        )
    }

    func testStableLocationDescriptionsMapAtTheDisplayBoundary() {
        let fieldLocation = SkippedBlank(
            label: "",
            locationDescription: "field Fax",
            reason: "no matching field"
        )
        let offsetLocation = SkippedBlank(
            label: "",
            locationDescription: "offset 10-20",
            reason: "not confirmed"
        )

        XCTAssertEqual(
            FillServicePresentation.locationDescription(
                fieldLocation.locationDescription,
                language: .english
            ),
            "Field Fax"
        )
        XCTAssertEqual(
            FillServicePresentation.locationDescription(
                offsetLocation.locationDescription,
                language: .english
            ),
            "Offset 10-20"
        )
        XCTAssertEqual(
            FillServicePresentation.locationDescription(
                fieldLocation.locationDescription,
                language: .french
            ),
            "Champ Fax"
        )
        XCTAssertEqual(
            FillServicePresentation.locationDescription(
                offsetLocation.locationDescription,
                language: .simplifiedChinese
            ),
            "文本范围 10-20"
        )
        XCTAssertEqual(fieldLocation.locationDescription, "field Fax")
        XCTAssertEqual(offsetLocation.locationDescription, "offset 10-20")
    }

    func testStableManualEntryAndEmptySourceReasonUseLocalizedDisplayKeys() {
        XCTAssertEqual(
            FillServicePresentation.sourceDocumentName(
                for: profileField(
                    sourceDocument: "manual entry",
                    sourceSnippet: "",
                    snippetVerified: false,
                    userEdited: true
                ),
                language: .english
            ),
            "Manual entry"
        )
        XCTAssertEqual(
            FillServicePresentation.sourceFailureReason(
                "no text content found",
                language: .english
            ),
            "No text content found"
        )
        XCTAssertEqual(
            FillServicePresentation.sourceDocumentName(
                for: profileField(
                    sourceDocument: "manual entry",
                    sourceSnippet: "",
                    snippetVerified: false,
                    userEdited: true
                ),
                language: .french
            ),
            "Saisie manuelle"
        )
        XCTAssertEqual(
            FillServicePresentation.skippedReason(
                "no matching field",
                language: .traditionalChinese
            ),
            "沒有相符的資料集欄位"
        )
    }

    func testTargetContextCopyLocalizesInterfaceTextAndPreservesDocumentText() {
        XCTAssertEqual(
            FillTargetPresentation.contextList(
                targetFileName: nil,
                blanks: [],
                language: .english
            ),
            "No target document loaded."
        )
        XCTAssertEqual(
            FillTargetPresentation.contextList(
                targetFileName: "客户合同.docx",
                blanks: [],
                language: .english
            ),
            "客户合同.docx\n\nNo blanks detected in this document."
        )
        XCTAssertEqual(
            FillTargetPresentation.contextList(
                targetFileName: "客户合同.docx",
                blanks: [],
                language: .simplifiedChinese
            ),
            "客户合同.docx\n\n此文档中未检测到空白字段。"
        )

        let context = "Le client signe ici: ______"
        let blank = Blank(
            location: .textSpan(start: 22, end: 28),
            label: "",
            context: context,
            proposedFieldID: nil,
            proposedValue: nil,
            status: .unmatched
        )
        let rendered = FillTargetPresentation.contextList(
            targetFileName: "contrat.pdf",
            blanks: [blank],
            language: .english
        )

        XCTAssertTrue(rendered.contains("contrat.pdf"))
        XCTAssertTrue(rendered.contains("(blank): \(context)"))
    }

    func testPortfolioIconHelpTreatsRuntimeStringsAsLocalizationKeys() throws {
        let source = try String(
            contentsOf: Self.packageRoot
                .appendingPathComponent("Sources/LDAUI/FillLibraryViews.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("helpKey: String"))
        XCTAssertTrue(source.contains(".help(L10n.string(helpKey))"))
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(Text(verbatim: L10n.string(labelKey)))"
            )
        )

        let requiredKeys = [
            "Edit",
            "Open for editing",
            "Fill a document from this portfolio",
            "Export as .ldaprofile",
            "Delete this portfolio",
            "Field %@",
            "Offset %@"
        ]
        for locale in ["en", "fr", "zh-Hans", "zh-Hant"] {
            let catalogURL = Self.packageRoot.appendingPathComponent(
                "Sources/LDAUI/Resources/\(locale).lproj/Localizable.strings"
            )
            let catalog = try XCTUnwrap(
                NSDictionary(contentsOf: catalogURL) as? [String: String]
            )
            for key in requiredKeys {
                XCTAssertNotNil(catalog[key], "\(locale) is missing \(key)")
            }
        }
    }

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func profileField(
        sourceDocument: String,
        sourceSnippet: String,
        snippetVerified: Bool = true,
        userEdited: Bool = false
    ) -> ProfileField {
        ProfileField(
            id: UUID(),
            key: .companyName,
            value: "Acme",
            sourceDocument: sourceDocument,
            sourceSnippet: sourceSnippet,
            snippetVerified: snippetVerified,
            confidence: 1,
            userEdited: userEdited
        )
    }
}
