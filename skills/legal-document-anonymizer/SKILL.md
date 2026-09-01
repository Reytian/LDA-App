---
name: legal-document-anonymizer
description: Use when a user needs to anonymize confidential legal, commercial, or client documents before sharing them with Claude Code, ChatGPT, Claude, or any third-party AI tool, needs to restore third-party AI output using a local mapping table, or needs to improve LDA review UX when a high-recall first scan produces too many repetitive findings. Handles safe batch review, result-derived selection state, placeholder replacement, mapping custody, and de-anonymization.
author: Codex
version: 1.1.0
date: 2026-09-01
metadata:
  short-description: Anonymize legal documents before third-party AI use
---

# Legal Document Anonymizer

Use this skill whenever the user wants to process confidential documents with an outside AI tool while controlling how client-identifying details are handled.

## Core Privacy Rule

By default, only the anonymized output may leave the local machine. Never send the original file, extracted raw text, mapping JSON, Pass 1 results, entity inventory, or restoration output to a third-party AI service unless the user explicitly instructs otherwise after being warned.

Prefer a local LLM endpoint for scanning. If LDA is configured with a non-local API base, tell the user that the scan itself may disclose raw document text before processing real client material.

If the user expressly authorizes cloud or chat processing for quality and speed, including by saying they are using a business or enterprise plan and are not worried about confidentiality, proceed with the configured cloud scanner and allow Codex to inspect sensitive content in the chat. Still keep the mapping JSON local as the restoration key unless the user specifically asks to share or export it.

## Local LDA Location

Default project path:

```bash
/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer
```

If the project has moved, use `LDA_REPO` or pass `--repo` to the bundled helper script.

The existing LDA workflow is:

1. Read `.txt`, `.docx`, or `.doc`.
2. Pass 1: detect key sections and extract entity definitions, aliases, and document type.
3. User reviews Pass 1 aliases.
4. Pass 2: scan the whole document in segments with alias context.
5. User reviews the full sensitive entity list.
6. Replace entities with typed placeholders such as `{COMPANY_1}`, `{PERSON_2}`, `{DATE_1}`, and `{AMOUNT_1}`.
7. Save an anonymized file plus a local mapping JSON.
8. Send only the anonymized file or anonymized text to the third-party tool.
9. Restore the AI output locally with the mapping JSON.

## Recommended Codex Workflow

1. Run preflight and confirm whether scanning is local:

```bash
python scripts/lda_skill.py preflight
```

2. Scan the document:

```bash
python scripts/lda_skill.py scan "/path/to/document.docx" --out-dir "/path/to/local/output"
```

3. Review the generated entity inventory with the user. Look especially for missed parties, aliases, dates, amounts, addresses, emails, phone numbers, IDs, bank accounts, registration numbers, and signature-block details.

4. After approval, anonymize using the reviewed scan artifacts:

```bash
python scripts/lda_skill.py anonymize "/path/to/document.docx" --out-dir "/path/to/local/output" --pass1 "/path/to/pass1.json" --entities "/path/to/entities.json"
```

5. Send only the anonymized file to Claude Code or another third-party tool. Keep `mapping_*.json` local and out of prompts.

6. When the third-party AI returns a draft or analysis containing placeholders, restore it locally:

```bash
python scripts/lda_skill.py restore "/path/to/ai-output.docx" --mapping "/path/to/mapping.json" --out-dir "/path/to/local/output"
```

## Fast Path

If the user explicitly asks to proceed without an intermediate review, run:

```bash
python scripts/lda_skill.py anonymize "/path/to/document.docx" --out-dir "/path/to/local/output" --auto-scan
```

Still report that manual review is the safer path for legal material.

## Output Handling

The helper writes generic filenames so client names are not exposed through filenames:

- `pass1_*.json`
- `entities_*.json`
- `ANONYMIZED_<DOCUMENT_TYPE>.<ext>`
- `mapping_*.json`
- `RESTORED_DOCUMENT.<ext>`
- `manifest_*.json`

When summarizing results, provide counts and output paths, but do not paste mapping contents or original sensitive values into the chat unless the user explicitly asks.

## Review Standards

Before any third-party handoff, check for:

- No obvious names, companies, emails, phone numbers, addresses, account numbers, or signature details remain in the anonymized text.
- Placeholders are internally consistent for the same party or person.
- The anonymized document still preserves enough legal structure for useful drafting or analysis.
- The mapping file is stored locally in a matter-safe folder.

## Review UX Safety for High-Recall Scans

When a first scan produces many findings, reduce review effort without silently reducing privacy coverage:

- Keep every finding selected for redaction by default. Do not auto-deselect low-confidence findings or tighten detection merely to shorten the list unless the user explicitly accepts the recall tradeoff.
- Collapse exact repeated values into one review group, then provide native multi-selection and batch actions such as `Redact` and `Keep Visible` for unrelated false positives.
- Do not group merely similar values by punctuation or normalization unless mapping and pseudonym overrides also share one identity. Near-duplicate display grouping can otherwise create conflicting restoration behavior.
- Treat selected group IDs as state derived from the current result set. Clear them only when a successful re-scan replaces that result set. Preserve them when a scan is cancelled and the old results remain visible.

Verify batch acceptance, batch reversal, keyboard activation, and successful re-scan invalidation in model tests. If the project has no native UI test target, document a manual smoke test for Command-click, Shift-click, batch actions, and keyboard commands.

## Known Limits

- The scan depends on LLM extraction quality, so manual review matters.
- `.doc` support uses macOS `textutil`.
- `.docx` replacement preserves common formatting, headers, footers, tables, and properties, but complex fields may require manual inspection.
- If aliases and canonical names share one placeholder, restoration can remove all placeholders but still choose the wrong alias in a few locations. Review restored drafts before use.
- Mapping JSON is not encrypted by the current app. Treat it as confidential client material.
