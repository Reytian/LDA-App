//
//  PromptStore.swift
//  LDACore
//
//  In-memory holder for the editable Pass-1 and Pass-2 prompt bodies.
//
//  The prompt bodies below are ported from the proven Python defaults in
//  core/prompts.py (PASS1_PROMPT, PASS2_PROMPT). They are kept verbatim in
//  content so the Swift core drives the same LLM contract as the Python
//  pipeline. The bodies are Chinese because the production target anonymizes
//  Chinese-language legal documents; that is intentional and not a house-rules
//  violation (the rule covers comments and English prose, not ported model
//  prompt content).
//
//  Placeholder convention: the Python templates use str.format, so they carry
//  doubled braces "{{" / "}}" for literal JSON braces and single braces for
//  substitution slots. We preserve those exact tokens here so a host that runs
//  the same format step gets byte-identical output. The slots are:
//    Pass-1: {key_sections_text}
//    Pass-2: {entity_aliases_context}, {document_segment}
//
//  GUARDRAILS (host keeps these fixed even when the editable body changes):
//  - The JSON-output contract: the model MUST return raw JSON only, with no
//    code fences. Both default bodies state this explicitly. The host is
//    expected to keep enforcing JSON parsing regardless of edits, and validate()
//    warns when an edited body drops the instruction.
//  - The thinking-off directive: the bundled Qwen3.5 v2 model is a reasoning
//    model that defaults to thinking. The host (LLMEngine) disables it when it
//    renders the ChatML generation prompt, by ending that prompt with a
//    pre-closed "<think>\n\n</think>\n\n" block so the unsloth chat template
//    skips reasoning (see LLMEngine.buildChatMLPrompt). That switch lives at the
//    engine layer, NOT inside this editable prompt body. The host owns it and
//    keeps it fixed; editing the prompt body here can never turn thinking back
//    on. This is documented so a future editor does not assume the body
//    controls it.
//
//  House rules: all comments and added English strings are English. No em-dash
//  and no en-dash-as-separator anywhere.
//

import Foundation

// MARK: - PromptKind

/// Which prompt a reset or accessor targets.
public enum PromptKind: String, Codable, Sendable, CaseIterable {
    case pass1
    case pass2
    case extraction
    case profile
    case blankMatch
}

// MARK: - PromptSnapshot

/// A Codable snapshot of the current prompt bodies. The host layer persists this
/// (UserDefaults, a file, iCloud, whatever it chooses); PromptStore itself stays
/// purely in-memory. Round-trips exactly through Codable.
public struct PromptSnapshot: Equatable, Sendable, Codable {
    /// The current Pass-1 body.
    public var pass1: String
    /// The current Pass-2 body.
    public var pass2: String

    public init(pass1: String, pass2: String) {
        self.pass1 = pass1
        self.pass2 = pass2
    }
}

// MARK: - PromptStore

/// Holds the current, editable Pass-1 and Pass-2 prompt bodies in memory.
///
/// The defaults are ported from core/prompts.py. Callers edit currentPass1 and
/// currentPass2 freely; reset(...) restores the exact ported defaults. A Codable
/// snapshot is exposed so a host app can persist and restore the bodies, but this
/// type never touches disk or UserDefaults itself.
public final class PromptStore {

    // MARK: Static defaults (ported verbatim from core/prompts.py)

    /// Default Pass-1 body. Ported from PASS1_PROMPT in core/prompts.py.
    /// Extracts entity definitions, aliases, and sensitive items from the key
    /// contract sections, and returns raw JSON only.
    public static let defaultPass1: String = """
    你是一个法律文档分析助手。以下是一份法律合同的关键片段（包含定义条款、通知条款和签署页）。

    请从中提取所有当事方和实体的定义关系，以及所有出现的敏感信息。

    需要提取的内容：
    1. 实体定义关系：哪些简称/别名指向同一个实体
       例如："甲方" = "上海某某科技有限公司"，"the Target" = "XYZ Technology Limited"
    2. 所有敏感信息：人名、公司名、地址、电话、邮箱、金额等

    同时请判断该文档的类型（例如：股权转让协议、Employment Agreement、Loan Agreement、NDA、Share Purchase Agreement 等），用简短的英文表述。

    请以 JSON 格式返回，不要返回任何其他内容（不要加 ```json 标记）：
    {{
      "document_type": "Equity Transfer Agreement",
      "aliases": [
        {{
          "canonical": "上海某某科技有限公司",
          "aliases": ["甲方", "转让方"],
          "type": "company"
        }}
      ],
      "entities": [
        {{"text": "上海某某科技有限公司", "type": "company"}},
        {{"text": "john@example.com", "type": "email"}}
      ]
    }}

    ---
    合同关键片段：
    {key_sections_text}
    """

