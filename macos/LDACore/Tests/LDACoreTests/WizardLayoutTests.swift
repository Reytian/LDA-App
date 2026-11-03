import AppKit
import SwiftUI
import XCTest
@testable import LDAUI

@MainActor
final class WizardLayoutTests: XCTestCase {
    func testBackNavigationRespectsSkippedModelStep() {
        for hasModel in [false, true] {
            var page = OnboardingPresentation.firstPage(mode: .firstRun)
            while let next = OnboardingPresentation.nextPage(after: page, mode: .firstRun, hasModel: hasModel) {
                XCTAssertEqual(OnboardingPresentation.previousPage(before: next, mode: .firstRun, hasModel: hasModel), page)
                page = next
            }
        }
        XCTAssertNil(OnboardingPresentation.previousPage(before: .model, mode: .modelAskOnly, hasModel: false))
    }

    func testGuideReferencesUseTheActualTranslatedControlNames() {
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            XCTAssertTrue(OnboardingPresentation.languageStepExplanation(language: language)
                .contains(L10n.string("Follow System", language: language)))
            XCTAssertTrue(L10n.string("You can do this later in Settings > AI Assistants. Choose Get Started to open LDA.", language: language)
                .contains(L10n.string("MCP Setup", language: language)))
        }
    }

    func testLanguageAndUnavailableModelPagesRenderInEveryLanguage() throws {
        guard let path = ProcessInfo.processInfo.environment["LDA_WIZARD_CAPTURE_DIR"] else { return }
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let (defaults, name) = TestNamespace.defaults("wizard-render")
        defer { defaults.removePersistentDomain(forName: name) }
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            defaults.set(language.rawValue, forKey: AppLanguage.storageKey)
            for fallback in [false, true] {
                let content = OnboardingView(isPresented: .constant(true), hasModel: !fallback,
                    installer: ModelInstaller(), catalog: ModelCatalog(tiers: []), canRunAModel: !fallback,
                    mode: fallback ? .modelAskOnly : .firstRun, onOpenModelManagement: {})
                    .defaultAppStorage(defaults)
                    .environment(\.appLanguage, language)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 680, height: 640)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: destination.appendingPathComponent("wizard-\(fallback ? "unavailable" : "language")-\(language.rawValue).png"))
            }
        }
    }

    func testTranslatedWizardPagesKeepActionsInTheVisibleWindow() throws {
        let directory = ProcessInfo.processInfo.environment["LDA_WIZARD_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            for dark in [false, true] {
                for width in [520.0, 680.0] {
                    for connection in [false, true] {
                        let marker = NSView()
                        let view = OnboardingPageLayout {
                            if connection { OnboardingConnectionContent() }
                            else { OnboardingWorkflowContent(hasModel: true, language: language) }
                        } footer: {
                            HStack {
                                L10n.button("Back") {}
                                Spacer()
                                L10n.button(connection ? "Get Started" : "Continue") {}
                                    .buttonStyle(.borderedProminent)
                            }
                            .background(FooterMarker(view: marker))
                        }
                        .environment(\.appLanguage, language)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .font(CounselTheme.Typography.readingBody)
                        .controlSize(.large)
                        let host = NSHostingView(rootView: view)
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
                        host.layoutSubtreeIfNeeded()
                        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                        host.layoutSubtreeIfNeeded()
                        let footer = host.convert(marker.bounds, from: marker)
                        XCTAssertGreaterThan(footer.height, 20)
                        XCTAssertTrue(host.bounds.insetBy(dx: -1, dy: -1).contains(footer), "Footer clipped in \(language.rawValue)")
                        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5)
                        if let directory {
                            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                            host.cacheDisplay(in: host.bounds, to: bitmap)
                            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            let name = "wizard-\(connection ? "connect" : "workflow")-\(language.rawValue)-\(dark ? "dark" : "light")-\(Int(width)).png"
                            try png.write(to: directory.appendingPathComponent(name))
                        }
                    }
                }
            }
        }
    }
}

private struct FooterMarker: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
