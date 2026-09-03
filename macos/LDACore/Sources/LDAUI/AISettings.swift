//
//  AISettings.swift
//  LDAUI
//
//  The user-facing AI settings. As of the model-tiers work this is ONE ladder
//  (DetectionLevel: patterns only, Quick, Balanced, Most thorough) rather than
//  a separate quality switch plus a free-text model path. See
//  docs/design/model-tiers-prd.md.
//
//  DetectionMode is kept ONLY as a derived value so ReviewModel.useLLM and its
//  call sites are unchanged. It is no longer a user-facing setting, and the old
//  UserDefaults key is left in place unread for one release so a downgrade does
//  not lose the user's choice.
//
//  No model ships inside the app. Every tier is either downloaded into the app
//  container through Manage Models or added there by the verified offline
//  import. A build made with BUNDLE_MODEL=1 carries Quick as a deliberate
//  single-file deploy, which is why the bundled lookup survives as a last
//  resort. A tier with no file resolves to nil and that state is reported,
//  never silently degraded.
//
//  Sandbox note: a custom model chosen through an open panel is reachable for
//  that launch only. Persisting the plain path is not enough, because the
//  sandbox grants access to the URL, not to the string. We store a
//  security-scoped bookmark alongside it and resolve that on read. Tier models
//  do not need this at all: they are copied into the app container, which the
//  app owns outright. Adding the bookmark entitlement is NOT adding a network
//  entitlement; the offline guarantee in LDA.entitlements is untouched.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// The quality/speed tradeoff for detection.
///
/// No longer user-facing: it is derived from `DetectionLevel.usesLLM`. Kept so
/// existing call sites and stored values continue to compile and migrate.
public enum DetectionMode: String, CaseIterable {
    /// Patterns plus the on-device AI model.
    case thorough
    /// Patterns only.
    case fast

    public var label: String {
        switch self {
        case .thorough: return "Thorough (patterns + on-device AI)"
        case .fast: return "Fast (patterns only)"
        }
    }
}

/// Shared keys and resolution for the AI settings.
public enum AISettings {

    // MARK: Keys

    /// UserDefaults key for the custom GGUF model path ("" = no custom model).
    public static let customModelPathKey = "com.haotianyi.LDA.customModelPath"

    /// Security-scoped bookmark for the custom model. Without this the stored
    /// path is unreadable after relaunch under the sandbox.
    public static let customModelBookmarkKey = "com.haotianyi.LDA.customModelBookmark"

    /// Legacy key for the two-value detection mode. Written by versions before
    /// the ladder. Read once for migration, then left alone.
    public static let detectionModeKey = "com.haotianyi.LDA.detectionMode"

    /// UserDefaults key for the selected rung of the ladder.
    public static let detectionLevelKey = "com.haotianyi.LDA.detectionLevel"

    /// Set once migration from `detectionModeKey` has run.
    public static let migratedKey = "com.haotianyi.LDA.detectionLevelMigrated"

    /// Set once the one-time offer to leave the retired lda-v2 fine tune has
    /// been answered, either way, so it never appears twice.
    public static let ldaV2NoticeDismissedKey = "com.haotianyi.LDA.ldaV2NoticeDismissed"

    /// UserDefaults key for the output style (token, pseudonym, asterisk).
    /// Stored as the SubstitutionStyle raw value; absent means token.
    public static let outputStyleKey = "com.haotianyi.LDA.outputStyle"

    /// The answer to the first-run model ask. Absent means "not asked yet".
    ///
    /// A string rather than a Bool: a Bool collapses "declined" into "never
    /// asked" the moment a later version wants to re-ask, and it cannot express
    /// the 8 GB Mac's "there was nothing to ask".
    ///
    /// Separate from hasCompletedFirstRun on purpose: that flag records that
    /// the SHEET was shown, and conflating the two is why pressing Set Up a
    /// Model and then closing Manage Models counted as an answer.
    public enum ModelSetupAnswer: String, Sendable {
        /// Started a download, or said the file is already on hand.
        case accepted
        /// Not Now, or a dismissal that reached the shell's fallback.
        case declined
        /// No tier can run on this Mac, so there was nothing to ask.
        case unavailable
    }

