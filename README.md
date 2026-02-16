# Legal Document Anonymizer

A tool that strips sensitive information from legal documents before they touch any cloud AI service, then restores it afterward. Built for lawyers who want to use consumer AI apps like ChatGPT, Claude, or Kimi — without violating client confidentiality.

> **The end goal is fully local.** This proof-of-concept uses a cloud LLM API for entity detection during development, but the production version is designed to run entirely on your machine — no API calls, no cloud services, no data leaving your laptop. The anonymization engine will use a local model (via [Ollama](https://ollama.com), [vLLM](https://github.com/vllm-project/vllm), or similar) so that even the scanning step never transmits client data anywhere. The architecture is already built for this: swap the API endpoint from a remote URL to `http://localhost:11434` and everything else stays the same.

## Why Anonymize Legal Documents?

Lawyers are bound by strict confidentiality rules. In the United States, ABA Model Rule 1.6 and its state equivalents (e.g., New York RPC 1.6) prohibit disclosing client information without informed consent. Similar obligations exist in virtually every jurisdiction worldwide — from the SRA Code in England and Wales to the professional conduct rules across the EU, Asia, and Latin America.

The problem is practical: modern AI tools are extraordinarily useful for legal work — drafting, translation, summarization, clause comparison, risk analysis — but every major AI platform processes user inputs on remote servers. When a lawyer pastes a merger agreement into ChatGPT, they are transmitting client names, deal terms, financial figures, and personal data to a third party. This creates real professional responsibility risk:

- **Disciplinary exposure.** Bar associations have begun issuing ethics opinions on AI use (e.g., NY State Bar Ethics Opinion 1238, Florida Bar Opinion 24-1). The consensus is clear: lawyers must take reasonable steps to prevent unauthorized disclosure when using cloud-based tools.
- **Data protection liability.** Cross-border agreements often contain personal data subject to GDPR or other privacy regimes. Uploading these documents to a US-based AI service without anonymization can constitute an unauthorized cross-border data transfer.
- **Client trust.** Even where no rule is technically violated, clients do not expect their confidential deal terms to appear in training data or be accessible to platform employees.

Anonymization solves this by replacing every sensitive element — names, addresses, amounts, registration numbers, bank accounts — with neutral placeholders *before* the document leaves the lawyer's machine. The AI sees `{COMPANY_1}` instead of the actual company name. It can still perform useful work on the document structure and legal content. Afterward, the lawyer restores the original information locally.

## How This Benefits Lawyers Using Consumer AI Apps

The typical workflow looks like this:

1. **Anonymize** the agreement locally (this tool)
2. **Upload** the anonymized version to any AI app (ChatGPT, Claude, Kimi, etc.)
3. **Use the AI** for drafting, review, translation, or analysis — the AI works with placeholders and has no access to actual client data
4. **Download** the AI's output (still containing placeholders)
5. **De-anonymize** locally — the tool restores all original names, figures, and details using a saved mapping table

This workflow gives lawyers the full benefit of AI assistance while maintaining an auditable compliance posture:

- **Use any AI tool freely.** No need to negotiate enterprise data processing agreements or wait for your firm's IT department to approve a new vendor. The anonymized document contains nothing confidential.
- **Cross-border work becomes safer.** A lawyer working on cross-border transactions can run anonymized agreements through any AI service without triggering GDPR or other cross-border data transfer concerns, because no personal data leaves the local machine.
- **Preserve work product.** The mapping table serves as a local record of exactly what was redacted and restored, creating a defensible audit trail if a client or regulator ever asks how AI was used on their matter.
- **No vendor lock-in.** This tool works with any OpenAI-compatible LLM API. Use a cloud API during evaluation; switch to a local model (Ollama, vLLM) for production. The anonymization logic stays the same.
- **The ultimate version runs 100% locally.** The current PoC uses a cloud API only to validate the scanning approach quickly. In production, the LLM itself runs on your machine — via Ollama, vLLM, or any local inference server that exposes an OpenAI-compatible endpoint. At that point, *nothing* leaves your laptop: the original document stays local, the LLM scanning happens local, the anonymized output stays local, and the mapping table stays local. The cloud AI app only ever sees a document with every sensitive detail already replaced.

## How It Works

The tool uses a two-pass LLM scanning approach:

**Pass 1 — Entity Definition Extraction.** The tool identifies key sections of the document (recitals, definitions, notice clauses, signature pages) and asks the LLM to extract entity definitions and alias relationships. For example: *"Party A" = "Shanghai Xingchen Technology Co., Ltd." = "the Transferor"*.

**Pass 2 — Full Document Scan.** Armed with the alias context from Pass 1, the tool scans the entire document segment by segment, identifying every sensitive item: names, companies, amounts, phone numbers, emails, ID numbers, bank accounts, addresses, registration numbers, and dates.

**Replacement.** All identified items are replaced with typed placeholders (`{COMPANY_1}`, `{PERSON_2}`, `{AMOUNT_1}`, etc.). Items sharing the same canonical identity receive the same placeholder. A mapping table (JSON) records every replacement with its position and surrounding context.

**De-anonymization.** When restoring, the tool uses a three-step strategy:
1. *Position-based matching* — restores placeholders found at or near their original positions
2. *Context-based fuzzy matching* — uses `difflib.SequenceMatcher` to match placeholders by surrounding text similarity (handles cases where the AI moved or reformatted content)
3. *Canonical fallback* — any remaining placeholders are replaced with the canonical name and flagged for manual review

## Quick Start

### Requirements

- Python 3.10+
- macOS (uses `textutil` for `.doc` file conversion — Linux/Windows users can use `.docx` and `.txt` only)

### Installation

```bash
git clone https://github.com/Reytian/Vibe-Coding-Legal-AI-Tools.git
cd Vibe-Coding-Legal-AI-Tools

pip install -r requirements.txt

cp .env.example .env
# Edit .env with your API credentials
```

### Configuration

Edit `.env` with any OpenAI-compatible API:

```
LLM_API_BASE=https://api.deepseek.com/v1
LLM_API_KEY=sk-your-key-here
LLM_MODEL=deepseek-chat
```

Or configure through the Settings page in the UI after launching.

### Run

```bash
streamlit run app.py
```

Open `http://localhost:8501` in your browser.

### Supported File Formats

| Input | Output |
|-------|--------|
| `.txt` | `.txt` |
| `.docx` | `.docx` (preserves formatting, headers, footers, properties) |
| `.doc` | `.doc` (via macOS `textutil` conversion) |

## Project Structure

```
├── app.py                  # Streamlit entry point + sidebar
├── core/
│   ├── anonymizer.py       # Two-pass scanning + replacement engine
│   ├── deanonymizer.py     # Three-step restoration engine
│   ├── file_handler.py     # File I/O, DOCX/DOC processing
│   ├── llm_client.py       # OpenAI-compatible API client
│   ├── prompts.py          # LLM prompt templates
│   └── section_detector.py # Key section detection (definitions, notices, signatures)
├── ui/
│   ├── anonymize_page.py   # Anonymization workflow UI
│   ├── deanonymize_page.py # Restoration workflow UI
│   └── settings_page.py    # API configuration UI
├── tests/
│   └── sample_contract.txt # Sample equity transfer agreement (fictitious)
├── data/
│   └── mappings/           # Saved mapping tables (gitignored)
├── requirements.txt
├── .env.example
└── .gitignore
```

## Roadmap: Fully Local Operation

This PoC validates the two-pass scanning and three-step restoration approach using a cloud API. The production roadmap is:

1. **Local LLM integration.** Replace the cloud API with a local model running via Ollama or vLLM. The tool already uses an OpenAI-compatible interface — switching to a local endpoint (`http://localhost:11434/v1`) requires only a config change, no code changes. Candidate models include Qwen 2.5, DeepSeek-V2, and Llama 3 variants with strong multilingual and instruction-following capabilities.
2. **One-click desktop app.** Package the Streamlit app + local model into a standalone desktop application so lawyers can run it without any technical setup.
3. **Encrypted mapping storage.** Encrypt mapping tables at rest so they cannot be read if the machine is compromised.
4. **Broader language support.** Expand prompt templates for additional languages and jurisdictions beyond the current bilingual (Chinese/English) contract support.

## Limitations

This is a proof-of-concept. Current limitations include:

- **Uses a cloud API for entity detection in this PoC.** The scanning step currently calls an external LLM API. This means the raw document text is sent to a third-party server during scanning. The production version will eliminate this by running the LLM locally. Until then, do not process real client documents through this tool unless you have configured a local model endpoint.
- Relies on LLM accuracy for entity detection — manual review of the entity list before anonymization is essential
- Prompt templates are currently optimized for bilingual (Chinese/English) contracts; pure English or other-language contracts may need prompt adjustments
- `.doc` support requires macOS `textutil`
- No encryption on mapping tables — store them securely

## License

MIT
