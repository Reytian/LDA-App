"""
De-anonymization engine — restores anonymized documents to original content.

Three-step restoration strategy:
Step A: Position-based restoration (most precise)
Step B: Context-based fuzzy matching (handles document structure changes)
Step C: Canonical name fallback (last resort)
"""

import re
import difflib
from collections import Counter


# Canonical placeholder detection regex (kept in sync with core.anonymizer).
PLACEHOLDER_REGEX = r"\{[A-Z][A-Z0-9]*_\d+\}"


def _nearest_occurrence(
    text: str, placeholder: str, position: int, window: int = 50
) -> int | None:
    """
    Return the absolute index of the occurrence of ``placeholder`` CLOSEST to
    ``position`` within +/-window, or None if it does not occur in the window.

    Picking the nearest (rather than the leftmost) occurrence stops a restore
    from grabbing an identical placeholder-shaped token that merely sits earlier
    in the window (e.g. a literal "{COMPANY_1}" merge field in the source).
    """
    search_start = max(0, position - window)
    search_end = min(len(text), position + len(placeholder) + window)
    region = text[search_start:search_end]

    best = None
    best_dist = None
    idx = region.find(placeholder)
    while idx != -1:
        abs_idx = search_start + idx
        dist = abs(abs_idx - position)
        if best_dist is None or dist < best_dist:
            best_dist = dist
            best = abs_idx
        idx = region.find(placeholder, idx + 1)
    return best


# ============================================================
# Step A: Position-based restoration
# ============================================================
def restore_by_position(
    text: str, replacement_log: list[dict], budget: dict | None = None
) -> tuple[str, int, int]:
    """
    Restore placeholders using recorded position information.
    Processes back-to-front to avoid position offset issues.

    Prefers an EXACT match at the recorded position -- always available on a
    clean round-trip, since the recorded position is the placeholder's index in
    the final anonymized text -- and only falls back to the occurrence NEAREST
    the recorded position within a +/-50 window. The previous leftmost-in-window
    search could restore an identical placeholder-shaped token sitting earlier in
    the window (e.g. a literal "{COMPANY_1}" merge field), corrupting the source
    (bug #10).

    Args:
        text: Text containing placeholders
        replacement_log: Replacement records from anonymization
        budget: Optional per-placeholder remaining-restore counter, decremented
            on each successful restore so later steps never restore more
            occurrences of a placeholder string than were actually emitted.

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

        if text.startswith(placeholder, position):
            actual_pos = position
        else:
            actual_pos = _nearest_occurrence(text, placeholder, position, window=50)

        if actual_pos is not None:
            text = (
                text[:actual_pos]
                + original_text
                + text[actual_pos + len(placeholder) :]
            )
            matched_count += 1
            if budget is not None and placeholder in budget:
                budget[placeholder] -= 1
        else:
            unmatched_count += 1

    return text, matched_count, unmatched_count


# ============================================================
# Step B: Context-based fuzzy matching
# ============================================================
def restore_by_context(
    text: str, replacement_log: list[dict], budget: dict | None = None
) -> tuple[str, int]:
    """
    Restore remaining placeholders by comparing surrounding context similarity.
    Uses SequenceMatcher to find the best match from replacement records.

    Args:
        text: Text after position-based restoration
        replacement_log: Replacement records
        budget: Optional per-placeholder remaining-restore counter. A placeholder
            whose emitted instances were all restored by Step A is skipped here
            so original placeholder-shaped content is left intact (bug #10).

    Returns:
        (restored_text, context_matched_count)
    """
    context_matched = 0

    remaining_placeholders = list(re.finditer(PLACEHOLDER_REGEX, text))

    if not remaining_placeholders:
        return text, 0

    for match in reversed(remaining_placeholders):
        placeholder_text = match.group()
        pos = match.start()

        if budget is not None and placeholder_text in budget and budget[placeholder_text] <= 0:
            # Every emitted instance of this placeholder was already restored;
            # any identical token left here is original content, not a redaction.
            continue

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
            if budget is not None and placeholder_text in budget:
                budget[placeholder_text] -= 1

    return text, context_matched


# ============================================================
# Step C: Canonical name fallback
# ============================================================
def restore_by_canonical(
    text: str, mappings: dict, budget: dict | None = None
) -> tuple[str, int]:
    """
    Replace remaining placeholders with their recorded original text.
    These positions should be manually reviewed by the user.

    Restores the EXACT surface text recorded for the placeholder
    (mappings[ph]["surface_text"]), falling back to the canonical "value" only
    for legacy mappings written before surface_text existed. Restoring the
    canonical name would silently substitute a different (formal) name for the
    short form that was actually anonymized (bug #4).

    Args:
        text: Text still containing placeholders
        mappings: Mapping table (placeholder -> info)
        budget: Optional per-placeholder remaining-restore counter. A placeholder
            whose emitted instances were all restored earlier is skipped so
            original placeholder-shaped content is left intact (bug #10).

    Returns:
        (restored_text, fallback_count)
    """
    fallback_count = 0

    remaining = list(re.finditer(PLACEHOLDER_REGEX, text))

    for match in reversed(remaining):
        placeholder_text = match.group()
        pos = match.start()

        if placeholder_text not in mappings:
            continue

        if budget is not None and placeholder_text in budget and budget[placeholder_text] <= 0:
            continue

        info = mappings[placeholder_text]
        replacement = info.get("surface_text") or info.get("value", placeholder_text)

        text = text[:pos] + replacement + text[pos + len(placeholder_text) :]
        fallback_count += 1
        if budget is not None and placeholder_text in budget:
            budget[placeholder_text] -= 1

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

    # Per-placeholder budget = how many instances the anonymizer actually emitted
    # (one replacement_log entry per emitted occurrence). The three restore steps
    # share this counter so they never restore MORE occurrences of a placeholder
    # string than were emitted -- placeholder-shaped text the anonymizer never
    # produced (literal merge fields, etc.) is therefore preserved (bug #10).
    # Placeholders absent from the log (legacy/hand-built mappings with no log)
    # are left UNBOUNDED so the canonical fallback can still restore them.
    budget = dict(Counter(entry.get("placeholder", "") for entry in replacement_log))

    # Step A
    text, position_matched, position_unmatched = restore_by_position(
        text, replacement_log, budget
    )

    # Step B
    text, context_matched = restore_by_context(text, replacement_log, budget)

    # Step C
    text, fallback_count = restore_by_canonical(text, mappings, budget)

    remaining = len(re.findall(PLACEHOLDER_REGEX, text))

    stats = {
        "position_matched": position_matched,
        "context_matched": context_matched,
        "fallback_count": fallback_count,
        "remaining_placeholders": remaining,
        "total_in_log": len(replacement_log),
    }

    return text, stats
