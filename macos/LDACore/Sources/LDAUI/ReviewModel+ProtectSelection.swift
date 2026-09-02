//
//  ReviewModel+ProtectSelection.swift
//  LDAUI
//
//  "Select text in the document, then Protect as <kind>": the model half of
//  the scan-phase feature. The pane reports the NSTextView selection (UTF-16,
//  identical to Span offsets) into selectedTextRange; every entry point
//  (context menu, Review menu, footer button) reads canProtectSelection; and
//  protectSelection applies the rules below, returning a ProtectOutcome the
//  notice and the tests read.
//
//  Rules:
//  1. Trim whitespace, then surrounding punctuation from a fixed set. Periods
//     are kept ("Inc." keeps its dot). The trimmed value is what every notice
//     quotes, so the user sees exactly what was protected.
//  2. Empty after trimming: refused silently (the entry points are disabled).
//     A newline inside the selection: refused with "Select text within one
//     paragraph." A role label (甲方, Party A): blocked with a Protect Anyway
//     override, because role labels are kept visible by design.
//  3. Retype path: the value already exists as an entity. Every occurrence
//     takes the chosen kind, becomes accepted, and is marked manual; no
//     identities change. Any literal occurrence the scan missed is added too,
//     since more redaction is the safe direction.
//  4. Overlap policy for every literal occurrence: no overlap adds a manual
//     span; a partial overlap removes the overlapped findings and adds the
//     manual span (the user's hand wins, this is the "model caught half the
//     company name" case); a selection strictly inside an ACCEPTED span is
//     skipped (never shrink a protected span, it would leak the remainder);
//     strictly inside a KEPT-VISIBLE span replaces it, because the user is
//     asking for protection.
//  5. Reveal: the new group is selected and the sidebar scrolls to it.
//  6. Undo: one UndoManager action named "Protect as <kind>" restores the
//     exact prior entity list; redo re-applies. Undo removes spans, it does
//     not reject them, so no learned suppression is ever recorded for an
//     undone protection.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

// MARK: - Outcome types

/// What a Protect action did, for the notice text and for tests.
public struct ProtectOutcome: Equatable {
    /// Why nothing was protected, when nothing was.
    public enum Refusal: Equatable {
        /// Nothing selected, out of range, or only punctuation and whitespace.
        case emptySelection
        /// The selection crosses a paragraph break.
        case multipleParagraphs
        /// The value is a contract role label (kept visible by design).
        case roleLabel
        /// Every occurrence sits strictly inside an already protected span.
        case insideProtected(container: String)
    }

    /// The trimmed value the action worked on.
    public let value: String
    /// The kind the user chose.
    public let type: EntityType
    /// On the retype path, the kind the value had before.
    public let previousType: EntityType?
    /// New manual spans added.
    public let added: Int
    /// Earlier findings removed because the selection overlapped them.
    public let replaced: Int
    /// Existing spans of the same value that took the chosen kind.
    public let retyped: Int
    /// Occurrences left alone because they sit inside a protected span.
    public let skippedInsideProtected: Int
    /// nil when something was protected.
    public let refusal: Refusal?

    public init(
        value: String,
        type: EntityType,
        previousType: EntityType?,
        added: Int,
        replaced: Int,
        retyped: Int,
        skippedInsideProtected: Int,
        refusal: Refusal?
    ) {
        self.value = value
        self.type = type
        self.previousType = previousType
        self.added = added
        self.replaced = replaced
        self.retyped = retyped
        self.skippedInsideProtected = skippedInsideProtected
        self.refusal = refusal
    }

    /// True when the entity list changed.
    public var changedAnything: Bool { added + replaced + retyped > 0 }

    /// How many occurrences are protected as the chosen kind after the action.
    public var protectedCount: Int { added + retyped }

