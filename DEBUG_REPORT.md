# Legal Document Anonymizer: Debugging Report

**Summary:** 17 confirmed bugs. By severity: 1 CRITICAL, 8 HIGH, 6 MEDIUM, 2 LOW. The CRITICAL and several HIGH bugs are silent PII leaks or irreversible data loss in the tool's core anonymization and round-trip paths.

## Bug Table

| Severity | File:Line | Title |
|----------|-----------|-------|
| CRITICAL | core/file_handler.py:115-126 | PII inside hyperlink runs is never anonymized (leaks into output document) |
| HIGH | core/anonymizer.py:272-306 | Short entity text collides with digits/letters inside already-inserted placeholders, corrupting output |
| HIGH | core/anonymizer.py:269-270 | Same surface text shared by two canonical groups is overwritten, restoring the wrong entity |
| HIGH | core/anonymizer.py:254-261 | Multi-token entity type produces a placeholder the deanonymizer regex can never match |
| HIGH | core/llm_client.py:106-117 | parse_json_response returns a dict for a single-entity array in prose, dropping entities |
| HIGH | core/llm_client.py:62 | call_llm blindly indexes choices[0], raising on HTTP-200 error envelopes; swallowed in Pass-2 |
| HIGH | core/llm_client.py:52-61 | Non-200 responses and timeouts swallowed segment-by-segment, partial output presented as complete |
| HIGH | core/file_handler.py:121-126, 161-163, 177-178, 241-265 | Cascading text replacement corrupts placeholders and causes irreversible data loss |
| HIGH | core/file_handler.py:128-137 | Nested tables (table inside a cell) are not processed, leaving PII unredacted |
| MEDIUM | core/file_handler.py:123-126 | Per-run formatting is destroyed on any paragraph that contains a replacement |
| MEDIUM | ui/deanonymize_page.py:100-171 | Restoration results and download button live inside the button block, wiped on click |
| MEDIUM | ui/anonymize_page.py:307-311 | Full plaintext PII mapping auto-saved to disk on every run, errors silently swallowed |
| MEDIUM | ui/anonymize_page.py:110-114 | data_editor widget state for alias/entity tables never cleared on new upload |
| MEDIUM | skills/legal-document-anonymizer/scripts/lda_skill.py:246-271 | restore: same-format failure aborts entire restoration with no .txt fallback |
| MEDIUM | skills/legal-document-anonymizer/scripts/lda_skill.py:212-229 | anonymize: same-format failure aborts before mapping is written, losing restoration key |
| LOW | core/file_handler.py:79 | _read_doc builds txt temp path with str.replace, replacing every '.doc' in the path |
| LOW | ui/settings_page.py:74-78 | API key written to .env in plaintext with default (world-readable) permissions |

---

## CRITICAL

### 1. PII inside hyperlink runs is never anonymized (leaks into output document)

**File:** core/file_handler.py:115-126

**Problem:** `_replace_in_paragraph` operates on `para.runs`. In python-docx 1.2.0 (the installed version), `Paragraph.runs` returns only direct `<w:r>` children of the paragraph and excludes runs nested inside `<w:hyperlink>` elements. However, `para.text` (used by `_read_docx` to feed the LLM) does include hyperlink display text. The model therefore sees the PII and creates a mapping for it, but the actual DOCX rewrite skips it.

**Failure scenario:** A legal document contains a mailto: link or an external URL whose display text is a person or company name (e.g. "John Smith"). The model maps it, the preview claims it was removed, but the delivered .docx still contains the sensitive text inside the hyperlink. This is a silent, undetectable-from-the-mapping leak of exactly the data the tool exists to scrub. Headers, footers, and tables reuse the same function, so hyperlinks there leak too.

**Evidence:** A paragraph with a normal run "Contact " plus a hyperlink run "John Smith" yields `para.text == 'Contact John Smith'` but `[r.text for r in para.runs] == ['Contact ']`. After `apply_replacements_to_docx(bytes, [('John Smith','[PERSON_1]')])` the output body text was still "Contact John Smith" (unchanged). The function is the real production rewrite path (called from ui/anonymize_page.py:241 and the skill script at line 100).

**Suggested fix:** Iterate the underlying XML runs including those under hyperlinks (e.g. `para._p.findall('.//' + qn('w:r'))` and reconstruct text from their `w:t` children), or use the `iter_inner_content()` API, instead of relying on `para.runs`. Apply the same join-then-replace logic across all runs (including hyperlink runs) in the paragraph.

