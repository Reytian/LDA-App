//
//  MCPBatchHandoff.swift
//  LDAUI
//
//  The app side of the batch_anonymize MCP tool (MCPBatchBridge). A request
//  opens the batch window; the next batch the person runs there answers it
//  with an outcome and counts, and a window that closes first answers it as
//  closed. Nothing else about the batch reaches the MCP helper.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import LDACore
import SwiftUI

@MainActor
public final class MCPBatchHandoff: ObservableObject {
    public static let shared = MCPBatchHandoff()

    /// The request the batch window shows and its next batch answers.
    @Published private(set) var pending: MCPBatchRequest?
    /// True while the batch window runs a batch.
    var isBatchRunning = false

    private let send: (MCPBatchReply) -> Void

    init(send: @escaping (MCPBatchReply) -> Void = { try? MCPBatchBridge.reply($0) }) {
        self.send = send
    }

    /// Takes a request from the MCP helper. A newer request replaces one
    /// still waiting, which is answered as closed.
    public func receive(_ request: MCPBatchRequest) {
        guard !request.isExpired() else { return }
        if isBatchRunning {
            answer(request, .busy)
            return
        }
        if let earlier = pending, earlier.id != request.id {
            answer(earlier, .closed)
        }
        pending = request
        answer(request, .opened)
    }

    /// The batch starting now takes the pending request, unless the helper
    /// has stopped waiting for it.
    func claim(at now: Date = Date()) -> MCPBatchRequest? {
        defer { pending = nil }
        guard let pending, pending.canBeAnswered(at: now) else { return nil }
        return pending
    }

    /// The batch window closed before a batch took the request.
    func windowClosed() {
        guard let request = pending else { return }
        pending = nil
        answer(request, .closed)
    }

    func answer(_ request: MCPBatchRequest, _ outcome: MCPBatchReply.Outcome, report: BatchReport? = nil) {
        send(MCPBatchReply(requestID: request.id, outcome: outcome, report: report))
    }
}

/// Opens the batch window when a batch_anonymize request arrives. A view,
/// because opening a window needs the environment's openWindow action.
public struct MCPBatchWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var handoff = MCPBatchHandoff.shared

    public init() {}

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: handoff.pending?.id) { _, id in
                if id != nil {
                    openWindow(id: LDAWindowID.batch)
                }
            }
    }
}
