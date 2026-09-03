//
//  LLMEngine.swift
//  On-device LLM inference for the fuzzy entities (PERSON / COMPANY / ADDRESS),
//  backed by a local GGUF model run through llama.cpp with the Metal backend.
//  The model path is always supplied by the caller: the CLI and the MCP server
//  take it as an argument, and the app resolves it from the installed tier. No
//  model ships inside the app.
//
//  This is the substrate for Phase 2. It exposes a minimal, synchronous text
//  completion API. Higher layers (Pass-1 anchoring, Pass-2 chunked extraction,
//  JSON parsing into Spans) build on top of it.
//
//  The validated v2 model is a reasoning model that defaults to thinking. The
//  unsloth chat template only disables thinking when the generation prompt ends
//  with a pre-closed block ("<think>\n\n</think>\n\n"); llama.cpp's template
//  flags do not drive this template. So we render ChatML ourselves and append
//  that closed block. See buildChatMLPrompt(system:user:).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import Cllama

// MARK: - TextCompleter

/// A minimal text-completion seam. LLMEngine is the production conformer (it
/// drives llama.cpp); tests inject a lightweight fake so LLMExtractor and the
/// higher Pass layers can be exercised without loading the 2.7 GB GGUF model.
///
/// The single requirement matches LLMEngine.complete(prompt:maxTokens:stop:);
/// the concrete method keeps its defaults, which a protocol witness is allowed
/// to supply.
public protocol TextCompleter {
    /// Greedy-decode a completion for a raw prompt, stopping on an
    /// end-of-generation token, on any provided stop string, or at maxTokens.
    func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String
}

/// LLMEngine already exposes complete(prompt:maxTokens:stop:) with defaults, so
/// it satisfies TextCompleter without any additional code.
extension LLMEngine: TextCompleter {}

// MARK: - BatchTextCompleter

/// A completer that can decode many prompts through a fixed number of
/// parallel sequence slots (continuous batching). Greedy generation is
/// memory-bandwidth-bound on the model weights, so decoding N sequences per
/// weight pass multiplies throughput nearly N-fold; refilling a slot the
/// moment its sequence finishes keeps all slots busy instead of convoying on
/// the slowest member of a fixed group. LLMExtractor hands ALL extraction
/// windows to one call and receives per-window completions.
public protocol BatchTextCompleter {
    /// Complete every prompt, one independent sequence each, streaming them
    /// through the available slots. Returns one output per prompt, in order.
    /// Outputs may be truncated at maxTokens exactly like complete(prompt:...);
    /// callers handle truncation the same way. onSequenceDone fires once per
    /// finished prompt (with its index) for progress reporting.
    func completeBatch(
        prompts: [String],
        maxTokens: Int?,
        stop: [String],
        onSequenceDone: ((Int) -> Void)?
    ) throws -> [String]
}

extension LLMEngine: BatchTextCompleter {}

// MARK: - CancelAwareCompleter

/// A completer that honors an ExtractionCancelToken, checking it during
/// generation so a user's stop request takes effect mid-completion.
public protocol CancelAwareCompleter: AnyObject {
    var cancelToken: ExtractionCancelToken? { get set }
}

extension LLMEngine: CancelAwareCompleter {}

/// A loaded GGUF model plus an inference context. Not Sendable: it owns raw
/// llama.cpp pointers and must be used from a single thread at a time.
public final class LLMEngine {

    public struct Config {
        /// Absolute path to the GGUF model file.
        public var modelPath: String
        /// Context window in tokens. With batchSlots > 1 the window is a
        /// UNIFIED pool shared by all in-flight sequences (kv_unified), so a
        /// batch of N windows fits as long as their prompts plus generation
        /// caps sum below this, and a single long retry can still use the
        /// whole pool.
        public var contextLength: Int32
        /// Layers to offload to the Metal GPU. 999 means "all" (clamped to the
        /// model's real layer count).
        public var gpuLayers: Int32
        /// Default generation cap.
        public var maxTokens: Int
        /// How many independent sequences completeBatch may decode at once.
        public var batchSlots: Int