---

## HIGH

### 2. Short entity text collides with digits/letters inside already-inserted placeholders, corrupting the anonymized output

**File:** core/anonymizer.py:272-306

**Problem:** Step 2 replacement sorts entity strings longest-first (line 273) and replaces with `str.find` on the progressively-mutated `anonymized_text` (lines 278-306). Longest-first only prevents entity-vs-entity substring conflicts; it does not prevent a later, shorter entity from matching text that lives inside a placeholder an earlier replacement already inserted. Placeholders look like `{COMPANY_1}`, so a short entity whose literal text is "1" (a date, amount, or page number) matches the "1" inside `{COMPANY_1}` and rewrites it.

**Failure scenario:** The shareable anonymized document is corrupted with nested garbage like `{COMPANY_{AMOUNT_1}}`, and the deanonymize position log no longer points at intact placeholders. Triggered when a short numeric entity (single digit or letter) is in the extracted entity set. prompts.py:72 explicitly lists amount, id, and date types that can legitimately be single characters or short numerics, and there is no minimum-length guard anywhere.

**Evidence:** With text "Invoice number 1 for Alpha Beta Company. Quantity: 1 unit." and entities `[{'text':'Alpha Beta Company','type':'company'}, {'text':'1','type':'amount'}]`, `execute_replacement` produced "Invoice number {AMOUNT_1} for {COMPANY_{AMOUNT_1}}. Quantity: {AMOUNT_1} unit." plus a phantom log entry at position 39 pointing inside a placeholder.

**Suggested fix:** Compute all match spans against the original text, resolve overlaps once (longest-first), then build the output in a single left-to-right pass so no inserted placeholder is ever re-scanned. Alternatively, mask already-replaced regions, or reject entity texts that are pure substrings of the placeholder grammar (e.g. bare digits).

---

### 3. Same surface text shared by two canonical groups is overwritten, restoring the wrong entity

**File:** core/anonymizer.py:269-270

**Problem:** `text_to_placeholder` maps each surface string to a single placeholder via `for t in group_info["texts"]: text_to_placeholder[t] = placeholder`. When the same surface text legitimately belongs to two different canonical groups (e.g. "Smith" as an alias of the person "John Smith" and of the company "Smith Corp"), the loop over `canonical_groups` overwrites the earlier mapping with the later group's placeholder.

**Failure scenario:** Every occurrence of that surface text is replaced with the wrong placeholder and restored as the wrong entity, silently attributing one party's text to another. The Pass-2 dedup at line 162 keys on (text, type), so two entities with identical text but different types both survive and seed two distinct groups, making this reachable through the real pipeline.

**Evidence:** Entities "Smith" under group John Smith (person) and "Smith" under group Smith Corp (company) on text "Smith Corp hired John Smith. Smith is the CEO." produced restored output "Smith Corp hired Smith. John Smith is the CEO." Roundtrip match vs original: False. The standalone person "Smith" was mis-restored.

**Suggested fix:** `text_to_placeholder` cannot be a flat string-to-placeholder dict when surface strings are ambiguous. Detect collisions when assigning (line 270) and either keep per-occurrence context-aware decisions, or at minimum log and refuse to silently overwrite. Practically, resolve ambiguity using the surrounding context already captured in `replacement_log` rather than a global last-writer-wins map.

---

### 4. Multi-token / spaced entity type produces a placeholder the deanonymizer regex can never match

**File:** core/anonymizer.py:254-261

**Problem:** The placeholder is built as `'{' + entity_type.upper() + '_' + N + '}'` with no sanitization. `entity_type` comes straight from the LLM JSON and is not validated against an allowlist. If the model returns a type containing a space or underscore (e.g. "reg num", "reg_num", "bank account"), the placeholder becomes `{REG NUM_1}` or `{REG_NUM_1}`. The deanonymizer's recovery regex is `\{[A-Z]+_\d+\}` (deanonymizer.py lines 77, 137, 185), which requires a single A-Z token immediately before _digits and matches neither form.

