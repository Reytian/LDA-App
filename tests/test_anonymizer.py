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
    _split_into_segments,
    count_effective_occurrences,
    execute_replacement,
    safe_doc_type,
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


# ============================================================
# Bug #3: an empty-string Pass-1 alias must not hang execute_replacement
# (text.find("") returns the same index forever -> unbounded candidate spans).
# ============================================================
def test_empty_pass1_alias_does_not_hang_and_roundtrips():
    # Arrange: a realistic Pass-1 output with a stray empty-string alias.
    text = "Acme Corporation signed. Acme is the Company."
    entities = [
        {"text": "Acme Corporation", "type": "company", "canonical": "Acme Corporation"},
    ]
    pass1 = {
        "aliases": [
            {"canonical": "Acme Corporation", "type": "company",
             "aliases": ["Acme", "the Company", ""]},
        ],
        "entities": [],
    }

    # Act: must return promptly (the empty alias is dropped, never minted).
    anonymized, mapping = execute_replacement(text, entities, pass1)

    # Assert: no empty surface text was minted into a placeholder, and the
    # round-trip is clean.
    for info in mapping["mappings"].values():
        assert info.get("surface_text", "").strip() != ""
    restored, stats = run_deanonymize(anonymized, mapping)
    assert restored == text
    assert stats["remaining_placeholders"] == 0


# ============================================================
# Bug #9: a whitespace-only alias must not mint a placeholder that overwrites
# real document spacing, garbling the anonymized output.
# ============================================================
def test_whitespace_only_alias_does_not_corrupt_document():
    # Arrange: a whitespace-only alias "  " plus a document with double spaces.
    text = "Acme Corp signed  the  deal  today."
    entities = [
        {"text": "Acme Corp", "type": "company", "canonical": "Acme Corp"},
    ]
    pass1 = {
        "aliases": [
            {"canonical": "Acme Corp", "type": "company", "aliases": ["  "]},
        ],
        "entities": [],
    }

    # Act
    anonymized, mapping = execute_replacement(text, entities, pass1)

    # Assert: no placeholder represents whitespace, and the document's real
    # spacing/words are intact (only "Acme Corp" was replaced).
    for info in mapping["mappings"].values():
        assert info.get("surface_text", "").strip() != ""
    assert anonymized.endswith(" signed  the  deal  today.")
    restored, stats = run_deanonymize(anonymized, mapping)
    assert restored == text


# ============================================================
# Bug #8: an oversize single paragraph must not be split INSIDE a dotted entity
# (email / decimal amount / dotted ID), or Pass-2 never sees it whole -> leak.
# ============================================================
def test_oversize_paragraph_keeps_dotted_email_whole():
    # Arrange: one paragraph (no newline) over the limit, with an email whose
    # interior dots would tear under a naive split-at-every-period.
    email = "john.smith@secret-law-firm.com"
    para = ("Filler sentence here. " * 20) + f"Reach {email} today. " + ("More text. " * 20)
    assert "\n" not in para

    # Act: use a small max_chars so the boundary would fall mid-paragraph.
    segments = _split_into_segments(para, max_chars=200)

    # Assert: the email appears WHOLE in exactly one segment (never torn across
    # two), so a Pass-2 detector can see and redact it.
    assert any(email in seg for seg in segments), segments
    for seg in segments:
        # No segment ends or begins mid-email.
        assert not seg.endswith("john."), seg


def test_oversize_paragraph_split_preserves_inter_sentence_whitespace():
    # Bug #14: the sentence-split path must not delete the space after a
    # sentence ender, which would glue a company end to the next name
    # ("Ltd. Carol" -> "Ltd.Carol") and corrupt the text Pass-2 scans.
    para = ("This is filler text in the agreement. " * 300) + \
        "Payment goes to Beta Holdings Ltd. Carol Danvers approves it."
    assert len(para) > 10000 and "\n" not in para

    # Act
    segments = _split_into_segments(para, max_chars=10000)

    # Assert: the boundary "Ltd. Carol" keeps its space (not glued) and no
    # characters are lost relative to the original paragraph.
    joined = "".join(segments)
    assert "Ltd.Carol" not in joined
    assert "Ltd. Carol Danvers" in joined


# ============================================================
# Bug #13: a model-supplied document_type must slugify to a safe, capped,
# filename-friendly token (no party-name leak, no illegal chars).
# ============================================================
def test_safe_doc_type_slugifies_and_caps():
    assert safe_doc_type("Share Purchase Agreement") == "SHARE_PURCHASE_AGREEMENT"
    # Illegal filename characters are removed.
    assert "/" not in safe_doc_type("Loan / Security Agreement")
    assert "\n" not in safe_doc_type("Weird\nType")
    # Empty / None fall back to a fixed generic stem.
    assert safe_doc_type("") == "DOCUMENT"
    assert safe_doc_type(None) == "DOCUMENT"
    # Over-described types that embed party names are length-capped.
    over = "Share Purchase Agreement between Acme Corp and John Smith"
    assert len(safe_doc_type(over)) <= 40
    # Always a clean uppercase slug.
    assert re.fullmatch(r"[A-Z0-9_]+", safe_doc_type("Equity Transfer Agreement"))


def test_safe_doc_type_preserves_non_ascii_word_chars():
    # This tool processes Chinese contracts (its prompts are Chinese), so a
    # Chinese document_type must not be flattened to the generic stem -- that
    # would make every Chinese file download as ANONYMIZED_DOCUMENT.
    slug = safe_doc_type("股权转让协议")
    assert slug != "DOCUMENT"
    assert "股权转让协议" in slug
    # Dangerous characters are still stripped even when non-ASCII is present.
    assert "/" not in safe_doc_type("协议 / Agreement")
    assert "\n" not in safe_doc_type("协议\nAgreement")


# ============================================================
# Bug #15: the displayed occurrence count must reflect the replacements that
# execute_replacement actually makes (non-overlapping, longest-match-wins),
# not naive str.count substring frequency.
# ============================================================
def test_count_effective_occurrences_excludes_substring_of_longer_entity():
    # Arrange: "Aaa" is also a substring of "Aaa Corp".
    text = "Aaa works at Aaa Corp. Aaa Corp pays Aaa."
    entities = [
        {"text": "Aaa", "type": "person", "canonical": ""},
        {"text": "Aaa Corp", "type": "company", "canonical": ""},
    ]

    # Act
    counts = count_effective_occurrences(text, entities, EMPTY_PASS1)

    # Assert: only the two STANDALONE "Aaa" are counted (the two inside
    # "Aaa Corp" are consumed by the longer company match). str.count -> 4.
    assert counts["Aaa"] == 2
    assert counts["Aaa Corp"] == 2
