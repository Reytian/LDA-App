//
//  LDAApp.swift
//  The SwiftUI app entry point. The window hosts the top-level RootShell from
//  LDAUI, which provides a segmented mode switcher between the Anonymize shell
//  (AppShell + ReviewModel) and the Fill shell (FillShell + FillModel). Both
//  child models are owned by RootShell and kept alive for the window's lifetime.
//
//  The "Review" menu commands remain wired to the shared ReviewModel so the
//  keyboard review loop works in Anonymize mode.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDAUI

@main
struct LDAApp: App {
    // RootShell owns both ReviewModel and FillModel internally as @StateObject,
    // so we only need a separate ReviewModel here for the menu commands. We use
    // the same default model path for consistency; RootShell passes it to both
    // of its own models.
    //
    // NOTE: The ReviewModel used by the menu commands is the SAME instance that
    // RootShell creates internally because RootShell.init is called once and its
    // @StateObject ReviewModel is the canonical instance. To keep the menu
    // commands wired to the right model without re-architecture, we pass a
    // shared ReviewModel into RootShell and hoist it here.
    //
    // For this iteration we use the simpler approach: hoist both models here
    // and pass them into RootShell so menu commands can reference reviewModel.

    /// The single review model for the Anonymize window. Hoisted here so the
    /// "Review" menu commands can reference it.
    @StateObject private var reviewModel = ReviewModel(modelPath: LDAApp.defaultModelPath())

    /// The fill model for the Fill window. Hoisted here for symmetry.
    @StateObject private var fillModel = FillModel(modelPath: LDAApp.defaultModelPath())

    /// The persisted custom vocabulary, shared by the window and Settings.
    @StateObject private var patternStore = CustomPatternStore()

    /// The persisted on-device learning store, shared by the window and Settings.
    @StateObject private var learningStore = LearningStore()

    /// The theme preference (System, Light, Dark), shared with Settings.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    private var colorScheme: ColorScheme? {
        AppearanceMode.from(rawValue: appearanceRaw).colorScheme
    }

    var body: some Scene {
        WindowGroup("LDA") {
            RootShell(reviewModel: reviewModel, fillModel: fillModel)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    // Feed the user's custom vocabulary into each anonymize run,
                    // and let the model learn from each export.
                    reviewModel.customPatternProvider = { [patternStore] in patternStore.activePatterns }
                    reviewModel.learningStore = learningStore
                }
        }

        .commands {
            CommandGroup(after: .saveItem) {
                Button("Export Redacted Document…") {
                    reviewModel.requestExport()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!reviewModel.canExport)

                Button("Restore Original…") {
                    reviewModel.requestRestore()
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            // The keyboard review loop for the Anonymize mode.
            CommandMenu("Review") {
                Button("Next Entity") {
                    reviewModel.selectNextGroup()
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(reviewModel.entities.isEmpty)

                Button("Previous Entity") {
                    reviewModel.selectPreviousGroup()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(reviewModel.entities.isEmpty)

                Divider()

                Button("Toggle Redaction") {
                    reviewModel.toggleSelectedGroup()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(reviewModel.selectedGroupID == nil)
            }
        }

        Settings {
            SettingsView(patterns: patternStore, learning: learningStore)
                .preferredColorScheme(colorScheme)
        }
    }

    /// The default v2 GGUF model path. Prefers the copy bundled inside the app
    /// (a distributed, self-contained .app), then falls back to the developer
    /// location, then nil (deterministic-only).
    private static func defaultModelPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "lda-v2-Q4_K_M", ofType: "gguf") {
            return bundled
        }
        let dev = ("~/Developer/lda-models/lda-v2-Q4_K_M.gguf" as NSString)
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }
}
