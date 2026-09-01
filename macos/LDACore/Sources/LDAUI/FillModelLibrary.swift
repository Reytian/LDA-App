//
//  FillModelLibrary.swift
//  LDAUI
//
//  Extension on FillModel that owns all Client Portfolio Library intents:
//  browsing (refreshLibrary), creation (createPortfolio), opening (openForEdit,
//  fillFrom), persistence (saveToLibrary, deletePortfolio), export/import, and
//  the private library-instance resolver (resolveLibrary).
//
//  Stored properties (@Published state, test seams, _library cache) STAY in
//  FillModel.swift because stored properties cannot live in extensions. The
//  methods here access those properties directly; they compile as part of the
//  same @MainActor class, so all main-actor isolation rules apply identically.
//
//  Access-level note: resolveLibrary is declared internal (not private) because
//  private is file-scoped in Swift; a private declaration in FillModel.swift
//  would not be visible here. All other moved methods were already public.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

extension FillModel {

    // MARK: - Field helpers

    /// Resolve a typed field name string to a ProfileFieldKey. Uses canonical-first
    /// resolution: if the raw string matches a known canonical key it returns that
    /// canonical case; otherwise it returns .custom(typed).
    ///
    /// Exposed for UI preview and addField callers. Wraps ProfileFieldKey(rawKey:)
    /// which handles the "custom:" prefix convention transparently.
    public func resolveFieldName(_ typed: String) -> ProfileFieldKey {
        ProfileFieldKey(rawKey: typed)
    }

    /// Append a field with manual-entry provenance to the current profile and mark
    /// dirty. The key is stored as provided (canonical or custom). No-op when
    /// profile is nil.
    public func addField(key: ProfileFieldKey, value: String) {
        guard profile != nil else { return }
        let field = ProfileField(
            id: UUID(),
            key: key,
            value: value,
            sourceDocument: "manual entry",
            sourceSnippet: "",
            snippetVerified: false,
            confidence: 1.0,
            userEdited: true
        )
        profile!.fields.append(field)
        profileDirty = true
    }

    // MARK: - Library intents

    /// Refresh the library: load the list off-main, publish summaries, set stage
    /// to .library. On failure, stage becomes .failed. Builds libraryNotice from
    /// lastListReconciled / lastIndexPersistFailed when set.
    ///
    /// Called by the shell on appear to boot from .idle into .library.
    public func refreshLibrary() async {
        libraryNotice = nil
        exportError = nil

        do {
            let lib = try await resolveLibrary()
            let fetched = try await Task.detached(priority: .userInitiated) {
                try lib.list()
            }.value

            summaries = fetched

            // Build the one-time notice from the flags set during list().
            if lib.lastListReconciled || lib.lastIndexPersistFailed {
                var parts: [String] = []
                if lib.lastListReconciled {
                    parts.append(L10n.string("The portfolio index was rebuilt; the list was rebuilt from the portfolio files."))
                }
                if lib.lastIndexPersistFailed {
                    parts.append(L10n.string("Portfolio list changes may not persist; check Keychain access and disk space."))
                }
                libraryNotice = parts.joined(separator: " ")
            }

            stage = .library

        } catch {
            publishFailure(error, context: .library)
        }
    }

    /// Create a new portfolio (from scratch or from extraction), set stage to
    /// .profileReady, and mark dirty. currentPortfolioID is nil until the first
    /// saveToLibrary call.
    ///
    /// fromScratch true: empty ClientPortfolio of the given kind/label.
    /// fromScratch false: same empty portfolio with stage .profileReady; the shell
    /// follows up with extractProfile which populates fields (extraction threads
    /// the portfolio's kind from the profile automatically).
    ///
    /// createdAtISO8601 is supplied by the caller per the purity rule.
    public func createPortfolio(
        kind: PortfolioKind,
        label: String,
        fromScratch: Bool,
        createdAtISO8601: String
    ) async {
        let emptyPortfolio = ClientPortfolio(
            label: label,
            fields: [],
            sourceDocuments: [],
            createdAtISO8601: createdAtISO8601,
            incomplete: false,
            kind: kind,
            modifiedAtISO8601: createdAtISO8601
        )
        currentPortfolioID = nil
        // Reset the source list so a new portfolio starts with no staged documents
        // from a prior session.
        sourcePaths = []
        profile = emptyPortfolio
        profileDirty = true
        stage = .profileReady
    }

    /// Load a portfolio from the library for editing. Sets stage to .profileReady,
    /// currentPortfolioID to id, and dirty to false. On failure, stage becomes
    /// .failed.
    public func openForEdit(id: UUID) async {
        do {
            let lib = try await resolveLibrary()
            let loaded = try await Task.detached(priority: .userInitiated) {
                try lib.load(id: id)
            }.value

            profile = loaded
            currentPortfolioID = id
            profileDirty = false
            stage = .profileReady

        } catch {
            publishFailure(error, context: .library)
        }
    }

    /// Identical to openForEdit. The shell drives the target-opening flow from
    /// .profileReady after this call completes.
    public func fillFrom(id: UUID) async {
        await openForEdit(id: id)
    }