    static func refused(_ refusal: Refusal, value: String, type: EntityType, skipped: Int = 0) -> ProtectOutcome {
        ProtectOutcome(
            value: value, type: type, previousType: nil,
            added: 0, replaced: 0, retyped: 0,
            skippedInsideProtected: skipped, refusal: refusal
        )
    }
}

/// The transient row shown after a Protect action.
public struct ProtectNotice: Equatable, Identifiable {
    public let id: UUID
    /// The sentence shown to the user.
    public let message: String
    /// The VoiceOver announcement, present for successful protections.
    public let announcement: String?
    /// The trimmed value the notice is about.
    public let value: String
    /// The kind involved.
    public let type: EntityType
    /// The selection the action ran on, so Protect Anyway can re-run it.
    public let range: NSRange?
    /// True when the notice describes a reversible change.
    public let canUndo: Bool
    /// True when the chooser can be reopened on the same value (retype path).
    public let canChangeKind: Bool
    /// True for the role-label block, which offers an override.
    public let offersProtectAnyway: Bool
    /// The entity identities right after the action; the pane dismisses the
    /// notice when the list changes again.
    public let entityIDs: Set<ReviewEntity.ID>
}

/// What the kind chooser should offer for a value, given what already exists.
public enum ProtectVariant: Equatable {
    /// The value is new; `occurrences` literal matches would be protected.
    case protect(occurrences: Int)
    /// The value is already protected; the chooser changes its kind.
    case changeKind(current: EntityType)
    /// The value exists but is kept visible; the chooser re-accepts it.
    case protectAgain(current: EntityType)
}

// MARK: - Rules

enum ProtectSelectionRules {
    /// Punctuation stripped from both ends of a selection. Periods are absent
    /// on purpose so "Inc." keeps its dot.
    static let strippablePunctuation: Set<Character> = Set(
        "，。；：、！？“”‘’「」『』（）()[]【】《》<>\"',;:!?"
    )