        public init(
            modelPath: String,
            contextLength: Int32 = 8192,
            gpuLayers: Int32 = 999,
            maxTokens: Int = 1024,
            batchSlots: Int = 4
        ) {
            self.modelPath = modelPath
            self.contextLength = contextLength
            self.gpuLayers = gpuLayers
            self.maxTokens = maxTokens
            self.batchSlots = max(1, batchSlots)
        }
    }

    public enum LLMError: Error, Equatable {
        case modelFileMissing(String)
        case modelLoadFailed(String)
        case contextCreationFailed
        case decodeFailed(Int32)
        case cancelled
        /// llama_batch_init returned a batch whose per-token sequence-id rows
        /// are not all allocated. Reported instead of force-unwrapped: a nil
        /// row used to crash the process, which in the MCP server means the
        /// host loses the connection mid-request and in the GUI means the app
        /// disappears while a lawyer is mid-review.
        case batchUnallocated(row: Int)
    }

    /// Optional cancellation flag. Checked once per generated token in both
    /// complete() and completeBatch(); when set, generation aborts by throwing
    /// LLMError.cancelled. Safe to leave nil.
    ///
    /// THREADING CONTRACT. LLMEngine is not Sendable: it owns raw llama.cpp
    /// pointers and one inference context, so exactly one thread may call into
    /// it at a time. This property inherits that contract rather than relaxing
    /// it. Assign it from the owning thread BEFORE starting a run, and do not
    /// write it while complete() or completeBatch() is executing. Cross-thread
    /// cancellation is the job of ExtractionCancelToken, which is itself
    /// synchronized: hold a reference to the token and call cancel() on it from
    /// wherever the stop button lives, instead of reassigning this property.
    public var cancelToken: ExtractionCancelToken?

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let config: Config

    /// One-time llama backend bootstrap. A `static let` initializer is run
    /// exactly once even under concurrent first access, unlike the previous
    /// unsynchronized boolean flag, which could double-call
    /// llama_backend_init() when two engines were constructed at once.
    private static let backendBootstrap: Void = {
        llama_backend_init()
    }()

