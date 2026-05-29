"""
Live end-to-end test against a real local model (e.g. gemma4-v4 via Ollama).

This test exercises the SHIPPED client (core.llm_client.call_llm) through the
full anonymize -> deanonymize pipeline. It is the only test that touches the
network, so it is guarded and SKIPS by default. CI never runs it.

To run it locally against a warm local model:

    LDA_LIVE_TEST=1 LLM_BACKEND=ollama LLM_MODEL=gemma4-v4 \
        python3 -m pytest tests/test_live_gemma.py -q

The guard checks LDA_LIVE_TEST only; the backend and model are configured via
the same env vars the shipped client reads (LLM_BACKEND, LLM_MODEL,
LLM_OLLAMA_BASE), so nothing in this file pins a backend implicitly.
"""

import os

import pytest

# A short synthetic document with known PII across several entity types. No real
# personal data; safe to ship in the repo.
SAMPLE_DOCUMENT = (
    "ENGAGEMENT LETTER\n\n"
    "This Engagement Letter is entered into as of January 15, 2024 between "
    "Northwind Trading LLC (the \"Client\") and Jonathan Reyes, Esq. (the "
    "\"Attorney\").\n\n"
    "The Client's principal place of business is 482 Harbor Avenue, Seattle, "
    "Washington. The Attorney may be reached at jonathan.reyes@example.com or "
    "by phone at (206) 555-0147.\n\n"
    "The Client agrees to pay a retainer of $25,000 upon execution of this "
    "letter. Northwind Trading LLC further agrees that all invoices are due "
    "within thirty days.\n"
)

# Surface strings that must NOT survive in the anonymized output. Each is a
# distinct piece of sensitive data the two-pass scan is expected to catch.
EXPECTED_PII = [
    "Northwind Trading LLC",
    "Jonathan Reyes",
    "482 Harbor Avenue",
    "jonathan.reyes@example.com",
    "(206) 555-0147",
    "$25,000",
]


@pytest.mark.skipif(
    not os.getenv("LDA_LIVE_TEST"),
    reason="set LDA_LIVE_TEST=1 and LLM_BACKEND=ollama to run against a real local model",
)
def test_live_roundtrip_and_no_residual_pii():
    # Import inside the test so module collection never requires a live backend.
    from core.anonymizer import (
        run_first_pass,
        run_second_pass,
        execute_replacement,
    )
    from core.deanonymizer import run_deanonymize

    # Pick up env-driven config the live run depends on (backend/model/base).
    from core import llm_client

    llm_client.reload_config()

    # Pass 1 -> Pass 2 -> replacement, all through the shipped LLM client.
    pass1 = run_first_pass(SAMPLE_DOCUMENT)
    entities = run_second_pass(SAMPLE_DOCUMENT, pass1)
    anonymized_text, mapping = execute_replacement(
        SAMPLE_DOCUMENT, entities, pass1, source_filename="engagement_letter.txt"
    )

    # Zero residual PII: none of the known sensitive strings may remain.
    leaked = [pii for pii in EXPECTED_PII if pii in anonymized_text]
    assert not leaked, f"PII leaked into anonymized text: {leaked}"

    # Sanity: the model actually replaced something (not a no-op pass).
    assert mapping["mappings"], "no placeholders were produced"

    # Lossless roundtrip: deanonymizing restores the original document exactly.
    restored, stats = run_deanonymize(anonymized_text, mapping)
    assert stats["remaining_placeholders"] == 0
    assert restored == SAMPLE_DOCUMENT
