"""
Anonymization engine — two-pass scanning + replacement + mapping generation.

Workflow:
1. Pass 1: Extract entity definitions and alias relationships from key sections
2. Pass 2: Scan full document segment by segment for all sensitive items
3. Execute replacement: Replace sensitive items with placeholders, generate mapping
"""

import re
from datetime import datetime
from core.llm_client import call_llm, parse_json_response
from core.prompts import PASS1_PROMPT, PASS2_PROMPT
from core.section_detector import detect_key_sections


# ============================================================
# Placeholder grammar contract
# ============================================================
# A placeholder is literally "{TYPE_N}" where N is a positive integer and TYPE
# is derived from the raw entity type. TYPE always matches [A-Z][A-Z0-9]* (no
# spaces, no stray underscores). The canonical detection regex below MUST be
# kept in sync with the emit side and with the deanonymizer.
PLACEHOLDER_REGEX = r"\{[A-Z][A-Z0-9]*_\d+\}"


def _sanitize_type(entity_type: str) -> str:
    """
    Slugify a raw entity type into a contract-conforming placeholder TYPE token.

    Bug #4: the LLM may return a multi-token type such as "reg num" or
    "bank account", which would otherwise build a placeholder like
    "{REG NUM_1}" that the deanonymizer regex can never match.

    Rules:
    - Uppercase, then strip every character that is not A-Z or 0-9.
    - If the result is empty, return "UNKNOWN".
    - If the first character is not A-Z (e.g. type was all digits), prefix "X"
      so the token always matches [A-Z][A-Z0-9]*.

    Args:
        entity_type: Raw entity type string from the model or user.

    Returns:
        A token matching [A-Z][A-Z0-9]*.
    """
    token = re.sub(r"[^A-Z0-9]", "", (entity_type or "").upper())
    if not token:
        return "UNKNOWN"
    if not ("A" <= token[0] <= "Z"):
        token = "X" + token
    return token


# ============================================================
# Pass 1: Extract entity definitions and aliases
# ============================================================
def run_first_pass(text: str) -> dict:
    """
    Pass 1: Extract entity definitions and alias relationships from key sections.

    Args:
        text: Full document text

    Returns:
        Structured data: {"aliases": [...], "entities": [...]}
    """
    key_sections = detect_key_sections(text)

    prompt = PASS1_PROMPT.format(key_sections_text=key_sections)
    messages = [{"role": "user", "content": prompt}]

    response_text = call_llm(messages)
    result = parse_json_response(response_text)

    if "aliases" not in result:
        result["aliases"] = []
    if "entities" not in result:
        result["entities"] = []
    if "document_type" not in result:
        result["document_type"] = "Document"

    return result


# ============================================================
# Pass 2: Scan full document for all sensitive items
# ============================================================
def _split_into_segments(text: str, max_chars: int = 10000) -> list[str]:
    """
    Split text into segments by paragraph, each no longer than max_chars.
    Single paragraphs exceeding the limit are further split by sentence.

    Args:
        text: Full document text
        max_chars: Maximum characters per segment (default 10000 for faster processing)

    Returns:
        List of text segments
    """
    paragraphs = text.split("\n")
    segments = []
    current_segment = ""

    for paragraph in paragraphs:
        if len(paragraph) > max_chars:
            if current_segment.strip():
                segments.append(current_segment.strip())
                current_segment = ""
            sentences = re.split(r"(?<=[。.！!？?])\s*", paragraph)
            temp = ""
            for sentence in sentences:
                if len(temp) + len(sentence) > max_chars and temp:
                    segments.append(temp.strip())
                    temp = ""
                temp += sentence
            if temp.strip():
                segments.append(temp.strip())
            continue

        if len(current_segment) + len(paragraph) + 1 > max_chars and current_segment.strip():
            segments.append(current_segment.strip())
            current_segment = ""

        current_segment += paragraph + "\n"

    if current_segment.strip():
        segments.append(current_segment.strip())

    return segments


def _build_alias_context(pass1_result: dict) -> str:
    """
    Format Pass 1 results as context text for Pass 2 prompts.

    Args:
        pass1_result: Structured data from Pass 1

    Returns:
        Formatted alias context string
    """
    lines = []
    for alias_group in pass1_result.get("aliases", []):
        canonical = alias_group.get("canonical", "")
        aliases = alias_group.get("aliases", [])
        entity_type = alias_group.get("type", "")
        alias_str = ", ".join(aliases) if aliases else "none"
        lines.append(f"- {canonical} (type: {entity_type}) = {alias_str}")

    if not lines:
        return "(no known entity definitions)"

    return "\n".join(lines)


