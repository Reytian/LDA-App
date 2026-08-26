//
//  TestSeam.swift
//  LDACore
//
//  A lock-guarded holder for a dependency-injection seam that exists only for
//  tests.
//
//  Two properties matter, and both were missing from the hand-rolled
//  `internal static var ...ForTesting` seams this type replaces:
//
//   1. It is compiled ONLY in debug builds. A shipped release binary therefore
//      carries no injection point at all, so nothing in the product can be
//      persuaded to swap the real LLM extractor or the real portfolio library
//      root for something else.
//   2. Access is serialized by a lock. A bare mutable static is a data race the
//      moment two tests touch it at once, and a torn read of a closure
//      reference is not a recoverable failure.
//
//  Usage: declare the seam inside `#if DEBUG`, expose it through a computed
//  property so call sites and existing tests keep their original spelling, and
//  wrap every READ site in `#if DEBUG` as well so the release build compiles
//  the production path only.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

#if DEBUG
import Foundation

/// A lock-guarded, debug-only slot for an injected test double.
///
/// `@unchecked Sendable` is correct here rather than a shortcut: every access
/// to `storage` goes through `lock`, and the type does not exist outside debug
/// builds, so it can never widen the concurrency surface of a shipped binary.
public final class TestSeam<Value>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: Value?

    public init() {}

    /// The installed double, or nil when the production path should be used.
    public var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    /// True while a double is installed. Tests assert this is false in tearDown:
    /// a seam left installed leaks a fake into every later test in the process,
    /// which shows up as an unrelated failure far from its cause.
    public var isInstalled: Bool {
        lock.withLock { storage != nil }
    }

    /// Remove any installed double.
    public func clear() {
        lock.withLock { storage = nil }
    }
}
#endif
