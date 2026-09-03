import AppKit
import SwiftUI
import XCTest
@testable import LDAUI

final class MultilingualLayoutTests: XCTestCase {
    private static let interfaceLanguages: [AppLanguage] = [
        .english,
        .french,
        .simplifiedChinese,
        .traditionalChinese
    ]

    @MainActor
    func testMainModePickerFitsItsProductionWidthInEveryLanguage() {
        let productionWidth: CGFloat = 430

        for language in Self.interfaceLanguages {
            let intrinsicPicker = NSHostingView(
                rootView: ModePickerProbe(language: language)
                    .fixedSize(horizontal: true, vertical: true)
            )
            let intrinsicSize = intrinsicPicker.fittingSize

            XCTAssertLessThanOrEqual(
                intrinsicSize.width,
                productionWidth,
                "The \(language.rawValue) mode labels need \(intrinsicSize.width) pt, "
                    + "which would truncate inside the 430 pt toolbar picker."
            )

            let productionPicker = NSHostingView(
                rootView: ModePickerProbe(language: language)
                    .frame(width: productionWidth)
            )
            let productionSize = productionPicker.fittingSize

            XCTAssertEqual(productionSize.width, productionWidth, accuracy: 0.5)
            XCTAssertLessThanOrEqual(
                productionSize.height,
                20.5,
                "The \(language.rawValue) mode picker exceeds the native toolbar height."
            )
        }
    }