def run_second_pass(
    text: str,
    pass1_result: dict,
    progress_callback=None,
) -> list[dict]:
    """
    Pass 2: Scan full document segment by segment for all sensitive items.

    Args:
        text: Full document text
        pass1_result: Structured data from Pass 1
        progress_callback: Callback function taking (current_segment, total_segments)

    Returns:
        De-duplicated entity list: [{"text": ..., "type": ..., "canonical": ...}, ...]

    Raises:
        RuntimeError: If any segment fails to scan after retries, so a partially
            scanned document is never silently presented as fully anonymized.
    """
    segments = _split_into_segments(text)
    alias_context = _build_alias_context(pass1_result)

    all_entities = []
    failed_segments = []
    for i, segment in enumerate(segments):
        if progress_callback:
            progress_callback(i + 1, len(segments))

        prompt = PASS2_PROMPT.format(
            entity_aliases_context=alias_context,
            document_segment=segment,
        )
        messages = [{"role": "user", "content": prompt}]

        try:
            response_text = call_llm(messages)
            entities = parse_json_response(response_text)
            if isinstance(entities, list):
                all_entities.extend(entities)
            elif isinstance(entities, dict) and entities.get("text"):
                # A single-entity response that arrived as a bare object: treat
                # it as a one-element list rather than silently dropping it.
                all_entities.append(entities)
            else:
                print(f"Segment {i + 1} returned an unexpected shape, ignoring: {type(entities).__name__}")
        except Exception as e:
            # Fail loud: a swallowed segment failure would leak PII by presenting
            # a partially scanned document as fully anonymized.
            print(f"Segment {i + 1} scan failed: {e}")
            failed_segments.append((i + 1, str(e)))

    if failed_segments:
        detail = "; ".join(f"segment {n}: {msg}" for n, msg in failed_segments)
        raise RuntimeError(
            f"Pass 2 scan incomplete: {len(failed_segments)} of {len(segments)} "
            f"segment(s) failed after retries. The document was NOT fully scanned "
            f"and may still contain sensitive data. Details: {detail}"
        )

    # De-duplicate by (text, type)
    seen = set()
    unique_entities = []
    for entity in all_entities:
        key = (entity.get("text", ""), entity.get("type", ""))
        if key not in seen and entity.get("text", "").strip():
            seen.add(key)
            unique_entities.append(entity)

    _link_aliases(unique_entities, pass1_result)

    return unique_entities


def _link_aliases(entities: list[dict], pass1_result: dict):
    """
    Link Pass 2 entities with Pass 1 alias data.
    Sets canonical name for entities matching known aliases.

    Args:
        entities: Entity list from Pass 2 (modified in place)
        pass1_result: Pass 1 results
    """
    for entity in entities:
        if entity.get("canonical"):
            continue

        for alias_group in pass1_result.get("aliases", []):
            canonical = alias_group.get("canonical", "")
            aliases = alias_group.get("aliases", [])
            all_names = [canonical] + aliases

            if entity.get("text") in all_names:
                entity["canonical"] = canonical
                break


