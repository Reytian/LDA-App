//
//  LDAApp.swift
//  The SwiftUI app entry point. The window hosts the top-level RootShell from
//  LDAUI, which provides a segmented mode switcher between the Anonymize shell
//  (AppShell + ReviewModel) and the Fill shell (FillShell + FillModel). Both
//  child models are owned by RootShell and kept alive for the window's lifetime.
//
//  Keyboard shortcut design (mode-aware commands, option b):
//  Cmd+J / Cmd+Shift+J are shared shortcuts for the navigation loop. A single
//  CommandMenu("Review / Fill") entry reads the current AppModeStore.activeMode
//  and dispatches to ReviewModel (Anonymize) or FillModel (Fill). This preserves
//  muscle memory and matches the entity-loop parity the Fill spec requires.
//  Cmd+Return toggles the selected item in whichever mode is active.
//
//  AppModeStore is created here and passed into RootShell so the toolbar picker
//  and the command dispatchers share the same mode state.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDAUI

@main
struct LDAApp: App {
    // Both child models and the mode store are hoisted here so the CommandMenu
    // closures can capture and dispatch to the right model at call time.

    /// The session model for the Anonymize window: the document tray plus one
    /// review model per document (R12/R19).
    @StateObject private var sessionModel = SessionModel(
        makeModel: { ReviewModel(modelPath: LDAApp.defaultModelPath()) }
    )

    /// The fill model for the Fill window.
    @StateObject private var fillModel = FillModel(modelPath: LDAApp.defaultModelPath())

    /// The shared mode store. Owned here; passed into RootShell and read by
    /// the CommandMenu entries to route Cmd+J / Cmd+Shift+J / Cmd+Return.
    @StateObject private var modeStore = AppModeStore()

    /// The persisted custom vocabulary, shared by the window and Settings.
    @StateObject private var patternStore = CustomPatternStore()

    /// The persisted on-device learning store, shared by the window and Settings.
    @StateObject private var learningStore = LearningStore()

    /// The theme preference (System, Light, Dark), shared with Settings.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    /// The AI settings (custom model path and detection mode), observed so a
    /// change in Settings re-applies to every open document model.
    @AppStorage(AISettings.customModelPathKey) private var customModelPath = ""
    @AppStorage(AISettings.detectionModeKey) private var detectionModeRaw = DetectionMode.thorough.rawValue

    private var colorScheme: ColorScheme? {
        AppearanceMode.from(rawValue: appearanceRaw).colorScheme
    }

    var body: some Scene {
        WindowGroup("LDA") {
            RootShell(session: sessionModel, fillModel: fillModel, modeStore: modeStore)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    // Feed the user's custom vocabulary into every document's
                    // anonymize run, let each model learn from its export, and
                    // apply the AI settings (model path, detection mode).
                    sessionModel.configureNewModel = { [patternStore, learningStore] model in
                        model.customPatternProvider = { patternStore.activePatterns }
                        model.learningStore = learningStore
                        AISettings.apply(to: model, bundledDefault: LDAApp.defaultModelPath())
                    }
                }
                .onChange(of: customModelPath) { _, _ in
                    sessionModel.reapplyConfiguration()
                }
                .onChange(of: detectionModeRaw) { _, _ in
                    sessionModel.reapplyConfiguration()
                }
        }

        .commands {
            CommandGroup(after: .saveItem) {
                Button("Copy for AI") {
                    sessionModel.requestCopyForAI()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Restore from AI…") {
                    sessionModel.requestPasteRestore()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button("Export Redacted Document…") {
                    sessionModel.activeModel.requestExport()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!sessionModel.activeModel.canExport)

                Button("Restore Original…") {
                    sessionModel.activeModel.requestRestore()
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            // Mode-aware navigation loop. Cmd+J / Cmd+Shift+J advance or retreat
            // through entities (Anonymize mode) or blanks (Fill mode). Cmd+Return
            // toggles the selected item in the active mode. The menu title and
            // item labels update when the mode switches so the menu bar tells the
            // truth about what the shortcut does.
            CommandMenu(modeStore.activeMode == .anonymize ? "Review" : "Fill") {
                Button(modeStore.activeMode == .anonymize ? "Next Entity" : "Next Blank") {
                    if modeStore.activeMode == .anonymize {
                        sessionModel.activeModel.selectNextGroup()
                    } else {
                        fillModel.selectNextBlank()
                    }
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(
                    modeStore.activeMode == .anonymize
                        ? sessionModel.activeModel.entities.isEmpty
                        : fillModel.blanks.isEmpty
                )

                Button(modeStore.activeMode == .anonymize ? "Previous Entity" : "Previous Blank") {
                    if modeStore.activeMode == .anonymize {
                        sessionModel.activeModel.selectPreviousGroup()
                    } else {
                        fillModel.selectPreviousBlank()
                    }
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(
                    modeStore.activeMode == .anonymize
                        ? sessionModel.activeModel.entities.isEmpty
                        : fillModel.blanks.isEmpty
                )

                Divider()

                Button(modeStore.activeMode == .anonymize ? "Toggle Redaction" : "Accept Blank") {
                    if modeStore.activeMode == .anonymize {
                        sessionModel.activeModel.toggleSelectedGroup()
                    } else if let id = fillModel.selectedBlankID {
                        fillModel.acceptBlank(id: id)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(
                    modeStore.activeMode == .anonymize
                        ? sessionModel.activeModel.selectedGroupID == nil
                        : fillModel.selectedBlankID == nil
                )
            }
        }

        Settings {
            SettingsView(patterns: patternStore, learning: learningStore)
                .preferredColorScheme(colorScheme)
        }

        // The menu-bar companion (auxiliary posture): the round-trip has no
        // dead end. Coming back from the AI, the user can restore the
        // clipboard without raising the main window.
        MenuBarExtra("LDA", systemImage: "shield.lefthalf.filled") {
            CompanionMenu(session: sessionModel)
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
