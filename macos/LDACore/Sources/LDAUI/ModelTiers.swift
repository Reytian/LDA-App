//
//  ModelTiers.swift
//  LDAUI
//
//  The model ladder: one user-facing control that answers "how hard should LDA
//  look for the entity types patterns cannot catch". See
//  docs/design/model-tiers-prd.md.
//
//  Three pieces live here:
//    1. DetectionLevel, the four-rung ladder that replaces DetectionMode as the
//       user-facing setting. DetectionMode survives only as a derived value so
//       ReviewModel.useLLM and its call sites keep working unchanged.
//    2. ModelCatalog, which loads the bundled Models.json manifest describing
//       each tier: file name, byte count, digest, measured peak RSS, and the
//       GGUF header fields used to identify a user-supplied file.
//    3. MemoryGate, which decides whether a tier is runnable on this Mac given
//       a normal office working set, so the app never offers a rung that would
//       thrash the machine.
//
//  Peak RSS figures in the manifest come from the benchmark harness
//  (llama-server -c 12288 -np 1). Production LLMEngine.Config uses a smaller KV
//  pool and measured lower on every tier, so gating on the harness numbers is
//  conservative in the safe direction. See Appendix M of the PRD.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import SwiftUI

// MARK: - DetectionLevel

/// How hard the app looks for PERSON, COMPANY, and ADDRESS, which are the types
/// no regex layer covers. One ladder, four rungs, lowest first.
///
/// This replaces `DetectionMode` as the user-facing setting. The old two-value
/// mode is still derived from this (see `usesLLM`) so nothing downstream of
/// `ReviewModel.useLLM` has to change.
public enum DetectionLevel: String, CaseIterable, Sendable {
    /// Patterns only. No model runs at all.
    case patternsOnly
    /// Qwen3.5-4B. Bundled with the app.
    case quick
    /// gemma-4-12b-it. User installed.
    case balanced
    /// Qwen3.8-27B Q3_K_XL. User installed.
    case mostThorough

    /// The user-facing name. Deliberately avoids "Fast" and "Thorough", which
    /// already mean something different in shipped copy for `DetectionMode`.
    public var displayName: String {
        switch self {
        case .patternsOnly: return "Patterns only"
        case .quick: return "Quick"
        case .balanced: return "Balanced"
        case .mostThorough: return "Most thorough"
        }
    }

    public var localizedDisplayName: LocalizedStringKey {
        LocalizedStringKey(displayName)
    }

    /// One line under the name in the picker.
    public var summary: String {
        switch self {
        case .patternsOnly:
            return "Instant. Finds emails, phones, dates, amounts, and ID numbers "
                + "only. Names, companies, and addresses are not detected."
        case .quick:
            return "Smallest download. Finds nearly every name, company, and "
                + "address, and is the fastest option that does."
        case .balanced:
            return "Catches the most overall, at about twice the wait."
        case .mostThorough:
            return "Missed nothing in testing. Slowest by a wide margin."
        }
    }

    public var localizedSummary: LocalizedStringKey {
        LocalizedStringKey(summary)
    }

    /// Whether this rung runs the on-device model. The derived replacement for
    /// the old `DetectionMode` distinction.
    public var usesLLM: Bool { self != .patternsOnly }

    /// The manifest tier id backing this rung, or nil when no model runs.
    public var tierID: String? {
        switch self {
        case .patternsOnly: return nil
        case .quick: return "quick"
        case .balanced: return "balanced"
        case .mostThorough: return "most-thorough"
        }
    }

    /// The rungs that run a model, in ladder order.
    public static var modelLevels: [DetectionLevel] { [.quick, .balanced, .mostThorough] }
}

// MARK: - ModelTier

/// One entry in the shipped `Models.json` manifest.
///
/// `sizeBytes` and `sha256` identify a user-supplied file exactly. The `arch`
/// fields identify the model family even when the quantisation differs, which
/// is what separates a legitimate different build from an unrelated model that
/// happens to be the right size.
public struct ModelTier: Codable, Equatable, Sendable {
    public let id: String
    public let level: String
    public let displayName: String
    public let fileName: String
    public let sizeBytes: Int64
    public let sha256: String
    /// Measured peak resident memory, in GB, under the benchmark harness.
    public let peakRSSGB: Double
    /// Rough seconds for one full agreement, for the picker's time estimate.
    public let secondsPerDocument: Int
    /// GGUF `general.architecture`, for family identification.
    public let architecture: String
    /// GGUF `<arch>.block_count`, which separates sizes within a family.
    public let blockCount: Int
    /// GGUF `<arch>.embedding_length`.
    public let embeddingLength: Int
    /// Where this file is downloaded from. Model Management fetches it from
    /// here when the user starts a download, and it is also shown as selectable
    /// text so a user who prefers to fetch it themselves can. This is the ONLY
    /// host the app ever contacts.
    public let sourceURL: String

    public var detectionLevel: DetectionLevel? { DetectionLevel(rawValue: level) }

