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
import LDACore

@main
struct LDAApp: App {

    init() {
        // Container keys are protected by Touch ID (login password fallback)
        // in the GUI app: retrieval goes through the data-protection keychain
        // behind a user-presence access control, with existing silent keys
        // upgraded in place on first use. Headless surfaces (lda CLI, MCP
        // server, tests) leave this off; biometry prompts require a signed
        // app and an interactive user.
        KeychainAccessPolicy.requireUserPresence = true

        // Turn on the local encrypted audit trail for the GUI app. It records
        // encryption and Keychain operations (timestamps, operation, store
        // kind, success or failure) and never a document value, a file path, or
        // a client label. Headless surfaces leave it off, so linking LDACore
        // does not start writing an audit file.
        SecurityEventLog.shared.isEnabled = true
    }
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

    /// The Cmd+J navigation loop applies to Anonymize (entities) and Fill
    /// (blanks); the De-anonymize mode has no list to walk.
    private var navigationLoopDisabled: Bool {
        switch modeStore.activeMode {
        case .anonymize: return sessionModel.activeModel.entities.isEmpty
        case .fill: return fillModel.blanks.isEmpty
        case .deanonymize: return true
        }
    }

    /// Cmd+Return toggles the selected entity (Anonymize) or accepts the
    /// selected blank (Fill).
    private var toggleDisabled: Bool {
        switch modeStore.activeMode {
        case .anonymize: return sessionModel.activeModel.selectedGroupID == nil
        case .fill: return fillModel.selectedBlankID == nil
        case .deanonymize: return true
        }
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
                    // NOTE: a parked awaiting-AI session is resumed lazily
                    // (first paste-restore), NOT here. The parked mapping is
                    // Keychain-protected, and a Keychain prompt at app launch
                    // is exactly the kind of surprise dialog users distrust.
                }
                .onChange(of: customModelPath) { _, _ in
                    sessionModel.reapplyConfiguration()
                }
                .onChange(of: detectionModeRaw) { _, _ in
                    sessionModel.reapplyConfiguration()
                }
                .onDisappear {
                    // Closing the window ends the session: documents unpacked
                    // from a .zip are un-redacted originals and should not stay
                    // in the temp directory, and any buffered audit events
                    // should reach disk.
                    sessionModel.discardExpandedArchives()
                    SecurityEventLog.shared.flush()
                }
        }

        .commands {
            CommandGroup(after: .saveItem) {
                Button("Scan for PII") {
                    modeStore.activeMode = .anonymize
                    sessionModel.activeModel.requestAnonymize()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!sessionModel.activeModel.canAnonymize)

                Button("Copy for AI") {
                    sessionModel.requestCopyForAI()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Paste from AI…") {
                    modeStore.activeMode = .deanonymize
                    sessionModel.requestPasteRestore()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Divider()

                Button("Export Redacted Document…") {
                    sessionModel.activeModel.requestExport()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!sessionModel.activeModel.canExport)

                Button("Restore Redacted File…") {
                    // Land the user in the De-anonymize mode so the flow has
                    // visible context, then start it.
                    modeStore.activeMode = .deanonymize
                    sessionModel.activeModel.requestRestore()
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            // Mode-aware navigation loop. Cmd+J / Cmd+Shift+J advance or retreat
            // through entities (Anonymize mode) or blanks (Fill mode). Cmd+Return
            // toggles the selected item in the active mode. The menu title and
            // item labels update when the mode switches so the menu bar tells the
            // truth about what the shortcut does.
            CommandMenu(modeStore.activeMode == .fill ? "Fill" : "Review") {
                Button(modeStore.activeMode == .fill ? "Next Blank" : "Next Entity") {
                    switch modeStore.activeMode {
                    case .anonymize:
                        sessionModel.activeModel.selectNextGroup()
                    case .fill:
                        fillModel.selectNextBlank()
                    case .deanonymize:
                        break
                    }
                }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(navigationLoopDisabled)

                Button(modeStore.activeMode == .fill ? "Previous Blank" : "Previous Entity") {
                    switch modeStore.activeMode {
                    case .anonymize:
                        sessionModel.activeModel.selectPreviousGroup()
                    case .fill:
                        fillModel.selectPreviousBlank()
                    case .deanonymize:
                        break
                    }
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(navigationLoopDisabled)

                Divider()

                Button(modeStore.activeMode == .fill ? "Accept Blank" : "Toggle Redaction") {
                    switch modeStore.activeMode {
                    case .anonymize:
                        sessionModel.activeModel.toggleSelectedGroup()
                    case .fill:
                        if let id = fillModel.selectedBlankID {
                            fillModel.acceptBlank(id: id)
                        }
                    case .deanonymize:
                        break
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(toggleDisabled)
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