**Failure scenario:** Two consequences. (1) `restore_by_context` and `restore_by_canonical` can never recover these placeholders, so if position-based restore fails (any document edit beyond +/-50 chars) the placeholder stays in the text forever and the original PII is unrecoverable. (2) `run_deanonymize`'s remaining count uses the same regex (line 185) and reports `remaining_placeholders=0` even though `{REG NUM_1}` is literally still in the output, falsely telling the user restoration was complete. The type is fully model-controlled, and the documented production target (local Ollama gemma4-v4) is prone to format drift.

**Evidence:** Entity `{'text':'91310000XYZ','type':'reg num'}` produced "Reg: {REG NUM_1} end." After prepending text to drift position, `run_deanonymize` returned `{'position_matched':0,'context_matched':0,'fallback_count':0,'remaining_placeholders':0}` while the output still literally contained `{REG NUM_1}`, and `re.findall(r'\{[A-Z]+_\d+\}', restored) == []`.

**Suggested fix:** Sanitize the type before building the placeholder: validate against the known type allowlist and slugify (uppercase, strip spaces, collapse to a single `[A-Z0-9]` token) so it always conforms to the recovery regex. Alternatively broaden the deanonymizer regex to match the actual placeholder grammar. Either way, `run_deanonymize`'s remaining-placeholder count must detect the same placeholder shape that anonymize emits (e.g. scan the mapping keys), so it cannot report 0 while placeholders persist.

---

### 5. parse_json_response returns a dict for a single-entity array wrapped in prose, causing Pass-2 to silently drop entities

**File:** core/llm_client.py:106-117

**Problem:** The brace/bracket fallback tries the object delimiters (`{`, `}`) before the array delimiters (`[`, `]`). When the model returns a JSON array containing exactly one entity object wrapped in explanatory prose (so `json.loads` on the raw and cleaned text fails), `text.find('{')...text.rfind('}')` slices out just the single object, which is itself valid JSON. The function returns a dict instead of a list.

**Failure scenario:** In `run_second_pass` (core/anonymizer.py:152) the result is gated by `if isinstance(entities, list)`, so a dict is silently discarded with no else branch and no log. That segment's detected sensitive items are never added, never replaced, never logged. The Pass-2 prompt's own example block (prompts.py:69-75) shows a single object inside the array, so single-item responses are a realistic, common case, and prose-wrapping is exactly what the fallback exists to handle.

**Evidence:** Input `'I found one sensitive item:\n[\n  {"text": "Acme Corp", "type": "company", "canonical": ""}\n]\nDone.'` returns a dict `{'text':'Acme Corp',...}` rather than a list. Caller at core/anonymizer.py:152 drops it with no else branch and no log.

**Suggested fix:** Try the array delimiters before the object delimiters when a list is expected, or have `parse_json_response` normalize a bare object into a one-element list when context indicates an array was expected. In `run_second_pass`, if a dict with a 'text' key is returned, treat it as a one-element list, and log a warning whenever a non-list is returned so the drop is never silent.

---

### 6. call_llm blindly indexes choices[0], raising on HTTP-200 error envelopes; swallowed in Pass-2 leaking the segment's PII

**File:** core/llm_client.py:62

**Problem:** `call_llm` returns `response.json()["choices"][0]["message"]["content"]` with no validation. Many OpenAI-compatible gateways (and the local Ollama/OpenRouter proxies this tool targets) return HTTP 200 with a body that has no 'choices' key (e.g. `{"error": {...}}` for rate limiting or content filtering) or an empty 'choices' list. `raise_for_status()` does not catch these because the status is 200, so the indexing raises KeyError/IndexError.

**Failure scenario:** In `run_second_pass` (core/anonymizer.py:149-156) the call is inside a broad `except Exception` that prints to stdout and `continue`s, so the entire segment is skipped: its entities are never extracted or replaced, and the only signal is a `print()` the Streamlit UI never surfaces. Result: silent PII leakage for any segment whose API call returns a 200 error envelope or truncated body. Pass-1 does not have this swallowing wrapper.

**Evidence:** Indexing `{'error': {...}}` raises KeyError 'choices'; indexing `{'choices': []}` raises IndexError. core/anonymizer.py:154-156 catches with `except Exception as e: print(...); continue`, dropping the segment silently. The UI shows "Scan complete!" regardless.

