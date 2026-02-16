# Legal Document Anonymizer

A tool that strips sensitive information from legal documents before they touch any cloud AI service, then restores it afterward. Built for lawyers who want to use consumer AI apps like ChatGPT, Claude, or Kimi — without violating client confidentiality.

## Why Anonymize Legal Documents?

Lawyers are bound by strict confidentiality rules. In the United States, ABA Model Rule 1.6 and its state equivalents (e.g., New York RPC 1.6) prohibit disclosing client information without informed consent. Similar obligations exist in virtually every jurisdiction worldwide — from the SRA Code in England and Wales to China's *Lawyers Law* (律师法) Article 38.

The problem is practical: modern AI tools are extraordinarily useful for legal work — drafting, translation, summarization, clause comparison, risk analysis — but every major AI platform processes user inputs on remote servers. When a lawyer pastes a merger agreement into ChatGPT, they are transmitting client names, deal terms, financial figures, and personal data to a third party. This creates real professional responsibility risk:

- **Disciplinary exposure.** Bar associations have begun issuing ethics opinions on AI use (e.g., NY State Bar Ethics Opinion 1238, Florida Bar Opinion 24-1). The consensus is clear: lawyers must take reasonable steps to prevent unauthorized disclosure when using cloud-based tools.
- **Data protection liability.** Cross-border agreements often contain personal data subject to GDPR, PIPL (China), or other privacy regimes. Uploading these documents to a US-based AI service without anonymization can constitute an unauthorized cross-border data transfer.
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
- **Cross-border work becomes safer.** A New York lawyer working on a Shanghai acquisition can run the anonymized agreement through any AI service without triggering PIPL cross-border transfer concerns, because no personal data leaves the local machine.
- **Preserve work product.** The mapping table serves as a local record of exactly what was redacted and restored, creating a defensible audit trail if a client or regulator ever asks how AI was used on their matter.
- **No vendor lock-in.** This tool works with any OpenAI-compatible LLM API. Use a cloud API during evaluation; switch to a local model (Ollama, vLLM) for production. The anonymization logic stays the same.

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
│   └── sample_contract.txt # Sample Chinese equity transfer agreement (fictitious)
├── data/
│   └── mappings/           # Saved mapping tables (gitignored)
├── requirements.txt
├── .env.example
└── .gitignore
```

## Limitations

This is a proof-of-concept. Current limitations include:

- Relies on LLM accuracy for entity detection — manual review of the entity list before anonymization is essential
- Prompt templates are optimized for Chinese legal documents (bilingual Chinese/English contracts work well; pure English contracts may need prompt adjustments)
- `.doc` support requires macOS `textutil`
- No encryption on mapping tables — store them securely

## License

MIT
