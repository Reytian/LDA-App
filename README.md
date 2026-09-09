# Legal Document Anonymizer

**By Forme Locale Studio**

[Download the Mac app](https://github.com/Reytian/LDA-App/releases/latest) · [Step-by-step user guide](docs/user-guide.md) · [Q&A](#questions-and-answers)

## Why LDA exists

AI can help lawyers draft, translate, summarize, and review documents. A useful
prompt, however, can also disclose a client's identity, negotiation position,
financial information, or an unannounced transaction. LDA helps you replace
sensitive details on your Mac before sharing a document, then restore those
details locally when the work comes back.

### A lawyer's duty of confidentiality

Confidentiality reaches beyond names and identification numbers. Under
[ABA Model Rule 1.6](https://www.americanbar.org/groups/professional_responsibility/publications/model_rules_of_professional_conduct/rule_1_6_confidentiality_of_information/),
information relating to a representation is protected, subject to informed
consent, implied authorization, and the rule's exceptions. Lawyers must also
take reasonable steps to prevent unauthorized disclosure or access. The Model
Rules are a reference framework; the rules adopted in the lawyer's jurisdiction
govern.

For example, [New York Rule 1.6(a) and (c)](https://www.nycourts.gov/LegacyPDFS/RULES/jointappellate/NY-Rules-Prof-Conduct-1200.pdf)
protect specified confidential client information and require reasonable efforts
against unauthorized disclosure, use, or access. A vendor's privacy promise does
not determine whether a particular disclosure is authorized.

[ABA Formal Opinion 512](https://www.americanbar.org/content/dam/aba/administrative/professional_responsibility/ethics-opinions/aba-formal-opinion-512.pdf)
applies these responsibilities to generative AI: understand the tool, assess who
can access submitted information, review its terms and privacy policies, and
address client consent where required. It does not impose a blanket ban on cloud
AI or require consent for every use.

### Why zero data retention is not enough on its own

**Zero data retention (ZDR) can reduce the risk created by stored prompts and
responses. Its limitation as a standalone safeguard is that the provider still
receives and processes what you submit.** A retention commitment does not remove
confidential facts from the request or decide whether you may disclose them.

The scope also matters:

- **Coverage depends on the service and feature.** OpenAI's API documentation
  distinguishes ZDR-eligible endpoints from features that may retain application
  state even when ZDR is enabled. It also describes model-specific exceptions
  subject to advance notice. A no-training setting alone is a different control.
  See [OpenAI's data controls](https://developers.openai.com/api/docs/guides/your-data).
- **An API agreement does not automatically cover a chat subscription.**
  Anthropic distinguishes eligible API and Claude Code configurations from
  consumer products and other interfaces. Its policy also identifies exceptions
  for flagged content and legal requirements. See
  [Anthropic's ZDR scope and exceptions](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention).
- **Connected services have their own policies.** A model provider's ZDR does
  not establish the retention policy of a third-party tool or integration. Check
  the complete workflow, including the app through which you access the model.
  See the third-party service provisions in the
  [OpenAI](https://developers.openai.com/api/docs/guides/your-data) and
  [Anthropic](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)
  documentation.

LDA addresses an earlier step: reducing the sensitive information in the material
you choose to send. Use it alongside appropriate vendor controls, client
instructions, and professional judgment. Neither LDA nor ZDR guarantees that a
document is safe to disclose. Provider-policy references were checked on
September 9, 2026; verify the terms and settings for your own account.

## Native macOS app

LDA is an offline legal privacy workspace for macOS. The native app in
`macos/LDACore` anonymizes and restores documents,
fills drafts from encrypted profiles, and organizes work in privacy-safe matter
workspaces. The distributable app is sandboxed, signed with Developer ID, and
notarized by Apple. Its one network permission exists solely so the model
manager can fetch a detection model you pick. Document processing runs on-device.
You choose which reviewed export to share with an external AI app, whose own
privacy terms then apply.

## Install the macOS app

You need an **Apple Silicon Mac, macOS 14 or later, and at least 16 GB of memory**.

1. Open the [latest app release](https://github.com/Reytian/LDA-App/releases/latest)
   and download **LDA-notarized.zip** from **Assets**.
2. Double-click the ZIP in Finder, then drag **LDA.app** into **Applications**.
3. Open LDA from Applications. Choose your language and a detection model in
   the setup wizard. **Quick** is the starting option for a 16 GB Mac.
4. Wait for the model download and verification to finish, or use **Add Model
   File** to import a compatible model you already have.

The app and detection model are separate downloads. The September 4 version 1.1
app archive is approximately 5.3 MB; the Quick model is approximately 2.74 GB.
Later packages may differ in size. No cloud API key is required for the Mac app.

Without a model, **Patterns only** can find structured items such as emails,
phone numbers, dates, amounts, IDs, and case numbers. It does **not** detect
people's names, company names, or addresses. For an offline Mac, use the
[model import instructions](macos/LDACore/README.md#installing-a-detection-model).

For download verification, also download **SHA256SUMS.txt** into the same folder
as the ZIP and follow the [checksum instructions](docs/user-guide.md#verify-the-download-optional).

## Your first document

1. Open **De-identify** and choose **Choose Files**, or drop a document into LDA.
2. Choose **Scan for PII** and wait for the scan to finish.
3. Review the findings. Protect missed text and read **Safe Preview**, including
   any remaining details that could identify the client or matter.
4. Choose **Export for AI**. LDA saves a redacted Markdown file and an encrypted
   **.ldamap** file beside it. Keep the mapping on your Mac.
5. Open and check the exported Markdown file. Send only that reviewed file to
   your chosen AI service and ask it to preserve the placeholders exactly.
6. Save the AI's result, open **Restore** in LDA, and select the returned file.
   Use the matching local mapping, then review and save the restored result.

Start with a fictional document. The [full user guide](docs/user-guide.md)
explains each step, profile filling, optional AI-app integration, and common
problems. Labels can vary by version; older builds may call De-identify
**Anonymize**.

## macOS App: Fill from Profile

The native macOS version of LDA (in `macos/LDACore`) adds a fill-from-profile
feature that extracts structured company facts from source documents (certificates,
articles, registry printouts) and uses them to auto-fill blanks in draft agreements
and AcroForm PDFs, all on-device. Profiles are saved as
AES-GCM encrypted `.ldaprofile` files; no plaintext profile data is written to
disk. The feature supports `.docx` (text-span blanks) and `.pdf` (AcroForm text
widgets) as fill targets, and uses a review-first posture so you inspect proposed
fills before they are applied. A built-in portfolio library (stored in Application
Support, key in the macOS Keychain) lets you browse, create, edit, fill, export,
import, and delete portfolios for three subject kinds: company, individual, and
general. Full CLI usage, library commands, and V1 limits are documented in
[macos/LDACore/README.md](macos/LDACore/README.md).

## Questions and answers

### The basics

**What does LDA do?**

LDA replaces selected sensitive information with placeholders such as
`{PERSON_1}` and `{COMPANY_1}`. You can work on the protected copy in another
app, then use LDA's local mapping to put the original values back. It also
supports reusable encrypted profiles for filling documents.

**Is LDA an AI chatbot? Do I need an API key?**

LDA is a local document tool. Its detection model runs on your Mac; the native
app does not require a cloud API key. If you send the protected copy to ChatGPT,
Claude, or another service, that service has its own account, pricing, and terms.
The Python prototype's API instructions below do not apply to LDA.app.

**What can I import, and what will I get back?**

The Mac app accepts Word `.docx`, PDF, and text documents. **Export for AI**
produces Markdown text plus an encrypted mapping. Restore accepts Word,
Markdown, and text files. The Markdown route does not preserve the original
Word or PDF layout. PDF import is not a promise to produce a visually redacted
PDF; inspect the actual exported file before sharing it. See the
[guide's format notes](docs/user-guide.md#file-formats-and-layout).

**Will it detect everything?**

No. Pattern matching, local models, and OCR can all miss information. Names,
companies, and addresses require a model. Review detected items, protect missed
text, and consider the remaining context: unusual facts can identify a matter
even after names are replaced. Safe Preview is a review view, not a certification.

### Data privacy

**Does LDA upload my documents or train a cloud model on them?**

The native app's scanning, replacement, profile filling, and restoration run
on-device. Its document-processing pipeline does not upload documents for
inference or training. The model manager connects to a download host when you
request a model; that host can see ordinary connection information such as your
IP address, but the download does not require your documents.

**What does an external AI service see?**

It sees the file or text you send, your prompt, and any other context your AI app
provides. Protected values are replaced in LDA's export, but missed or deliberately
retained details remain readable. Keep original files, mappings, profiles, and
passwords out of the conversation. An optional LDA integration does not control
other tools, attachments, or filesystem access available to that AI app.

**Can I use LDA fully offline?**

Yes, once a compatible detection model is installed or imported. Local
de-identification, filling, and restoration need no internet connection. Using
an external cloud AI service is a separate online step. You can also work on the
protected copy in a local editor or local AI tool.

**Where are the original values kept?**

LDA keeps restoration mappings and saved profiles encrypted locally, with
Keychain or passphrase protection depending on the workflow. **Export for AI**
saves a Keychain-protected `.ldamap` beside the Markdown file. It needs the
corresponding key to restore values; copying that file alone to another Mac is
not a recovery plan. Keep protected backups and preserve any passphrase you use.
Your original source files and restored or filled exports still contain real
information and need their own access and backup controls.

**Does local processing stop iCloud, backups, or clipboard tools from copying files?**

No. LDA does not control those services. A file saved in a synced folder can be
uploaded by the sync client. Clipboard history, screenshots, and other apps can
also create copies. Choose storage and sharing tools appropriate to the matter.

**Does de-identification remove confidentiality or GDPR obligations?**

Not automatically. LDA is deliberately reversible. Where a mapping can reconnect
personal data to an individual, do not assume irreversible anonymization; GDPR
Article 4(5) and Recital 26 distinguish pseudonymisation and identifiability.
Remaining text may also reveal confidential facts unrelated to personal data.
Assess the actual output, recipient, applicable rules, and client instructions
before sharing. See [GDPR](https://eur-lex.europa.eu/legal-content/EN-NL/TXT/?uri=CELEX%3A32016R0679)
and the [confidentiality introduction](#a-lawyers-duty-of-confidentiality).

**Should I still use ZDR or other vendor privacy controls?**

Yes, where suitable and available. Reducing what you submit and limiting what a
provider retains address different risks. Check that the controls cover the exact
product, account, model, and features you use. See
[why ZDR is not enough on its own](#why-zero-data-retention-is-not-enough-on-its-own).

### License and permitted use

**What license applies to LDA?**

The current source is licensed under **GNU GPL version 3 only (GPL-3.0-only)**.
Copyright remains with Haotian Yi, with Forme Locale Studio credited as creator.
The [LICENSE](LICENSE) contains the governing terms. Copies previously released
under MIT retain their applicable MIT permissions; libraries and models keep
their own licenses. Check the license supplied with your particular release.

**Can I use it for paid client work or in a large firm?**

Yes. The GPL permits commercial use and does not impose a firm-size limit or an
enterprise fee merely for running the program. Using LDA internally does not
require you to publish your client work. See [GPL section 2](LICENSE).

**Do my contracts, client documents, or outputs become open source?**

No. Merely processing a document with LDA does not put it under the GPL or
require you to disclose it. The license applies to the software; GPL section 2
addresses when software output is itself a covered work. See [LICENSE](LICENSE).

**Can I modify, redistribute, or sell LDA?**

Yes, subject to the GPL. When distributing covered software, preserve the required
notices and license, identify modifications, and satisfy the corresponding-source
requirements for distributed binaries. Covered modified versions remain under
the GPL, including its applicable interactive-interface notice requirements.
Private modifications need not be published merely because you use them
internally. See [GPL sections 2, 4, 5, and 6](LICENSE).

**Does the license include a warranty or a compliance guarantee?**

The GPL includes warranty disclaimers and liability limitations, subject to
applicable law and any separate written agreement. LDA does not certify a
document as legally safe to disclose. See [GPL sections 15 and 16](LICENSE).

## Build from source

Requirements: Apple Silicon Mac running macOS 14 or later.

```bash
cd macos/LDACore
swift test
./packaging/package-app.sh
open "$HOME/Developer/lda-dist/LDA.app"
```

The packaging script builds a model-less app by default, which is the shipping
configuration: LDA asks for a detection model on first run and either downloads
it or accepts a file you add. Set `BUNDLE_MODEL=1` with `MODEL_PATH` pointing at
the Quick GGUF to build a single-file distributable instead; the script verifies
that file's SHA-256 against the app's own catalog and refuses to bundle anything
else. Document processing needs no network in any configuration; downloading a
model does. See `macos/LDACore/README.md` for the two model-installation paths.

## Legacy Python proof of concept

<details>
<summary>Developer reference: the earlier Python/Streamlit prototype</summary>

The material below describes the historical prototype, including its cloud API
configuration and then-planned features. It does not describe the native Mac
app. LDA.app already processes documents locally and uses encrypted mappings;
its installation does not require Python, Streamlit, or an API key.

The prototype can transmit original document text to the configured API. Use
fictional data for evaluation unless you have configured an appropriate local
endpoint and assessed the workflow.

### How It Works

The tool uses a two-pass LLM scanning approach:

**Pass 1: Entity Definition Extraction.** The tool identifies key sections of the document (recitals, definitions, notice clauses, signature pages) and asks the LLM to extract entity definitions and alias relationships. For example: *"Party A" = "Shanghai Xingchen Technology Co., Ltd." = "the Transferor"*.

**Pass 2: Full Document Scan.** Armed with the alias context from Pass 1, the tool scans the entire document segment by segment, identifying every sensitive item: names, companies, amounts, phone numbers, emails, ID numbers, bank accounts, addresses, registration numbers, and dates.

**Replacement.** All identified items are replaced with typed placeholders (`{COMPANY_1}`, `{PERSON_2}`, `{AMOUNT_1}`, etc.). Items sharing the same canonical identity receive the same placeholder. A mapping table (JSON) records every replacement with its position and surrounding context.

**De-anonymization.** When restoring, the tool uses a three-step strategy:
1. *Position-based matching* restores placeholders found at or near their original positions
2. *Context-based fuzzy matching* uses `difflib.SequenceMatcher` to match placeholders by surrounding text similarity (handles cases where the AI moved or reformatted content)
3. *Canonical fallback* replaces any remaining placeholders with the canonical name and flags them for manual review

### Quick Start

#### Requirements

- Python 3.10+
- macOS (uses `textutil` for `.doc` file conversion; Linux/Windows users can use `.docx` and `.txt` only)

#### Installation

```bash
git clone https://github.com/Reytian/Vibe-Coding-Legal-AI-Tools.git
cd Vibe-Coding-Legal-AI-Tools

pip install -r requirements.txt

cp .env.example .env
# Edit .env with your API credentials
```

#### Configuration

Edit `.env` with any OpenAI-compatible API:

```
LLM_API_BASE=https://api.deepseek.com/v1
LLM_API_KEY=sk-your-key-here
LLM_MODEL=deepseek-chat
```

Or configure through the Settings page in the UI after launching.

#### Run

```bash
streamlit run app.py
```

Open `http://localhost:8501` in your browser.

#### Supported File Formats

| Input | Output |
|-------|--------|
| `.txt` | `.txt` |
| `.docx` | `.docx` (preserves formatting, headers, footers, properties) |
| `.doc` | `.doc` (via macOS `textutil` conversion) |

### Project Structure

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

### Roadmap: Fully Local Operation

This PoC validates the two-pass scanning and three-step restoration approach using a cloud API. The production roadmap is:

1. **Local LLM integration.** Replace the cloud API with a local model running via Ollama or vLLM. The tool already uses an OpenAI-compatible interface, so switching to a local endpoint (`http://localhost:11434/v1`) requires only a config change, no code changes. Candidate models include Qwen 2.5, DeepSeek-V2, and Llama 3 variants with strong multilingual and instruction-following capabilities.
2. **One-click desktop app.** Package the Streamlit app + local model into a standalone desktop application so lawyers can run it without any technical setup.
3. **Encrypted mapping storage.** Encrypt mapping tables at rest so they cannot be read if the machine is compromised.
4. **Broader language support.** Expand prompt templates for additional languages and jurisdictions beyond the current bilingual (Chinese/English) contract support.

### Limitations

This is a proof-of-concept. Current limitations include:

- **Uses a cloud API for entity detection in this PoC.** The scanning step currently calls an external LLM API. This means the raw document text is sent to a third-party server during scanning. The production version will eliminate this by running the LLM locally. Until then, do not process real client documents through this tool unless you have configured a local model endpoint.
- Relies on LLM accuracy for entity detection; manual review of the entity list before anonymization is essential
- Prompt templates are currently optimized for bilingual (Chinese/English) contracts; pure English or other-language contracts may need prompt adjustments
- `.doc` support requires macOS `textutil`
- No encryption on mapping tables; store them securely

</details>

## License

Copyright (c) 2026 Haotian Yi. Created by **Forme Locale Studio**.

LDA is free software licensed under the **GNU General Public License, version 3
only** (`GPL-3.0-only`). You may use, modify, and redistribute it under the terms
of the [full license](LICENSE). It is provided without any warranty, including
any implied warranty of merchantability or fitness for a particular purpose.

Third-party libraries and detection models retain their own licenses. Versions
previously released under the MIT License remain available under that license.