**Suggested fix:** In `call_llm`, parse `response.json()` defensively: check that 'choices' exists and is non-empty and that an error key is absent; if the body contains an 'error' field or no usable content, raise a descriptive exception. Separately, in `run_second_pass` do not silently continue on failure: track failed segments and surface them to the UI so the user knows the output may be incomplete.

---

### 7. Non-200 responses and timeouts swallowed segment-by-segment, partial output presented as complete

**File:** core/llm_client.py:52-61

**Problem:** `call_llm` uses `requests.post(..., timeout=120)` and `response.raise_for_status()`. On a non-200 (HTTPError) or a connect/read timeout the function raises, which is correct in isolation. The problem is the contract with the Pass-2 caller: `run_second_pass` wraps each segment call in `except Exception` and continues, so a transient 429, 500, or timeout on any segment silently removes that segment's entities while the overall job still succeeds. There is no retry in `call_llm` and no per-segment failure accounting.

**Failure scenario:** A multi-segment document (text over the 10000-char max, or a paragraph forcing a sentence split) hits a single flaky network blip on one segment, yielding a document that looks anonymized but still contains PII from the failed segment. Both callers treat the partial result as complete: ui/anonymize_page.py shows "Scan complete!" and the skill script has no per-segment failure accounting.

**Evidence:** Lines 52-61 perform a single POST with no retry; line 61 `raise_for_status()` turns 4xx/5xx into HTTPError. Combined with core/anonymizer.py:154 `except Exception` + continue, any raised error from one segment is dropped without affecting the reported outcome.

**Suggested fix:** Add a bounded retry with backoff for transient failures (timeouts, 429, 5xx) inside `call_llm`, and change the Pass-2 loop so segment failures are collected and reported to the user (fail loud) instead of being swallowed, so a partially-processed document is never presented as fully anonymized.

---

### 8. Cascading text replacement corrupts placeholders and causes irreversible data loss

**File:** core/file_handler.py:121-126, 161-163, 177-178, 241-265

**Problem:** `build_replacement_pairs()` returns pairs sorted only by `old_text` length (longest first), and every replace path (`_replace_in_paragraph`, core_properties, extended-properties XML) applies them sequentially via `str.replace` on the accumulating result. For anonymization the pairs are value-to-placeholder. Placeholders have the form `{TYPE_N}` where N is a digit. When a short numeric PII value (an amount "1", a date fragment "2") is a replacement key, it matches the digit inside a placeholder inserted earlier in the same loop, so `{PERSON_1}` becomes `{PERSON_{AMOUNT_1}}`.

**Failure scenario:** Because the mapping JSON key `{PERSON_1}` no longer appears literally in the document, de-anonymization can never restore it: reverse replacement turns the corrupted text back into the literal `{PERSON_1}` and the original name "John" is permanently lost. This breaks the core round-trip guarantee. Scope: confined to the DOCX/DOC same-format export path (the headline same-format output feature, invoked from ui/anonymize_page.py:239-245 and the skill). The plain-text path in core/anonymizer.py is safe because it advances `search_start` past inserted placeholders.

**Evidence:** Mapping `{'{PERSON_1}': {'value':'John'}, '{AMOUNT_1}': {'value':'1'}}`. Forward "John owes 1 unit." became "{PERSON_{AMOUNT_1}} owes {AMOUNT_1} unit." and reverse became "{PERSON_1} owes 1 unit." The name "John" is gone.

**Suggested fix:** Do not apply replacements as a chained sequence of independent `str.replace` calls. Scan the text once and replace non-overlapping matches in a single left-to-right pass (e.g. build a combined regex with `re.escape` of all keys, ordered longest-first, and substitute via a single `re.sub` with a lookup function), so text already emitted as a placeholder is never re-scanned for subsequent keys.

---

### 9. Nested tables (table inside a cell) are not processed, leaving PII unredacted

**File:** core/file_handler.py:128-137

**Problem:** `_replace_in_container` processes `container.tables` one level deep and, for each cell, processes only `cell.paragraphs`. It does not recurse into `cell.tables`. DOCX supports tables nested inside table cells, which are common in legal exhibits and schedules. PII located in a nested table is left untouched in the output, another silent leak. The function is not recursive despite its generic name.

**Failure scenario:** A legal exhibit with a table nested inside a cell carries PII (e.g. a party name) in the inner table. The outer cell's direct text is redacted, but the nested cell survives untouched. `_read_docx` also only reads `doc.paragraphs`, so table text (top-level or nested) is never even shown to the LLM, compounding the gap.