# ============================================================
# Execute replacement: generate anonymized text + mapping table
# ============================================================
def execute_replacement(
    text: str,
    entities: list[dict],
    pass1_result: dict,
    source_filename: str = "",
) -> tuple[str, dict]:
    """
    Execute anonymization: replace sensitive items with placeholders.

    Args:
        text: Original document text
        entities: Full entity list (from Pass 2, possibly user-edited)
        pass1_result: Pass 1 results (with alias info)
        source_filename: Original filename

    Returns:
        (anonymized_text, mapping_dict)
    """
    # Step 1: Assign placeholders grouped by canonical entity
    canonical_groups = {}

    for entity in entities:
        entity_text = entity.get("text", "").strip()
        entity_type = entity.get("type", "unknown")
        canonical = entity.get("canonical", "").strip()

        if not entity_text:
            continue

        group_key = canonical if canonical else entity_text

        if group_key not in canonical_groups:
            canonical_groups[group_key] = {
                "type": entity_type,
                "texts": set(),
                "aliases": [],
            }

        canonical_groups[group_key]["texts"].add(entity_text)
        if canonical:
            canonical_groups[group_key]["texts"].add(canonical)

    # Add aliases from Pass 1
    for alias_group in pass1_result.get("aliases", []):
        canonical = alias_group.get("canonical", "")
        if canonical in canonical_groups:
            for alias in alias_group.get("aliases", []):
                canonical_groups[canonical]["texts"].add(alias)
                canonical_groups[canonical]["aliases"].append(alias)

    # Assign numbered placeholders.
    #
    # Invariant (fixes bug #3): every distinct placeholder STRING restores to
    # exactly one original surface text. A single surface text may legitimately
    # belong to more than one canonical group (e.g. "Smith" is an alias of the
    # person "John Smith" and of the company "Smith Corp"), and a single group
    # may carry several distinct surface texts ("John Smith" plus the alias
    # "Smith"). If two distinct surface texts shared one placeholder, the
    # deanonymizer's position-window restore could not tell them apart and would
    # restore the wrong one. We therefore mint one placeholder PER DISTINCT
    # surface text. The mapping "value" still records the canonical name so the
    # canonical-fallback restore step keeps grouping entities semantically.
    type_counters = {}
    placeholder_map = {}
    # surface text -> (placeholder, sanitized type token). The first canonical
    # group that registers a given surface text wins its placeholder; later
    # groups reuse the same placeholder for that identical surface text so the
    # one-string-one-original invariant holds.
    text_to_placeholder: dict[str, str] = {}

    for canonical, group_info in canonical_groups.items():
        type_token = _sanitize_type(group_info["type"])

        for surface_text in group_info["texts"]:
            if surface_text in text_to_placeholder:
                continue

            if type_token not in type_counters:
                type_counters[type_token] = 1
            else:
                type_counters[type_token] += 1

            placeholder = "{" + f"{type_token}_{type_counters[type_token]}" + "}"
            text_to_placeholder[surface_text] = placeholder

            placeholder_map[placeholder] = {
                "value": canonical,
                "type": group_info["type"],
                "surface_text": surface_text,
                "aliases": list(group_info["texts"] - {surface_text}),
            }

    # Step 2: Single-pass replacement over the ORIGINAL text.
    #
    # Bug #2: replacing on the progressively mutated text let a later short
    # numeric entity (e.g. "1") match a digit inside a placeholder inserted by
    # an earlier entity, producing nested garbage like "{COMPANY_{AMOUNT_1}}".
    # Fix: compute all candidate match spans against the ORIGINAL text, resolve
    # overlaps (longest match wins, earliest position breaks ties), then build
    # the anonymized text in one left-to-right walk so no inserted placeholder
    # is ever re-scanned.
    sorted_texts = sorted(text_to_placeholder.keys(), key=len, reverse=True)

    # Collect candidate spans against the original text.
    candidate_spans: list[tuple[int, int, str, str]] = []
    for entity_text in sorted_texts:
        placeholder = text_to_placeholder[entity_text]
        start = 0
        while True:
            pos = text.find(entity_text, start)
            if pos == -1:
                break
            candidate_spans.append(
                (pos, pos + len(entity_text), placeholder, entity_text)
            )
            start = pos + len(entity_text)

    # Resolve overlaps: prefer the longest span; on equal length prefer the
    # earliest start. Drop any span that overlaps an already-accepted span.
    candidate_spans.sort(key=lambda s: (-(s[1] - s[0]), s[0]))

    accepted_spans: list[tuple[int, int, str, str]] = []
    for span in candidate_spans:
        start, end, _, _ = span
        overlaps = any(
            start < acc_end and end > acc_start
            for acc_start, acc_end, _, _ in accepted_spans
        )
        if not overlaps:
            accepted_spans.append(span)

    # Walk left-to-right over the original text, emitting placeholders.
    accepted_spans.sort(key=lambda s: s[0])

    replacement_log = []
    result_parts: list[str] = []
    cursor = 0
    out_len = 0  # length of anonymized text built so far

    for start, end, placeholder, entity_text in accepted_spans:
        # Copy the untouched original text before this span.
        prefix = text[cursor:start]
        result_parts.append(prefix)
        out_len += len(prefix)

        context_before = text[max(0, start - 40) : start]
        context_after = text[end : end + 40]

        # Position recorded is the placeholder's position in the FINAL
        # anonymized text, which is what restore_by_position expects.
        replacement_log.append({
            "placeholder": placeholder,
            "original_text": entity_text,
            "position": out_len,
            "context_before": context_before,
            "context_after": context_after,
        })

        result_parts.append(placeholder)
        out_len += len(placeholder)
        cursor = end

    # Trailing untouched text.
    result_parts.append(text[cursor:])
    anonymized_text = "".join(result_parts)

    # Step 3: Assemble mapping table
    mapping = {
        "metadata": {
            "created_at": datetime.now().isoformat(),
            "source_file": source_filename,
            "entity_count": len(canonical_groups),
        },
        "mappings": placeholder_map,
        "replacement_log": replacement_log,
    }

    return anonymized_text, mapping