    /// Default Pass-2 body. Ported from PASS2_PROMPT in core/prompts.py.
    /// Identifies every sensitive item in one document segment, using the known
    /// entity definitions, and returns a raw JSON array only.
    public static let defaultPass2: String = """
    你是一个法律文档脱敏助手。请仔细阅读以下法律文档片段，识别其中所有的敏感信息。

    【已知实体定义（来自合同定义条款）】
    {entity_aliases_context}

    基于以上定义，当文中出现"甲方"、"目标公司"等简称时，也应视为敏感信息。

    敏感信息包括但不限于：
    - 自然人姓名（中文和英文）
    - 公司/机构名称（中文和英文，包括上述定义中的简称/别名）
    - 金额（包含货币符号的数字）
    - 电话号码、传真号码
    - 电子邮箱
    - 身份证号、护照号、SSN、EIN
    - 银行账号
    - 加密货币钱包地址
    - 具体地址（街道级别）
    - 公司注册号（包括统一社会信用代码、开曼/BVI注册号）
    - 具体日期（合同签署日、截止日等，不包括法律生效日等通用日期）

    请以 JSON 数组格式返回，不要返回任何其他内容（不要加 ```json 标记）：
    [
      {{
        "text": "原文中的敏感信息（保持原文形式）",
        "type": "person/company/amount/phone/email/id/bank/wallet/address/regnum/date",
        "canonical": "如果是已知实体的别名则填正式名称，否则留空字符串"
      }}
    ]

    ---
    文档片段：
    {document_segment}
    """

    /// Default system prompt for the v2 single-shot extraction format. This is
    /// the exact instruction the bundled v2 model was trained on (see the
    /// original infer.py). Unlike the Pass-1/Pass-2 bodies above, this prompt is
    /// English because the v2 model was trained on this English instruction.
    public static let defaultExtractionSystem: String = """
    You are a legal document anonymizer. Identify every piece of sensitive or personally identifying \
    information and return strict JSON. Entity types: PERSON, COMPANY, DATE, AMOUNT, EMAIL, PHONE, ADDRESS.
    """

    /// Default system prompt for the profile-extraction pass. Extracts company
    /// facts from incorporation documents and returns a raw JSON array of fact
    /// objects. English by design (the "Fill from Profile" feature targets
    /// English-language incorporation documents as the primary input).
    public static let defaultProfileSystem: String = """
    You extract company facts from incorporation documents (certificates of \
    incorporation, articles of association, business licenses). The document may \
    be in English or Chinese; extract facts regardless of language.

    Return RAW JSON ONLY, no code fences, no commentary: an array of objects, \
    each {"key": string, "value": string, "snippet": string, "confidence": number}.

    Allowed keys: companyName, companyNameLocal, formerName, entityKind, \
    jurisdiction, companyNumber, incorporationDate, registeredOffice, \
    authorizedCapital, issuedCapital, parValue, shareClass, directorName, \
    shareholderName, shareholderShares, companySecretary, registeredAgent. \
    If you find an important fact that fits none of these, use a single camelCase \
    word of your own (no spaces, no underscores).

    Rules:
    - "value" is the exact fact as written in the document. Do not translate, \
    reformat, or abbreviate it.
    - "snippet" is the EXACT sentence or line from the document containing the \
    value, copied verbatim.
    - If the snippet is truncated by a chunk boundary, include what is visible; \
    that is acceptable.
    - "confidence" is between 0 and 1.
    - One object per fact. Repeat keys for lists (several directors, several \
    shareholders).
    - shareholderShares values must name the shareholder, for example \
    "Jane Roe: 9,000 ordinary shares".
    - If the chunk contains no extractable fact, return [].
    """