**Evidence:** Lines 133-137 iterate table.rows -> row.cells -> cell.paragraphs only, with no recursive call back into `_replace_in_container(cell)`. An empirical test against python-docx 1.2.0 with an outer cell containing both "John Smith" (direct) and a nested table containing "Jane Doe" showed John Smith redacted to [PERSON_1] while Jane Doe survived. The nested-table doc also read back as empty string from `_read_docx`.

**Suggested fix:** Make `_replace_in_container` recursive: for each cell, call `_replace_in_container(cell)` so nested tables are handled, and ensure table and cell text (including nested) is included when extracting text for the LLM in `_read_docx`.

---

## MEDIUM

### 10. Per-run formatting is destroyed on any paragraph that contains a replacement

**File:** core/file_handler.py:123-126

**Problem:** When a replacement occurs, the entire joined paragraph text is written into `runs[0]` and all other runs are blanked (`runs[0].text = new_text; for run in runs[1:]: run.text = ""`). This collapses every run in the paragraph into the formatting of the first run. Any bold, italic, underline, font-size, or color distinctions among runs are lost. The docstring claims it preserves formatting, but it only preserves paragraph-level formatting.

**Failure scenario:** A paragraph contains a bolded defined term or a differently-styled signature name in the same paragraph as a replaced entity. After anonymization, all that intra-paragraph styling is flattened to the first run's style. Multi-run paragraphs are extremely common in real Word documents (Word fragments runs on spell-check boundaries, formatting changes, and revision markers), so this triggers readily. No content is lost and redaction still succeeds, hence MEDIUM.

**Evidence:** Lines 124-126: `runs[0].text = new_text; for run in runs[1:]: run.text = ""`. All styling carried by `runs[1:]` is discarded whenever `new_text != full_text`. Called from ui/anonymize_page.py:241, ui/deanonymize_page.py:114, core/file_handler.py:221, and the skill script.

**Suggested fix:** Map the replacement back onto the original run boundaries: compute character offsets of each run in the joined string, then rewrite each run's text in place so unaffected runs keep their original formatting. Only runs overlapping a replaced span need modification.

---

### 11. Restoration results and download button live inside the button block, wiped on click

**File:** ui/deanonymize_page.py:100-171

**Problem:** The entire results section, including the `st.download_button`, is nested inside `if st.button("Execute Restoration"):`. In Streamlit, clicking any widget (including a download_button) triggers a full script rerun. On that rerun, `st.button("Execute Restoration")` returns False, so the whole block at lines 100-171 is skipped and nothing is rendered. `restored_text`, `stats`, and `restored_file_bytes` are local variables never stored in `session_state`.

**Failure scenario:** User uploads file and mapping, clicks "Execute Restoration", sees stats and the download button. They click "Download restored file". The browser does receive that one download (bytes were bound at render time), but the page immediately reruns and the results, metrics, preview, and download button all vanish. To download again, the user must re-click "Execute Restoration", re-invoking `run_deanonymize`. The UI gives the strong impression the action failed. `run_deanonymize` is pure Python (no LLM call), so the recompute is cheap, hence MEDIUM rather than HIGH.

**Evidence:** Line 100: `if st.button("Execute Restoration", type="primary"):` then results computed as locals (line 103) and rendered at lines 121-171 all inside the if-block. `restored_text` and `restored_file_bytes` are never written to `st.session_state`.

**Suggested fix:** Store `restored_text`, `stats`, `restored_file_bytes`, and `file_ext`/`base_name` in `st.session_state` when the button is clicked, then render the results and download_button outside the button conditional based on the presence of session_state values. Mirror the pattern used on the anonymize page.

---

### 12. Full plaintext PII mapping auto-saved to disk on every run, errors silently swallowed

**File:** ui/anonymize_page.py:307-311

**Problem:** After a successful anonymization, the app unconditionally calls `save_mapping(st.session_state.mapping_data, "anonymized")`, which writes the complete mapping (every original sensitive value: names, addresses, emails, phone numbers, amounts) as plaintext JSON into `data/mappings/`. There is no user opt-in, and the surrounding `try/except Exception: pass` swallows any failure silently, so the user is never told whether the sensitive file was written.

