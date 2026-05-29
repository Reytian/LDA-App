r"""
Cross-module end-to-end roundtrip regression tests.

These tests exercise BOTH sides of the shared placeholder-grammar contract:
they call core.anonymizer.execute_replacement to produce anonymized text plus
a mapping, then core.deanonymizer.run_deanonymize to restore it, and assert a
LOSSLESS roundtrip (restored == original) for adversarial inputs.

All tests run fully offline. execute_replacement and run_deanonymize are pure
text-processing functions; entities and pass1_result dicts are constructed by
hand, so no LLM or network call is ever made.

Covered regressions:
- Bug #3: the "Smith" ambiguity (one surface text shared by two canonical
  groups must restore to the correct original everywhere).
- Bug #2 / #8: a short numeric entity ("1") must not collide with placeholder
  digits inserted for an earlier entity, and a single-pass replacement must not
  corrupt placeholders.
- Bug #4: a spaced/odd entity type ("reg num") must sanitize to a
  contract-conforming placeholder that the deanonymizer fully restores, with
  run_deanonymize reporting remaining_placeholders == 0 only when truly clean.

Placeholder grammar contract: r"\{[A-Z][A-Z0-9]*_\d+\}".
"""

import re

import pytest

from core.anonymizer import PLACEHOLDER_REGEX, execute_replacement
from core.deanonymizer import run_deanonymize


EMPTY_PASS1 = {"aliases": [], "entities": []}


def _assert_all_placeholders_conform(anonymized: str) -> None:
    """Every brace-delimited token in the output must match the contract."""
    for token in re.findall(r"\{[^{}]*\}", anonymized):
        assert re.fullmatch(PLACEHOLDER_REGEX, token), token
    # No nested or doubled braces anywhere.
    assert "{{" not in anonymized
    assert "}}" not in anonymized


def _assert_lossless(text: str, entities: list, pass1: dict = EMPTY_PASS1):
    """Anonymize then deanonymize and assert an exact, clean roundtrip."""
    anonymized, mapping = execute_replacement(text, entities, pass1)
    _assert_all_placeholders_conform(anonymized)
    restored, stats = run_deanonymize(anonymized, mapping)
    assert restored == text, (
        f"roundtrip not lossless\n"
        f"  original:   {text!r}\n"
        f"  anonymized: {anonymized!r}\n"
        f"  restored:   {restored!r}"
    )
    assert stats["remaining_placeholders"] == 0
    return anonymized, mapping, restored, stats


# ============================================================
# Bug #3: the "Smith" ambiguity
# ============================================================
def test_smith_ambiguity_roundtrip_lossless():
    # Arrange: "Smith" is simultaneously an alias of the person "John Smith"
    # and of the company "Smith Corp". A flat last-writer-wins placeholder map
    # mis-restores the standalone "Smith" at the end.
    text = "Smith Corp hired John Smith. Smith is the CEO."
    entities = [
        {"text": "Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith", "type": "company", "canonical": "Smith Corp"},
        {"text": "John Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith Corp", "type": "company", "canonical": "Smith Corp"},
    ]

    # Act + Assert
    anonymized, _, _, _ = _assert_lossless(text, entities)

    # The raw surface text must be fully scrubbed from the anonymized output.
    assert "Smith" not in anonymized


def test_smith_ambiguity_via_pass1_aliases_roundtrip_lossless():
    # Same ambiguity, but the alias relationships arrive through pass1_result
    # rather than per-entity canonical fields. This exercises the alias-merge
    # path in execute_replacement.
    text = "Smith Corp hired John Smith. Smith is the CEO."
    entities = [
        {"text": "John Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith Corp", "type": "company", "canonical": "Smith Corp"},
        {"text": "Smith", "type": "person", "canonical": "John Smith"},
        {"text": "Smith", "type": "company", "canonical": "Smith Corp"},
    ]
    pass1 = {
        "aliases": [
            {"canonical": "John Smith", "type": "person", "aliases": ["Smith"]},
            {"canonical": "Smith Corp", "type": "company", "aliases": ["Smith"]},
        ],
        "entities": [],
    }

    _assert_lossless(text, entities, pass1)


