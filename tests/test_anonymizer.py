"""
Tests for core.anonymizer.execute_replacement covering bugs #2, #3, and the
emit side of #4.

These tests run fully offline: execute_replacement is pure text processing and
makes no LLM or network calls. The #3 roundtrip imports core.deanonymizer to
prove the anonymize -> deanonymize cycle is lossless.
"""

import re

import pytest

from core.anonymizer import (
    PLACEHOLDER_REGEX,
    _sanitize_type,
    execute_replacement,
)
from core.deanonymizer import run_deanonymize


EMPTY_PASS1 = {"aliases": [], "entities": []}


# ============================================================
# Bug #2: short numeric entity must not corrupt earlier placeholders
# ============================================================
def test_short_numeric_does_not_corrupt_placeholder():
    # Arrange
    text = "Invoice number 1 for Alpha Beta Company. Quantity: 1 unit."
    entities = [
        {"text": "Alpha Beta Company", "type": "company", "canonical": ""},
        {"text": "1", "type": "amount", "canonical": ""},
    ]

    # Act
    anonymized, mapping = execute_replacement(text, entities, EMPTY_PASS1)

    # Assert: no nested garbage like "{COMPANY_{AMOUNT_1}}" anywhere.
    assert "{COMPANY_{" not in anonymized
    assert "{{" not in anonymized
    assert "}}" not in anonymized

    # Every emitted placeholder conforms to the grammar contract.
    found = re.findall(PLACEHOLDER_REGEX, anonymized)
    # We expect exactly: COMPANY_1 once, AMOUNT_1 twice (the two "1" digits).
    assert "{COMPANY_1}" in found
    assert found.count("{AMOUNT_1}") == 2

    # The company token is intact (its "1" was not rewritten by the amount).
    assert "{COMPANY_1}" in anonymized

    # Logged positions point at intact placeholders in the FINAL text.
    for entry in mapping["replacement_log"]:
        pos = entry["position"]
        ph = entry["placeholder"]
        assert anonymized[pos : pos + len(ph)] == ph


def test_short_numeric_roundtrip_is_lossless():
    # Arrange
    text = "Invoice number 1 for Alpha Beta Company. Quantity: 1 unit."
    entities = [
        {"text": "Alpha Beta Company", "type": "company", "canonical": ""},
        {"text": "1", "type": "amount", "canonical": ""},
    ]

    # Act
    anonymized, mapping = execute_replacement(text, entities, EMPTY_PASS1)
    restored, stats = run_deanonymize(anonymized, mapping)

    # Assert
    assert restored == text
    assert stats["remaining_placeholders"] == 0


# ============================================================
# Bug #3: same surface text in two canonical groups must roundtrip losslessly
# ============================================================
def test_smith_ambiguity_roundtrip_lossless():
    # Arrange: "Smith" is both a person alias (John Smith) and a company alias
    # (Smith Corp). A flat last-writer-wins map mis-restores the standalone
    # "Smith".
    text = "Smith Corp hired John Smith. Smith is the CEO."
    entities = [
        {"text": "Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith", "type": "company", "canonical": "Smith Corp"},
        {"text": "John Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith Corp", "type": "company", "canonical": "Smith Corp"},
    ]

    # Act
    anonymized, mapping = execute_replacement(text, entities, EMPTY_PASS1)
    restored, stats = run_deanonymize(anonymized, mapping)

    # Assert: exact roundtrip and no placeholders left behind.
    assert restored == text
    assert stats["remaining_placeholders"] == 0

    # The original surface text is fully gone from the anonymized output.
    assert "Smith" not in anonymized


def test_smith_overlaps_resolved_longest_first():
    # The longer spans "John Smith" and "Smith Corp" must win over the bare
    # "Smith" where they overlap, so no nested or partial placeholders appear.
    text = "Smith Corp hired John Smith. Smith is the CEO."
    entities = [
        {"text": "Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith", "type": "company", "canonical": "Smith Corp"},
        {"text": "John Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith Corp", "type": "company", "canonical": "Smith Corp"},
    ]

    anonymized, _ = execute_replacement(text, entities, EMPTY_PASS1)

    # All placeholders conform to the contract grammar.
    for ph in re.findall(r"\{[^}]*\}", anonymized):
        assert re.fullmatch(PLACEHOLDER_REGEX, ph), ph


# ============================================================
# Bug #4 (emit side): spaced type must sanitize to a contract placeholder
# ============================================================
def test_spaced_type_produces_contract_placeholder():
    # Arrange
    text = "Reg: 91310000XYZ end."
    entities = [{"text": "91310000XYZ", "type": "reg num", "canonical": ""}]

    # Act
    anonymized, mapping = execute_replacement(text, entities, EMPTY_PASS1)

    # Assert: no space in the placeholder, and it matches the canonical regex.
    assert "{REG NUM_1}" not in anonymized
    found = re.findall(PLACEHOLDER_REGEX, anonymized)
    assert found == ["{REGNUM_1}"]
    assert "{REGNUM_1}" in mapping["mappings"]


def test_sanitize_type_edge_cases():
    assert _sanitize_type("reg num") == "REGNUM"
    assert _sanitize_type("reg_num") == "REGNUM"
    assert _sanitize_type("bank account") == "BANKACCOUNT"
    # Empty / non-letter inputs are coerced to valid tokens.
    assert _sanitize_type("") == "UNKNOWN"
    assert _sanitize_type("   ") == "UNKNOWN"
    assert _sanitize_type("123") == "X123"
    # Result always matches the contract token shape.
    for raw in ["reg num", "123", "", "_a_b_", "9to5"]:
        token = _sanitize_type(raw)
        assert re.fullmatch(r"[A-Z][A-Z0-9]*", token), (raw, token)


def test_spaced_type_emit_matches_canonical_regex_roundtrip():
    # The placeholder the deanonymizer count uses must detect this placeholder.
    text = "Reg: 91310000XYZ end."
    entities = [{"text": "91310000XYZ", "type": "reg num", "canonical": ""}]
    anonymized, mapping = execute_replacement(text, entities, EMPTY_PASS1)
    restored, stats = run_deanonymize(anonymized, mapping)
    assert restored == text
    assert stats["remaining_placeholders"] == 0


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))


# ============================================================
# Bugs #6/#7 (upstream): a failed segment must fail loud, never silently
# present a partially scanned document as fully anonymized.
# ============================================================
def test_run_second_pass_raises_when_a_segment_fails(monkeypatch):
    import core.anonymizer as anon

    # Force a single segment and make the LLM call raise after retries.
    monkeypatch.setattr(anon, "_split_into_segments", lambda text, max_chars=10000: ["only segment"])

    def boom(messages, temperature=None):
        raise RuntimeError("gateway 200 error envelope")

    monkeypatch.setattr(anon, "call_llm", boom)

    with pytest.raises(RuntimeError, match="Pass 2 scan incomplete"):
        anon.run_second_pass("some text", EMPTY_PASS1)


def test_run_second_pass_normalizes_bare_object(monkeypatch):
    import core.anonymizer as anon

    monkeypatch.setattr(anon, "_split_into_segments", lambda text, max_chars=10000: ["only segment"])
    monkeypatch.setattr(anon, "call_llm", lambda messages, temperature=None: "ignored")
    # parse_json_response returns a bare dict (single-entity object, not a list).
    monkeypatch.setattr(
        anon, "parse_json_response",
        lambda text: {"text": "Acme Corp", "type": "company", "canonical": ""},
    )

    result = anon.run_second_pass("some text", EMPTY_PASS1)

    assert [e["text"] for e in result] == ["Acme Corp"]
