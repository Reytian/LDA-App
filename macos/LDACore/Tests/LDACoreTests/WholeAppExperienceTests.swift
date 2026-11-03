import AppKit
import SwiftUI
import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class WholeAppExperienceTests: XCTestCase {
    func testRestoredSidebarWidthKeepsNamesReadableAndPreservesCollapsedState() {
        let controller = NSSplitViewController()
        controller.splitView.isVertical = true
        let side = NSViewController()
        side.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 600))
        let detail = NSViewController()
        detail.view = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 600))
        let item = NSSplitViewItem(sidebarWithViewController: side)
        controller.addSplitViewItem(item)
        controller.addSplitViewItem(NSSplitViewItem(viewController: detail))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 600)
        controller.splitView.setPosition(160, ofDividerAt: 0)
        FindingsSidebarWidthView.apply(to: controller, sidebar: item)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(side.view.frame.width, 260)
        XCTAssertLessThanOrEqual(side.view.frame.width, 420)
        item.isCollapsed = true
        FindingsSidebarWidthView.apply(to: controller, sidebar: item)
        XCTAssertTrue(item.isCollapsed)
    }

    func testEmptyManualProfileOffersAddingInformationBeforeChoosingAForm() {
        XCTAssertEqual(FillProfilePrimaryAction.resolve(hasProfile: true, hasSources: false,
            needsSave: true, hasFields: false), .addField)
        XCTAssertEqual(FillProfilePrimaryAction.resolve(hasProfile: true, hasSources: true,
            needsSave: true, hasFields: false), .extract)
        XCTAssertEqual(FillProfilePrimaryAction.resolve(hasProfile: true, hasSources: false,
            needsSave: true, hasFields: true), .saveAndChooseTarget)
    }

    func testFocusedProfileEditIsIncludedInSaveWithoutSubmitting() throws {
        let field = ProfileField(id: UUID(), key: .companyName, value: "Before", sourceDocument: "fixture.txt",
                                 sourceSnippet: "Before", snippetVerified: true, confidence: 1, userEdited: false)
        let model = FillModel(modelPath: nil)
        model.loadProfile(ClientPortfolio(label: "Synthetic test", fields: [field], sourceDocuments: [],
                                          createdAtISO8601: "2026-11-03T00:00:00Z", incomplete: false))
        let row = ProfileFieldRow(model: model, field: field, isConflicted: false, conflictCandidates: [])
        row.valueBinding.wrappedValue = "After typing, before Return"
        XCTAssertTrue(model.profileDirty)
        let profile = try XCTUnwrap(model.profile)
        XCTAssertTrue(profile.fields[0].userEdited)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ldaprofile")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProfileStore.save(profile, to: url, protection: .passphrase("synthetic-test-only"))
        let saved = try ProfileStore.load(from: url, protection: .passphrase("synthetic-test-only"))
        XCTAssertEqual(saved.fields[0].value, "After typing, before Return")
        model.updateField(id: field.id, value: "Updated elsewhere")
        XCTAssertEqual(row.valueBinding.wrappedValue, "Updated elsewhere")
    }

    func testUnchangedProfileInputDoesNotMarkCleanProfileDirty() {
        let field = ProfileField(id: UUID(), key: .companyName, value: "Same", sourceDocument: "fixture.txt",
                                 sourceSnippet: "Same", snippetVerified: true, confidence: 1, userEdited: false)
        let model = FillModel(modelPath: nil)
        model.loadProfile(ClientPortfolio(label: "Synthetic test", fields: [field], sourceDocuments: [],
                                          createdAtISO8601: "2026-11-03T00:00:00Z", incomplete: false))
        let row = ProfileFieldRow(model: model, field: field, isConflicted: false, conflictCandidates: [])
        row.valueBinding.wrappedValue = "Same"
        XCTAssertFalse(model.profileDirty)
        XCTAssertEqual(model.profile?.fields.first?.userEdited, false)
    }

    func testDialogsAndVocabularyFitAcrossLanguagesAndAppearances() throws {
        let destination = ProcessInfo.processInfo.environment["LDA_EXPERIENCE_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
        if let destination { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        let (defaults, name) = TestNamespace.defaults("experience-layout")
        defer { defaults.removePersistentDomain(forName: name) }
        let acceptance = LegalAcceptanceStore(defaults: defaults, documents: try LegalDocuments.bundled())
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            defaults.set(language.rawValue, forKey: AppLanguage.storageKey)
            for dark in [false, true] {
                let examples: [(String, AnyView, CGFloat, CGFloat)] = [
                    ("workspace-save", AnyView(WorkspaceSaveSheet(flow: WorkspaceFlowModel(), onConfirm: {})), 480, 700),
                    ("workspace-open", AnyView(WorkspaceOpenSheet(flow: WorkspaceFlowModel(), onConfirm: {})), 480, 520),
                    ("report-export", AnyView(ComplianceReportExportSheet(flow: ComplianceReportFlowModel(), onConfirm: {})), 480, 850),
                    ("vocabulary", AnyView(PatternRow(pattern: .constant(CustomPattern(text: "[", isRegex: true))).padding(20)), 480, 340),
                    ("legal", AnyView(LegalConsentView(acceptance: acceptance)), 900, 680)
                ]
                for (name, content, width, maximumHeight) in examples {
                    let host = NSHostingView(rootView: content
                        .defaultAppStorage(defaults)
                        .environment(\.appLanguage, language)
                        .environment(\.locale, language.locale)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .font(CounselTheme.Typography.readingBody)
                        .frame(width: width)
                        .background(CounselTheme.appSurface)
                        .disclosureGroupStyle(FullRowDisclosureStyle()))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: maximumHeight)
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                    host.layoutSubtreeIfNeeded()
                    let fitting = host.fittingSize
                    XCTAssertLessThanOrEqual(fitting.width, width + 1, "\(name) exceeds width in \(language.rawValue)")
                    // A legal-document ScrollView has a larger ideal height than its viewport.
                    if name != "legal" {
                        XCTAssertLessThanOrEqual(fitting.height, maximumHeight + 1, "\(name) exceeds height in \(language.rawValue)")
                    }
                    XCTAssertEqual(host.bounds.height, maximumHeight, accuracy: 0.5)
                    if let destination {
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: destination.appendingPathComponent("\(name)-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
