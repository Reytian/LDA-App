//
//  LDAApp.swift
//  The SwiftUI app entry point. The window hosts the Counsel review shell from
//  LDAUI, driven by a ReviewModel. The default model path points at the bundled
//  v2 GGUF model when it exists on disk, otherwise the model runs
//  deterministic-only.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDAUI

@main
struct LDAApp: App {
    /// The single review model for the main window. The default model path is
    /// used only when the GGUF file is actually present; otherwise detection is
    /// deterministic-only.
    @StateObject private var model = ReviewModel(modelPath: LDAApp.defaultModelPath())

    /// The persisted custom vocabulary, shared by the window and Settings.
    @StateObject private var patternStore = CustomPatternStore()

    /// The persisted on-device learning store, shared by the window and Settings.
    @StateObject private var learningStore = LearningStore()

    var body: some Scene {
        WindowGroup("LDA") {
            AppShell(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    // Feed the user's custom vocabulary into each anonymize run,
                    // and let the model learn from each export.
                    model.customPatternProvider = { [patternStore] in patternStore.activePatterns }
                    model.learningStore = learningStore
                }
        }

        Settings {
            SettingsView(patterns: patternStore, learning: learningStore)
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
