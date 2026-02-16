"""
De-anonymization engine — restores anonymized documents to original content.

Three-step restoration strategy:
Step A: Position-based restoration (most precise)
Step B: Context-based fuzzy matching (handles document structure changes)
Step C: Canonical name fallback (last resort)
"""

import re
import difflib


# ============================================================
# Step A: Position-based restoration
# ============================================================
def restore_by_position(text: str, replacement_log: list[dict]) -> tuple[str, int, int]:
    """
    Restore placeholders using recorded position information.
    Processes back-to-front to avoid position offset issues.

    Args:
        text: Text containing placeholders
        replacement_log: Replacement records from anonymization

    Returns:
        (restored_text, matched_count, unmatched_count)
    """
    matched_count = 0
    unmatched_count = 0

    sorted_log = sorted(replacement_log, key=lambda x: x["position"], reverse=True)

    for entry in sorted_log:
        placeholder = entry["placeholder"]
        original_text = entry["original_text"]
        position = entry["position"]

        # Search within +/- 50 chars of recorded position
        search_start = max(0, position - 50)
        search_end = min(len(text), position + len(placeholder) + 50)
        search_region = text[search_start:search_end]

        local_pos = search_region.find(placeholder)

        if local_pos != -1:
            actual_pos = search_start + local_pos
            text = (
                text[:actual_pos]
                + original_text
                + text[actual_pos + len(placeholder) :]
            )
            matched_count += 1
        else:
            unmatched_count += 1

    return text, matched_count, unmatched_count


# ============================================================
# Step B: Context-based fuzzy matching
# ============================================================
def restore_by_context(text: str, replacement_log: list[dict]) -> tuple[str, int]:
    """
    Restore remaining placeholders by comparing surrounding context similarity.
    Uses SequenceMatcher to find the best match from replacement records.

    Args:
        text: Text after position-based restoration
        replacement_log: Replacement records

    Returns:
        (restored_text, context_matched_count)
    """
    context_matched = 0

    remaining_placeholders = list(re.finditer(r"\{[A-Z]+_\d+\}", text))

    if not remaining_placeholders:
        return text, 0

    for match in reversed(remaining_placeholders):
        placeholder_text = match.group()
        pos = match.start()

        current_before = text[max(0, pos - 40) : pos]
        current_after = text[pos + len(placeholder_text) : pos + len(placeholder_text) + 40]

        best_score = 0
        best_entry = None

        for entry in replacement_log:
            if entry["placeholder"] != placeholder_text:
                continue

            stored_before = entry.get("context_before", "")
            stored_after = entry.get("context_after", "")

            score_before = difflib.SequenceMatcher(
                None, current_before, stored_before
            ).ratio()
            score_after = difflib.SequenceMatcher(
                None, current_after, stored_after
            ).ratio()

            total_score = (score_before + score_after) / 2

            if total_score > best_score:
                best_score = total_score
                best_entry = entry

        if best_entry and best_score > 0.5:
            original_text = best_entry["original_text"]
            text = text[:pos] + original_text + text[pos + len(placeholder_text) :]
            context_matched += 1

    return text, context_matched


# ============================================================
# Step C: Canonical name fallback
# ============================================================
def restore_by_canonical(text: str, mappings: dict) -> tuple[str, int]:
    """
    Replace remaining placeholders with canonical (formal) names.
    These positions should be manually reviewed by the user.

    Args:
        text: Text still containing placeholders
        mappings: Mapping table (placeholder -> info)

    Returns:
        (restored_text, fallback_count)
    """
    fallback_count = 0

    remaining = list(re.finditer(r"\{[A-Z]+_\d+\}", text))

    for match in reversed(remaining):
        placeholder_text = match.group()
        pos = match.start()

        if placeholder_text in mappings:
            canonical_name = mappings[placeholder_text].get("value", placeholder_text)
        else:
            continue

        text = text[:pos] + canonical_name + text[pos + len(placeholder_text) :]
        fallback_count += 1

    return text, fallback_count


# ============================================================
# Orchestrator: run all three steps in sequence
# ============================================================
def run_deanonymize(
    text: str,
    mapping: dict,
) -> tuple[str, dict]:
    """
    Execute the full 3-step restoration pipeline.

    Args:
        text: Anonymized text to restore
        mapping: Full mapping dictionary

    Returns:
        (restored_text, stats_dict)
    """
    replacement_log = mapping.get("replacement_log", [])
    mappings = mapping.get("mappings", {})

    # Step A
    text, position_matched, position_unmatched = restore_by_position(
        text, replacement_log
    )

    # Step B
    text, context_matched = restore_by_context(text, replacement_log)

    # Step C
    text, fallback_count = restore_by_canonical(text, mappings)

    remaining = len(re.findall(r"\{[A-Z]+_\d+\}", text))

    stats = {
        "position_matched": position_matched,
        "context_matched": context_matched,
        "fallback_count": fallback_count,
        "remaining_placeholders": remaining,
        "total_in_log": len(replacement_log),
    }

    return text, stats
