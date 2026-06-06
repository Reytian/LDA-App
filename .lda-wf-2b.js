export const meta = {
  name: 'lda-llm-orchestration',
  description: 'Phase 2b: chunker + entity JSON parser + offset locator + LLMExtractor over LLMEngine, wired into LDAService to fill SpanMerger llm seam. TDD, verified green incl gated model integration.',
  phases: [
    { title: 'Scaffold', detail: 'TextCompleter protocol + LLMEngine conformance, PromptStore v2 extraction defaults, frozen interfaces, compiling stubs' },
    { title: 'Implement', detail: 'Chunker, EntityJSONParser, EntityLocator, LLMExtractor, LDAService wiring (parallel, TDD)' },
    { title: 'Verify', detail: 'swift build + swift test until green (incl gated real-model integration)' },
  ],
}

const REPO = "/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer"
const PKG = REPO + "/macos/LDACore"
const CORETYPES = PKG + "/Sources/LDACore/Domain/CoreTypes.swift"
const LLMENGINE = PKG + "/Sources/LDACore/Engine/LLMEngine.swift"

const V2PROMPT = [
  "The bundled v2 model was trained (see the original infer.py) on this single-shot extraction format:",
  'SYSTEM: "You are a legal document anonymizer. Identify every piece of sensitive or personally identifying',
  '         information and return strict JSON. Entity types: PERSON, COMPANY, DATE, AMOUNT, EMAIL, PHONE, ADDRESS."',
  'USER:   "Anonymize. Return ONLY JSON with keys entities (array of {value,type}) and redacted_text.\\n\\nTEXT:\\n" + <chunk>',
  'The model returns JSON like {"entities":[{"value":"Acme Corporation","type":"COMPANY"}, ...], "redacted_text":"..."}.',
  "For LDA we only KEEP the fuzzy types from the LLM: PERSON, COMPANY, ADDRESS (the DeterministicEngine owns EMAIL/PHONE/",
  "DATE/AMOUNT/BANK_ACCOUNT/USCC/NATIONAL_ID and wins on conflict via SpanMerger priority). Thinking is disabled by",
  "LLMEngine.buildChatMLPrompt (the closed think block)."
].join("\n")

phase('Scaffold')
const scaffold = await agent(
  "Extend the SwiftPM package LDACore at \"" + PKG + "\" (quote the path) for Phase 2b: orchestrating the on-device LLM to "
  + "produce PERSON/COMPANY/ADDRESS spans that fill SpanMerger's currently-empty llm input. Read \"" + CORETYPES + "\" and \""
  + LLMENGINE + "\" first; do not change CoreTypes.\n\n" + V2PROMPT + "\n\n"
  + "TASK 1 - Testability seam: in \"" + LLMENGINE + "\", add a protocol so LLMExtractor can be unit-tested without the 2.7 GB "
  + "model:\n"
  + "  public protocol TextCompleter { func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String }\n"
  + "  extension LLMEngine: TextCompleter {}   // its existing complete(prompt:maxTokens:stop:) already matches\n"
  + "Ensure the existing LLMEngine.complete signature matches the protocol requirement (defaults are fine on the concrete method).\n\n"
  + "TASK 2 - PromptStore v2 extraction defaults: in Sources/LDACore/Engine/PromptStore.swift add editable, reset-able defaults "
  + "for the v2 single-shot extraction prompt: a defaultExtractionSystem string, a mutable currentExtractionSystem, and an "
  + "extractionUser(chunk:) function building the USER text above. Mirror the existing PromptStore pattern (static default, "
  + "mutable current, reset). Leave the existing Pass-1/Pass-2 fields untouched.\n\n"
  + "TASK 3 - Freeze interfaces as compiling stubs (throwing or empty bodies) in new files under Sources/LDACore/Engine/:\n"
  + "  // Chunker.swift\n"
  + "  public struct TextChunk: Equatable, Sendable { public let text: String; public let startUTF16: Int; public init(text: String, startUTF16: Int) }\n"
  + "  public enum Chunker { public static func chunk(_ text: String, targetChars: Int = 2000, overlapChars: Int = 350) -> [TextChunk] }\n"
  + "  // EntityJSONParser.swift\n"
  + "  public struct ExtractedEntity: Equatable, Sendable { public let value: String; public let type: EntityType; public init(value: String, type: EntityType) }\n"
  + "  public enum EntityJSONParser { public static func parse(_ modelOutput: String) -> [ExtractedEntity] }\n"
  + "  // EntityLocator.swift\n"
  + "  public enum EntityLocator { public static func spans(forValue value: String, type: EntityType, in text: String, source: DetectionSource = .llm, confidence: Double = 0.7) -> [Span] }\n"
  + "  // LLMExtractor.swift\n"
  + "  public final class LLMExtractor { public init(completer: TextCompleter, prompts: PromptStore = PromptStore()); public func extract(from text: String) throws -> [Span] }\n\n"
  + "TASK 4 - LDAService seam (Sources/LDACore/Service/LDAService.swift): add OPTIONAL parameters with defaults so existing "
  + "CLI/MCP call sites keep compiling unchanged: anonymize(... , llmModelPath: String? = nil) and detect(... , llmModelPath: "
  + "String? = nil). For the scaffold keep llm: [] so it compiles; do not change return types.\n\n"
  + "After edits, run from \"" + PKG + "\": swift build 2>&1 | grep -v 'ld: warning' | tail -25  -- it MUST compile green (stubs ok). "
  + "Return the exact frozen signatures, the new PromptStore symbols, the new LDAService signatures, and confirmation swift build is green.",
  { phase: 'Scaffold', label: 'scaffold:2b-interfaces' }
)

