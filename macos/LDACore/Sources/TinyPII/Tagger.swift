import CoreML
import Foundation

/// Runtime settings exported with the assets (runtime.json).
public struct RuntimeConfig: Decodable {
    public let labelNames: [String]
    public let maxLength: Int
    public let stride: Int
    public let clsId: Int
    public let sepId: Int
    public let padId: Int
    public let pretokenizer: String

    enum CodingKeys: String, CodingKey {
        case labelNames = "label_names", maxLength = "max_length", stride, clsId = "cls_id", sepId = "sep_id", padId = "pad_id", pretokenizer
    }
}

public struct DocumentSpan {
    public let span: Span
    /// UTF-16 offsets (NSString / LDA).
    public let start16: Int
    public let end16: Int
}

/// The whole app-side pipeline: tokenize, window, Core ML logits, BIOES decode, merge.
public final class Tagger {
    public let tokenizer: Tokenizer
    public let config: RuntimeConfig
    let decoder: Decoder
    let model: MLModel
    public let loadSeconds: Double

    public init(assets: URL, model modelURL: URL, computeUnits: MLComputeUnits) throws {
        tokenizer = try Tokenizer(assets: assets)
        config = try JSONDecoder().decode(RuntimeConfig.self, from: readLocalFile(assets.appendingPathComponent("runtime.json")))
        guard config.pretokenizer == "cjk-punct-v1" else { throw RuntimeError("unsupported pre-tokenizer \(config.pretokenizer)") }
        decoder = Decoder(labelNames: config.labelNames)
        let started = Date()
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiled, configuration: mlConfig)
        loadSeconds = Date().timeIntervalSince(started)
    }

    /// Logits [position][label] for one window, padded to max_length.
    func logits(_ window: Window) throws -> [[Float]] {
        let n = config.maxLength
        let ids = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .int32)
        for i in 0..<n {
            let real = i < window.inputIds.count
            ids[i] = NSNumber(value: real ? window.inputIds[i] : Int32(config.padId))
            mask[i] = NSNumber(value: real ? Int32(1) : Int32(0))
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: ids),
                                                                 "attention_mask": MLFeatureValue(multiArray: mask)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: "logits")?.multiArrayValue else { throw RuntimeError("no logits output") }
        let labels = config.labelNames.count
        // The label inventory comes from runtime.json (round 2 added TRADEMARK and VESSEL), so check it fits the model.
        guard array.shape.count == 3, array.shape[1].intValue >= window.inputIds.count, array.shape[2].intValue == labels else {
            throw RuntimeError("logits shape \(array.shape) does not fit \(labels) labels in runtime.json")
        }
        let strides = array.strides.map { $0.intValue }
        var rows = [[Float]](repeating: [Float](repeating: 0, count: labels), count: window.inputIds.count)
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for t in 0..<window.inputIds.count { for j in 0..<labels { rows[t][j] = p[t * strides[1] + j * strides[2]] } }
        case .float16:
            let p = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for t in 0..<window.inputIds.count { for j in 0..<labels { rows[t][j] = Float(p[t * strides[1] + j * strides[2]]) } }
        default:
            for t in 0..<window.inputIds.count { for j in 0..<labels { rows[t][j] = array[[0, NSNumber(value: t), NSNumber(value: j)]].floatValue } }
        }
        return rows
    }

    public func predict(_ text: String) throws -> [DocumentSpan] {
        let tokens = tokenizer.encode(text)
        let windows = makeWindows(tokens: tokens, text: text, tables: tokenizer.tables, maxLength: config.maxLength,
                                  stride: config.stride, cls: config.clsId, sep: config.sepId)
        var perWindow: [[(Span, Bool)]] = []
        for window in windows {
            let positions = window.offsets.indices.filter { window.offsets[$0].1 > window.offsets[$0].0 }
            if positions.isEmpty { perWindow.append([]); continue }
            let all = try logits(window)
            let rows = positions.map { Decoder.logSoftmax(all[$0]) }
            let tags = decoder.viterbi(rows)
            let probs = zip(rows, tags).map { exp($0.0[$0.1]) }
            perWindow.append(decoder.windowSpans(tags: tags, offsets: positions.map { window.offsets[$0] }, probs: probs,
                                                 atDocStart: window.index == 0, atDocEnd: window.isLast))
        }
        // code points -> UTF-16
        var utf16At = [Int](repeating: 0, count: text.unicodeScalars.count + 1)
        var u = 0
        for (k, scalar) in text.unicodeScalars.enumerated() {
            utf16At[k] = u
            u += scalar.value > 0xFFFF ? 2 : 1
        }
        utf16At[text.unicodeScalars.count] = u
        return decoder.merge(perWindow).map { DocumentSpan(span: $0, start16: utf16At[$0.start], end16: utf16At[$0.end]) }
    }
}
