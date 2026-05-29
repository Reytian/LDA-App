"""
Live end-to-end smoke test of the LDA pipeline against a real local LLM.

This drives the SHIPPED client (core.llm_client) with NO monkeypatching: the
ollama backend now lives in the client itself. Run it on a host where Ollama
serves gemma4-v4 (e.g. the Mac Mini) with the ollama backend selected:

    LLM_BACKEND=ollama LLM_MODEL=gemma4-v4 \
    LLM_OLLAMA_BASE=http://127.0.0.1:11434 LLM_TIMEOUT=600 \
    python3 smoke_gemma.py

Runs Pass 1 -> Pass 2 -> replacement -> de-anonymization and checks:
  - per-phase latency
  - no residual sensitive value leaks into the anonymized text
  - no malformed/nested placeholder grammar
  - restoration stats (no remaining placeholders)
  - the round-trip is lossless
Exits nonzero on failure.
"""

import os
import re
import sys
import time

# Make the local package importable regardless of CWD.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from core import llm_client
from core.anonymizer import (
    run_first_pass,
    run_second_pass,
    execute_replacement,
    PLACEHOLDER_REGEX,
)
from core.deanonymizer import run_deanonymize

llm_client.reload_config()


def main() -> int:
    if llm_client.LLM_BACKEND != "ollama":
        print(
            f"[config] WARNING: LLM_BACKEND={llm_client.LLM_BACKEND!r}; "
            "this smoke test expects LLM_BACKEND=ollama against a gemma4-v4 host."
        )

    sample = os.path.join(os.path.dirname(__file__), "tests", "sample_contract.txt")
    with open(sample, "r", encoding="utf-8") as f:
        original = f.read()

    print(
        f"Backend: {llm_client.LLM_BACKEND}  Model: {llm_client.LLM_MODEL}  "
        f"Ollama base: {llm_client.LLM_OLLAMA_BASE}  Timeout: {llm_client.LLM_TIMEOUT}s"
    )
    print(f"Document: {len(original)} chars\n")

    t0 = time.time()
    pass1 = run_first_pass(original)
    t1 = time.time()
    print(
        f"[Pass 1] {t1 - t0:.1f}s  type={pass1.get('document_type')!r}  "
        f"aliases={len(pass1.get('aliases', []))}  entities={len(pass1.get('entities', []))}"
    )

    entities = run_second_pass(original, pass1)
    t2 = time.time()
    print(f"[Pass 2] {t2 - t1:.1f}s  unique sensitive items={len(entities)}")
    for e in entities:
        print(
            f"    - {e.get('text')!r}  ({e.get('type')})  canonical={e.get('canonical')!r}"
        )

    anonymized, mapping = execute_replacement(
        original, entities, pass1, source_filename="sample_contract.txt"
    )
    t3 = time.time()
    placeholders = re.findall(PLACEHOLDER_REGEX, anonymized)
    print(
        f"\n[Replace] {t3 - t2:.1f}s  placeholders inserted={len(placeholders)}  "
        f"distinct={len(set(placeholders))}"
    )
    print(
        f"[Replace] mapping entries={len(mapping['mappings'])}  "
        f"log entries={len(mapping['replacement_log'])}"
    )

    # Leak check: no original sensitive value should survive in the anonymized text.
    leaks = []
    for ph, info in mapping["mappings"].items():
        for needle in [info.get("value", "")] + list(info.get("aliases", [])):
            if needle and needle in anonymized:
                leaks.append((ph, needle))
    print(f"[Leak check] residual sensitive strings in anonymized text: {len(leaks)}")
    for ph, needle in leaks:
        print(f"    LEAK {ph}: {needle!r}")

    # Malformed-placeholder grammar check (bugs #2/#8 regression).
    malformed = re.findall(r"\{[A-Z]*\{|\}\}", anonymized)
    print(f"[Grammar check] malformed/nested placeholder fragments: {len(malformed)}")

    restored, stats = run_deanonymize(anonymized, mapping)
    t4 = time.time()
    print(f"\n[Restore] {t4 - t3:.2f}s  {stats}")

    lossless = restored == original
    print(f"\n[ROUNDTRIP] lossless == {lossless}")
    if not lossless:
        # Show first divergence for debugging.
        for i, (a, b) in enumerate(zip(restored, original)):
            if a != b:
                print(
                    f"    first diff at char {i}: "
                    f"restored={restored[i:i + 30]!r} vs original={original[i:i + 30]!r}"
                )
                break
        if len(restored) != len(original):
            print(f"    length differs: restored={len(restored)} original={len(original)}")

    print("\n----- ANONYMIZED EXCERPT (first 600 chars) -----")
    print(anonymized[:600])

    ok = (
        lossless
        and not leaks
        and not malformed
        and stats["remaining_placeholders"] == 0
    )
    print(f"\n=== SMOKE {'PASS' if ok else 'FAIL'} ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
