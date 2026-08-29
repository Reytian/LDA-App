#!/usr/bin/env python3
"""Structural validator for the LDA benchmark golden corpus.

Every document in bench/corpus/ is checked against the invariants the scorer
relies on. If any of these break, the scores computed later are meaningless,
so this runs as a gate before any model is invoked.

Checks, in order of severity:

ERROR   the file is not valid JSON, or a required key is missing
ERROR   id does not match the filename stem
ERROR   a gold entry has a type outside the seven wire types the contract allows
ERROR   a gold value is not a verbatim substring of text (the scorer does string
        matching, so a non-verbatim gold value can never be matched by any model)
ERROR   a gold_negatives entry is not a verbatim substring of text (a decoy that
        is not actually in the document cannot be fallen for)
ERROR   the same (value, type) pair appears twice in gold
ERROR   a value appears in both gold and gold_negatives after normalization,
        which would make the document self-contradictory
WARN    text length is outside the 300 to 3000 character band the corpus targets
WARN    a document has neither gold entries nor a control note

Usage:
    python3 bench/harness/validate_corpus.py [--corpus DIR] [--quiet]

Exit status is 0 when there are no errors, 1 otherwise. Warnings never fail
the run.

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import unicodedata

# The seven wire types the extraction contract allows. Sourced from
# PromptStore.defaultExtractionSystem and EntityJSONParser.mapType.
ALLOWED_TYPES = ("PERSON", "COMPANY", "DATE", "AMOUNT", "EMAIL", "PHONE", "ADDRESS")

ALLOWED_LANGS = ("zh", "en", "mixed")

REQUIRED_KEYS = ("id", "lang", "category", "adversarial", "text", "gold", "gold_negatives", "notes")

MIN_TEXT_CHARS = 300
MAX_TEXT_CHARS = 3000


def normalize(value: str) -> str:
    """Fold a surface value to the key the scorer compares on.

    NFKC collapses full-width forms onto their half-width equivalents, which is
    what makes a full-width comma or digit in a Chinese document comparable to
    the half-width form a model may return. Case folding, whitespace collapsing
    and outer punctuation stripping follow.
    """
    folded = unicodedata.normalize("NFKC", value)
    folded = "".join(ch for ch in folded if ch not in "​‌‍﻿")
    folded = " ".join(folded.split())
    folded = folded.strip(" \t\r\n\"'`,.;:()[]{}<>，。、；：（）【】《》")
    return folded.casefold()


class Finding:
    """One validation result attached to a file."""

    def __init__(self, level: str, path: pathlib.Path, message: str) -> None:
        self.level = level
        self.path = path
        self.message = message

    def render(self) -> str:
        return "{:<5} {}: {}".format(self.level, self.path.name, self.message)


def check_document(path: pathlib.Path, doc: dict) -> list[Finding]:
    """Run every structural check against one decoded document."""
    findings: list[Finding] = []

    def error(message: str) -> None:
        findings.append(Finding("ERROR", path, message))

    def warn(message: str) -> None:
        findings.append(Finding("WARN", path, message))

    missing = [key for key in REQUIRED_KEYS if key not in doc]
    if missing:
        error("missing required key(s): " + ", ".join(missing))
        return findings

    if doc["id"] != path.stem:
        error("id {!r} does not match filename stem {!r}".format(doc["id"], path.stem))

    if doc["lang"] not in ALLOWED_LANGS:
        error("lang {!r} is not one of {}".format(doc["lang"], ", ".join(ALLOWED_LANGS)))

    if not isinstance(doc["adversarial"], bool):
        error("adversarial must be a JSON boolean, got {}".format(type(doc["adversarial"]).__name__))

    text = doc["text"]
    if not isinstance(text, str) or not text.strip():
        error("text is empty or not a string")
        return findings

    if len(text) < MIN_TEXT_CHARS or len(text) > MAX_TEXT_CHARS:
        warn("text length {} is outside the {} to {} band".format(len(text), MIN_TEXT_CHARS, MAX_TEXT_CHARS))

    if not isinstance(doc["gold"], list):
        error("gold must be a list")
        return findings
    if not isinstance(doc["gold_negatives"], list):
        error("gold_negatives must be a list")
        return findings

    seen_pairs: set[tuple[str, str]] = set()
    gold_keys: set[str] = set()

    for index, entry in enumerate(doc["gold"]):
        label = "gold[{}]".format(index)
        if not isinstance(entry, dict):
            error("{} is not an object".format(label))
            continue
        if "value" not in entry or "type" not in entry:
            error("{} is missing value or type".format(label))
            continue

        value = entry["value"]
        etype = entry["type"]

        if not isinstance(value, str) or not value.strip():
            error("{} has an empty value".format(label))
            continue
        if etype not in ALLOWED_TYPES:
            error("{} type {!r} is outside the allowed set {}".format(label, etype, ", ".join(ALLOWED_TYPES)))

        if value not in text:
            error("{} value {!r} is not a verbatim substring of text".format(label, value))

        pair = (value, etype)
        if pair in seen_pairs:
            error("{} duplicates an earlier entry {!r}".format(label, pair))
        seen_pairs.add(pair)
        gold_keys.add(normalize(value))

    seen_negatives: set[str] = set()
    for index, negative in enumerate(doc["gold_negatives"]):
        label = "gold_negatives[{}]".format(index)
        if not isinstance(negative, str) or not negative.strip():
            error("{} is empty or not a string".format(label))
            continue
        if negative not in text:
            error("{} decoy {!r} is not a verbatim substring of text".format(label, negative))
        if negative in seen_negatives:
            error("{} duplicates an earlier decoy {!r}".format(label, negative))
        seen_negatives.add(negative)

        key = normalize(negative)
        if key in gold_keys:
            error(
                "{} decoy {!r} normalizes to the same key as a gold value, "
                "which makes the document self-contradictory".format(label, negative)
            )

    if not doc["gold"] and "control" not in doc["notes"].lower():
        warn("document has no gold entries but its notes do not describe it as a control")

    return findings


def main() -> int:
    default_corpus = pathlib.Path(__file__).resolve().parent.parent / "corpus"

    parser = argparse.ArgumentParser(description="Validate the LDA benchmark golden corpus.")
    parser.add_argument("--corpus", type=pathlib.Path, default=default_corpus, help="corpus directory")
    parser.add_argument("--quiet", action="store_true", help="print only the summary and any findings")
    args = parser.parse_args()

    if not args.corpus.is_dir():
        print("ERROR corpus directory not found: {}".format(args.corpus), file=sys.stderr)
        return 1

    paths = sorted(args.corpus.glob("*.json"))
    if not paths:
        print("ERROR no .json documents found in {}".format(args.corpus), file=sys.stderr)
        return 1

    findings: list[Finding] = []
    documents: list[dict] = []
    seen_ids: dict[str, pathlib.Path] = {}

    for path in paths:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            findings.append(Finding("ERROR", path, "invalid JSON: {}".format(exc)))
            continue
        except OSError as exc:
            findings.append(Finding("ERROR", path, "cannot read file: {}".format(exc)))
            continue

        if not isinstance(doc, dict):
            findings.append(Finding("ERROR", path, "top level value is not an object"))
            continue

        doc_id = doc.get("id")
        if isinstance(doc_id, str):
            if doc_id in seen_ids:
                findings.append(
                    Finding("ERROR", path, "duplicate id {!r}, already used by {}".format(doc_id, seen_ids[doc_id].name))
                )
            seen_ids[doc_id] = path

        findings.extend(check_document(path, doc))
        documents.append(doc)

    errors = [f for f in findings if f.level == "ERROR"]
    warnings = [f for f in findings if f.level == "WARN"]

    if not args.quiet:
        print_inventory(documents)

    for finding in findings:
        print(finding.render())

    print()
    print(
        "{} document(s) checked, {} error(s), {} warning(s)".format(
            len(documents), len(errors), len(warnings)
        )
    )

    return 1 if errors else 0


def print_inventory(documents: list[dict]) -> None:
    """Print the per-document and aggregate inventory of the corpus."""
    type_totals: dict[str, int] = {t: 0 for t in ALLOWED_TYPES}
    lang_totals: dict[str, int] = {}
    gold_total = 0
    negative_total = 0
    char_total = 0

    header = "{:<38} {:<6} {:<22} {:>5} {:>6} {:>5} {:>4}".format(
        "id", "lang", "category", "chars", "gold", "neg", "adv"
    )
    print(header)
    print("-" * len(header))

    for doc in sorted(documents, key=lambda d: d.get("id", "")):
        gold = doc.get("gold", [])
        negatives = doc.get("gold_negatives", [])
        gold_total += len(gold)
        negative_total += len(negatives)
        char_total += len(doc.get("text", ""))
        lang_totals[doc.get("lang", "?")] = lang_totals.get(doc.get("lang", "?"), 0) + 1
        for entry in gold:
            etype = entry.get("type")
            if etype in type_totals:
                type_totals[etype] += 1
        print(
            "{:<38} {:<6} {:<22} {:>5} {:>6} {:>5} {:>4}".format(
                doc.get("id", "?"),
                doc.get("lang", "?"),
                doc.get("category", "?"),
                len(doc.get("text", "")),
                len(gold),
                len(negatives),
                "yes" if doc.get("adversarial") else "no",
            )
        )

    print("-" * len(header))
    print(
        "{:<38} {:<6} {:<22} {:>5} {:>6} {:>5}".format(
            "TOTAL", "", "", char_total, gold_total, negative_total
        )
    )
    print()
    print("gold entities by type:")
    for etype in ALLOWED_TYPES:
        print("  {:<9} {:>3}".format(etype, type_totals[etype]))
    print("documents by language:")
    for lang in sorted(lang_totals):
        print("  {:<9} {:>3}".format(lang, lang_totals[lang]))
    print()


if __name__ == "__main__":
    sys.exit(main())
