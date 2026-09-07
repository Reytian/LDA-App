//
//  ExportMappingHome.swift
//  LDAUI
//
//  Where a Save Redacted export's key goes, decided BEFORE the export
//  suspends.
//
//  THE FAILURE THIS FILE EXISTS TO PREVENT (R7). A DOCX export runs the AI
//  pass over headers, footers, notes and comments, which takes seconds to
//  minutes, and the window stays live throughout. The completion used to
//  build its workspace from whatever the session held when it resumed, and to
//  adopt its mapping into that session unconditionally. Switch matter while
//  an export runs and both halves went wrong at once: matter A's mapping
//  entered matter B's session, where B's restoration could then reach A's
//  values, and A's own workspace was written with B's matter label and none
//  of A's documents, so A's export lost its key home.
//
//  So the home is a SNAPSHOT. The destination, the protection, the whole
//  workspace payload and the matter identity are all captured on the main
//  actor before the export's detached work begins. The completion writes that
//  snapshot, with only the freshly minted mapping filled in, so matter A's
//  export always lands in matter A's workspace with matter A's document.
//
//  Adoption into the LIVE session is the part that must be conditional: it is
//  the one step that puts values on screen. It happens only while the session
//  is still the one the export started in, compared on both the matter
//  generation and the label. Otherwise the key is still kept, and the user is
//  told where, because nothing else on screen would say: the completion card
//  belongs to a document that is no longer open.
//
//  House rules: user-facing copy is localized. No em-dash or
//  en-dash-as-separator.
//

import Foundation
import LDACore

// MARK: - The snapshot

/// Everything an export's mapping needs in order to reach its home, captured
/// before the export suspends.
///
/// The payload's `mapping` is deliberately nil here: the export mints the
/// mapping, so it is the one field the snapshot cannot know. Every other
/// field is the session as it was when the user pressed Save.
struct ExportMappingHome {

    /// The document this export redacted. The default workspace file name is
    /// derived from it, so the destination stays this document's whatever the
    /// tray holds later.
    ///
    /// Deliberately NOT a pre-resolved destination URL. Resolving the folder
    /// can fail (no room, no Application Support), and that failure has to
    /// stay where it was: inside the completion, where an export that also
    /// wrote a passphrase sidecar still stands because its key travelled with
    /// the document. Resolving early would turn that into a refusal.
    let source: URL

    /// The workspace payload for the exported document alone, mapping absent.
    let payload: WorkspacePayload

    /// The matter that was selected when the export started, so the
    /// completion can tell "still here" from "the user moved on".
    let matterLabel: String?

    /// The session's matter generation at the same moment.
    let matterGeneration: Int
}

// MARK: - Session side

extension SessionModel {

    /// Capture what this export's key needs from the session, before anything
    /// suspends.
    ///
    /// Cannot fail: every field is read straight off the session. The one
    /// step that can fail, resolving the workspace folder, is deliberately
    /// left to the completion; see ExportMappingHome.source.
    func exportMappingHome(
        forSource source: URL,
        documentID: UUID,
        createdAtISO8601: String
    ) -> ExportMappingHome {
        ExportMappingHome(
            source: source,
            payload: buildWorkspacePayload(
                createdAtISO8601: createdAtISO8601,
                documentIDs: [documentID],
                mapping: nil
            ),
            matterLabel: clientLabel,
            matterGeneration: matterGeneration
        )
    }

    /// Write `mapping` into the home the export was started with, and adopt it
    /// as the session mapping only while that session is still on screen.
    ///
    /// Returns where the key was kept, which is what the completion card
    /// names. Throws rather than degrading: a caller that has already written
    /// a redacted document needs to hear that its key did not land, because
    /// nothing else on screen would say so. ReviewModel.export takes that
    /// further and removes what it wrote, so a failure here cannot leave an
    /// unrestorable document behind.
    @discardableResult
    func keepMapping(_ mapping: Mapping, in home: ExportMappingHome) throws -> URL {
        let destination = try defaultWorkspaceURL(forSource: home.source)
        var payload = home.payload
        payload.mapping = mapping
        try WorkspaceArchive.write(
            payload,
            to: destination,
            protection: defaultWorkspaceProtection(destination)
        )
        guard isStillTheSessionThatStarted(home) else {
            mappingHomeAdvisory = ExportMappingHomePresentation.keptElsewhereAdvisory(
                workspaceFileName: destination.lastPathComponent
            )
            return destination
        }
        adoptWorkspaceMapping(mapping)
        mappingHomeAdvisory = nil
        return destination
    }

    /// Whether the session is still the one `home` was captured from.
    ///
    /// Both halves are load bearing. The generation catches every matter
    /// switch and every workspace opened over the session. The label catches
    /// the one identity change that does not go through those two: a parked
    /// round trip resumed into a session that had no matter selected.
    private func isStillTheSessionThatStarted(_ home: ExportMappingHome) -> Bool {
        home.matterGeneration == matterGeneration && home.matterLabel == clientLabel
    }
}

// MARK: - Presentation

enum ExportMappingHomePresentation {

    /// The sentence for a key that was kept but not adopted.
    ///
    /// It names the FILE and not the matter. The file name is what the user
    /// needs in order to open the workspace again, and it is already what the
    /// completion card shows for an ordinary export; naming the outgoing
    /// matter would put one matter's party label on another matter's screen
    /// for no gain.
    static func keptElsewhereAdvisory(
        workspaceFileName: String,
        language: AppLanguage? = nil
    ) -> String {
        // One literal, deliberately not a concatenation; see ReviewModel.export.
        String(
            format: L10n.string("An export finished after you switched matters. Its mapping was kept in \"%@\" for the matter it was started in, and was not loaded into this session. Open that workspace to restore that document.", language: language),
            workspaceFileName as NSString
        )
    }
}