    /// UserDefaults key for the answer to the first-run model ask.
    public static let modelSetupAnswerKey = "com.haotianyi.LDA.modelSetupAnswer"

    /// Offline mode. When on, the app makes no network request at all, so model
    /// downloads are refused rather than attempted.
    ///
    /// This does not make a typical user safer: the app already only connects
    /// when they press Download. It exists so a firm can answer "can you
    /// guarantee it will not" with a setting rather than with trust, and so IT
    /// can force that answer through a managed preference. The UI must admit
    /// its own limit: it is a setting inside LDA, not a firewall.
    public static let offlineModeKey = "com.haotianyi.LDA.offlineMode"

    // MARK: Custom model resolution

    /// The custom model URL, resolved from its security-scoped bookmark when
    /// one exists. Returns nil when no custom model is set, the bookmark cannot
    /// be resolved, or the file is gone.
    ///
    /// The caller is responsible for balancing `startAccessingSecurityScopedResource`
    /// with a matching stop; `withCustomModelAccess` does that for you.
    public static func customModelURL(defaults: UserDefaults = .standard) -> URL? {
        if let data = defaults.data(forKey: customModelBookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                // A stale bookmark still resolves; refresh it opportunistically.
                if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
                    defaults.set(fresh, forKey: customModelBookmarkKey)
                }
                return url
            }
        }
        // No bookmark (or it failed to resolve). Fall back to the bare path,
        // which is all that older versions stored and which still works in the
        // unsandboxed dev binary.
        guard let path = defaults.string(forKey: customModelPathKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Holds the security scope for the custom model for as long as that model
    /// may be loaded.
    ///
    /// The model file is not opened where the path is resolved. It is opened
    /// much later, on another thread, inside `LLMEngine`. Releasing the scope
    /// when the resolver returns (the obvious `defer` that this code used to
    /// have) leaves the engine with an unreadable path under the sandbox, and
    /// the failure looks exactly like a deliberate patterns-only run.
    ///
    /// So the scope is opened once and held until the custom model changes.
    /// There is at most one custom model, so this leaks nothing that outlives
    /// the selection itself.
    private final class ScopeHolder: @unchecked Sendable {
        static let shared = ScopeHolder()
        private let lock = NSLock()
        private var held: URL?

        /// Begin access to `url`, releasing any previously held scope.
        func hold(_ url: URL?) {
            lock.lock()
            defer { lock.unlock() }
            if let held, held != url {
                held.stopAccessingSecurityScopedResource()
                self.held = nil
            }
            guard let url, self.held == nil else { return }
            if url.startAccessingSecurityScopedResource() {
                self.held = url
            }
        }

        func release() { hold(nil) }
    }

    /// The custom model path when it is set AND currently readable.
    ///
    /// Opening the scope here and keeping it is deliberate: see ScopeHolder.
    public static func customModelPath(defaults: UserDefaults = .standard) -> String? {
        guard let url = customModelURL(defaults: defaults) else {
            ScopeHolder.shared.release()
            return nil
        }
        ScopeHolder.shared.hold(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    /// Record a user-chosen custom model, storing both the path and a
    /// security-scoped bookmark so it survives relaunch.
    public static func setCustomModel(url: URL?, defaults: UserDefaults = .standard) {
        guard let url else {
            ScopeHolder.shared.release()
            defaults.removeObject(forKey: customModelPathKey)
            defaults.removeObject(forKey: customModelBookmarkKey)
            return
        }
        defaults.set(url.path, forKey: customModelPathKey)
        if let data = try? url.bookmarkData(options: [.withSecurityScope]) {
            defaults.set(data, forKey: customModelBookmarkKey)
        } else {
            // Unsandboxed dev binary, or a URL that cannot be bookmarked. The
            // plain path still works there.
            defaults.removeObject(forKey: customModelBookmarkKey)
        }
    }

    /// Persist a user-selected model and keep its sandbox access active.
    ///
    /// Kept from feat/lda-macos-core, which solved the security-scope bug
    /// independently and in parallel. Both designs held the scope for the life
    /// of the selection; this one throws when the bookmark cannot be made,
    /// which is the more honest signal, so the API is preserved and delegates
    /// to the shared implementation rather than duplicating it.
    @MainActor
    public static func selectCustomModel(
        at url: URL,
        defaults: UserDefaults = .standard
    ) throws {
        // Surface a bookmark failure instead of silently degrading to a bare
        // path that will stop resolving after the next launch.
        _ = try url.bookmarkData(options: [.withSecurityScope])
        setCustomModel(url: url, defaults: defaults)
    }

    /// Return to the tier model and release any custom-model file access.
    @MainActor
    public static func clearCustomModel(defaults: UserDefaults = .standard) {
        setCustomModel(url: nil, defaults: defaults)
    }

    // MARK: Level

    /// The selected rung, after migrating a legacy `detectionMode` when needed.
    ///
    /// The default is `.quick` even on an install that has no model file, and
    /// that is deliberate. Defaulting to `.patternsOnly` instead would set
    /// `usesLLM == false`, which makes `ReviewModel.llmSpans` report
    /// `attempted: false` with no failure, and that state is reserved for "the
    /// user did not ask for an AI pass". Auto-demoting would convert a reported
    /// failure into a silent one, which in a redaction tool is the worst
    /// outcome available. So the default is a rung that cannot run until a
    /// model is added, and `isModelMissing()` stays true so the app says so.
    public static func detectionLevel(
        defaults: UserDefaults = .standard,
        catalog: ModelCatalog = .load()
    ) -> DetectionLevel {
        migrateIfNeeded(defaults: defaults, catalog: catalog)
        guard let raw = defaults.string(forKey: detectionLevelKey),
              let level = DetectionLevel(rawValue: raw) else {
            return .quick
        }
        return level
    }

    /// One-time migration from the two-value `detectionMode` to the ladder.
    ///
    /// fast -> patternsOnly. thorough with no custom model -> quick. thorough
    /// with a custom model that matches an installed tier -> that tier.
    /// Anything else thorough keeps its custom model and lands on quick, with
    /// the custom path preserved so the Manage Models sheet can still show it.
    public static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        catalog: ModelCatalog = .load()
    ) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }

        // Nothing stored at all: a fresh install, no migration to do.
        guard let legacyRaw = defaults.string(forKey: detectionModeKey),
              let legacy = DetectionMode(rawValue: legacyRaw) else {
            return
        }

        if legacy == .fast {
            defaults.set(DetectionLevel.patternsOnly.rawValue, forKey: detectionLevelKey)
            return
        }

        // thorough: map the custom model onto a tier when we can recognise it.
        let path = defaults.string(forKey: customModelPathKey) ?? ""
        if !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if let tier = catalog.tiers.first(where: { $0.fileName == name }),
               let level = tier.detectionLevel {
                defaults.set(level.rawValue, forKey: detectionLevelKey)
                return
            }
        }
        defaults.set(DetectionLevel.quick.rawValue, forKey: detectionLevelKey)
    }

    /// Store the selected rung.
    public static func setDetectionLevel(
        _ level: DetectionLevel,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(level.rawValue, forKey: detectionLevelKey)
        defaults.set(true, forKey: migratedKey)
    }

    /// The stored detection mode, derived from the ladder.
    public static func detectionMode(defaults: UserDefaults = .standard) -> DetectionMode {
        detectionLevel(defaults: defaults).usesLLM ? .thorough : .fast
    }

    // MARK: Output style

    /// The stored output style. Absent or unrecognized values resolve to
    /// .token, the historical behavior, so an old install never changes its
    /// output on update.
    public static func outputStyle(defaults: UserDefaults = .standard) -> SubstitutionStyle {
        guard let raw = defaults.string(forKey: outputStyleKey),
              let style = SubstitutionStyle(rawValue: raw) else {
            return .token
        }
        return style
    }

    /// Store the selected output style.
    public static func setOutputStyle(
        _ style: SubstitutionStyle,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(style.rawValue, forKey: outputStyleKey)
    }

    /// Whether to show the one-time offer to stop using the retired lda-v2
    /// fine tune.
    ///
    /// Only fires for a user who EXPLICITLY chose an lda-v2 file. Someone on a
    /// catalog tier simply receives the new model when they install it, with no
    /// decision to make. An explicit choice is never silently overridden.
    public static func shouldOfferLdaV2Switch(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: ldaV2NoticeDismissedKey) else { return false }
        guard let path = defaults.string(forKey: customModelPathKey), !path.isEmpty else {
            return false
        }
        return URL(fileURLWithPath: path).lastPathComponent.lowercased().contains("lda-v2")
    }

    /// Record that the offer was answered, whichever way.
    public static func dismissLdaV2Notice(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: ldaV2NoticeDismissedKey)
    }

    /// Whether offline mode is on.
    ///
    /// A managed preference (an MDM-deployed value, which UserDefaults reports
    /// as forced) wins over the user's own choice and cannot be turned off in
    /// the app. That is the point: IT sets it, the user cannot quietly undo it.
    public static func isOfflineMode(defaults: UserDefaults = .standard) -> Bool {
        if let forced = managedOfflineMode(defaults: defaults) { return forced }
        return defaults.bool(forKey: offlineModeKey)
    }

    /// The MDM-forced value, when one is deployed.
    public static func managedOfflineMode(defaults: UserDefaults = .standard) -> Bool? {
        guard !defaults.objectIsForced(forKey: offlineModeKey) else {
            return defaults.bool(forKey: offlineModeKey)
        }
        return nil
    }

    /// Whether a tier can be downloaded on this Mac.
    ///
    /// Every affordance that could start a download must read this one property.
    /// This codebase has a history of multi-entry actions where one path was
    /// gated and another was not.
    public static func canDownload(
        _ tier: ModelTier,
        installedGB: Double = MemoryGate.installedGB(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if isOfflineMode(defaults: defaults) { return false }
        if ModelCatalog.isBundled(tier) { return false }
        if ModelCatalog.isInstalled(tier, fileManager: fileManager) { return false }
        // Apple silicon memory is soldered, so a blocked tier is blocked for the
        // life of the machine and the ladder would refuse to select the file
        // even after it arrived.
        return MemoryGate.availability(for: tier, installedGB: installedGB).isSelectable
    }

    /// The highest rung this Mac can actually run right now.
    ///
    /// Shared by three callers so they cannot drift: launch fallback, recovery
    /// when a selected model's file has gone, and demotion after a removal.
    ///
    /// `notAbove` bounds the result for the removal case. Removing Balanced
    /// while Most thorough is also installed must demote to Quick, not promote
    /// the user to something they did not choose.
    public static func bestAvailableLevel(
        catalog: ModelCatalog = .load(),
        installedGB: Double = MemoryGate.installedGB(),
        fileManager: FileManager = .default,
        notAbove: DetectionLevel? = nil
    ) -> DetectionLevel {
        let order: [DetectionLevel] = [.mostThorough, .balanced, .quick]
        // Fail CLOSED when the bound is not a model rung. notAbove: .patternsOnly
        // means "nothing above patterns only", which is patterns only. Treating
        // an unknown bound as no bound at all would silently PROMOTE the user,
        // and this function is shared by launch, recovery and removal.
        if let notAbove, !order.contains(notAbove) { return .patternsOnly }
        let ceiling = notAbove.flatMap { order.firstIndex(of: $0) }
        for (index, level) in order.enumerated() {
            if let ceiling, index <= ceiling { continue }
            guard let tier = catalog.tier(for: level) else { continue }
            let present = ModelCatalog.isInstalled(tier, fileManager: fileManager)
                || ModelCatalog.isBundled(tier)
            guard present,
                  MemoryGate.availability(for: tier, installedGB: installedGB).isSelectable
            else { continue }
            return level
        }
        // Nothing runnable. Patterns only is the honest destination, and the
        // caller must say so rather than leaving a rung selected that cannot run.
        return .patternsOnly
    }

    // MARK: Model path resolution

    /// The model path detection should use for the selected rung.
    ///
    /// Every tier is downloaded into the app container or added there by the
    /// verified offline import. A tier with no file resolves to nil, and the
    /// caller reports that rather than substituting a different model.
    ///
    /// Resolution order:
    ///   1. Patterns only: no model at all.
    ///   2. A custom model, when one is set and readable, wins over every tier.
    ///      That is the escape hatch for a firm's own fine tune.
    ///   3. The tier's file in the app container, when downloaded.
    ///   4. The tier's file inside the app bundle. Only a BUNDLE_MODEL=1 build
    ///      ships one that way, so this is a last resort and not a guarantee
    ///      that any model is present.
    ///   5. Otherwise nil, which the caller MUST report as a requested-but-
    ///      unavailable AI pass rather than silently running patterns only.
    ///
    /// A tier NEVER falls back to a different tier's model: running Quick while
    /// the user believes Most thorough is active would misrepresent the
    /// redaction.
    public static func resolveModelPath(
        defaults: UserDefaults = .standard,
        catalog: ModelCatalog = .load(),
        fileManager: FileManager = .default
    ) -> String? {
        let level = detectionLevel(defaults: defaults, catalog: catalog)
        guard level.usesLLM else { return nil }

        if let custom = customModelPath(defaults: defaults) { return custom }

        guard let tier = catalog.tier(for: level) else { return nil }

        if ModelCatalog.isInstalled(tier, fileManager: fileManager),
           let url = ModelCatalog.installedURL(for: tier, fileManager: fileManager) {
            return url.path
        }

        return ModelCatalog.bundledPath(for: tier)
    }

    /// Whether the selected rung wants a model but has none available. The UI
    /// must distinguish this from a deliberate patterns-only run: they produce
    /// the same detection result and the user needs to know which happened.
    public static func isModelMissing(
        defaults: UserDefaults = .standard,
        catalog: ModelCatalog = .load(),
        fileManager: FileManager = .default
    ) -> Bool {
        let level = detectionLevel(defaults: defaults, catalog: catalog)
        guard level.usesLLM else { return false }
        return resolveModelPath(
            defaults: defaults, catalog: catalog, fileManager: fileManager
        ) == nil
    }

    /// Whether ANY model is present on this Mac: a tier installed in the app
    /// container, a tier inside the app bundle, or a resolvable custom model.
    ///
    /// A different question from `isModelMissing()`, and the two must not be
    /// conflated. `isModelMissing()` is about the SELECTED rung and is false for
    /// a deliberate patterns-only user, who has made a legitimate choice and
    /// must not be nagged mid-workflow. This is about the MACHINE, and it stays
    /// false for that same patterns-only user when they have no file at all,
    /// which is exactly who first-run setup needs to reach.
    public static func hasAnyModelAvailable(
        catalog: ModelCatalog = .load(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if customModelPath(defaults: defaults) != nil { return true }
        return catalog.tiers.contains {
            ModelCatalog.isInstalled($0, fileManager: fileManager)
                || ModelCatalog.isBundled($0)
        }
    }

    // MARK: First-run model ask

    /// The recorded answer to the first-run model ask, or nil when the user
    /// has not been asked yet.
    public static func modelSetupAnswer(
        defaults: UserDefaults = .standard
    ) -> ModelSetupAnswer? {
        guard let raw = defaults.string(forKey: modelSetupAnswerKey) else { return nil }
        return ModelSetupAnswer(rawValue: raw)
    }

    /// Record the answer, on the click rather than on a dismissal.
    ///
    /// Writes ONLY this key. Recording a decline as
    /// `detectionLevel = .patternsOnly` would be the obvious shortcut and it is
    /// wrong: `isModelMissing()` short-circuits on `usesLLM`, so it would
    /// silence the red advisory for the one user who most needs it, and
    /// `attempted == false` is reserved for "the user did not ask".
    public static func recordModelSetupAnswer(
        _ answer: ModelSetupAnswer,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(answer.rawValue, forKey: modelSetupAnswerKey)
    }

    /// Whether ANY tier could run on this Mac, ignoring what is installed.
    ///
    /// Memory only: offline mode blocks the download but NOT the verified
    /// import, so it must not make this false. Apple silicon memory is
    /// soldered, so a false here is permanent for this machine.
    public static func canRunAnyModel(
        catalog: ModelCatalog = .load(),
        installedGB: Double = MemoryGate.installedGB()
    ) -> Bool {
        catalog.tiers.contains {
            MemoryGate.availability(for: $0, installedGB: installedGB).isSelectable
        }
    }

    /// Whether a scan must ask first: this Mac has no model at all, and it
    /// could have one.
    ///
    /// Reads the MACHINE, not the rung, on purpose: `isModelMissing()` is false
    /// for a deliberate patterns-only user, and that user is exactly the one
    /// who otherwise never learns that names are not looked for. Reading the
    /// machine also means a decline can never decay into permanent silence,
    /// and that removing the last model re-arms the gate with no bookkeeping.
    public static func scanNeedsModelConfirmation(
        catalog: ModelCatalog = .load(),
        installedGB: Double = MemoryGate.installedGB(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !hasAnyModelAvailable(
            catalog: catalog, fileManager: fileManager, defaults: defaults
        ) else { return false }
        return canRunAnyModel(catalog: catalog, installedGB: installedGB)
    }

    /// Whether the ask should be presented at launch.
    ///
    /// "accepted" is deliberately NOT terminal: a user who pressed Download
    /// and cancelled, or who left the drive at the office, has an unresolved
    /// ask and is asked once more. Only "declined" is honoured forever, and
    /// "unavailable" is already covered by canRunAnyModel.
    public static func shouldPresentModelAsk(
        catalog: ModelCatalog = .load(),
        installedGB: Double = MemoryGate.installedGB(),
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard scanNeedsModelConfirmation(
            catalog: catalog, installedGB: installedGB,
            fileManager: fileManager, defaults: defaults
        ) else { return false }
        switch modelSetupAnswer(defaults: defaults) {
        case .declined, .unavailable: return false
        case .accepted, nil: return true
        }
    }

    /// Apply the current settings to the Fill window's model.
    ///
    /// From feat/lda-macos-core: the fill flow runs the same local model, so it
    /// has to follow the same setting. FillModel has no useLLM of its own, so
    /// only the path is synced.
    @MainActor
    public static func apply(
        to model: FillModel,
        defaults: UserDefaults = .standard
    ) {
        model.modelPath = resolveModelPath(defaults: defaults)
    }

    /// Apply the current settings to one document model.
    @MainActor
    public static func apply(
        to model: ReviewModel,
        defaults: UserDefaults = .standard
    ) {
        let catalog = ModelCatalog.load()
        let level = detectionLevel(defaults: defaults, catalog: catalog)
        model.modelPath = resolveModelPath(defaults: defaults, catalog: catalog)
        // A rung that wants a model it cannot find must not silently run as
        // patterns only: useLLM stays true so the engine reports the failure.
        model.useLLM = level.usesLLM
    }
}