    /// Default system prompt for the blank-match pass. Matches blanks in a legal
    /// draft to fields from a company profile and returns a raw JSON array.
    /// English by design (the "Fill from Profile" feature targets English-language
    /// draft agreements).
    public static let defaultBlankMatchSystem: String = """
    You match blanks in a legal draft to fields from a company profile. You are \
    given a numbered field catalog (key and value) and a numbered list of blanks, \
    each with a label and the surrounding text.

    Return RAW JSON ONLY, no code fences: an array of objects, each \
    {"blank": number, "field": number or null, "value": string or null}.

    Rules:
    - "blank" is the blank's number from the list.
    - "field" is the catalog number of the matching field, or null when no \
    catalog field fits. Never guess: if the context calls for a fact the catalog \
    does not contain (for example the counterparty's name), answer null.
    - "value" is OPTIONAL: provide it only when the blank needs a reformatted \
    form of the field value (for example the day, month, or year part of a date, \
    or a spelled-out form the context requires). When the canonical value fits \
    as written, leave "value" null.
    - Answer every blank exactly once.
    """

    // MARK: Validation anchors

    /// Substrings that mark the JSON-output contract in a body. Presence of any
    /// one of these is treated as the body still instructing JSON-only output.
    /// These are the exact phrases the ported defaults use.
    private static let jsonInstructionAnchors: [String] = [
        "JSON 格式返回",
        "JSON 数组格式返回"
    ]

    /// The no-code-fence directive phrase. Part of the JSON-output guardrail:
    /// the model must emit raw JSON with no Markdown fences.
    private static let noFenceAnchor = "不要加 ```json"

    /// Pass-2 substitution placeholders. Removing either breaks str.format-style
    /// rendering of the segment text or the alias context.
    private static let pass2Placeholders: [String] = [
        "{entity_aliases_context}",
        "{document_segment}"
    ]

    /// Pass-1 substitution placeholder. Removing it means the key sections never
    /// reach the model.
    private static let pass1Placeholder = "{key_sections_text}"

    // MARK: Mutable in-memory state

    /// The current Pass-1 body. Defaults to defaultPass1; edit freely.
    public var currentPass1: String

    /// The current Pass-2 body. Defaults to defaultPass2; edit freely.
    public var currentPass2: String

    /// The current v2 extraction system prompt. Defaults to
    /// defaultExtractionSystem; edit freely. reset(.extraction) restores it.
    public var currentExtractionSystem: String

    /// The current profile-extraction system prompt. Defaults to
    /// defaultProfileSystem; edit freely. reset(.profile) restores it.
    public var currentProfileSystem: String

    /// The current blank-match system prompt. Defaults to
    /// defaultBlankMatchSystem; edit freely. reset(.blankMatch) restores it.
    public var currentBlankMatchSystem: String

    // MARK: Init

    /// Creates a store seeded with the ported defaults.
    public init() {
        self.currentPass1 = PromptStore.defaultPass1
        self.currentPass2 = PromptStore.defaultPass2
        self.currentExtractionSystem = PromptStore.defaultExtractionSystem
        self.currentProfileSystem = PromptStore.defaultProfileSystem
        self.currentBlankMatchSystem = PromptStore.defaultBlankMatchSystem
    }

    /// Creates a store seeded from a previously persisted snapshot. The
    /// extraction, profile, and blankMatch system prompts are not carried in
    /// PromptSnapshot, so they are seeded to their defaults here.
    public init(snapshot: PromptSnapshot) {
        self.currentPass1 = snapshot.pass1
        self.currentPass2 = snapshot.pass2
        self.currentExtractionSystem = PromptStore.defaultExtractionSystem
        self.currentProfileSystem = PromptStore.defaultProfileSystem
        self.currentBlankMatchSystem = PromptStore.defaultBlankMatchSystem
    }

    // MARK: Reset

    /// Restores the given prompt to its ported default, discarding edits.
    public func reset(_ kind: PromptKind) {
        switch kind {
        case .pass1:
            currentPass1 = PromptStore.defaultPass1
        case .pass2:
            currentPass2 = PromptStore.defaultPass2
        case .extraction:
            currentExtractionSystem = PromptStore.defaultExtractionSystem
        case .profile:
            currentProfileSystem = PromptStore.defaultProfileSystem
        case .blankMatch:
            currentBlankMatchSystem = PromptStore.defaultBlankMatchSystem
        }
    }

