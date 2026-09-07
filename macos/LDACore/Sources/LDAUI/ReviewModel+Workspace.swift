//
//  ReviewModel+Workspace.swift
//  LDAUI
//
//  The review model's half of the portable workspace (.ldawork): capture one
//  document's decisions, and put them back WITHOUT re-running detection.
//
//  Why re-applying rather than re-detecting is the whole point: the colleague
//  who receives a workspace may not have the detection model installed at all,
//  and even with it, a second pass over the same document is not guaranteed to
//  return the same list. A workspace that re-scanned would show a DIFFERENT
//  review state than the one that was saved, which for a redaction tool is a
//  correctness failure, not a cosmetic one.
//
//  The one thing that can go wrong is offsets. Spans are UTF-16 offsets into
//  the imported text; if this build imports the same bytes into slightly
//  different text (a normalizer change between versions), applying the offsets
//  verbatim would mark the wrong characters, and the tool would confidently
//  redact the wrong thing. The snapshot therefore carries a digest of the text
//  the offsets were measured against, and a mismatch downgrades to relocating
//  each value by its exact surface text instead of trusting the numbers.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// What re-applying a snapshot actually achieved.
public struct WorkspaceSnapshotApplication: Equatable, Sendable {

    /// How many entities were restored into the review list.
    public let appliedCount: Int

    /// True when the document text did not match the snapshot's digest, so
    /// entities were relocated by surface text rather than by offset.
    public let didRelocate: Bool

    /// How many recorded entities could not be found in the document at all.
    /// Non-zero only on the relocation path.
    public let droppedCount: Int
}

extension ReviewModel {

    // MARK: - Capture

    /// Capture this document's review state for a workspace archive.
    ///
    /// Decisions, assigned replacements, and the AI coverage of the result
    /// they belong to. No selection, no scroll position, no status: a
    /// workspace restores work, not a desktop. The coverage is part of the
    /// work: a review list whose AI pass never ran is a different deliverable
    /// from one whose pass finished, and the Export for AI gate on the
    /// reopening Mac has to know which one it is looking at.
    func workspaceSnapshot(documentID: UUID) -> WorkspaceReviewSnapshot {
        WorkspaceReviewSnapshot(
            documentID: documentID,
            textDigest: WorkspaceReviewSnapshot.digest(of: documentText),
            entities: entities.map {
                WorkspaceEntityRecord(
                    id: $0.id,
                    span: $0.span,
                    accepted: $0.accepted,
                    token: $0.token
                )
            },
            aiCoverage: aiCoverage.workspaceRecord
        )
    }

    // MARK: - Restore

    /// Put a snapshot's decisions back on this document.
    ///
    /// The model must already hold the document text (the workspace unpacked
    /// the original bytes and the ordinary importer read them). Detection is
    /// NOT run, and the document ends in the reviewed state so the restored
    /// session can hand off and export immediately.
    ///
    /// Reviewed does not mean AI-scanned. The coverage the snapshot recorded
    /// is re-applied with the decisions, so a result whose AI pass failed or
    /// stopped short is gated here exactly as it was before it was saved; a
    /// snapshot from before coverage was recorded is gated as if the pass
    /// did not run, and a snapshot whose text no longer matches is gated
    /// whatever it recorded, because that pass ran over different text.
    @discardableResult
    func applyWorkspaceSnapshot(
        _ snapshot: WorkspaceReviewSnapshot
    ) -> WorkspaceSnapshotApplication {
        let matches = snapshot.textDigest == WorkspaceReviewSnapshot.digest(of: documentText)
        let outcome = matches
            ? (restored: snapshot.entities.map(Self.entity(from:)), dropped: 0)
            : relocated(snapshot.entities)

        entities = outcome.restored
        // A relocated review is one whose text is no longer the text that was
        // scanned. Whatever the record says about that scan, it ran over other
        // text, so this text re-applies warned; see AIScanCoverage.
        aiCoverage = matches
            ? AIScanCoverage.restored(from: snapshot.aiCoverage)
            : AIScanCoverage.textChangedSinceScan()
        selectedGroupID = nil
        // A dropped record is a protected value that this build could not
        // locate. Keep the document out of the export gate until the user
        // scans it again. A complete relocation can retain reviewed state.
        status = outcome.dropped == 0 ? .ready : .imported
        progress = outcome.dropped == 0 ? 1 : 0
        etaText = nil
        return WorkspaceSnapshotApplication(
            appliedCount: outcome.restored.count,
            didRelocate: !matches,
            droppedCount: outcome.dropped
        )
    }

    private static func entity(from record: WorkspaceEntityRecord) -> ReviewEntity {
        ReviewEntity(
            id: record.id,
            span: record.span,
            accepted: record.accepted,
            token: record.token
        )
    }

    /// Re-find every recorded value in the current text by its exact surface,
    /// one occurrence per record, never reusing a range.
    ///
    /// Order matters: records are placed in their recorded order, so a value
    /// that appeared twice keeps its two decisions in the same sequence.
    private func relocated(
        _ records: [WorkspaceEntityRecord]
    ) -> (restored: [ReviewEntity], dropped: Int) {
        let text = documentText as NSString
        var taken: [(start: Int, end: Int)] = []
        var restored: [ReviewEntity] = []
        var dropped = 0

        for record in records {
            guard let range = Self.firstFreeRange(
                of: record.span.text,
                in: text,
                avoiding: taken
            ) else {
                dropped += 1
                continue
            }
            taken.append((range.location, range.location + range.length))
            restored.append(
                ReviewEntity(
                    id: record.id,
                    span: Self.span(record.span, movedTo: range),
                    accepted: record.accepted,
                    token: record.token
                )
            )
        }
        return (restored.sorted { $0.span.start < $1.span.start }, dropped)
    }

    /// The first occurrence of `needle` that overlaps none of `taken`.
    private static func firstFreeRange(
        of needle: String,
        in text: NSString,
        avoiding taken: [(start: Int, end: Int)]
    ) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        var searchStart = 0
        while searchStart < text.length {
            let range = text.range(
                of: needle,
                options: [],
                range: NSRange(location: searchStart, length: text.length - searchStart)
            )
            guard range.location != NSNotFound else { return nil }
            let end = range.location + range.length
            let overlaps = taken.contains { range.location < $0.end && end > $0.start }
            if !overlaps { return range }
            searchStart = range.location + max(range.length, 1)
        }
        return nil
    }

    /// The same span at a new location. A new value, never a mutation of the
    /// recorded one.
    private static func span(_ original: Span, movedTo range: NSRange) -> Span {
        Span(
            start: range.location,
            end: range.location + range.length,
            type: original.type,
            text: original.text,
            source: original.source,
            confidence: original.confidence,
            priority: original.priority
        )
    }
}
