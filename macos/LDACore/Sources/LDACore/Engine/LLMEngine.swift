//
//  LLMEngine.swift
//  On-device LLM inference for the fuzzy entities (PERSON / COMPANY / ADDRESS),
//  backed by a bundled GGUF model run through llama.cpp with the Metal backend.
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

/// A loaded GGUF model plus an inference context. Not Sendable: it owns raw
/// llama.cpp pointers and must be used from a single thread at a time.
public final class LLMEngine {

    public struct Config {
        /// Absolute path to the GGUF model file.
        public var modelPath: String
        /// Context window in tokens.
        public var contextLength: Int32
        /// Layers to offload to the Metal GPU. 999 means "all" (clamped to the
        /// model's real layer count).
        public var gpuLayers: Int32
        /// Default generation cap.
        public var maxTokens: Int

        public init(
            modelPath: String,
            contextLength: Int32 = 8192,
            gpuLayers: Int32 = 999,
            maxTokens: Int = 1024
        ) {
            self.modelPath = modelPath
            self.contextLength = contextLength
            self.gpuLayers = gpuLayers
            self.maxTokens = maxTokens
        }
    }

    public enum LLMError: Error, Equatable {
        case modelFileMissing(String)
        case modelLoadFailed(String)
        case contextCreationFailed
        case decodeFailed(Int32)
    }

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

        // Tokenize. add_special = false because the prompt already carries the
        // ChatML special tokens; parse_special = true so they are recognized.
        let byteCount = Int32(prompt.utf8.count)
        let capacity = Int(byteCount) + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        let written = prompt.withCString { cstr in
            llama_tokenize(vocab, cstr, byteCount, &tokens, Int32(capacity), false, true)
        }
        guard written > 0 else { throw LLMError.decodeFailed(written) }
        tokens = Array(tokens.prefix(Int(written)))

        // Decode the prompt.
        try tokens.withUnsafeMutableBufferPointer { buffer in
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
