//
//  ExtractionCancelToken.swift
//  LDACore
//
//  A tiny thread-safe cancellation flag shared between the UI (main actor)
//  and the extraction worker (background thread). The UI calls cancel(); the
//  LLM engine checks isCancelled once per generated token and the extractor
//  checks it between windows, so a stop request lands within a fraction of a
//  second even mid-generation.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ExtractionCancelToken

/// Thread-safe one-way cancellation flag. Once cancelled it stays cancelled.
public final class ExtractionCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    /// Request cancellation. Safe to call from any thread, any number of times.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// True once cancel() has been called.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

// MARK: - ExtractionCancelled

/// Thrown by the extraction pipeline when the user stopped the run. Callers
/// treat this as a deliberate abort, distinct from a backend failure: no
/// partial result is presented as a completed pass.
public struct ExtractionCancelled: Error, Equatable {
    public init() {}
}