const COMMON = "Package \"" + PKG + "\" (quote it). Read the frozen interfaces (Engine/Chunker.swift, Engine/EntityJSONParser.swift, "
  + "Engine/EntityLocator.swift, Engine/LLMExtractor.swift, Engine/PromptStore.swift, Engine/LLMEngine.swift, Domain/CoreTypes.swift, "
  + "Service/LDAService.swift) and implement EXACTLY against them. All Span offsets are UTF-16 (use NSString/NSRange). Use XCTest with "
  + "hermetic fixtures. Do NOT edit Package.swift or CoreTypes.swift. Do NOT run swift build (Verify builds). House rules: English only; "
  + "no em-dash or en-dash-as-separator."

phase('Implement')
const units = [
  {
    label: 'impl:Chunker',
    prompt: COMMON + "\n"
      + "Implement Chunker.chunk in Sources/LDACore/Engine/Chunker.swift. Recursive, structure-aware splitting: prefer paragraph "
      + "boundaries (double newline then single newline), then sentence boundaries (period, question mark, exclamation, and CJW "
      + "full-stop / question / exclamation), so chunks are <= ~targetChars. Add an OVERLAP of overlapChars between consecutive "
      + "chunks (carry the tail of the previous chunk into the next) so an entity straddling a boundary is fully contained in at "
      + "least one chunk; overlap at least ~150 chars. Each TextChunk.startUTF16 is the chunk's UTF-16 offset in the ORIGINAL text. "
      + "Handle text shorter than targetChars (one chunk). "
      + "Tests (Tests/LDACoreTests/ChunkerTests.swift): a long multi-paragraph doc yields multiple chunks each <= targetChars+slack; "
      + "consecutive chunks overlap; a name placed near a 2000-char boundary appears intact in some chunk; CJK text chunks without "
      + "breaking mid-character; startUTF16 offsets are correct (slicing the original at startUTF16 matches the chunk head); short "
      + "text -> exactly one chunk with startUTF16 0."
  },
  {
    label: 'impl:EntityJSONParser',
    prompt: COMMON + "\n"
      + "Implement EntityJSONParser.parse in Sources/LDACore/Engine/EntityJSONParser.swift. Robustly extract entities from the "
      + "model's raw text output. Strategy: locate the JSON (it may be wrapped in prose or fenced code blocks delimited by triple "
      + "backticks); try JSONSerialization on the largest balanced brace or bracket region; accept either an object with an "
      + "entities array of {value,type} plus redacted_text, OR a bare array of {value,type}. Map the type string to EntityType "
      + "case-insensitively (PERSON/COMPANY/ADDRESS/EMAIL/PHONE/DATE/AMOUNT, also NATIONAL_ID/USCC/BANK_ACCOUNT; unknown -> "
      + ".unknown). Skip entities with empty value. Return [] on unparseable input (never throw). If JSONSerialization fails, fall "
      + "back to a brace-matching scan. "
      + "Tests (Tests/LDACoreTests/EntityJSONParserTests.swift): clean object shape; bare array; JSON wrapped in prose and in a "
      + "fenced code block; case-insensitive types; empty-value skipped; garbage -> []; a realistic multi-entity sample."
  },
  {
    label: 'impl:EntityLocator',
    prompt: COMMON + "\n"
      + "Implement EntityLocator.spans in Sources/LDACore/Engine/EntityLocator.swift. Using NSString over text, find EVERY "
      + "non-overlapping occurrence of value (exact substring) and return a Span for each with UTF-16 start/end, the given type, "
      + "text = value, source, confidence, and a priority typical for LLM fuzzy entities (e.g. 30, below deterministic). If value "
      + "not found, return []. Trim surrounding whitespace from value before searching; ignore empty/whitespace value. "
      + "Tests (Tests/LDACoreTests/EntityLocatorTests.swift): single and multiple occurrences -> correct UTF-16 offsets that slice "
      + "back to value; CJK value offsets correct; value absent -> []; advance past each match so occurrences do not overlap."
  },
  {
    label: 'impl:LLMExtractor',
    prompt: COMMON + "\n" + V2PROMPT + "\n"
      + "Implement LLMExtractor in Sources/LDACore/Engine/LLMExtractor.swift. extract(from text:):\n"
      + "1. chunks = Chunker.chunk(text).\n"
      + "2. For each chunk: prompt = LLMEngine.buildChatMLPrompt(system: prompts.currentExtractionSystem, user: "
      + "prompts.extractionUser(chunk: chunk.text)); raw = try completer.complete(prompt: prompt, maxTokens: 1024, stop: [the "
      + "im_end marker]); entities += EntityJSONParser.parse(raw).\n"
      + "3. Keep ONLY .person/.company/.address. Drop any whose trimmed value is a RoleLabels.isRoleLabel.\n"
      + "4. Canonicalize/dedup by (lowercased value, type). For each unique kept entity, EntityLocator.spans(forValue:type:in: "
      + "the FULL original text); collect all spans, dedup identical spans, return them.\n"
      + "If a chunk completion throws, skip that chunk but continue (never fail the whole extraction or crash on bad JSON).\n"
      + "Tests (Tests/LDACoreTests/LLMExtractorTests.swift): use a MOCK TextCompleter (a small struct conforming to TextCompleter) "
      + "returning canned JSON. Verify: a doc with John Smith (PERSON) and Acme Corp (COMPANY) yields llm Spans for both at the "
      + "right offsets; structured types in the mock JSON (EMAIL/DATE) are DROPPED; a role label (Buyer) is dropped; a chunk whose "
      + "mock returns garbage is skipped without failing."
  },
  {
    label: 'impl:LDAServiceWiring',
    prompt: COMMON + "\n"
      + "Wire the LLM path into Sources/LDACore/Service/LDAService.swift (the scaffold already added optional llmModelPath params). "
      + "When llmModelPath is non-nil AND the file exists: construct an LLMEngine(config: .init(modelPath: llmModelPath!)) and an "
      + "LLMExtractor(completer: engine), run extractor.extract(from: importedText), and pass those spans as the llm: argument to "
      + "SpanMerger.merge(deterministic:llm:) in BOTH anonymize and detect. If the model is missing or LLMEngine init throws, FALL "
      + "BACK gracefully to llm: [] (deterministic-only) without failing. When llmModelPath is nil, behavior is unchanged.\n"
      + "Tests (Tests/LDACoreTests/LDAServiceLLMTests.swift):\n"
      + "- Unit (no model): anonymize/detect with llmModelPath nil behaves as before (a .txt with an email still tokenizes EMAIL "
      + "deterministically); anonymize with a bogus llmModelPath (/nonexistent.gguf) still SUCCEEDS via graceful fallback.\n"
      + "- Gated integration (XCTSkip if ~/Developer/lda-models/lda-v2-Q4_K_M.gguf and env LDA_MODEL_PATH are both absent): run "
      + "LDAService.detect on 'This SPA is between Acme Corporation and John Smith.' with llmModelPath set, and assert the result "
      + "contains a .person and a .company span."
  },
]

await parallel(units.map(u => () => agent(u.prompt, { phase: 'Implement', label: u.label })))

phase('Verify')
const verify = await agent(
  "Green the SwiftPM package at \"" + PKG + "\" (quote path). Run:\n"
  + "  swift build 2>&1 | grep -v 'ld: warning' | tail -40\n"
  + "then:\n"
  + "  swift test 2>&1 | grep -vE 'ld: warning|was built for newer' | tail -60\n"
  + "Iterate with MINIMAL correct edits until swift build passes and swift test is green. Honor the frozen public APIs (fix "
  + "implementations, not signatures). The pre-existing 159 tests must still pass. The LLM-gated tests run because the model is "
  + "present at ~/Developer/lda-models/lda-v2-Q4_K_M.gguf; if a gated test reveals a real orchestration bug, fix the orchestration. "
  + "Do not weaken assertions; if something genuinely cannot pass, XCTSkip with a clear reason and report it. House rules: English "
  + "only, no em-dash or en-dash-as-separator. Return: the final swift test summary (passed/skipped), the new source files, and "
  + "confirmation the LLM end-to-end detect test produced a person and a company span.",
  { phase: 'Verify', label: 'verify:2b-build+test', agentType: 'build-error-resolver' }
)

return { scaffold, verify }