    /// Human-readable download size, for the install sheet.
    public var downloadSizeDescription: String {
        String(format: "%.2f GB", Double(sizeBytes) / 1_000_000_000)
    }
}

// MARK: - ModelCatalog

/// Loads and queries the bundled tier manifest.
public struct ModelCatalog: Sendable {

    public let tiers: [ModelTier]

    public init(tiers: [ModelTier]) {
        self.tiers = tiers
    }

    /// Load `Models.json`. Returns an empty catalog when the resource is
    /// absent or unreadable, which degrades to "Quick only, no install offers"
    /// rather than crashing.
    ///
    /// Looks in the SwiftPM resource bundle first (`Bundle.module`, where
    /// `resources: [.process("Resources")]` puts it) and then in the host app
    /// bundle, so a packaged LDA.app that copies the manifest to its own
    /// Resources directory also resolves.
    public static func load(from bundle: Bundle? = nil) -> ModelCatalog {
        for candidate in searchBundles(explicit: bundle) {
            guard let url = candidate.url(forResource: "Models", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let tiers = try? JSONDecoder().decode([ModelTier].self, from: data) else {
                continue
            }
            return ModelCatalog(tiers: tiers)
        }
        return ModelCatalog(tiers: [])
    }

    /// Bundles to search, in order, WITHOUT touching `Bundle.module`.
    ///
    /// SwiftPM's generated `Bundle.module` accessor calls `Swift.fatalError`
    /// when the resource bundle is absent, and it looks only in
    /// `Bundle.main.bundleURL` and a compile-time scratch path that does not
    /// exist on a user's machine. Referencing it at all makes a packaged app
    /// that is missing the bundle crash on launch rather than degrade. We
    /// therefore locate the same bundle by hand and fall back to the host app.
    private static func searchBundles(explicit: Bundle?) -> [Bundle] {
        if let explicit { return [explicit] }
        var found: [Bundle] = []
        let name = "LDACore_LDAUI.bundle"
        // Where the packaged app puts it. codesign rejects loose files at the
        // .app root ("unsealed contents present in the bundle root"), so the
        // manifest cannot live where the generated Bundle.module accessor
        // looks; package-app.sh copies it here instead.
        if let res = Bundle.main.resourceURL,
           let b = Bundle(path: res.appendingPathComponent(name).path) {
            found.append(b)
        }
        // The location the generated accessor prefers, kept for unpackaged dev
        // layouts that do sit next to the executable.
        if let b = Bundle(path: Bundle.main.bundleURL.appendingPathComponent(name).path) {
            found.append(b)
        }
        // Alongside the code bundle. This is where SwiftPM puts it for unit
        // tests: the resource bundle sits next to the .xctest binary, which is
        // neither Bundle.main (the xctest runner) nor the code bundle itself.
        let codeBundle = Bundle(for: BundleToken.self)
        let sibling = codeBundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        if let b = Bundle(path: sibling.path) { found.append(b) }
        // Any host that copies Models.json in directly.
        found.append(codeBundle)
        found.append(Bundle.main)
        return found
    }

    public func tier(for level: DetectionLevel) -> ModelTier? {
        guard let id = level.tierID else { return nil }
        return tiers.first { $0.id == id }
    }

    public func tier(id: String) -> ModelTier? {
        tiers.first { $0.id == id }
    }

    // MARK: Installed model locations

    /// Root of the app-owned model store:
    /// `Application Support/LDA/Models`. Inside the sandbox this lives in the
    /// app container, which the app can always read without a security-scoped
    /// bookmark, across relaunches and reboots. That is the whole reason tier
    /// models are copied in rather than referenced where the user left them.
    public static func modelsRoot(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return support.appendingPathComponent("LDA/Models", isDirectory: true)
    }

    /// Where a given tier's file lives once installed.
    public static func installedURL(
        for tier: ModelTier,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let root = modelsRoot(fileManager: fileManager) else { return nil }
        return root
            .appendingPathComponent(tier.id, isDirectory: true)
            .appendingPathComponent(tier.fileName)
    }

    /// The tier's file inside the app bundle, when it ships there.
    ///
    /// Only Quick is bundled: it is the one tier that runs on the 16 GB minimum
    /// spec, so bundling it means an offline user always has a model that works
    /// on their machine. A bundled file cannot be deleted by the user, which
    /// Model Management must reflect.
    public static func bundledPath(for tier: ModelTier) -> String? {
        let stem = (tier.fileName as NSString).deletingPathExtension
        return Bundle.main.path(forResource: stem, ofType: "gguf")
    }

    /// Whether this tier ships inside the app rather than being downloaded.
    public static func isBundled(_ tier: ModelTier) -> Bool {
        bundledPath(for: tier) != nil
    }

    /// A downloaded copy of a tier that ALSO ships inside the app.
    ///
    /// An earlier build shipped no model and downloaded Quick into the
    /// container. A user who upgrades from it has Quick in both places, wasting
    /// 2.74 GB, with the container copy shadowing the bundled one. Returns the
    /// redundant container file so the UI can offer to reclaim it.
    public static func redundantContainerCopy(
        for tier: ModelTier,
        fileManager: FileManager = .default
    ) -> URL? {
        guard isBundled(tier),
              let url = installedURL(for: tier, fileManager: fileManager),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Whether the tier's file is present and the expected size. Size is the
    /// cheap first identity layer: it catches a truncated download instantly.
    public static func isInstalled(
        _ tier: ModelTier,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let url = installedURL(for: tier, fileManager: fileManager),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return false
        }
        return Int64(size) == tier.sizeBytes
    }
}

// MARK: - MemoryGate

/// Whether a tier can run on this Mac alongside the user's other applications.
public enum TierAvailability: Equatable, Sendable {
    /// Comfortably within budget.
    case available
    /// Within budget, but with under 1 GB to spare.
    case tight
    /// Over budget. The rung is shown disabled with the reason, never hidden.
    case insufficientMemory(needsGB: Double, budgetGB: Double)

