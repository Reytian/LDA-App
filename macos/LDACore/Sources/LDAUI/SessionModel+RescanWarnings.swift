//
//  SessionModel+RescanWarnings.swift
//  LDAUI
//
//  The cross-document rescan warnings the hand-to-AI summary carries: which
//  ready documents still contain a party another ready document confirmed,
//  and whether re-running Scan can actually close that gap or learned
//  suppression would drop the swept party right back out.
//
//  Split out of SessionModel.swift to keep the model file inside its size
//  budget. Self-contained concern with a single caller (buildHandToAI).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

extension SessionModel {

    /// One ready document that still carries a party another ready document
    /// has confirmed. Advice, never an edit: the mention has to reach a human
    /// before it is redacted, so the warning only ever names the document and
    /// the action that puts it there.
    ///
    /// Value-free on purpose: the surfaces themselves stay out of the banner,
    /// matching the session record. The document and the counts are enough to
    /// act on.
    public struct RescanWarning: Equatable, Sendable {
        /// The tray entry the warning is about.
        public let entryID: UUID
        /// That entry's tray name, for the banner.
        public let documentName: String
        /// How many distinct partner-confirmed parties it still carries.
        public let missedPartyCount: Int
        /// How many of those the user has net rejected before. Learned
        /// suppression runs AFTER the rescan sweep (ReviewModelDetection), so
        /// Scan pulls these in and then drops them again: re-scanning cannot
        /// close their gap, and the banner must not send the user there.
        public let suppressedPartyCount: Int

        /// The parties a re-scan really would surface for review.
        public var rescannablePartyCount: Int {
            max(0, missedPartyCount - suppressedPartyCount)
        }

        public init(
            entryID: UUID,
            documentName: String,
            missedPartyCount: Int,
            suppressedPartyCount: Int = 0
        ) {
            self.entryID = entryID
            self.documentName = documentName
            self.missedPartyCount = missedPartyCount
            self.suppressedPartyCount = suppressedPartyCount
        }
    }

    /// The ready documents that literally still contain a party another ready
    /// document confirmed, outside every span of their own. The needle safety
    /// filters and the overlap block come from EntityRescan, so the warning
    /// can never name a gap that re-running Scan would refuse to close.
    ///
    /// One filter EntityRescan cannot see is learned suppression: it lives in
    /// the UI's LearningStore and is applied after the sweep, so a net
    /// rejected party is swept in and dropped again. Those surfaces are still
    /// reported (the document does carry them) but counted separately, so the
    /// banner can prescribe the action that actually works.
    func crossDocumentRescanWarnings(
        ready: [DocumentEntry],
        documents: [SessionDocument]
    ) -> [RescanWarning] {
        guard documents.count > 1 else { return [] }

        let partiesByDocument = documents.map { document in
            document.spans.filter { $0.type == .person || $0.type == .company }
        }
        var warnings: [RescanWarning] = []
        for (index, document) in documents.enumerated() {
            let partners = partiesByDocument.enumerated()
                .filter { $0.offset != index }
                .flatMap { $0.element }
            guard !partners.isEmpty else { continue }
            let missed = EntityRescan.unsweptNeedles(
                in: document.text,
                confirmed: document.spans,
                knownEntities: partners
            )
            guard !missed.isEmpty else { continue }
            warnings.append(
                RescanWarning(
                    entryID: ready[index].id,
                    documentName: ready[index].name,
                    missedPartyCount: missed.count,
                    suppressedPartyCount: suppressedCount(
                        of: missed,
                        entry: ready[index]
                    )
                )
            )
        }
        return warnings
    }

    /// How many of one document's unswept surfaces its own detection pass
    /// would suppress again. Each surface is checked under the ONE type its
    /// sweep needle would carry (EntityRescan.UnsweptSurface): suppression
    /// keys are (value, type) pairs and the sweep mints spans of exactly that
    /// needle type, so that single key decides whether re-running Scan can
    /// close the gap. A homograph surface partners confirmed under several
    /// types is still swept under its first partner type only.
    private func suppressedCount(
        of missed: [EntityRescan.UnsweptSurface],
        entry: DocumentEntry
    ) -> Int {
        guard let suppressKeys = entry.model.learningStore?.suppressKeys,
              !suppressKeys.isEmpty else {
            return 0
        }
        return missed.filter {
            suppressKeys.contains(LearningStore.key(value: $0.value, type: $0.type))
        }.count
    }
}
