r"""
Tests for core.deanonymizer match-side handling of the canonical placeholder
grammar (bug #4).

These tests run fully offline. No LLM, no network: mapping dicts are built by
hand to exercise the deanonymizer regex directly.

Canonical placeholder grammar (shared contract):
    A placeholder is literally "{TYPE_N}" where TYPE matches [A-Z][A-Z0-9]*
    and N is a positive integer. The ONE canonical detection regex is
    r"\{[A-Z][A-Z0-9]*_\d+\}", so a TYPE containing digits (e.g. "{REG2_1}")
    must be matched.
"""

import os
import sys

import pytest

# Make the project root importable so "core.deanonymizer" resolves regardless
# of the directory pytest is invoked from.
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from core.deanonymizer import (  # noqa: E402
    restore_by_canonical,
    restore_by_context,
    run_deanonymize,
)


# ============================================================
# Step C: restore_by_canonical must detect a digit-bearing TYPE
# ============================================================
def test_restore_by_canonical_matches_type_with_digit():
    # Arrange: a placeholder whose TYPE contains a digit ("{REG2_1}").
    text = "Filing reference: {REG2_1} on record."
    mappings = {"{REG2_1}": {"value": "Reg No. 91310000XYZ"}}

    # Act
    restored, fallback_count = restore_by_canonical(text, mappings)

    # Assert: the digit-bearing placeholder is detected and replaced.
    assert fallback_count == 1
    assert "{REG2_1}" not in restored
    assert "Reg No. 91310000XYZ" in restored


def test_restore_by_canonical_leaves_unknown_placeholder_in_place():
    # Arrange: placeholder is matched by the regex but absent from the mapping.
    text = "Unknown ref {REG2_9} stays put."
    mappings = {"{REG2_1}": {"value": "something else"}}

    # Act
    restored, fallback_count = restore_by_canonical(text, mappings)

    # Assert: no mapping entry, so it is left untouched (not silently dropped).
    assert fallback_count == 0
    assert "{REG2_9}" in restored


# ============================================================
# Step B: restore_by_context must also see a digit-bearing TYPE
# ============================================================
def test_restore_by_context_matches_type_with_digit():
    # Arrange
    text = "Filing reference: {REG2_1} on record."
    pos = text.index("{REG2_1}")
    replacement_log = [
        {
            "placeholder": "{REG2_1}",
            "original_text": "91310000XYZ",
            "context_before": text[max(0, pos - 40):pos],
            "context_after": text[pos + len("{REG2_1}"):pos + len("{REG2_1}") + 40],
        }
    ]

    # Act
    restored, context_matched = restore_by_context(text, replacement_log)

    # Assert
    assert context_matched == 1
    assert "{REG2_1}" not in restored
    assert "91310000XYZ" in restored


# ============================================================
# Orchestrator: remaining count must be NONZERO when a canonical
# placeholder is still literally present in the output text.
# ============================================================
def test_run_deanonymize_reports_nonzero_remaining_for_unmatched_placeholder():
    # Arrange: a canonical placeholder with no log/mapping entry to restore it.
    text = "Leftover ref {REG2_1} survives restoration."
    mapping = {"replacement_log": [], "mappings": {}}

    # Act
    restored, stats = run_deanonymize(text, mapping)

    # Assert: placeholder is still literally present, so the count must be > 0.
    assert "{REG2_1}" in restored
    assert stats["remaining_placeholders"] == 1


def test_run_deanonymize_reports_zero_remaining_after_full_restore():
    # Arrange: a digit-bearing placeholder fully recoverable via the mapping.
    text = "Filing reference: {REG2_1} on record."
    mapping = {
        "replacement_log": [],
        "mappings": {"{REG2_1}": {"value": "91310000XYZ"}},
    }

    # Act
    restored, stats = run_deanonymize(text, mapping)

    # Assert: restored cleanly, count back to zero.
    assert "{REG2_1}" not in restored
    assert "91310000XYZ" in restored
    assert stats["remaining_placeholders"] == 0


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