**Failure scenario:** The de-anonymization key (the most sensitive artifact in the pipeline) is persisted to disk on every run with no cleanup, no encryption, no permission restriction, and no notice on failure. The app's own sidebar warns "Do not process real client files" precisely because it is a PoC. The download button at line 300 already gives the user the mapping; the silent disk write is an additional hidden copy.

**Evidence:** Lines 307-311: `try: save_path = save_mapping(...); st.caption(...) except Exception: pass`. `save_mapping` (core/file_handler.py:268-288) writes the dict via `json.dump` to `data/mappings/` with no encryption and no permission restriction. The mapping contains canonical "value", "aliases", and "replacement_log" "original_text".

**Suggested fix:** Make the on-disk save opt-in (a checkbox) or remove it entirely and rely on the download button. At minimum, do not swallow the exception silently: surface a warning so the user knows whether the sensitive mapping was written. Consider restrictive file permissions (0600) on any persisted mapping.

---

### 13. data_editor widget state for alias/entity tables never cleared on new upload

**File:** ui/anonymize_page.py:110-114

**Problem:** The two `st.data_editor` widgets use fixed keys ('alias_editor' at line 113, 'entity_editor' at line 197). Streamlit persists each data_editor's edit state (added rows, deleted rows, cell edits) in `st.session_state` under that key across reruns. The new-file handler at lines 60-72 resets pass1_result, pass2_result, and uploaded_* but does not delete `st.session_state['alias_editor']` or `st.session_state['entity_editor']`.

**Failure scenario:** User anonymizes file A, edits or deletes rows in the entity table, completes the flow, then uploads file B without restarting. When the editors render for file B, Streamlit replays the stale edit deltas from file A onto file B's freshly built dataframe: `deleted_rows` can silently drop file B entities (leaving them un-anonymized), `edited_rows` can mutate cells, and `added_rows` can inject file A's entity text into file B's list (cross-document leakage). The confirm handlers iterate the returned dataframe, so corruption propagates into `execute_replacement`. Conditional on the user having edited the tables and re-uploading in the same session, hence MEDIUM.

**Evidence:** New-file block (lines 60-72) clears uploaded_* and pass*_result but never does `st.session_state.pop('alias_editor', None)` / `pop('entity_editor', None)`. A repo-wide grep confirms no session_state.pop or del anywhere. The editors at lines 110-114 and 194-198 reuse the same keys every run.

**Suggested fix:** In the new-file branch, delete the editor widget state keys: `st.session_state.pop('alias_editor', None); st.session_state.pop('entity_editor', None)` so each new document starts the editors from a clean slate.

---

### 14. restore: same-format failure aborts entire restoration with no .txt fallback

**File:** skills/legal-document-anonymizer/scripts/lda_skill.py:246-271

**Problem:** In `command_restore`, the call to `same_format_restored()` (which for .doc runs `apply_replacements_to_doc` and two textutil subprocess conversions, and for .docx runs python-docx) is not wrapped in try/except. If textutil is unavailable, times out, or the file is malformed, the exception propagates out to `main` and the CLI exits with an uncaught traceback, producing no restored output and no manifest. The main Streamlit app does the opposite: ui/deanonymize_page.py:110-118 wraps the same generation in try/except and falls back to a .txt download with a warning.

**Failure scenario:** A user restores an AI-edited .doc on a machine where textutil hiccups (non-macOS, timeout, or malformed file). `restored_text` is already fully computed, but it is discarded when the conversion throws, and the manifest is never written. The user gets a crash instead of the recoverable plaintext restoration the app guarantees.

**Evidence:** `command_restore`: `restored_path.write_bytes(same_format_restored(ext, anonymized_bytes, restored_text, mapping))` (line 262) with no try/except. `same_format_restored` for `ext=='doc'` calls `apply_replacements_to_doc` which runs textutil subprocesses and raises RuntimeError on nonzero return. Compare ui/deanonymize_page.py:110-118 which catches and warns "Falling back to .txt."

**Suggested fix:** Wrap the `same_format_restored` call in try/except; on failure, write `restored_text.encode('utf-8')` to a .txt path and record the degradation in the manifest, mirroring the app's fallback.

---

### 15. anonymize: same-format failure aborts before mapping is written, losing the restoration key

**File:** skills/legal-document-anonymizer/scripts/lda_skill.py:212-229