    public init(config: Config) throws {
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw LLMError.modelFileMissing(config.modelPath)
        }
        _ = LLMEngine.backendBootstrap

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = config.gpuLayers
        guard let loadedModel = llama_model_load_from_file(config.modelPath, modelParams) else {
            throw LLMError.modelLoadFailed(config.modelPath)
        }
        self.model = loadedModel

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(config.contextLength)
        // Allow a prompt as large as the full context in a single decode.
        contextParams.n_batch = UInt32(config.contextLength)
        // Physical micro-batch for prompt processing. The 512 default starves
        // Apple-silicon Metal: prefill throughput scales with the micro-batch
        // because larger matmuls amortize the weight-bandwidth cost. Measured
        // on the 18-page e2e document, prefill dominates total time, so this
        // is the single most effective latency knob.
        contextParams.n_ubatch = 2048
        // Parallel decoding: completeBatch runs one sequence per prompt. The
        // KV buffer is UNIFIED across sequences so the n_ctx budget is a
        // shared pool: a batch of short windows fits together, and a single
        // long-cap retry can still use the whole pool. (A partitioned cache,
        // kv_unified false, would cap every sequence at n_ctx / n_seq_max and
        // break the 4096-token truncation retry.)
        contextParams.n_seq_max = UInt32(config.batchSlots)
        contextParams.kv_unified = true
        // Collect real prompt-eval vs generation timings when the field
        // diagnosability flag is on (printed from deinit).
        if ProcessInfo.processInfo.environment["LDA_PERF"] != nil {
            contextParams.no_perf = false
        }
        guard let createdContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw LLMError.contextCreationFailed
        }
        self.context = createdContext

        guard let modelVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(createdContext)
            llama_model_free(loadedModel)
            throw LLMError.contextCreationFailed
        }
        self.vocab = modelVocab
        self.config = config
    }

    deinit {
        // Field diagnosability: LDA_PERF=1 in the environment prints llama.cpp
        // context timings (prompt eval vs generation, tokens and tok/s) to
        // stderr on teardown, splitting where inference time actually goes.
        if ProcessInfo.processInfo.environment["LDA_PERF"] != nil {
            llama_perf_context_print(context)
        }
        llama_free(context)
        llama_model_free(model)
    }

    // MARK: - Prompt construction

    /// Render a single-turn ChatML prompt for this model with thinking disabled.
    /// The trailing "<think>\n\n</think>\n\n" is what makes the unsloth template
    /// skip reasoning and answer directly.
    public static func buildChatMLPrompt(system: String, user: String) -> String {
        return "<|im_start|>system\n\(system)<|im_end|>\n"
            + "<|im_start|>user\n\(user)<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    // MARK: - Completion

    /// Greedy-decode a completion for a raw prompt. Special tokens in the prompt
    /// (the ChatML markers) are parsed. Generation stops on an end-of-generation
    /// token, on any provided stop string, or at maxTokens.
    public func complete(
        prompt: String,
        maxTokens: Int? = nil,
        stop: [String] = ["<|im_end|>"]
    ) throws -> String {
        let cap = maxTokens ?? config.maxTokens

        // Each call is a stateless completion. Clear the context memory so this
        // prompt decodes from position 0 instead of appending to the previous
        // call's KV cache. Without this, per-segment calls accumulate until the
        // context overflows; llama_decode then fails and the caller skips the
        // segment, silently leaving its PII un-scanned. Earlier segments also
        // bleed attention state into later ones.
        llama_memory_clear(llama_get_memory(context), false)

        let tokens = try tokenize(prompt)

        // Decode the prompt.
        var promptTokens = tokens
        try promptTokens.withUnsafeMutableBufferPointer { buffer in
            let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
            let rc = llama_decode(context, batch)
            if rc != 0 { throw LLMError.decodeFailed(rc) }
        }

        // Greedy sampler chain.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var outputBytes = [UInt8]()
        outputBytes.reserveCapacity(cap * 4)

        for _ in 0..<cap {
            if let cancelToken, cancelToken.isCancelled { throw LLMError.cancelled }
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            appendPiece(of: token, to: &outputBytes)

            // Stop strings, checked in UTF-8 byte space. Comparing bytes (not a
            // decoded String) is exact when the tail holds a partial multi-byte
            // sequence mid-character, and avoids re-decoding the whole output
            // on every token.
            if let trimmed = LLMEngine.trimmingStopSuffix(outputBytes, stop: stop) {
                return String(decoding: trimmed, as: UTF8.self)
            }

            // Feed the sampled token back in.
            var next = [token]
            let failed = next.withUnsafeMutableBufferPointer { buffer -> Int32 in
                let batch = llama_batch_get_one(buffer.baseAddress, 1)
                return llama_decode(context, batch)
            }
            if failed != 0 { break }
        }

        return String(decoding: outputBytes, as: UTF8.self)
    }

    // MARK: - Batched completion (continuous batching)

    /// Greedy-decode many prompts through `config.batchSlots` parallel
    /// sequence slots with continuous batching: the moment a sequence
    /// finishes, its slot is refilled with the next queued prompt, so the
    /// decode loop never convoys on the slowest member of a fixed group.
    ///
    /// Measured note (Apple M4, Metal, this llama.cpp build): multi-row
    /// generation steps show NO per-token amortization over single-row steps,
    /// so the end-to-end win over sequential decoding is modest; the loop is
    /// kept because it is correctness-neutral, keeps latency from convoying,
    /// and inherits any future backend batching improvements.
    ///
    /// Shared-prefix KV via llama_memory_seq_cp was tried here and REMOVED:
    /// on this build it corrupted continuations (sequences rambled to the cap
    /// or died instantly, forcing truncation retries that cost more than the
    /// prefill it saved). Re-evaluate on a newer llama.cpp before
    /// reintroducing.
    ///
    /// Falls back to sequential complete() when batching cannot help (single
    /// prompt, one slot) or cannot fit (a single prompt plus its cap exceeding
    /// the context pool). A failing llama_decode mid-run throws: the caller
    /// falls back to its sequential path, which preserves the
    /// skip-and-report semantics for backend failures. Cancellation is
    /// checked once per step.
    public func completeBatch(
        prompts: [String],
        maxTokens: Int? = nil,
        stop: [String] = ["<|im_end|>"],
        onSequenceDone: ((Int) -> Void)? = nil
    ) throws -> [String] {
        guard !prompts.isEmpty else { return [] }
        let cap = maxTokens ?? config.maxTokens
        let tokenLists = try prompts.map { try tokenize($0) }

        // Per-slot budget in the unified pool: the largest prompt plus its
        // generation cap, times the number of concurrent slots, must fit.
        let longestPrompt = tokenLists.map(\.count).max() ?? 0
        let slots = min(config.batchSlots, prompts.count)
        let perSlotBudget = longestPrompt + cap
        if prompts.count == 1 || slots < 2 || perSlotBudget * slots > Int(config.contextLength) {
            var outputs: [String] = []
            for (index, prompt) in prompts.enumerated() {
                outputs.append(try complete(prompt: prompt, maxTokens: maxTokens, stop: stop))
                onSequenceDone?(index)
            }
            return outputs
        }

        let memory = llama_get_memory(context)
        llama_memory_clear(memory, false)

        let capacity = max(longestPrompt * slots, slots)
        var batch = llama_batch_init(Int32(capacity), 0, 1)
        defer { llama_batch_free(batch) }

        // llama_batch_init allocates one sequence-id row per token slot. Verify
        // every row once here and keep the unwrapped pointers, so the two hot
        // loops below index a non-optional array instead of force-unwrapping on
        // each token. A failed allocation now surfaces as a thrown error the
        // caller can report and retry, rather than a trap.
        guard let seqIdBase = batch.seq_id else {
            throw LLMError.batchUnallocated(row: 0)
        }
        var seqIdRows: [UnsafeMutablePointer<llama_seq_id>] = []
        seqIdRows.reserveCapacity(capacity)
        for row in 0 ..< capacity {
            guard let rowPointer = seqIdBase[row] else {
                throw LLMError.batchUnallocated(row: row)
            }
            seqIdRows.append(rowPointer)
        }

        // Greedy sampler chain, shared across sequences (greedy is stateless).
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        // Slot state.
        var outputs = [[UInt8]](repeating: [], count: prompts.count)
        var slotPrompt = [Int?](repeating: nil, count: slots)   // prompt index per slot
        var slotPos = [llama_pos](repeating: 0, count: slots)   // next decode position
        var slotPending = [llama_token](repeating: 0, count: slots)
        var slotGenerated = [Int](repeating: 0, count: slots)
        var nextPrompt = 0
        var finishedCount = 0

        func finishSlot(_ slot: Int) {
            if let promptIndex = slotPrompt[slot] {
                finishedCount += 1
                onSequenceDone?(promptIndex)
            }
            slotPrompt[slot] = nil
        }

        while finishedCount < prompts.count {
            if let cancelToken, cancelToken.isCancelled { throw LLMError.cancelled }

            // 2. Admission: fill every free slot with the next queued prompt.
            //    All admitted suffixes decode in ONE batch; only each suffix's
            //    last token requests logits.
            var admissionRows: [(slot: Int, batchIndex: Int)] = []
            var batchIndex = 0
            for slot in 0..<slots where slotPrompt[slot] == nil && nextPrompt < prompts.count {
                let promptIndex = nextPrompt
                nextPrompt += 1

                // Drop this slot's previous sequence entirely.
                llama_memory_seq_rm(memory, llama_seq_id(slot), 0, -1)

                let tokens = tokenLists[promptIndex]
                for position in 0..<tokens.count {
                    batch.token[batchIndex] = tokens[position]
                    batch.pos[batchIndex] = llama_pos(position)
                    batch.n_seq_id[batchIndex] = 1
                    seqIdRows[batchIndex][0] = llama_seq_id(slot)
                    batch.logits[batchIndex] = position == tokens.count - 1 ? 1 : 0
                    batchIndex += 1
                }
                slotPrompt[slot] = promptIndex
                slotPos[slot] = llama_pos(tokens.count)
                slotGenerated[slot] = 0
                admissionRows.append((slot: slot, batchIndex: batchIndex - 1))
            }
            if !admissionRows.isEmpty {
                batch.n_tokens = Int32(batchIndex)
                let rc = llama_decode(context, batch)
                guard rc == 0 else { throw LLMError.decodeFailed(rc) }
                for row in admissionRows {
                    slotPending[row.slot] = llama_sampler_sample(sampler, context, Int32(row.batchIndex))
                }
            }

            // 3. Consume each active slot's sampled token: stop on EOG, append
            //    bytes, stop on a stop-string suffix, stop at the cap.
            for slot in 0..<slots {
                guard let promptIndex = slotPrompt[slot] else { continue }
                let token = slotPending[slot]
                if llama_vocab_is_eog(vocab, token) {
                    finishSlot(slot)
                    continue
                }
                appendPiece(of: token, to: &outputs[promptIndex])
                if let trimmed = LLMEngine.trimmingStopSuffix(outputs[promptIndex], stop: stop) {
                    outputs[promptIndex] = trimmed
                    finishSlot(slot)
                    continue
                }
                slotGenerated[slot] += 1
                if slotGenerated[slot] >= cap {
                    // Cap hit: the output stays as-is (truncated); the caller's
                    // truncation recovery takes over.
                    finishSlot(slot)
                }
            }

            // 4. Generation step: one token per still-active slot, one decode
            //    for all of them.
            let activeSlots = (0..<slots).filter { slotPrompt[$0] != nil }
            if activeSlots.isEmpty {
                if nextPrompt >= prompts.count { break }
                continue
            }
            for (row, slot) in activeSlots.enumerated() {
                batch.token[row] = slotPending[slot]
                batch.pos[row] = slotPos[slot]
                batch.n_seq_id[row] = 1
                seqIdRows[row][0] = llama_seq_id(slot)
                batch.logits[row] = 1
                slotPos[slot] += 1
            }
            batch.n_tokens = Int32(activeSlots.count)
            let rc = llama_decode(context, batch)
            guard rc == 0 else { throw LLMError.decodeFailed(rc) }
            for (row, slot) in activeSlots.enumerated() {
                slotPending[slot] = llama_sampler_sample(sampler, context, Int32(row))
            }
        }

        return outputs.map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: - Tokenization

    /// Tokenize a prompt. add_special = false because prompts already carry
    /// the ChatML special tokens; parse_special = true so they are recognized.
    private func tokenize(_ prompt: String) throws -> [llama_token] {
        let byteCount = Int32(prompt.utf8.count)
        let capacity = Int(byteCount) + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        let written = prompt.withCString { cstr in
            llama_tokenize(vocab, cstr, byteCount, &tokens, Int32(capacity), false, true)
        }
        guard written > 0 else { throw LLMError.decodeFailed(written) }
        return Array(tokens.prefix(Int(written)))
    }

    /// If bytes ends with the UTF-8 encoding of any stop string, return bytes
    /// with that suffix removed; otherwise nil. Operating in byte space keeps
    /// the trim exact (a Character-space dropLast can disagree with the emitted
    /// byte stream under canonical equivalence or a partial multi-byte tail).
    static func trimmingStopSuffix(_ bytes: [UInt8], stop: [String]) -> [UInt8]? {
        for stopString in stop {
            let stopBytes = Array(stopString.utf8)
            guard !stopBytes.isEmpty, bytes.count >= stopBytes.count else { continue }
            if bytes.suffix(stopBytes.count).elementsEqual(stopBytes) {
                return Array(bytes.dropLast(stopBytes.count))
            }
        }
        return nil
    }

    /// Convert a token to its raw bytes and append them. Accumulating bytes (not
    /// per-token Strings) keeps multibyte CJK characters intact when a single
    /// character spans more than one token.
    private func appendPiece(of token: llama_token, to bytes: inout [UInt8]) {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        guard length != 0 else { return }
        let count = Int(abs(length))
        if count > buffer.count {
            buffer = [CChar](repeating: 0, count: count)
            let retry = llama_token_to_piece(vocab, token, &buffer, Int32(count), 0, false)
            guard retry > 0 else { return }
            for index in 0..<Int(retry) { bytes.append(UInt8(bitPattern: buffer[index])) }
            return
        }
        for index in 0..<count { bytes.append(UInt8(bitPattern: buffer[index])) }
    }
}