    /// Save the current profile to the library.
    ///
    /// Sets profile.modifiedAt from the caller-supplied timestamp (purity rule).
    /// When currentPortfolioID is nil (first save of a new portfolio), creates a
    /// new entry and captures the returned UUID. When currentPortfolioID is set,
    /// updates the existing entry. Clears profileDirty. Refreshes summaries.
    /// Stage remains .profileReady; the shell decides navigation.
    ///
    /// modifiedAtISO8601 is supplied by the caller per the purity rule.
    public func saveToLibrary(modifiedAtISO8601: String) async {
        guard var p = profile else { return }
        p.modifiedAtISO8601 = modifiedAtISO8601
        profile = p

        do {
            let lib = try await resolveLibrary()
            let savedID: UUID

            if let existingID = currentPortfolioID {
                try await Task.detached(priority: .userInitiated) {
                    try lib.save(p, id: existingID)
                }.value
                savedID = existingID
            } else {
                savedID = try await Task.detached(priority: .userInitiated) {
                    try lib.create(p)
                }.value
            }

            currentPortfolioID = savedID
            profileDirty = false

            // Refresh summaries so the shell's list stays current.
            let refreshed = try await Task.detached(priority: .userInitiated) {
                try lib.list()
            }.value
            summaries = refreshed
            stage = .profileReady

        } catch {
            publishFailure(error, context: .profile)
        }
    }

    /// Delete a portfolio from the library. When id matches currentPortfolioID,
    /// clears currentPortfolioID and sets stage to .library. Refreshes summaries
    /// regardless. On failure, stage becomes .failed.
    public func deletePortfolio(id: UUID) async {
        do {
            let lib = try await resolveLibrary()
            try await Task.detached(priority: .userInitiated) {
                try lib.delete(id: id)
            }.value

            let refreshed = try await Task.detached(priority: .userInitiated) {
                try lib.list()
            }.value
            summaries = refreshed

            if id == currentPortfolioID {
                currentPortfolioID = nil
            }
            stage = .library

        } catch {
            publishFailure(error, context: .library)
        }
    }

    /// Export the portfolio at id to url with the given protection. On failure,
    /// exportError is set and the stage is left unchanged so the user stays on the
    /// library list. exportError is cleared at the start of this call and in
    /// refreshLibrary (see FillModel.swift file header for the export-error
    /// surfacing choice).
    public func exportPortfolio(id: UUID, to url: URL, protection: MappingProtection) async {
        exportError = nil

        do {
            let lib = try await resolveLibrary()
            try await Task.detached(priority: .userInitiated) {
                try lib.exportPortfolio(id: id, to: url, protection: protection)
            }.value

        } catch {
            exportError = Self.describe(error)
        }
    }

    /// Import a portfolio from url and store it in the library. Returns the new
    /// UUID, or nil on failure (stage becomes .failed). Refreshes summaries.
    @discardableResult
    public func importPortfolio(from url: URL, protection: MappingProtection) async -> UUID? {
        do {
            let lib = try await resolveLibrary()
            let newID = try await Task.detached(priority: .userInitiated) {
                try lib.importPortfolio(from: url, protection: protection)
            }.value

            let refreshed = try await Task.detached(priority: .userInitiated) {
                try lib.list()
            }.value
            summaries = refreshed
            stage = .library

            return newID

        } catch {
            publishFailure(error, context: .library)
            return nil
        }
    }

    /// Import a portfolio from url using the Keychain fallback chain and store it
    /// in the library. Use this when the file was saved by the Keychain path (no
    /// passphrase) and may carry any of the legacy account formats (pre-portal UI,
    /// CLI, or MCP). Returns the new UUID, or nil on failure (stage becomes .failed).
    /// Refreshes summaries.
    @discardableResult
    public func importPortfolioWithKeychainFallback(from url: URL) async -> UUID? {
        do {
            let lib = try await resolveLibrary()
            let newID = try await Task.detached(priority: .userInitiated) {
                try lib.importPortfolioWithKeychainFallback(from: url)
            }.value

            let refreshed = try await Task.detached(priority: .userInitiated) {
                try lib.list()
            }.value
            summaries = refreshed
            stage = .library

            return newID

        } catch {
            publishFailure(error, context: .library)
            return nil
        }
    }

    // MARK: - Library instance resolver

    /// Returns the library to use for the current intent:
    ///   1. Test seam (libraryForTesting): returned as-is; no caching.
    ///   2. Cached instance (_library): returned immediately if already constructed.
    ///   3. Production construction: built off the main thread, cached in _library,
    ///      and returned. Uses libraryRootForTesting when set (test-only override
    ///      that exercises the cached-instance path without touching Application
    ///      Support); otherwise constructs the default Application Support root.
    ///
    /// Throws if the production default cannot be initialised (e.g. Application
    /// Support is unavailable).
    ///
    /// internal for FillModelLibrary.swift
    internal func resolveLibrary() async throws -> PortfolioLibrary {
        if let seam = Self.effectiveLibraryOverride {
            return seam
        }
        if let cached = _library {
            return cached
        }
        let root = Self.effectiveLibraryRoot
        let constructed = try await Task.detached(priority: .userInitiated) {
            if let root {
                return try PortfolioLibrary(rootDirectory: root)
            }
            return try PortfolioLibrary()
        }.value
        _library = constructed
        return constructed
    }
}