    public var isSelectable: Bool {
        if case .insufficientMemory = self { return false }
        return true
    }
}

/// The memory budget model.
///
/// Budgets assume a normal office working set resident (macOS, a word
/// processor, a browser, a messaging app, and an AI assistant), measured at
/// roughly 9 GB on the benchmark machine. They deliberately gate on INSTALLED
/// memory rather than free memory: free memory swings minute to minute, and a
/// picker whose options appear and disappear as the user quits Chrome would be
/// worse than one that is merely conservative.
public enum MemoryGate {

    /// Physical memory in GB.
    public static func installedGB(
        processInfo: ProcessInfo = .processInfo
    ) -> Double {
        Double(processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Anchor points, measured. Reserve grows with machine size because larger
    /// machines run larger working sets: 9.5 GB at 16, 10 at 24, 11 at 32.
    private static let anchors: [(installed: Double, budget: Double)] = [
        (8.0, 0.0), (16.0, 6.5), (24.0, 14.0), (32.0, 21.0)
    ]

    /// How much a model may use on a machine with the given installed memory.
    ///
    /// Interpolates between the anchors rather than bracketing them. Bracketing
    /// gave every machine in (16, 24] the full 24 GB budget, so an 18 GB Mac (a
    /// shipping M3/M4 Pro configuration) was offered a 13.83 GB model with only
    /// about 9 GB genuinely free. Interpolation gives 18 GB a 8.4 GB budget,
    /// which correctly blocks everything above Quick.
    public static func budgetGB(installedGB: Double) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if installedGB <= first.installed { return first.budget }
        for (lo, hi) in zip(anchors, anchors.dropFirst()) where installedGB <= hi.installed {
            let t = (installedGB - lo.installed) / (hi.installed - lo.installed)
            return lo.budget + t * (hi.budget - lo.budget)
        }
        return installedGB - (last.installed - last.budget)
    }

    /// Verdict for one tier on this machine.
    public static func availability(
        for tier: ModelTier,
        installedGB: Double
    ) -> TierAvailability {
        let budget = budgetGB(installedGB: installedGB)
        guard tier.peakRSSGB <= budget else {
            return .insufficientMemory(needsGB: tier.peakRSSGB, budgetGB: budget)
        }
        return (budget - tier.peakRSSGB) < 1.0 ? .tight : .available
    }

    /// The sentence shown under a disabled rung. States the requirement in
    /// terms the user can act on, which is installed RAM, not our budget, and
    /// then states what this Mac actually has so the gap is explicit.
    public static func requirementText(
        for tier: ModelTier,
        installedGB: Double = MemoryGate.installedGB()
    ) -> String {
        // Smallest installed size whose budget clears this tier.
        let have = " This Mac has \(Int(installedGB.rounded())) GB."
        for candidate in [16.0, 24.0, 32.0, 48.0, 64.0, 96.0, 128.0]
        where tier.peakRSSGB <= budgetGB(installedGB: candidate) {
            return "Needs \(Int(candidate)) GB of memory." + have
        }
        return "Needs more memory than this Mac has." + have
    }

    public static func localizedRequirementText(
        for tier: ModelTier,
        installedGB: Double = MemoryGate.installedGB(),
        language: AppLanguage? = nil
    ) -> String {
        let installed = Int(installedGB.rounded())
        let selectedLanguage = language ?? AppLanguage.selected()
        for candidate in [16.0, 24.0, 32.0, 48.0, 64.0, 96.0, 128.0]
        where tier.peakRSSGB <= budgetGB(installedGB: candidate) {
            return String(
                format: L10n.string(
                    "Needs %lld GB of memory. This Mac has %lld GB.",
                    language: language
                ),
                locale: selectedLanguage.locale,
                Int64(candidate),
                Int64(installed)
            )
        }
        return String(
            format: L10n.string(
                "Needs more memory than this Mac has. This Mac has %lld GB.",
                language: language
            ),
            locale: selectedLanguage.locale,
            Int64(installed)
        )
    }
}

/// Anchor for locating this module's resource bundle without going through
/// `Bundle.module`, whose generated accessor calls `fatalError` when absent.
private final class BundleToken {}
