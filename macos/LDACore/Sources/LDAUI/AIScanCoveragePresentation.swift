//
//  AIScanCoveragePresentation.swift
//  LDAUI
//
//  What the review summary says about the AI pass of the result on screen:
//  which headline it carries, and where the values the pass found but could
//  not remove are still written, so they can be protected in exactly those
//  places.
//
//  Kept out of AppShellStatusBanner so every choice is a pure function the
//  tests can pin for each state, in each language the app ships.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

// MARK: - Headline

/// The headline of the review summary when the AI pass did not run to full
/// coverage. There is none when it did.
///
/// Three states, and they must not read alike. A deliberate patterns-only run
/// is a normal choice and reads as information. An AI pass that was asked for
/// and never ran looked for no names at all. An AI pass that ran and stopped
/// short, or reported values it could not anchor, found some names and left
/// others in place, so its review list reads as finished when it is not.
/// Titling that third state "AI did not run" is false, and it sends the user
/// to look for a model problem instead of the values still in the document.
/// See docs/design/model-tiers-prd.md section 7.
enum AIScanHeadline: Equatable, CaseIterable {
    case patternsOnly
    case didNotRun
    case ranPartially

    /// The headline for a scan result, or nil when the pass ran to full
    /// coverage.
    ///
    /// Read off the classification a saved workspace records
    /// (AIScanCoverage.workspaceRecord), which mirrors the Export for AI gate
    /// (ModelSetupPresentation.exportGateReason). One decision, so the banner,
    /// the gate and a reopened workspace cannot describe one pass differently,
    /// and a new coverage state cannot reach the banner without a headline.
    init?(_ coverage: AIScanCoverage) {
        switch coverage.workspaceRecord {
        case .complete:
            return nil
        case .notRequested:
            self = .patternsOnly
        case .didNotRun:
            self = .didNotRun
        case .ranPartially:
            self = .ranPartially
        }
    }

    /// The catalog key of the headline.
    var titleKey: String {
        switch self {
        case .patternsOnly: return "Patterns only"
        case .didNotRun: return "AI did not run"
        case .ranPartially: return "AI scan incomplete"
        }
    }

    /// True for the two states the user did not choose. Both render in the
    /// red warning style with the warning sentence as their tooltip; patterns
    /// only renders as quiet information.
    var isWarning: Bool { self != .patternsOnly }

    /// The SF Symbol shown before the title.
    var systemImage: String {
        isWarning ? "exclamationmark.triangle.fill" : "info.circle"
    }
}

// MARK: - Values the pass could not remove

/// Where one value the AI pass could not anchor is still written in the
/// document.
///
/// Worked out once, when the scan's list is set: the text does not change
/// while it is reviewed, so the list never searches the document again.
struct UnlocatedValuePlacement: Equatable {
    /// The value as the pass reported it, with the type it was reported as.
    let value: ExtractedEntity
    /// Every place the value is written with a letter or digit run into it,
    /// the shape the locator refuses: a footnote marker ("Jordan Lee2"), a
    /// space lost from a PDF text layer ("byJordan Lee"), either of them with
    /// a line break inside the name. See EntityLocator.runInOccurrences.
    /// These are the places Protect redacts, and the only ones: a value is
    /// never redacted inside an ordinary word.
    let runIns: [NSRange]
    /// True when there is no such place but the text holds the value, case
    /// aside, inside longer words ("Lee" in "Leeds"). Nothing there is
    /// redacted automatically.
    let onlyInsideWords: Bool

    /// Where `value` is written in `text`.
    static func of(_ value: ExtractedEntity, in text: String) -> UnlocatedValuePlacement {
        let runIns = EntityLocator.runInOccurrences(forValue: value.value, in: text)
        guard runIns.isEmpty else {
            return UnlocatedValuePlacement(value: value, runIns: runIns, onlyInsideWords: false)
        }
        let needle = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let insideWords = !needle.isEmpty
            && (text as NSString).range(of: needle, options: [.caseInsensitive]).location != NSNotFound
        return UnlocatedValuePlacement(value: value, runIns: [], onlyInsideWords: insideWords)
    }
}

/// Whether one listed value is still exposed, judged against the review list
/// as it stands now.
enum UnlocatedValueProtection: Equatable {
    /// Some of its run-in places are not covered; `remaining` counts them.
    case exposed(remaining: Int)
    /// Every run-in place lies inside an entity that will be redacted.
    case protected
    /// It is written only inside longer words, so there is nothing LDA will
    /// redact on its own. If it is a name there, the user selects it.
    case insideOtherWords
    /// It is not in the document as reported: a GGUF model can report a value
    /// with spacing the text does not have. The user selects it instead.
    case writtenDifferently

    /// The protection state of a placement, given the review list.
    ///
    /// A place counts as covered only when a single accepted entity contains
    /// all of it; a place split across two entities reads as exposed, which
    /// errs toward asking rather than toward claiming protection.
    static func of(
        _ placement: UnlocatedValuePlacement,
        entities: [ReviewEntity]
    ) -> UnlocatedValueProtection {
        guard !placement.runIns.isEmpty else {
            return placement.onlyInsideWords ? .insideOtherWords : .writtenDifferently
        }
        let redacted = entities.filter(\.accepted).map(\.span)
        let remaining = placement.runIns.filter { range in
            !redacted.contains { $0.start <= range.location && $0.end >= NSMaxRange(range) }
        }.count
        return remaining == 0 ? .protected : .exposed(remaining: remaining)
    }
}

enum AIScanCoveragePresentation {

    /// The label of the control beside the warning that lists the values.
    static func showValuesTitle(count: Int, language: AppLanguage? = nil) -> String {
        L10n.formatted(
            count == 1 ? "Show %lld value" : "Show %lld values",
            language: language,
            [Int64(count)]
        )
    }
}

extension ReviewModel {

    /// The protection state of one listed value. See
    /// UnlocatedValueProtection.of.
    func protection(of placement: UnlocatedValuePlacement) -> UnlocatedValueProtection {
        UnlocatedValueProtection.of(placement, entities: entities)
    }

    /// True when there are listed values and every one of them is protected
    /// at each place it is written run-in. A value written only inside other
    /// words or written differently is not protected by anything LDA did, so
    /// it keeps this false.
    var allUnlocatedValuesProtected: Bool {
        !aiUnlocatedPlacements.isEmpty
            && aiUnlocatedPlacements.allSatisfy { protection(of: $0) == .protected }
    }

    /// The listed values the user has protected at every run-in place in the
    /// body. A .docx export redacts them where they are run-in in headers,
    /// footers, notes and comments too: the body's review never saw those
    /// parts, and their own scan refuses the same edges again.
    var protectedUnlocatedValues: [ExtractedEntity] {
        aiUnlocatedPlacements
            .filter { protection(of: $0) == .protected }
            .map(\.value)
    }
}
