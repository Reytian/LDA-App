//
//  LDAApp.swift
//  The SwiftUI app entry point. The window hosts the top-level RootShell from
//  LDAUI, which provides a segmented switcher for Matters, Anonymize, Restore,
//  and Fill. The child models are owned by RootShell and kept alive for the
//  window's lifetime.
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDAUI
import LDACore

@main
struct LDAApp: App {

    init() {
        // Container keys are protected by Touch ID (login password fallback)
        // in the GUI app: retrieval first uses a user-presence access control,
        // with existing silent keys upgraded in place when supported. Direct
        // Developer ID sandbox builds fall back to the traditional login
        // Keychain if macOS rejects the biometric path for lack of a provisioned
        // application identifier. Headless surfaces leave this policy off.
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
        makeModel: { ReviewModel(modelPath: AISettings.resolveModelPath()) }
    )

    /// The fill model for the Fill window.
    @StateObject private var fillModel = FillModel(modelPath: AISettings.resolveModelPath())

    /// The shared mode store. Owned here; passed into RootShell and read by
    /// the CommandMenu entries to route Cmd+J / Cmd+Shift+J / Cmd+Return.
    /// App-level so an in-flight model download survives closing Settings.
    @StateObject private var modelInstaller = ModelInstaller()

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
    // Observe the ladder's key. The legacy detectionModeKey is no longer
    // written by anything, so watching it meant a settings change never reached
    // an already-open document.
    @AppStorage(AISettings.detectionLevelKey) private var detectionLevelRaw = DetectionLevel.quick.rawValue

    private var colorScheme: ColorScheme? {
        AppearanceMode.from(rawValue: appearanceRaw).colorScheme
    }

    /// The Cmd+J navigation loop applies to Anonymize (entities) and Fill
    /// (blanks); the De-anonymize mode has no list to walk.
    private var navigationLoopDisabled: Bool {
        switch modeStore.activeMode {
        case .anonymize: return sessionModel.activeModel.entities.isEmpty
        case .fill: return fillModel.blanks.isEmpty
        case .matters, .deanonymize: return true
        }
    }

    /// Cmd+Return toggles the selected entity (Anonymize) or accepts the
    /// selected blank (Fill).
    private var toggleDisabled: Bool {
        switch modeStore.activeMode {
        case .anonymize: return sessionModel.activeModel.selectedGroupID == nil
        case .fill: return fillModel.selectedBlankID == nil
        case .matters, .deanonymize: return true
        }
    }

    var body: some Scene {
        Window("LDA", id: LDAWindowID.main) {
            RootShell(session: sessionModel, fillModel: fillModel, modeStore: modeStore)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    // Attach the global vocabulary and learning layers; the
                    // session injects matter-scoped facades over them into
                    // every document model (F4), so a rule learned under one
                    // matter can stay in that matter. The AI settings still
                    // apply per model through configureNewModel.
                    sessionModel.attachStores(
                        learning: learningStore,
                        patterns: patternStore
                    )
                    sessionModel.configureNewModel = { model in
                        AISettings.apply(to: model)
                    }
                    AISettings.apply(to: fillModel)
                    // NOTE: a parked awaiting-AI session is resumed lazily
                    // (first paste-restore), NOT here. The parked mapping is
                    // Keychain-protected, and a Keychain prompt at app launch
                    // is exactly the kind of surprise dialog users distrust.
                }
                .onOpenURL { url in
                    // Double-clicking a .ldawork or .ldareport file in Finder
                    // arrives here. The app does NOT open either directly: the
                    // review shell owns the passphrase prompt, the "this
                    // replaces what is open" question, and the choice of where
                    // readable report copies land, so a double-click can never
                    // discard live work or write names in the clear on its
                    // own. Anything else is ignored, because ordinary
                    // documents come in through the open panel, which is where
                    // the import budgets are applied.
                    switch url.pathExtension.lowercased() {
                    case WorkspaceArchive.fileExtension:
                        modeStore.activeMode = .anonymize
                        sessionModel.pendingWorkspaceURL = url
                    case ComplianceReportArchive.fileExtension:
                        modeStore.activeMode = .anonymize
                        sessionModel.pendingReportURL = url
                    default:
                        break
                    }
                }
                .onChange(of: customModelPath) { _, _ in
                    sessionModel.reapplyConfiguration()
                    AISettings.apply(to: fillModel)
                }
                .onChange(of: detectionLevelRaw) { _, _ in
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
            // File > Open. This is audit item F2's real closure: the document
            // pane has always offered a prominent "Choose Files", but there was
            // no menu item and no shortcut for it, so after a failed import a
            // keyboard-only user had no way to recover at all.
            CommandGroup(after: .newItem) {
                Button("Open Documents...") {
                    modeStore.activeMode = .anonymize
                    sessionModel.requestOpen()
                }
                .keyboardShortcut("o", modifiers: .command)

                // A workspace usually arrives by double-click, but the file
                // association only exists once the app is installed and
                // registered, so the menu is the reliable route.
                Button("Open Workspace\u{2026}") {
                    modeStore.activeMode = .anonymize
                    presentWorkspaceOpenPanel()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                // An encrypted compliance report needs LDA to read it, so the
                // app has to offer a way in. No shortcut: this is a rare,
                // recipient-side action, not part of the daily loop.
                Button("Open Report\u{2026}") {
                    modeStore.activeMode = .anonymize
                    presentReportOpenPanel()
                }
            }

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

                Button("Save Redacted Document…") {
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
                    case .matters, .deanonymize:
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
                    case .matters, .deanonymize:
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
                    case .matters, .deanonymize:
                        break
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(toggleDisabled)
            }
        }

        Settings {
            SettingsView(
                patterns: patternStore,
                learning: learningStore,
                installer: modelInstaller,
                // Any open document mid-scan gates model removal: llama.cpp
                // still has the file mmapped, so the disk would not
                // actually come back and the app would report otherwise.
                isScanning: sessionModel.entries.contains { $0.model.status == .detecting }
            )
                .preferredColorScheme(colorScheme)
        }

        // The menu-bar companion (auxiliary posture): the round-trip has no
        // dead end. Coming back from the AI, the user can restore the
        // clipboard without raising the main window.
        MenuBarExtra("LDA", systemImage: "shield.lefthalf.filled") {
            CompanionMenu(session: sessionModel)
        }
    }

    // The initial model path is whatever the current detection level resolves
    // to: the container copy, then the bundled Quick model, then nil. See
    // docs/design/model-tiers-prd.md section 6 and model-management-prd.md.

    /// Choose a .ldawork file and hand it to the review shell, which owns the
    /// passphrase prompt and the replace-live-work question.
    private func presentWorkspaceOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: WorkspaceArchive.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.message = "Choose a saved LDA workspace file."
        panel.prompt = "Open Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sessionModel.pendingWorkspaceURL = url
    }

    /// Choose a .ldareport file and hand it to the review shell, which owns
    /// the passphrase prompt and asks where the readable copies should land.
    private func presentReportOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: ComplianceReportArchive.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.message = "Choose an encrypted LDA report file."
        panel.prompt = "Open Report"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sessionModel.pendingReportURL = url
    }
}