# ============================================================
# Bug #2 / #8: short numeric entity colliding with placeholder digits
# ============================================================
def test_short_numeric_entity_roundtrip_lossless():
    # Arrange: the amount "1" appears both standalone and would, under a naive
    # cascading str.replace, match the digit inside an earlier company
    # placeholder (e.g. "{COMPANY_1}"). The roundtrip must survive that.
    text = "Invoice number 1 for Alpha Beta Company. Quantity: 1 unit."
    entities = [
        {"text": "Alpha Beta Company", "type": "company", "canonical": ""},
        {"text": "1", "type": "amount", "canonical": ""},
    ]

    # Act
    anonymized, mapping, _, _ = _assert_lossless(text, entities)

    # Assert: company placeholder survived intact (its "1" was not rewritten).
    found = re.findall(PLACEHOLDER_REGEX, anonymized)
    assert "{COMPANY_1}" in found
    # No placeholder digit was clobbered into nested garbage.
    assert "{COMPANY_{" not in anonymized


def test_numeric_collision_with_placeholder_index_roundtrip_lossless():
    # Adversarial: the standalone amount text is exactly "1", which is also the
    # numeric suffix the company placeholder "{COMPANY_1}" carries. If the
    # restore step ever matched on the suffix, this would break.
    text = "Acme Holdings owes 1 dollar. Acme Holdings filed report 1."
    entities = [
        {"text": "Acme Holdings", "type": "company", "canonical": ""},
        {"text": "1", "type": "amount", "canonical": ""},
    ]

    _assert_lossless(text, entities)


# ============================================================
# Bug #4: spaced / odd entity type produces a conforming placeholder
# ============================================================
def test_spaced_type_roundtrip_lossless_and_clean_count():
    # Arrange: a multi-token type "reg num" must slugify to "REGNUM" so the
    # emitted placeholder conforms to the contract and the deanonymizer's
    # remaining-placeholder count can detect it.
    text = "Registration: 91310000XYZ recorded on file."
    entities = [{"text": "91310000XYZ", "type": "reg num", "canonical": ""}]

    # Act
    anonymized, mapping, _, stats = _assert_lossless(text, entities)

    # Assert: exactly one conforming placeholder, no spaces inside it.
    found = re.findall(PLACEHOLDER_REGEX, anonymized)
    assert found == ["{REGNUM_1}"]
    assert "{REG NUM_1}" not in anonymized
    assert "{REGNUM_1}" in mapping["mappings"]
    assert stats["remaining_placeholders"] == 0


def test_remaining_count_nonzero_when_placeholder_truly_unmatched():
    # The clean-count guarantee must be honest: if the anonymized text carries a
    # conforming placeholder that the mapping cannot restore, run_deanonymize
    # must report remaining_placeholders > 0 rather than falsely claiming 0.
    # We hand-build a mapping with an empty log and empty mappings so none of
    # the three restore steps can touch the stray placeholder.
    stray_text = "Filed under {REGNUM_1} today."
    empty_mapping = {
        "metadata": {},
        "mappings": {},
        "replacement_log": [],
    }

    restored, stats = run_deanonymize(stray_text, empty_mapping)

    # Nothing could be restored, so the placeholder remains and is counted.
    assert restored == stray_text
    assert stats["remaining_placeholders"] == 1


def test_type_sanitizing_to_digits_roundtrip_lossless():
    # Edge of bug #4: a type that sanitizes to a digit-bearing token
    # ("9to5" -> "X9TO5"). The emit side must produce {X9TO5_1} and the
    # deanonymizer's broadened [A-Z][A-Z0-9]* regex must still detect and
    # restore it. This is the case the narrow [A-Z]+ regex used to miss.
    text = "Shift type 9to5 applies here."
    entities = [{"text": "9to5", "type": "9to5", "canonical": ""}]

    anonymized, mapping, _, _ = _assert_lossless(text, entities)

    found = re.findall(PLACEHOLDER_REGEX, anonymized)
    assert found == ["{X9TO5_1}"]


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