    @MainActor
    func testRestoreCardWrapsLocalizedCopyAtItsProductionWidth() throws {
        let source = try String(contentsOf: Self.restoreSourceURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains(".frame(maxWidth: 560)"),
            "The single Restore card must keep the production width this test measures."
        )
        let cardWidth: CGFloat = 560
        let cardHorizontalPadding: CGFloat = 24
        let bodyWidth = cardWidth - (cardHorizontalPadding * 2)

        for language in Self.interfaceLanguages {
            for card in RestoreCardCopy.allCases.map({ $0.localized(in: language) }) {
                assertTextWrapsWithoutClipping(
                    card.body,
                    width: bodyWidth,
                    font: CounselTheme.Typography.readingBody,
                    lineSpacing: 2,
                    language: language,
                    context: card.title
                )

                let cardView = NSHostingView(
                    rootView: RestoreCardProbe(copy: card)
                        .frame(width: cardWidth)
                )
                let renderedSize = cardView.fittingSize

                XCTAssertEqual(renderedSize.width, cardWidth, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(
                    renderedSize.height,
                    240,
                    "The \(language.rawValue) Restore card must retain its production minimum height."
                )
                XCTAssertLessThan(
                    renderedSize.height,
                    420,
                    "The \(language.rawValue) Restore card becomes impractically tall."
                )
            }
        }
    }

    @MainActor
    func testModelStepCopyFitsTheSheet() {
        // The wizard sheet's minWidth is 520 pt, with 28 pt of padding on
        // each side (OnboardingView.swift's outer VStack.padding(28)).
        let sheetWidth: CGFloat = 520
        let horizontalPadding: CGFloat = 28
        let bodyWidth = sheetWidth - (horizontalPadding * 2)

        for language in Self.interfaceLanguages {
            let explanation = ModelSetupPresentation.askBody(
                route: .download, language: language
            ).first ?? ""
            assertTextWrapsWithoutClipping(
                explanation,
                width: bodyWidth,
                font: .callout,
                language: language,
                context: "#10 model step explanation"
            )

            let blockedLine = ModelSetupPresentation.blockedRungsLine(
                blockedLevels: [.balanced, .mostThorough],
                installedGB: 16,
                language: language
            )
            assertTextWrapsWithoutClipping(
                blockedLine,
                width: bodyWidth,
                font: CounselTheme.Typography.supporting,
                language: language,
                context: "#22 blocked rungs line"
            )

            let provenance = ModelSetupPresentation.provenanceLine(
                route: .download, hostDescription: "huggingface.co", language: language
            )
            assertTextWrapsWithoutClipping(
                provenance,
                width: bodyWidth,
                font: CounselTheme.Typography.supporting,
                language: language,
                context: "#26 provenance line"
            )

            let deferLine = ModelSetupPresentation.deferConsequenceLine(language: language)
            assertTextWrapsWithoutClipping(
                deferLine,
                width: bodyWidth,
                font: CounselTheme.Typography.supporting,
                language: language,
                context: "#28 defer consequence line"
            )
        }
    }

    @MainActor
    func testNewPortfolioCopyFitsTheProductionMinimumSheetWidth() throws {
        let sheetWidth: CGFloat = 400
        let sheetHorizontalPadding: CGFloat = 24
        let contentWidth = sheetWidth - (sheetHorizontalPadding * 2)
        let source = try String(contentsOf: Self.fillLibrarySourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("ViewThatFits(in: .horizontal)"),
            "The production sheet must retain its narrow action fallback for translated copy."
        )

        for language in Self.interfaceLanguages {
            let copy = NewPortfolioCopy.localized(in: language)

            for description in copy.descriptions {
                assertTextWrapsWithoutClipping(
                    description,
                    width: contentWidth,
                    font: CounselTheme.Typography.readingBody,
                    language: language,
                    context: copy.title
                )
            }

            let actionRow = NSHostingView(
                rootView: NewPortfolioActionRow(copy: copy)
                    .fixedSize(horizontal: true, vertical: true)
            )
            let adaptiveActions = NSHostingView(
                rootView: NewPortfolioAdaptiveActions(copy: copy)
                    .frame(width: contentWidth)
            )
            let adaptiveSize = adaptiveActions.fittingSize

            XCTAssertEqual(adaptiveSize.width, contentWidth, accuracy: 0.5)
            XCTAssertLessThan(
                adaptiveSize.height,
                160,
                "The \(language.rawValue) New Portfolio fallback is too tall for the sheet."
            )

            if actionRow.fittingSize.width > contentWidth + 0.5 {
                XCTAssertGreaterThan(
                    adaptiveSize.height,
                    actionRow.fittingSize.height + 0.5,
                    "The \(language.rawValue) actions must switch rows instead of compressing."
                )
            }

            let sheet = NSHostingView(
                rootView: NewPortfolioCopyProbe(copy: copy)
                    .frame(width: sheetWidth)
            )
            let renderedSize = sheet.fittingSize

            XCTAssertEqual(renderedSize.width, sheetWidth, accuracy: 0.5)
            XCTAssertLessThan(
                renderedSize.height,
                520,
                "The \(language.rawValue) New Portfolio copy exceeds a practical sheet height."
            )
        }
    }

    @MainActor
    private func assertTextWrapsWithoutClipping(
        _ value: String,
        width: CGFloat,
        font: Font,
        lineSpacing: CGFloat = 0,
        language: AppLanguage,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let naturalText = NSHostingView(
            rootView: Text(verbatim: value)
                .font(font)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: true, vertical: true)
        )
        let naturalSize = naturalText.fittingSize

        let wrappedText = NSHostingView(
            rootView: Text(verbatim: value)
                .font(font)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .leading)
        )
        let wrappedSize = wrappedText.fittingSize

        XCTAssertEqual(wrappedSize.width, width, accuracy: 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            wrappedSize.height,
            naturalSize.height - 0.5,
            "The \(language.rawValue) copy for \(context) was vertically compressed.",
            file: file,
            line: line
        )

        if naturalSize.width > width + 0.5 {
            XCTAssertGreaterThan(
                wrappedSize.height,
                naturalSize.height + 0.5,
                "The \(language.rawValue) copy for \(context) must wrap instead of clipping.",
                file: file,
                line: line
            )
        }
    }

    private static let packageRootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let fillLibrarySourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/FillLibraryViews.swift")

    private static let restoreSourceURL = packageRootURL
        .appendingPathComponent("Sources/LDAUI/DeanonymizeShell.swift")
}

private struct ModePickerProbe: View {
    let language: AppLanguage
    @State private var selection = "Anonymize"

