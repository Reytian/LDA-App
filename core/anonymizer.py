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
    """
    segments = _split_into_segments(text)
    alias_context = _build_alias_context(pass1_result)

    all_entities = []
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
        except Exception as e:
            print(f"Segment {i + 1} scan failed: {e}")
            continue

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

    # Assign numbered placeholders per type
    type_counters = {}
    placeholder_map = {}
    text_to_placeholder = {}

    for canonical, group_info in canonical_groups.items():
        entity_type = group_info["type"].upper()

        if entity_type not in type_counters:
            type_counters[entity_type] = 1
        else:
            type_counters[entity_type] += 1

        placeholder = "{" + f"{entity_type}_{type_counters[entity_type]}" + "}"

        placeholder_map[placeholder] = {
            "value": canonical,
            "type": group_info["type"],
            "aliases": list(group_info["texts"] - {canonical}),
        }

        for t in group_info["texts"]:
            text_to_placeholder[t] = placeholder

    # Step 2: Replace longest-first to avoid substring conflicts
    sorted_texts = sorted(text_to_placeholder.keys(), key=len, reverse=True)

    replacement_log = []
    anonymized_text = text

    for entity_text in sorted_texts:
        placeholder = text_to_placeholder[entity_text]

        search_start = 0
        while True:
            pos = anonymized_text.find(entity_text, search_start)
            if pos == -1:
                break

            context_before = anonymized_text[max(0, pos - 40) : pos]
            context_after = anonymized_text[
                pos + len(entity_text) : pos + len(entity_text) + 40
            ]

            replacement_log.append({
                "placeholder": placeholder,
                "original_text": entity_text,
                "position": pos,
                "context_before": context_before,
                "context_after": context_after,
            })

            anonymized_text = (
                anonymized_text[:pos]
                + placeholder
                + anonymized_text[pos + len(entity_text) :]
            )

            search_start = pos + len(placeholder)

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