**Problem:** In `command_anonymize`, `execute_replacement()` produces `(anonymized_text, mapping)`. The code then calls `same_format_anonymized()` and writes the anonymized file first (line 228), and only writes the mapping JSON afterward (line 229). Neither call is wrapped in try/except. For a .doc input, `same_format_anonymized` -> `apply_replacements_to_doc` runs textutil conversions that can raise RuntimeError. If that raises, line 228 throws before line 229 executes, so the `mapping_*.json` (the only key that can ever reverse the anonymization) is never persisted, even though the expensive LLM scan already completed.

**Failure scenario:** A .doc input plus a textutil failure (corrupt file, missing textutil, sandboxed subprocess) leaves the user with no anonymized file and, more importantly, no mapping, after paying the full LLM cost. The app (ui/anonymize_page.py:226-252) wraps the block in try/except and sets `mapping_data` before same-format generation, so a generation failure there does not destroy the mapping. The CLI script regressed.

**Evidence:** `anonymized_text, mapping = execute_replacement(...)` then `anon_path.write_bytes(same_format_anonymized(ext, original_bytes, anonymized_text, mapping))` (line 228, can raise for `ext=='doc'`); `write_json(mapping_path, mapping)` (line 229, never reached on failure). `apply_replacements_to_doc` raises RuntimeError if `result.returncode != 0`.

**Suggested fix:** Write the mapping JSON before (or independently of) generating the same-format output, and wrap `same_format_anonymized` in try/except with a .txt fallback, so the restoration key is always saved once replacement succeeds.

---

## LOW

### 16. _read_doc builds the txt temp path with str.replace, replacing every '.doc' occurrence in the path

**File:** core/file_handler.py:79

**Problem:** `tmp_txt_path = tmp_doc_path.replace('.doc', '.txt')` replaces all occurrences of the substring '.doc' in the full path, not just the suffix. If the temp directory path (e.g. a user-set TMPDIR) contains the substring '.doc', the computed txt path diverges from where textutil actually writes, so the conversion fails or the subsequent `open()` raises. The random NamedTemporaryFile basename cannot contain '.doc', so this only triggers when the directory portion does.

**Failure scenario:** With `TMPDIR='/tmp/my.docs/'`, `tmp_doc_path='/tmp/my.docs/tmpXXXX.doc'` becomes `/tmp/my.txts/tmpXXXX.txt` after replace, corrupting the directory component. textutil is told to write into a non-existent directory, so the conversion fails (RuntimeError or FileNotFoundError). Low probability because the default macOS tempdir contains no '.doc'.

**Evidence:** Line 79 uses `str.replace` on the entire path. The sibling `apply_replacements_to_doc` at lines 206-208 correctly appends suffixes (`tmp_doc_path + '.docx'`), confirming the inconsistency.

**Suggested fix:** Derive the output path by suffix only: `tmp_txt_path = tmp_doc_path[:-4] + '.txt'`, or use `os.path.splitext`, or follow the append-suffix pattern already used in `apply_replacements_to_doc`.

---

### 17. API key written to .env in plaintext with default (world-readable) permissions

**File:** ui/settings_page.py:74-78

**Problem:** Both the "Save & Test Connection" and "Save Only" handlers write the API key in cleartext to `PROJECT_ROOT/.env` using `open(env_path, "w")` with default umask, producing a file typically readable by other local users (0644). Writing the key from the UI with no restrictive permissions, and overwriting the file each time, also clobbers any prior comments or unrelated variables in .env.

**Failure scenario:** The secret sits in a predictable location with default perms (verified 0644 on the machine), readable by other local users. On the intended single-user localhost laptop deployment, the "other local users" threat is largely theoretical, and the leaked secret is a cloud LLM API key rather than client documents, hence LOW. The truncating write also silently destroys unrelated .env content.

**Evidence:** Lines 74-78 (duplicated at 100-104): `with open(env_path, "w") as f: f.write(f"LLM_API_BASE={api_base}\n"); f.write(f"LLM_API_KEY={api_key}\n"); f.write(f"LLM_MODEL={model}\n")`. No `os.chmod`, no preservation of existing file contents.

**Suggested fix:** After writing, restrict permissions with `os.chmod(env_path, 0o600)`. Extract the duplicated write logic into a single helper (the two button handlers repeat it verbatim). Optionally preserve unrelated keys instead of truncating the whole file.