    /// Whitespace and newlines, then the punctuation set, then whitespace again.
    static func trim(_ raw: String) -> String {
        var value = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = value.first, strippablePunctuation.contains(first) {
            value.removeFirst()
        }
        while let last = value.last, strippablePunctuation.contains(last) {
            value.removeLast()
        }
        return String(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a trimmed value still contains a paragraph break.
    static func spansMultipleParagraphs(_ value: String) -> Bool {
        value.contains(where: \.isNewline)
    }

    /// Priority above the deterministic maximum so a user decision survives
    /// any later overlap resolution (same value addManualEntity uses).
    static let manualPriority = 110
}

// MARK: - ReviewModel

extension ReviewModel {

    /// The state gate: a document is loaded and the entity list is not being
    /// rebuilt. The context menu reads this one, because a right-click selects
    /// the word under the pointer before the menu is built.
    public var canProtectText: Bool {
        guard !documentText.isEmpty else { return false }
        switch status {
        case .imported, .ready:
            return true
        case .idle, .importing, .detecting, .failed:
            return false
        }
    }

    /// The one gate every Protect Selection entry point reads: Original mode
    /// is shown, a non-empty selection exists inside the text, and the entity
    /// list is not being rebuilt.
    public var canProtectSelection: Bool {
        guard canProtectText, previewMode == .original else { return false }
        guard let range = selectedTextRange, range.length > 0,
              range.location >= 0,
              NSMaxRange(range) <= (documentText as NSString).length else {
            return false
        }
        return true
    }

    /// The raw selected substring, or nil when the selection is empty or stale.
    public var selectedText: String? {
        guard let range = selectedTextRange, range.length > 0 else { return nil }
        let nsText = documentText as NSString
        guard range.location >= 0, NSMaxRange(range) <= nsText.length else { return nil }
        return nsText.substring(with: range)
    }

    /// Ask the pane to open the kind chooser on the current selection. Used by
    /// the Review menu command (Cmd+Shift+P).
    public func requestProtectSelection() {
        guard canProtectSelection else { return }
        protectSelectionRequestToken += 1
    }

    /// How often a value occurs literally in the document (non-overlapping).
    public func occurrenceCount(of value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        return literalRanges(of: value).count
    }

    /// What the chooser should offer for a value.
    public func protectVariant(for value: String) -> ProtectVariant {
        let matching = entities.filter { $0.span.text == value }
        guard let first = matching.first else {
            return .protect(occurrences: occurrenceCount(of: value))
        }
        return matching.contains(where: \.accepted)
            ? .changeKind(current: first.span.type)
            : .protectAgain(current: first.span.type)
    }

    /// Protect the selected text as `type`. See the file header for the rules.
    @discardableResult
    public func protectSelection(
        range: NSRange,
        type: EntityType,
        undoManager: UndoManager?,
        allowRoleLabel: Bool = false
    ) -> ProtectOutcome {
        let nsText = documentText as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              NSMaxRange(range) <= nsText.length else {
            return .refused(.emptySelection, value: "", type: type)
        }
        let value = ProtectSelectionRules.trim(nsText.substring(with: range))
        guard !value.isEmpty else {
            return .refused(.emptySelection, value: "", type: type)
        }
        if ProtectSelectionRules.spansMultipleParagraphs(value) {
            let outcome = ProtectOutcome.refused(.multipleParagraphs, value: value, type: type)
            postNotice(for: outcome, range: range)
            return outcome
        }
        return protectValue(
            value,
            type: type,
            undoManager: undoManager,
            allowRoleLabel: allowRoleLabel,
            sourceRange: range
        )
    }

    /// Protect every literal occurrence of an already trimmed value as `type`.
    /// The chooser's Change Kind path calls this directly with a known value.
    @discardableResult
    public func protectValue(
        _ value: String,
        type: EntityType,
        undoManager: UndoManager?,
        allowRoleLabel: Bool = false,
        sourceRange: NSRange? = nil
    ) -> ProtectOutcome {
        guard !value.isEmpty, !documentText.isEmpty else {
            return .refused(.emptySelection, value: value, type: type)
        }
        if !allowRoleLabel, RoleLabels.isRoleLabel(value) {
            let outcome = ProtectOutcome.refused(.roleLabel, value: value, type: type)
            postNotice(for: outcome, range: sourceRange)
            return outcome
        }

        let before = entities
        var working = entities

        // Retype path: the value is already known. Every occurrence takes the
        // chosen kind, keeps its identity, and becomes a manual decision.
        let matching = working.indices.filter { working[$0].span.text == value }
        let previousType = matching.first.map { working[$0].span.type }
        for index in matching {
            working[index].span.type = type
            working[index].span.source = .manual
            working[index].span.confidence = 1.0
            working[index].span.priority = ProtectSelectionRules.manualPriority
            working[index].accepted = true
        }

        var added = 0
        var replaced = 0
        var skipped = 0
        var container: String?

        for found in literalRanges(of: value) {
            let overlapping = working.filter { Self.overlaps($0.span, found) }
            if overlapping.isEmpty {
                working.append(Self.manualEntity(value: value, type: type, at: found))
                added += 1
                continue
            }
            if overlapping.allSatisfy({ Self.sameRange($0.span, found) }) {
                continue // already covered by the retype path
            }
            if let protected = overlapping.first(where: { $0.accepted && Self.strictlyContains($0.span, found) }) {
                skipped += 1
                container = container ?? protected.span.text
                continue
            }
            // Partial overlap, or strictly inside a kept-visible span: the
            // user's hand wins over the earlier findings.
            let removed = Set(overlapping.map(\.id))
            working.removeAll { removed.contains($0.id) }
            replaced += removed.count
            working.append(Self.manualEntity(value: value, type: type, at: found))
            added += 1
        }

        let outcome: ProtectOutcome
        if added + replaced + matching.count == 0 {
            outcome = skipped > 0
                ? .refused(.insideProtected(container: container ?? value), value: value, type: type, skipped: skipped)
                : .refused(.emptySelection, value: value, type: type)
            if skipped > 0 { postNotice(for: outcome, range: sourceRange) }
            return outcome
        }

        outcome = ProtectOutcome(
            value: value,
            type: type,
            previousType: previousType,
            added: added,
            replaced: replaced,
            retyped: matching.count,
            skippedInsideProtected: skipped,
            refusal: nil
        )
        entities = working
        let groupID = Self.groupID(value: value, type: type)
        selectedGroupIDs = [groupID]
        groupToReveal = groupID
        registerProtectUndo(restoring: before, reapplying: working, type: type, undoManager: undoManager)
        postNotice(for: outcome, range: sourceRange)
        return outcome
    }

    // MARK: - Undo

    /// Register one undoable step that puts the entity list back to
    /// `snapshot`; performing it registers the mirror step so redo re-applies
    /// `reapplying`. Both steps carry the "Protect as <kind>" action name.
    func registerProtectUndo(
        restoring snapshot: [ReviewEntity],
        reapplying: [ReviewEntity],
        type: EntityType,
        undoManager: UndoManager?
    ) {
        guard let undoManager, snapshot != reapplying else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.entities = snapshot
            model.protectNotice = nil
            model.registerProtectUndo(
                restoring: reapplying,
                reapplying: snapshot,
                type: type,
                undoManager: undoManager
            )
        }
        undoManager.setActionName(String(
            format: L10n.string("Protect as %@"),
            EntityTypePresentation.localizedName(for: type) as NSString
        ))
    }

    // MARK: - Notice

    private func postNotice(for outcome: ProtectOutcome, range: NSRange?) {
        let message = ProtectSelectionPresentation.message(for: outcome)
        guard !message.isEmpty else { return }
        protectNotice = ProtectNotice(
            id: UUID(),
            message: message,
            announcement: outcome.refusal == nil
                ? ProtectSelectionPresentation.announcement(for: outcome)
                : nil,
            value: outcome.value,
            type: outcome.type,
            range: range,
            canUndo: outcome.changedAnything,
            canChangeKind: outcome.changedAnything,
            offersProtectAnyway: outcome.refusal == .roleLabel,
            entityIDs: Set(entities.map(\.id))
        )
    }

    // MARK: - Helpers

    /// Every non-overlapping literal occurrence of `value` (no options, the
    /// same matching addManualEntity uses).
    private func literalRanges(of value: String) -> [NSRange] {
        let nsText = documentText as NSString
        var ranges: [NSRange] = []
        var searchStart = 0
        while searchStart < nsText.length {
            let found = nsText.range(
                of: value,
                options: [],
                range: NSRange(location: searchStart, length: nsText.length - searchStart)
            )
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            searchStart = found.location + max(found.length, 1)
        }
        return ranges
    }

    private static func manualEntity(value: String, type: EntityType, at range: NSRange) -> ReviewEntity {
        ReviewEntity(
            span: Span(
                start: range.location,
                end: range.location + range.length,
                type: type,
                text: value,
                source: .manual,
                confidence: 1.0,
                priority: ProtectSelectionRules.manualPriority
            ),
            accepted: true
        )
    }

    /// The sidebar group id for a value under a type (see groups(of:)).
    static func groupID(value: String, type: EntityType) -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(type.rawValue)|\(key)"
    }

    private static func overlaps(_ span: Span, _ range: NSRange) -> Bool {
        range.location < span.end && NSMaxRange(range) > span.start
    }

    private static func sameRange(_ span: Span, _ range: NSRange) -> Bool {
        span.start == range.location && span.end == NSMaxRange(range)
    }

    private static func strictlyContains(_ span: Span, _ range: NSRange) -> Bool {
        span.start <= range.location && span.end >= NSMaxRange(range) && !sameRange(span, range)
    }
}