    /// Restores all prompts to their ported defaults.
    public func resetAll() {
        reset(.pass1)
        reset(.pass2)
        reset(.extraction)
        reset(.profile)
        reset(.blankMatch)
    }

    // MARK: Extraction prompt builder

    /// Build the v2 single-shot extraction USER text for one document chunk.
    /// Based on the v2 user-turn format (see the original infer.py), but the
    /// "redacted_text" key is intentionally dropped: the parser only consumes
    /// "entities", while "redacted_text" echoes the whole chunk back and roughly
    /// doubles the output size, which is the dominant cause of hitting the
    /// generation token cap mid-array (LJE-001). Asking for entities only keeps
    /// the output budget on the data we actually use.
    public func extractionUser(chunk: String) -> String {
        return "Anonymize. Return ONLY JSON with key entities "
            + "(array of {value,type}).\n\nTEXT:\n"
            + chunk
    }

    // MARK: Profile and BlankMatch prompt builders

    /// Builds the profile-extraction USER turn for one document chunk.
    public func profileUser(documentName: String, chunk: String) -> String {
        "Document: \(documentName)\n\nText:\n\(chunk)"
    }

    /// Builds the blank-match USER turn for one draft, given a numbered field
    /// catalog and a numbered list of blanks.
    public func blankMatchUser(catalog: String, blanks: String) -> String {
        "Field catalog:\n\(catalog)\n\nBlanks:\n\(blanks)"
    }

    // MARK: Snapshot

    /// The current bodies as a Codable snapshot for host-side persistence.
    public var snapshot: PromptSnapshot {
        PromptSnapshot(pass1: currentPass1, pass2: currentPass2)
    }

    /// Replaces the current bodies from a snapshot.
    public func apply(_ snapshot: PromptSnapshot) {
        currentPass1 = snapshot.pass1
        currentPass2 = snapshot.pass2
    }

    // MARK: Validation

    /// Validates an arbitrary prompt body and returns human-readable warnings
    /// when it appears to drop required structural anchors. An empty array means
    /// no structural problems were detected.
    ///
    /// This is a lightweight, best-effort check, not a parser. It looks for:
    /// - a JSON-output instruction (the body must tell the model to return JSON);
    /// - the no-code-fence directive (raw JSON, no Markdown fences);
    /// - at least one substitution placeholder so the source text can be injected.
    ///   Pass-2 additionally needs both of its placeholders.
    ///
    /// The host keeps the JSON contract and thinking-off directive fixed at the
    /// engine layer regardless of these warnings; validate() only flags an
    /// editable body that has drifted away from the expected anchors.
    ///
    /// Note: this function is calibrated for the Chinese pass1/pass2 bodies only;
    /// it emits spurious warnings for the English extraction, profile, and
    /// blankMatch bodies because those bodies use different JSON-instruction
    /// phrasing and no str.format-style substitution placeholders.
    public static func validate(_ body: String) -> [String] {
        var warnings: [String] = []

        let hasJSONInstruction = jsonInstructionAnchors.contains { body.contains($0) }
        if !hasJSONInstruction {
            warnings.append(
                "Missing JSON-output instruction: the body should tell the model to return JSON."
            )
        }

        if !body.contains(noFenceAnchor) {
            warnings.append(
                "Missing no-code-fence directive: the body should instruct raw JSON with no Markdown fence."
            )
        }

        let hasPass1Placeholder = body.contains(pass1Placeholder)
        let presentPass2Placeholders = pass2Placeholders.filter { body.contains($0) }

        if !hasPass1Placeholder && presentPass2Placeholders.isEmpty {
            warnings.append(
                "Missing substitution placeholder: the body has no slot to inject the source text."
            )
        } else if !presentPass2Placeholders.isEmpty
            && presentPass2Placeholders.count < pass2Placeholders.count {
            let missing = pass2Placeholders.filter { !body.contains($0) }
            warnings.append(
                "Missing Pass-2 placeholder(s): " + missing.joined(separator: ", ") + "."
            )
        }

        return warnings
    }
}
