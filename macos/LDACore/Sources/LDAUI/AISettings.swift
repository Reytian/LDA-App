//
//  AISettings.swift
//  LDAUI
//
//  The user-facing AI settings (R3 swappable model, R14 quality/speed): a
//  custom local GGUF model path (empty means the bundled tuned default) and
//  the detection mode (thorough = patterns + on-device AI; fast = patterns
//  only). Stored in UserDefaults and applied to every document model.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// The quality/speed tradeoff for detection (R14).
public enum DetectionMode: String, CaseIterable {
    /// Patterns plus the on-device AI model. Finds people, companies, and
    /// addresses; slower.
    case thorough
    /// Patterns only. Instant, but names, companies, and addresses that do
    /// not match a pattern are missed.
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

    /// UserDefaults key for the custom GGUF model path ("" = bundled default).
    public static let customModelPathKey = "com.haotianyi.LDA.customModelPath"

    /// UserDefaults key for the detection mode raw value.
    public static let detectionModeKey = "com.haotianyi.LDA.detectionMode"

    /// The user's custom model path, when set and present on disk.
    public static func customModelPath(defaults: UserDefaults = .standard) -> String? {
        guard let path = defaults.string(forKey: customModelPathKey),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    /// The stored detection mode; thorough when unset.
    public static func detectionMode(defaults: UserDefaults = .standard) -> DetectionMode {
        guard let raw = defaults.string(forKey: detectionModeKey),
              let mode = DetectionMode(rawValue: raw) else {
            return .thorough
        }
        return mode
    }

    /// The model path detection should use: the custom model when valid,
    /// otherwise the bundled default.
    public static func resolveModelPath(
        bundledDefault: String?,
        defaults: UserDefaults = .standard
    ) -> String? {
        customModelPath(defaults: defaults) ?? bundledDefault
    }

    /// Apply the current settings to one document model.
    @MainActor
    public static func apply(
        to model: ReviewModel,
        bundledDefault: String?,
        defaults: UserDefaults = .standard
    ) {
        model.modelPath = resolveModelPath(bundledDefault: bundledDefault, defaults: defaults)
        model.useLLM = detectionMode(defaults: defaults) == .thorough
    }
}
