//
//  DominantEntityType.swift
//  LDACore
//
//  Names the entity kind of a short standalone value by running the
//  deterministic engine over that value alone and asking whether ONE detection
//  covers essentially all of it.
//
//  Two callers share the rule, which is why it lives here rather than in
//  either of them:
//   - SpanSplitter, when a break-crossing span is cut into run-local parts and
//     each part needs its own type instead of the parent's.
//   - ManualTypeGuess in LDAUI, when a hand-made selection needs a preselected
//     kind in the Protect chooser.
//
//  The coverage floor is what keeps the answer honest: a value is named only
//  when a detection accounts for nearly the whole of it, so an ID buried in a
//  longer string never names the string. Below the floor the caller keeps
//  whatever type it already had, which is always the conservative direction:
//  the value stays redacted, just under its previous label.
//
//  PERSON and COMPANY are LLM territory and are never returned here; a part
//  that is a name simply finds no detection and keeps its parent type.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// The deterministic entity type that names a whole value, when there is one.
public enum DominantEntityType {

    /// The share of the value one detection must cover to name it.
    public static let coverageFloor: Double = 0.9

    /// The type of the single deterministic detection that covers at least
    /// `coverageFloor` of `value`, or nil when no detection reaches the floor.
    ///
    /// - Parameters:
    ///   - value: the standalone value to name. Offsets are UTF-16 code units,
    ///     the convention every Span uses.
    ///   - engine: the detector to run. Callers that name many values in a row
    ///     pass one engine so the detector is not rebuilt per value.
    public static func of(
        _ value: String,
        engine: DeterministicEngine = DeterministicEngine()
    ) -> EntityType? {
        let total = (value as NSString).length
        guard total > 0 else { return nil }
        guard let widest = engine.detect(value).max(by: ranksBelow) else { return nil }
        let coverage = Double(widest.end - widest.start) / Double(total)
        return coverage >= coverageFloor ? widest.type : nil
    }

    /// Total, stable ordering whose maximum is the widest detection, then the
    /// highest priority, then the earliest. Detectors run in a fixed order but
    /// ranking explicitly keeps the answer independent of that order.
    private static func ranksBelow(_ lhs: Span, _ rhs: Span) -> Bool {
        let lhsLength = lhs.end - lhs.start
        let rhsLength = rhs.end - rhs.start
        if lhsLength != rhsLength { return lhsLength < rhsLength }
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.start > rhs.start
    }
}
