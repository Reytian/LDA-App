//
//  VaultCrossProcessLock.swift
//  LDACore
//
//  Finding 7 (2026-09-06 review): DocumentVault's registry read-modify-write
//  transaction was serialized only by an in-process NSLock (registryLock).
//  The lda CLI (staging) and the lda-mcp server open the SAME vault
//  directory as SEPARATE processes, so two writers could each load the
//  registry, append their own entry, and save: the later write silently
//  discarded the earlier one. Six concurrent `lda vault stage` processes
//  reproduced this as five lost registrations with their encrypted objects
//  orphaned on disk (see the review evidence for the exact repro).
//
//  flock(2) on a lock file inside the vault root closes the gap across
//  processes, not just threads. Its key property over a pid-in-a-file scheme
//  is that the KERNEL drops the lock the instant the holding process exits,
//  for any reason (normal return, crash, kill -9): a dead writer can never
//  wedge the vault for every other process. A pid file would leave every
//  other process guessing whether a recorded pid names a live holder or a
//  crash leftover, and would need its own cleanup logic to recover.
//
//  Scope: hold this lock only around the registry's read-modify-write
//  transaction (DocumentVault.withRegistryTransaction), never across object
//  encryption, which can be slow and never touches the registry.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// A blocking, cross-process exclusive lock backed by flock(2) on one file.
/// The file's contents are never read or written; it exists only to be
/// locked. Safe to construct fresh for every call: flock is associated with
/// the open file description, not with any DocumentVault value.
struct VaultCrossProcessLock {

    /// Where the lock file lives. Typically a sibling of registry.sealed
    /// inside the vault root.
    let lockFileURL: URL

    /// Acquire the lock (blocking until any other process releases it), run
    /// body while holding it, and release it afterward whether body returns
    /// or throws. Never call this recursively on the same lock file from the
    /// same thread: flock does not nest and the second call would deadlock
    /// against the first.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // O_CREAT so the first process to reach this line creates the file;
        // every process after that opens the SAME inode, which is what
        // flock(2) actually locks (the lock belongs to the open file
        // description, not to any path or process).
        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw DocumentVaultError.crossProcessLockUnavailable
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw DocumentVaultError.crossProcessLockUnavailable
        }
        // Runs before close(descriptor) above (defers unwind last-declared
        // first), so the lock is released explicitly rather than only as a
        // side effect of closing the descriptor.
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }
}

// MARK: - DocumentVault composition

extension DocumentVault {

    /// Orders threads of ONE process. Kept alongside the cross-process lock
    /// because it still buys in-process ordering, but on its own it is NOT a
    /// fix for finding 7: it says nothing about a second process.
    static let registryLock = NSLock()

    /// The cross-process lock file, a sibling of registry.sealed.
    var transactionLockURL: URL {
        rootDirectory.appendingPathComponent(DocumentVault.transactionLockFileName)
    }

    /// The lock guarding the registry transaction across every process that
    /// opens this vault directory.
    var transactionLock: VaultCrossProcessLock {
        VaultCrossProcessLock(lockFileURL: transactionLockURL)
    }

    /// Run body with the registry transaction lock held: the cross-process
    /// flock first, then the in-process NSLock. Every registry mutation and
    /// every plain registry read goes through this, so staging, derived
    /// commits, migration, list and entry all share one cross-process
    /// boundary. Hold this ONLY around the registry read-modify-write
    /// itself; never across object encryption, which can be slow.
    func withRegistryTransaction<T>(_ body: () throws -> T) throws -> T {
        try transactionLock.withLock {
            try DocumentVault.registryLock.withLock(body)
        }
    }
}