    var body: some View {
        Picker(L10n.string("Mode", language: language), selection: $selection) {
            ForEach(["Matters", "Anonymize", "Restore", "Fill"], id: \.self) { key in
                Text(verbatim: L10n.string(key, language: language)).tag(key)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }
}

private enum RestoreCardCopy: CaseIterable {
    case file

    func localized(in language: AppLanguage) -> LocalizedRestoreCardCopy {
        switch self {
        case .file:
            return LocalizedRestoreCardCopy(
                icon: "doc.badge.arrow.up",
                title: L10n.string("Restore a file", language: language),
                body: L10n.string(
                    "Choose or drop the file that came back: the Markdown you exported for the AI, "
                        + "or a redacted Word document you saved. The mapping is found automatically "
                        + "from this session or from the .ldamap saved next to the file. "
                        + "Formatting is kept when the file is a Word document.",
                    language: language
                ),
                buttonTitle: L10n.string("Choose File & Restore\u{2026}", language: language),
                isProminent: true
            )
        }
    }
}

private struct LocalizedRestoreCardCopy {
    let icon: String
    let title: String
    let body: String
    let buttonTitle: String
    let isProminent: Bool
}

private struct RestoreCardProbe: View {
    let copy: LocalizedRestoreCardCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: copy.title)
            } icon: {
                Image(systemName: copy.icon)
            }
            .font(CounselTheme.Typography.sectionTitle)

            Text(verbatim: copy.body)
                .font(CounselTheme.Typography.readingBody)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Group {
                if copy.isProminent {
                    Button(action: {}) {
                        Text(verbatim: copy.buttonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: {}) {
                        Text(verbatim: copy.buttonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(minHeight: 240)
    }
}

private struct NewPortfolioCopy {
    let title: String
    let portfolioType: String
    let kinds: [String]
    let descriptions: [String]
    let label: String
    let labelPrompt: String
    let cancel: String
    let fromDocuments: String
    let fromScratch: String

    static func localized(in language: AppLanguage) -> NewPortfolioCopy {
        NewPortfolioCopy(
            title: L10n.string("New Portfolio", language: language),
            portfolioType: L10n.string("Portfolio type", language: language),
            kinds: ["Company", "Individual", "General"].map {
                L10n.string($0, language: language)
            },
            descriptions: [
                "Corporate entity: company name, registration, directors, shareholders, capital structure.",
                "Natural person: name, date of birth, nationality, passport, national ID, address, contact.",
                "Covers both corporate and personal field sets. Use when a portfolio spans both."
            ].map { L10n.string($0, language: language) },
            label: L10n.string("Label", language: language),
            labelPrompt: L10n.string("e.g. Acme Corp, John Smith", language: language),
            cancel: L10n.string("Cancel", language: language),
            fromDocuments: L10n.string("From Documents", language: language),
            fromScratch: L10n.string("From Scratch", language: language)
        )
    }
}

private struct NewPortfolioActionRow: View {
    let copy: NewPortfolioCopy

    var body: some View {
        HStack {
            Button(copy.cancel, role: .cancel, action: {})
            Spacer()
            Button(action: {}) {
                Label(copy.fromDocuments, systemImage: "doc.badge.plus")
            }
            Button(action: {}) {
                Label(copy.fromScratch, systemImage: "pencil.and.list.clipboard")
            }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct NewPortfolioAdaptiveActions: View {
    let copy: NewPortfolioCopy

    var body: some View {
        ViewThatFits(in: .horizontal) {
            NewPortfolioActionRow(copy: copy)

            VStack(spacing: 10) {
                HStack {
                    Button(copy.cancel, role: .cancel, action: {})
                    Spacer()
                }
                Button(action: {}) {
                    Label(copy.fromDocuments, systemImage: "doc.badge.plus")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                Button(action: {}) {
                    Label(copy.fromScratch, systemImage: "pencil.and.list.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct NewPortfolioCopyProbe: View {
    let copy: NewPortfolioCopy
    @State private var selectedKind = 0
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: copy.title)
                .font(CounselTheme.Typography.sectionTitle)

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: copy.portfolioType)
                    .font(CounselTheme.Typography.readingBody.weight(.medium))

                Picker("", selection: $selectedKind) {
                    ForEach(Array(copy.kinds.enumerated()), id: \.offset) { index, value in
                        Text(verbatim: value).tag(index)
                    }
                }
                .pickerStyle(.segmented)

                Text(verbatim: copy.descriptions[2])
                    .font(CounselTheme.Typography.readingBody)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: copy.label)
                    .font(CounselTheme.Typography.readingBody.weight(.medium))
                TextField(copy.labelPrompt, text: $label)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 280)
            }

            Divider()
            NewPortfolioAdaptiveActions(copy: copy)
        }
        .padding(24)
    }
}
