#!/usr/bin/env python3
"""Structural validator for the LDA full-agreement benchmark documents.

bench/fulldocs/ holds complete contracts rather than the 300 to 900 character
fragments in bench/corpus/. They share the wire format exactly, so run_model.py
and score.py consume them unchanged, but they carry two extra invariants that
the fragment validator has no reason to check:

    the text is a full agreement, not a fragment (3500 to 6000 characters)
    the entities declared in tail_entities really are tail entities, meaning
    their FIRST occurrence falls inside the final 25% of the text

The second one is the entire point of these documents. A model that fatigues in
the back half of a long contract misses the notices clause, the signature page
and the annexes, which is exactly where the witness, the offshore signatory,
the escrow agent and every contact detail live. If a value listed in
tail_entities also appears early, a miss on it is no longer evidence of tail
fatigue and the measurement is void.

Every check in validate_corpus.py still applies and is reused directly by
import, so there is one definition of the shared rules. The fragment length
band is the only thing overridden.

Usage:
    python3 bench/harness/validate_fulldocs.py [--corpus DIR] [--quiet]

Exit status is 0 when there are no errors, 1 otherwise.

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import validate_corpus as vc

# Full agreements, not fragments. Overriding the module globals reconfigures the
# imported checker without editing bench/harness/validate_corpus.py.
MIN_FULLDOC_CHARS = 3500
MAX_FULLDOC_CHARS = 6000
vc.MIN_TEXT_CHARS = MIN_FULLDOC_CHARS
vc.MAX_TEXT_CHARS = MAX_FULLDOC_CHARS

TAIL_FRACTION = 0.75
MIN_TAIL_ENTITIES = 6
MIN_REPEATED_ENTITIES = 3
REPETITION_TARGET = 3


def check_fulldoc(path: pathlib.Path, doc: dict) -> list[vc.Finding]:
    """Run the full-agreement specific checks against one decoded document."""
    findings: list[vc.Finding] = []

    def error(message: str) -> None:
        findings.append(vc.Finding("ERROR", path, message))

    def warn(message: str) -> None:
        findings.append(vc.Finding("WARN", path, message))

    text = doc.get("text")
    if not isinstance(text, str) or not text.strip():
        return findings

    if "tail_entities" not in doc:
        error("missing required key: tail_entities")
        return findings

    tail = doc["tail_entities"]
    if not isinstance(tail, list):
        error("tail_entities must be a list")
        return findings

    if len(tail) < MIN_TAIL_ENTITIES:
        error(
            "only {} tail entities declared, at least {} are required to measure "
            "back-half fatigue".format(len(tail), MIN_TAIL_ENTITIES)
        )

    gold_values = {g["value"] for g in doc.get("gold", []) if isinstance(g, dict) and "value" in g}
    cut = int(len(text) * TAIL_FRACTION)
    seen: set[str] = set()

    for index, value in enumerate(tail):
        label = "tail_entities[{}]".format(index)
        if not isinstance(value, str) or not value.strip():
            error("{} is empty or not a string".format(label))
            continue
        if value in seen:
            error("{} duplicates an earlier entry {!r}".format(label, value))
        seen.add(value)

        if value not in gold_values:
            error("{} value {!r} is not present in gold".format(label, value))
            continue

        first = text.find(value)
        if first < cut:
            error(
                "{} value {!r} first occurs at character {} ({:.1f}% of the document), "
                "before the {:.0f}% tail boundary at character {}, so a miss on it is not "
                "evidence of tail fatigue".format(
                    label, value, first, first / len(text) * 100, TAIL_FRACTION * 100, cut
                )
            )

    repeated = sum(1 for value in gold_values if text.count(value) >= REPETITION_TARGET)
    if repeated < MIN_REPEATED_ENTITIES:
        warn(
            "only {} gold entities recur {} or more times; long-document fatigue is "
            "hard to attribute without repeated entities".format(repeated, REPETITION_TARGET)
        )

    return findings


def position_bucket(text: str, value: str) -> str:
    """Where in the document does this value first appear."""
    fraction = text.find(value) / len(text)
    if fraction < 0.50:
        return "head"
    if fraction < TAIL_FRACTION:
        return "mid"
    return "tail"


def print_report(documents: list[dict]) -> None:
    """Print the per-document gold breakdown by type and by position."""
    for doc in sorted(documents, key=lambda d: d.get("id", "")):
        text = doc.get("text", "")
        gold = doc.get("gold", [])
        if not text or not gold:
            continue
        print("{} ({}, {} chars, {} gold, {} decoys)".format(
            doc.get("id"), doc.get("lang"), len(text), len(gold), len(doc.get("gold_negatives", []))))

        by_type: dict[str, dict[str, int]] = {}
        for entry in gold:
            bucket = position_bucket(text, entry["value"])
            row = by_type.setdefault(entry["type"], {"head": 0, "mid": 0, "tail": 0})
            row[bucket] += 1

        print("  {:<9} {:>5} {:>5} {:>5} {:>6}".format("type", "head", "mid", "tail", "total"))
        totals = {"head": 0, "mid": 0, "tail": 0}
        for entity_type in vc.ALLOWED_TYPES:
            row = by_type.get(entity_type)
            if not row:
                continue
            for bucket in totals:
                totals[bucket] += row[bucket]
            print("  {:<9} {:>5} {:>5} {:>5} {:>6}".format(
                entity_type, row["head"], row["mid"], row["tail"], sum(row.values())))
        print("  {:<9} {:>5} {:>5} {:>5} {:>6}".format(
            "TOTAL", totals["head"], totals["mid"], totals["tail"], sum(totals.values())))

        repeated = sorted(
            ((text.count(g["value"]), g["value"]) for g in gold if text.count(g["value"]) >= REPETITION_TARGET),
            reverse=True,
        )
        print("  entities recurring {}+ times: {}".format(REPETITION_TARGET, len(repeated)))
        for count, value in repeated:
            print("    {:>2}x  {}".format(count, value))
        print()


def main() -> int:
    default = pathlib.Path(__file__).resolve().parent.parent / "fulldocs"
    parser = argparse.ArgumentParser(description="Validate the LDA full-agreement benchmark documents.")
    parser.add_argument("--corpus", type=pathlib.Path, default=default, help="fulldocs directory")
    parser.add_argument("--quiet", action="store_true", help="skip the position report")
    args = parser.parse_args()

    if not args.corpus.is_dir():
        print("ERROR directory not found: {}".format(args.corpus), file=sys.stderr)
        return 1

    paths = sorted(args.corpus.glob("*.json"))
    if not paths:
        print("ERROR no .json documents found in {}".format(args.corpus), file=sys.stderr)
        return 1

    findings: list[vc.Finding] = []
    documents: list[dict] = []

    for path in paths:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            findings.append(vc.Finding("ERROR", path, "invalid JSON: {}".format(exc)))
            continue
        except OSError as exc:
            findings.append(vc.Finding("ERROR", path, "cannot read file: {}".format(exc)))
            continue

        if not isinstance(doc, dict):
            findings.append(vc.Finding("ERROR", path, "top level value is not an object"))
            continue

        findings.extend(vc.check_document(path, doc))
        findings.extend(check_fulldoc(path, doc))
        documents.append(doc)

    if not args.quiet:
        print_report(documents)

    for finding in findings:
        print(finding.render())

    errors = [f for f in findings if f.level == "ERROR"]
    warnings = [f for f in findings if f.level == "WARN"]
    print()
    print("{} document(s) checked, {} error(s), {} warning(s)".format(
        len(documents), len(errors), len(warnings)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
