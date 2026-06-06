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

    var body: some Scene {
        WindowGroup("LDA") {
            AppShell(model: model)
                .frame(minWidth: 1100, minHeight: 720)
        }
    }

    /// The default v2 GGUF model path, returned only when the file exists.
    private static func defaultModelPath() -> String? {
        let path = ("~/Developer/lda-models/lda-v2-Q4_K_M.gguf" as NSString)
            .expandingTildeInPath
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}
