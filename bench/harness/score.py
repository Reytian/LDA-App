#!/usr/bin/env python3
"""Score model runs against the LDA benchmark golden corpus.

Reads one or more run files produced by the model runner and reports extraction
quality, output hygiene, and cost side by side for every model.

Input, one file per model, at bench/results/<label>.raw.json:

    {
      "label": "finetune-lda-v2",
      "weights_mb": 2583.0,
      "load_seconds": 1.0,
      "peak_rss_mb": 3354.0,
      "peak_rss_gb": 3.28,
      "docs": [
        {"id": "001-cn-equity-transfer", "latency_s": 8.4,
         "raw_output": "...", "reasoning_content": "", "finish_reason": "stop",
         "prompt_tokens": 512, "completion_tokens": 167, "gen_tok_per_s": 19.9}
      ]
    }

Usage:
    python3 bench/harness/score.py --corpus bench/corpus --results bench/results \
        --out bench/results/scores.json [--verbose]

Design notes that matter for reading the numbers:

Parse tiers. Real small models do not honor the JSON contract uniformly. Every
raw output is pushed through an escalating rescue ladder and the first rung that
yields a usable entity container is recorded:

    clean                json.loads on the trimmed output worked
    stripped_fence       a Markdown code fence had to be removed first
    extracted_substring  JSON had to be cut out of surrounding prose
    repaired             structural repair was needed: truncation salvage,
                         trailing-comma or unclosed-bracket repair, Python
                         literal syntax, or concatenated NDJSON objects
    unparseable          nothing worked, the chunk is unscanned

The tier histogram is the integration-cost metric. A model that lands on
stripped_fence for Chinese and clean for English has a language-conditional
format drift, which the per-document tier detail exposes.

Schema deviations are tracked separately from parse tiers because they cost
adapter code rather than parser code: a bare array instead of the contracted
{"entities": [...]} object, an alternate container key, alternate value keys
(text, entity, name), alternate type keys, or a type vocabulary outside the
seven wire types.

Type handling follows production. EntityJSONParser.mapType uppercases the wire
string before matching, so "company" and "COMPANY" are equivalent and neither is
penalized. A type outside the recognized wire vocabulary becomes .unknown in
production, so alias types such as ORG or 公司 are mapped here for scoring but
also counted in production_unknown_type_rate, which is what would actually
happen on device.

Strict versus lenient matching. EntityLocator re-anchors a reported value by
case-insensitive verbatim substring search over the source text. A value that
drifts from the source either fails to anchor at all (an added honorific or
title) or anchors on a fragment (a clipped surname), and both outcomes leak PII.
Strict equality is therefore the production-faithful metric. Lenient
containment is reported only as a diagnostic: the gap between lenient and strict
is the share of entities the model located conceptually but reported in a
surface form that would still leak.

Critical versus backstopped types. DeterministicEngine detects EMAIL, PHONE,
DATE, AMOUNT and the structured identifiers by regex, and SpanMerger gives those
detections priority. It does not detect PERSON, COMPANY or ADDRESS at all, so
the LLM is their only detector. A miss on a critical type is an unrecoverable
leak; a miss on a backstopped type is usually covered by the regex layer. The
composite score weights them accordingly.

Standard library only.
"""

from __future__ import annotations

import argparse
import ast
import json
import pathlib
import re
import sys
import unicodedata

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

try:
    from validate_corpus import normalize as normalize_strict
except ImportError:  # pragma: no cover, keeps score.py runnable in isolation
    def normalize_strict(value: str) -> str:
        folded = unicodedata.normalize("NFKC", value)
        folded = "".join(ch for ch in folded if ch not in "​‌‍﻿")
        folded = " ".join(folded.split())
        folded = folded.strip(" \t\r\n\"'`,.;:()[]{}<>，。、；：（）【】《》")
        return folded.casefold()


# ------------------------------------------------------------------ constants

SEVEN_TYPES = ("PERSON", "COMPANY", "DATE", "AMOUNT", "EMAIL", "PHONE", "ADDRESS")

# Types the LLM alone can detect. DeterministicEngine explicitly does not
# implement these, so a miss here is an unrecoverable leak.
CRITICAL_TYPES = ("PERSON", "COMPANY", "ADDRESS")

# Types with a deterministic regex backstop in production.
BACKSTOPPED_TYPES = ("DATE", "AMOUNT", "EMAIL", "PHONE")

# Wire strings EntityJSONParser.mapType recognizes. Anything else becomes
# .unknown on device, whatever this scorer manages to map it to.
PRODUCTION_WIRE_TYPES = SEVEN_TYPES + ("NATIONAL_ID", "USCC", "BANK_ACCOUNT")

# Alias table used only so a model is scored on what it found rather than on how
# it spelled the type. Every hit here is also counted as a production .unknown.
TYPE_ALIASES = {
    "PER": "PERSON", "PERSON_NAME": "PERSON", "NAME": "PERSON", "PEOPLE": "PERSON",
    "INDIVIDUAL": "PERSON", "人名": "PERSON", "姓名": "PERSON", "个人": "PERSON",
    "自然人": "PERSON",
    "ORG": "COMPANY", "ORGANIZATION": "COMPANY", "ORGANISATION": "COMPANY",
    "COMPANY_NAME": "COMPANY", "CORP": "COMPANY", "CORPORATION": "COMPANY",
    "ENTITY": "COMPANY", "公司": "COMPANY", "企业": "COMPANY", "机构": "COMPANY",
    "组织": "COMPANY", "单位": "COMPANY",
    "LOC": "ADDRESS", "LOCATION": "ADDRESS", "ADDR": "ADDRESS", "GPE": "ADDRESS",
    "PLACE": "ADDRESS", "地址": "ADDRESS", "住址": "ADDRESS", "地点": "ADDRESS",
    "MONEY": "AMOUNT", "CURRENCY": "AMOUNT", "AMT": "AMOUNT", "PRICE": "AMOUNT",
    "金额": "AMOUNT", "款项": "AMOUNT", "价格": "AMOUNT",
    "TIME": "DATE", "DATETIME": "DATE", "日期": "DATE", "时间": "DATE",
    "TEL": "PHONE", "PHONE_NUMBER": "PHONE", "TELEPHONE": "PHONE", "MOBILE": "PHONE",
    "FAX": "PHONE", "电话": "PHONE", "手机": "PHONE", "传真": "PHONE",
    "E-MAIL": "EMAIL", "MAIL": "EMAIL", "EMAIL_ADDRESS": "EMAIL",
    "邮箱": "EMAIL", "电子邮件": "EMAIL", "电邮": "EMAIL",
}

# Container keys accepted when the model wraps its list under something other
# than "entities". Order matters: the contracted key is tried first.
CONTAINER_KEYS = ("entities", "entity", "results", "items", "data", "output", "spans", "pii", "list")

# Value keys, contracted key first.
VALUE_KEYS = ("value", "text", "entity", "name", "surface", "span", "mention", "word", "原文", "值", "文本")

# Type keys, contracted key first.
TYPE_KEYS = ("type", "label", "entity_type", "category", "tag", "kind", "类型", "类别")

PARSE_TIERS = ("clean", "stripped_fence", "extracted_substring", "repaired", "unparseable")

# Memory ceilings. A 16 GB Mac needs headroom for the OS and the app, so the
# working budget is well under the nominal figure.
RSS_BUDGET_16GB = 12.0
RSS_BUDGET_32GB = 24.0

# Lenient containment guards. Without them a one-character prediction would
# "match" every gold value that happens to contain it.
LENIENT_MIN_CHARS = 2
LENIENT_MIN_RATIO = 0.5

FENCE_RE = re.compile(r"^\s*```[A-Za-z0-9_-]*\s*\n?|\n?\s*```\s*$")


# ------------------------------------------------------------------ normalizing

def normalize_nospace(value: str) -> str:
    """Strict normalization with every whitespace character removed.

    Used for lenient containment so that a CJK value written with an internal
    space still lines up with the unspaced source form.
    """
    return "".join(normalize_strict(value).split())


def estimate_tokens(text: str) -> int:
    """Rough token count without a tokenizer.

    CJK characters cost about one token each; other text runs about four
    characters per token. This is an estimate used only for reporting thinking
    overhead, never for scoring.
    """
    if not text:
        return 0
    cjk = 0
    other = 0
    for ch in text:
        code = ord(ch)
        if 0x3400 <= code <= 0x9FFF or 0xF900 <= code <= 0xFAFF or 0x3040 <= code <= 0x30FF or 0xAC00 <= code <= 0xD7AF:
            cjk += 1
        else:
            other += 1
    return cjk + (other + 3) // 4


# ------------------------------------------------------------------ JSON rescue

def strip_fences(text: str) -> str:
    """Remove a leading and trailing Markdown code fence if both are present."""
    stripped = text.strip()
    if "```" not in stripped:
        return stripped
    without = FENCE_RE.sub("", stripped)
    without = FENCE_RE.sub("", without)
    return without.strip()


def balanced_regions(text: str, opener: str, closer: str) -> list[str]:
    """Every complete top level region delimited by opener and closer.

    String literals are honored so a brace inside a quoted value never throws
    off the depth count. Mirrors EntityJSONParser.largestBalancedRegion.
    """
    regions: list[str] = []
    depth = 0
    start = None
    in_string = False
    escaped = False

    for index, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
            continue
        if ch == opener:
            if depth == 0:
                start = index
            depth += 1
        elif ch == closer and depth > 0:
            depth -= 1
            if depth == 0 and start is not None:
                regions.append(text[start:index + 1])
                start = None
    return regions


def salvage_truncated(text: str) -> tuple[list, bool]:
    """Recover complete entity objects emitted before a truncation point.

    Walks the entity array object by object and stops at the first object that
    never closes. Returns the recovered objects and whether the array was left
    unbalanced, which is the truncation signal.
    """
    start = None
    key_pos = text.find('"entities"')
    if key_pos == -1:
        key_pos = text.find('"entity"')
    if key_pos != -1:
        bracket = text.find("[", key_pos)
        if bracket != -1:
            start = bracket + 1
    if start is None:
        bracket = text.find("[")
        if bracket == -1:
            return [], False
        start = bracket + 1

    recovered: list = []
    index = start
    closed = False

    while index < len(text):
        while index < len(text) and text[index] not in "{]":
            index += 1
        if index >= len(text):
            break
        if text[index] == "]":
            closed = True
            break
        regions = balanced_regions(text[index:], "{", "}")
        if not regions or not text[index:].startswith(regions[0]):
            break
        chunk = regions[0]
        try:
            recovered.append(json.loads(chunk))
        except json.JSONDecodeError:
            pass
        index += len(chunk)

    return recovered, not closed


def repair_attempts(text: str) -> list[tuple[str, object]]:
    """Structural repairs, each returning a repair name and a decoded object."""
    results: list[tuple[str, object]] = []

    salvaged, truncated = salvage_truncated(text)
    if salvaged:
        results.append(("truncation_salvage" if truncated else "object_walk", salvaged))

    # Trailing commas plus unclosed brackets, the classic cap-hit shape.
    trimmed = text.strip().rstrip(",")
    for suffix in ("]", "}", "]}", "}]"):
        candidate = trimmed + suffix
        try:
            results.append(("bracket_close", json.loads(candidate)))
            break
        except json.JSONDecodeError:
            continue

    # Python literal syntax: single quoted keys and values, True/None.
    try:
        results.append(("python_literal", ast.literal_eval(text.strip())))
    except (ValueError, SyntaxError, MemoryError, RecursionError):
        pass

    # Concatenated or newline delimited objects.
    objects = []
    for region in balanced_regions(text, "{", "}"):
        try:
            objects.append(json.loads(region))
        except json.JSONDecodeError:
            continue
    if len(objects) > 1:
        results.append(("ndjson_objects", objects))

    return results


def find_container(decoded: object) -> tuple[list, str] | None:
    """Locate the entity list inside a decoded object and name its shape."""
    if isinstance(decoded, list):
        if not decoded:
            return [], "bare_array"
        if all(isinstance(item, dict) for item in decoded):
            return decoded, "bare_array"
        if all(isinstance(item, str) for item in decoded):
            return [{"value": item} for item in decoded], "string_array"
        return [item for item in decoded if isinstance(item, dict)], "bare_array"

    if isinstance(decoded, dict):
        for key in CONTAINER_KEYS:
            for actual in decoded:
                if actual.lower() == key and isinstance(decoded[actual], list):
                    shape = "object_entities" if key == "entities" else "alt_container_key:" + actual
                    items = decoded[actual]
                    if items and all(isinstance(item, str) for item in items):
                        return [{"value": item} for item in items], shape + "+string_array"
                    return [item for item in items if isinstance(item, dict)], shape

        # A single entity object returned bare.
        lowered = {k.lower() for k in decoded}
        if lowered & set(VALUE_KEYS):
            return [decoded], "single_object"

        # A map keyed by type, for example {"PERSON": ["Jane Roe"]}.
        if decoded and all(isinstance(v, list) for v in decoded.values()):
            items = []
            for type_key, values in decoded.items():
                for value in values:
                    if isinstance(value, str):
                        items.append({"value": value, "type": type_key})
                    elif isinstance(value, dict):
                        item = dict(value)
                        item.setdefault("type", type_key)
                        items.append(item)
            if items:
                return items, "type_keyed_map"

    return None


class ParseResult:
    """Outcome of pushing one raw output through the rescue ladder."""

    def __init__(self) -> None:
        self.tier = "unparseable"
        self.shape = "none"
        self.items: list[dict] = []
        self.parser_truncated = False
        self.repairs: list[str] = []


def parse_raw_output(raw: str) -> ParseResult:
    """Push one raw model output through the escalating rescue ladder."""
    result = ParseResult()
    if not isinstance(raw, str) or not raw.strip():
        return result

    # Rung 1: the output is already JSON.
    try:
        decoded = json.loads(raw.strip())
    except json.JSONDecodeError:
        decoded = None
    if decoded is not None:
        found = find_container(decoded)
        if found is not None:
            result.tier, result.items, result.shape = "clean", found[0], found[1]
            return result

    # Rung 2: a Markdown fence is in the way.
    unfenced = strip_fences(raw)
    if unfenced != raw.strip():
        try:
            decoded = json.loads(unfenced)
        except json.JSONDecodeError:
            decoded = None
        if decoded is not None:
            found = find_container(decoded)
            if found is not None:
                result.tier, result.items, result.shape = "stripped_fence", found[0], found[1]
                return result

    # Rung 3: JSON is embedded in prose, so cut out the largest balanced region.
    candidates: list[str] = []
    for source in (unfenced, raw):
        for opener, closer in (("{", "}"), ("[", "]")):
            regions = balanced_regions(source, opener, closer)
            if regions:
                candidates.append(max(regions, key=len))
    candidates.sort(key=len, reverse=True)
    for candidate in candidates:
        try:
            decoded = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        found = find_container(decoded)
        if found is not None:
            result.tier, result.items, result.shape = "extracted_substring", found[0], found[1]
            return result

    # Rung 4: structural repair.
    for name, decoded in repair_attempts(unfenced):
        found = find_container(decoded)
        if found is not None:
            shape = found[1]
            # Salvage hands back a bare Python list whatever the model wrote, so
            # recover the shape the model actually emitted before the cut.
            # Without this a contract-shaped output that merely hit the token cap
            # would be reported as an off-contract bare array.
            if name in ("truncation_salvage", "object_walk") and '"entities"' in unfenced:
                shape = "object_entities"
            result.tier, result.items, result.shape = "repaired", found[0], shape
            result.repairs.append(name)
            result.parser_truncated = name == "truncation_salvage"
            return result

    return result


# ------------------------------------------------------------------ prediction

class Prediction:
    """One entity a model reported, plus how far its shape strayed."""

    def __init__(self, value: str, raw_type: str, deviations: set[str]) -> None:
        self.value = value
        self.raw_type = raw_type
        self.deviations = deviations
        upper = (raw_type or "").strip().upper()
        self.canonical_type = "UNKNOWN"
        self.production_unknown = False
        self.out_of_vocab = False

        if upper in SEVEN_TYPES:
            self.canonical_type = upper
        elif upper in PRODUCTION_WIRE_TYPES:
            # Recognized on device but outside the seven the prompt asks for.
            self.canonical_type = "UNKNOWN"
            self.out_of_vocab = True
        elif upper in TYPE_ALIASES:
            self.canonical_type = TYPE_ALIASES[upper]
            self.production_unknown = True
            self.deviations.add("type_alias")
        else:
            self.canonical_type = "UNKNOWN"
            self.production_unknown = True
            self.out_of_vocab = True
            self.deviations.add("type_out_of_vocab")

        self.key_strict = normalize_strict(value)
        self.key_nospace = normalize_nospace(value)


def build_predictions(items: list[dict]) -> tuple[list[Prediction], set[str]]:
    """Turn raw entity dicts into Predictions, recording schema deviations."""
    predictions: list[Prediction] = []
    deviations: set[str] = set()

    for item in items:
        if not isinstance(item, dict):
            continue
        lowered = {k.lower(): v for k, v in item.items()}

        value = None
        for index, key in enumerate(VALUE_KEYS):
            if key in lowered and isinstance(lowered[key], (str, int, float)):
                value = str(lowered[key])
                if index > 0:
                    deviations.add("alt_value_key:" + key)
                break
        if value is None or not value.strip():
            deviations.add("missing_value")
            continue

        raw_type = ""
        for index, key in enumerate(TYPE_KEYS):
            if key in lowered and isinstance(lowered[key], (str, int, float)):
                raw_type = str(lowered[key])
                if index > 0:
                    deviations.add("alt_type_key:" + key)
                break
        if not raw_type:
            deviations.add("missing_type")

        per_item: set[str] = set()
        predictions.append(Prediction(value.strip(), raw_type, per_item))
        deviations |= per_item

    return predictions, deviations


# ------------------------------------------------------------------ matching

def lenient_pairs(gold_keys: list[tuple[str, str]], pred_keys: list[tuple[str, str]]) -> int:
    """Count one-to-one lenient matches between gold and predictions.

    Both sides carry (nospace key, type). A pair matches when the types agree
    and one key contains the other, subject to the length guards that stop a
    tiny fragment from matching everything. Longest gold values are matched
    first so a long value never loses its partner to a short one.
    """
    remaining = list(pred_keys)
    matched = 0

    for gold_key, gold_type in sorted(gold_keys, key=lambda item: len(item[0]), reverse=True):
        best_index = None
        for index, (pred_key, pred_type) in enumerate(remaining):
            if pred_type != gold_type:
                continue
            if gold_key == pred_key:
                best_index = index
                break
            if gold_key in pred_key or pred_key in gold_key:
                shorter, longer = sorted((len(gold_key), len(pred_key)))
                if shorter >= LENIENT_MIN_CHARS and longer > 0 and shorter / longer >= LENIENT_MIN_RATIO:
                    if best_index is None:
                        best_index = index
        if best_index is not None:
            remaining.pop(best_index)
            matched += 1

    return matched


def prf(true_positive: int, predicted: int, actual: int) -> dict:
    """Precision, recall and F1 with explicit zero handling."""
    precision = true_positive / predicted if predicted else 0.0
    recall = true_positive / actual if actual else 0.0
    f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
    return {
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "f1": round(f1, 4),
        "tp": true_positive,
        "predicted": predicted,
        "gold": actual,
    }


# ------------------------------------------------------------------ scoring

def score_document(doc: dict, run_doc: dict) -> dict:
    """Score one model output against one corpus document."""
    parsed = parse_raw_output(run_doc.get("raw_output", ""))
    predictions, deviations = build_predictions(parsed.items)

    raw_prediction_count = len(predictions)
    deduped: dict[tuple[str, str], Prediction] = {}
    for prediction in predictions:
        deduped.setdefault((prediction.key_strict, prediction.canonical_type), prediction)
    unique = list(deduped.values())

    gold_pairs = {(normalize_strict(g["value"]), g["type"]) for g in doc["gold"]}
    gold_values = {normalize_strict(g["value"]): g["type"] for g in doc["gold"]}
    negatives = {normalize_strict(n) for n in doc["gold_negatives"]}

    predicted_pairs = {(p.key_strict, p.canonical_type) for p in unique}
    strict_tp = len(gold_pairs & predicted_pairs)

    gold_lenient = [(normalize_nospace(g["value"]), g["type"]) for g in doc["gold"]]
    pred_lenient = [(p.key_nospace, p.canonical_type) for p in unique]
    lenient_tp = lenient_pairs(gold_lenient, pred_lenient)

    # Type confusion: the value was found but labelled with the wrong type.
    confusion: list[dict] = []
    for prediction in unique:
        gold_type = gold_values.get(prediction.key_strict)
        if gold_type is not None and gold_type != prediction.canonical_type:
            confusion.append({"value": prediction.value, "gold": gold_type, "predicted": prediction.canonical_type})

    decoys_hit = sorted({p.key_strict for p in unique if p.key_strict in negatives})
    decoy_predictions = sum(1 for p in unique if p.key_strict in negatives)

    missed = sorted(
        {g["value"] for g in doc["gold"] if (normalize_strict(g["value"]), g["type"]) not in predicted_pairs}
    )

    per_type: dict[str, dict] = {}
    for entity_type in SEVEN_TYPES:
        gold_of_type = {pair for pair in gold_pairs if pair[1] == entity_type}
        pred_of_type = {pair for pair in predicted_pairs if pair[1] == entity_type}
        per_type[entity_type] = {
            "tp": len(gold_of_type & pred_of_type),
            "predicted": len(pred_of_type),
            "gold": len(gold_of_type),
        }

    return {
        "id": doc["id"],
        "lang": doc["lang"],
        "adversarial": doc["adversarial"],
        "parse_tier": parsed.tier,
        "shape": parsed.shape,
        "repairs": parsed.repairs,
        "parser_truncated": parsed.parser_truncated,
        "deviations": sorted(deviations),
        "raw_predictions": raw_prediction_count,
        "unique_predictions": len(unique),
        "gold_count": len(gold_pairs),
        "strict_tp": strict_tp,
        "lenient_tp": lenient_tp,
        "per_type": per_type,
        "confusion": confusion,
        "decoys_hit": decoys_hit,
        "decoy_predictions": decoy_predictions,
        "decoy_total": len(negatives),
        "missed_gold": missed,
        "production_unknown": sum(1 for p in unique if p.production_unknown),
        "out_of_vocab": sum(1 for p in unique if p.out_of_vocab),
        "finish_reason": run_doc.get("finish_reason", ""),
        "latency_s": run_doc.get("latency_s"),
        "gen_tok_per_s": run_doc.get("gen_tok_per_s"),
        "completion_tokens": run_doc.get("completion_tokens"),
        "reasoning_chars": len(run_doc.get("reasoning_content") or ""),
        "reasoning_est_tokens": estimate_tokens(run_doc.get("reasoning_content") or ""),
        "raw_output_chars": len(run_doc.get("raw_output") or ""),
    }


def aggregate(label: str, run: dict, corpus: dict, verbose: bool) -> dict:
    """Score every document for one model and roll the results up."""
    run_by_id = {d.get("id"): d for d in run.get("docs", [])}
    per_doc = []
    missing_ids = []

    for doc_id in sorted(corpus):
        run_doc = run_by_id.get(doc_id)
        if run_doc is None:
            missing_ids.append(doc_id)
            run_doc = {"raw_output": "", "finish_reason": "missing"}
        per_doc.append(score_document(corpus[doc_id], run_doc))

    tiers = {tier: 0 for tier in PARSE_TIERS}
    shapes: dict[str, int] = {}
    deviations: dict[str, int] = {}
    for entry in per_doc:
        tiers[entry["parse_tier"]] += 1
        shapes[entry["shape"]] = shapes.get(entry["shape"], 0) + 1
        for deviation in entry["deviations"]:
            deviations[deviation] = deviations.get(deviation, 0) + 1

    docs_total = len(per_doc)
    parsed_ok = docs_total - tiers["unparseable"]

    strict_tp = sum(e["strict_tp"] for e in per_doc)
    lenient_tp = sum(e["lenient_tp"] for e in per_doc)
    predicted = sum(e["unique_predictions"] for e in per_doc)
    gold_total = sum(e["gold_count"] for e in per_doc)

    micro_strict = prf(strict_tp, predicted, gold_total)
    micro_lenient = prf(lenient_tp, predicted, gold_total)

    per_type_totals = {t: {"tp": 0, "predicted": 0, "gold": 0} for t in SEVEN_TYPES}
    for entry in per_doc:
        for entity_type, counts in entry["per_type"].items():
            for field in ("tp", "predicted", "gold"):
                per_type_totals[entity_type][field] += counts[field]
    per_type_scores = {
        t: prf(v["tp"], v["predicted"], v["gold"]) for t, v in per_type_totals.items()
    }

    def group_scores(types: tuple[str, ...]) -> dict:
        tp = sum(per_type_totals[t]["tp"] for t in types)
        pred = sum(per_type_totals[t]["predicted"] for t in types)
        gold = sum(per_type_totals[t]["gold"] for t in types)
        return prf(tp, pred, gold)

    critical = group_scores(CRITICAL_TYPES)
    backstopped = group_scores(BACKSTOPPED_TYPES)

    # Lenient recall restricted to the critical types, computed per document so
    # the one-to-one matching stays inside a document.
    critical_lenient_tp = 0
    critical_gold = 0
    for doc_id in sorted(corpus):
        doc = corpus[doc_id]
        gold_side = [
            (normalize_nospace(g["value"]), g["type"]) for g in doc["gold"] if g["type"] in CRITICAL_TYPES
        ]
        critical_gold += len(gold_side)
        if not gold_side:
            continue
        run_doc = run_by_id.get(doc_id, {"raw_output": ""})
        parsed = parse_raw_output(run_doc.get("raw_output", ""))
        predictions, _ = build_predictions(parsed.items)
        seen = set()
        pred_side = []
        for p in predictions:
            key = (p.key_strict, p.canonical_type)
            if key in seen or p.canonical_type not in CRITICAL_TYPES:
                continue
            seen.add(key)
            pred_side.append((p.key_nospace, p.canonical_type))
        critical_lenient_tp += lenient_pairs(gold_side, pred_side)

    critical_lenient_recall = critical_lenient_tp / critical_gold if critical_gold else 0.0

    decoys_hit = sum(len(e["decoys_hit"]) for e in per_doc)
    decoy_total = sum(e["decoy_total"] for e in per_doc)
    decoy_predictions = sum(e["decoy_predictions"] for e in per_doc)

    control_docs = [e for e in per_doc if e["gold_count"] == 0]
    control_chars = sum(len(corpus[e["id"]]["text"]) for e in control_docs)
    control_fp = sum(e["unique_predictions"] for e in control_docs)

    adversarial_docs = [e for e in per_doc if e["adversarial"]]
    adversarial_decoys_hit = sum(len(e["decoys_hit"]) for e in adversarial_docs)
    adversarial_decoy_total = sum(e["decoy_total"] for e in adversarial_docs)

    truncated_by_finish = sum(1 for e in per_doc if e["finish_reason"] == "length")
    truncated_by_parser = sum(1 for e in per_doc if e["parser_truncated"])

    latencies = [e["latency_s"] for e in per_doc if isinstance(e["latency_s"], (int, float))]
    throughputs = [e["gen_tok_per_s"] for e in per_doc if isinstance(e["gen_tok_per_s"], (int, float))]
    completion_tokens = sum(e["completion_tokens"] or 0 for e in per_doc)
    reasoning_tokens = sum(e["reasoning_est_tokens"] for e in per_doc)
    reasoning_chars = sum(e["reasoning_chars"] for e in per_doc)
    output_chars = sum(e["raw_output_chars"] for e in per_doc)

    raw_predictions = sum(e["raw_predictions"] for e in per_doc)

    # Per-language parse tiers, which is where format drift shows up.
    by_lang: dict[str, dict[str, int]] = {}
    for entry in per_doc:
        bucket = by_lang.setdefault(entry["lang"], {tier: 0 for tier in PARSE_TIERS})
        bucket[entry["parse_tier"]] += 1

    summary = {
        "label": label,
        "docs_total": docs_total,
        "docs_missing_from_run": missing_ids,
        "parse": {
            "tiers": tiers,
            "tiers_by_lang": by_lang,
            "parse_success_rate": round(parsed_ok / docs_total, 4) if docs_total else 0.0,
            "clean_rate": round(tiers["clean"] / docs_total, 4) if docs_total else 0.0,
            "shapes": shapes,
            "contract_shape_rate": round(shapes.get("object_entities", 0) / docs_total, 4) if docs_total else 0.0,
            "schema_deviations": deviations,
            "truncated_finish_reason": truncated_by_finish,
            "truncation_rate": round(truncated_by_finish / docs_total, 4) if docs_total else 0.0,
            "truncated_detected_by_parser": truncated_by_parser,
        },
        "quality": {
            "micro_strict": micro_strict,
            "micro_lenient": micro_lenient,
            "per_type_strict": per_type_scores,
            "critical_strict": critical,
            "critical_lenient_recall": round(critical_lenient_recall, 4),
            "backstopped_strict": backstopped,
            "surface_drift": round(micro_lenient["recall"] - micro_strict["recall"], 4),
        },
        "over_extraction": {
            "decoys_hit": decoys_hit,
            "decoys_total": decoy_total,
            "decoy_hit_rate": round(decoys_hit / decoy_total, 4) if decoy_total else 0.0,
            "decoy_share_of_predictions": round(decoy_predictions / predicted, 4) if predicted else 0.0,
            "adversarial_decoy_hit_rate": round(adversarial_decoys_hit / adversarial_decoy_total, 4)
            if adversarial_decoy_total else 0.0,
            "control_false_positives": control_fp,
            "control_fp_per_1k_chars": round(control_fp / (control_chars / 1000), 3) if control_chars else 0.0,
            "duplicate_rate": round(1 - (predicted / raw_predictions), 4) if raw_predictions else 0.0,
            "production_unknown_type_rate": round(
                sum(e["production_unknown"] for e in per_doc) / predicted, 4
            ) if predicted else 0.0,
            "out_of_vocab_type_rate": round(
                sum(e["out_of_vocab"] for e in per_doc) / predicted, 4
            ) if predicted else 0.0,
        },
        "confusion": build_confusion(per_doc),
        "cost": {
            "weights_mb": run.get("weights_mb"),
            "load_seconds": run.get("load_seconds"),
            "peak_rss_mb": run.get("peak_rss_mb"),
            "peak_rss_gb": run.get("peak_rss_gb"),
            "fits_16gb": (run.get("peak_rss_gb") or 0) <= RSS_BUDGET_16GB,
            "fits_32gb": (run.get("peak_rss_gb") or 0) <= RSS_BUDGET_32GB,
            "mean_latency_s": round(sum(latencies) / len(latencies), 2) if latencies else None,
            "total_latency_s": round(sum(latencies), 2) if latencies else None,
            "mean_gen_tok_per_s": round(sum(throughputs) / len(throughputs), 2) if throughputs else None,
            "completion_tokens": completion_tokens,
            "reasoning_est_tokens": reasoning_tokens,
            "reasoning_chars": reasoning_chars,
            "docs_with_reasoning": sum(1 for e in per_doc if e["reasoning_chars"] > 0),
            "thinking_share_chars": round(reasoning_chars / (reasoning_chars + output_chars), 4)
            if (reasoning_chars + output_chars) else 0.0,
            "thinking_overhead_vs_completion": round(reasoning_tokens / completion_tokens, 4)
            if completion_tokens else 0.0,
        },
    }

    if verbose:
        summary["documents"] = per_doc
    else:
        summary["documents"] = [
            {
                "id": e["id"],
                "parse_tier": e["parse_tier"],
                "shape": e["shape"],
                "strict_tp": e["strict_tp"],
                "gold_count": e["gold_count"],
                "unique_predictions": e["unique_predictions"],
                "decoys_hit": len(e["decoys_hit"]),
                "finish_reason": e["finish_reason"],
            }
            for e in per_doc
        ]

    return summary


def build_confusion(per_doc: list[dict]) -> dict:
    """Aggregate the gold type to predicted type confusion counts."""
    matrix: dict[str, dict[str, int]] = {}
    for entry in per_doc:
        for item in entry["confusion"]:
            row = matrix.setdefault(item["gold"], {})
            row[item["predicted"]] = row.get(item["predicted"], 0) + 1
    return matrix


# ------------------------------------------------------------------ composite

def apply_composite(summaries: list[dict]) -> None:
    """Attach gate verdicts and the weighted composite score to each summary.

    Weights, and why:

      0.40 critical strict recall   a missed PERSON, COMPANY or ADDRESS is an
                                    unrecoverable leak: no regex layer covers
                                    these types and the reviewer only sees what
                                    was flagged
      0.15 critical precision       every false flag is manual review work
      0.15 decoy avoidance          boilerplate flooding is what makes a review
                                    queue unusable, and it is the failure mode
                                    LegalBoilerplate exists to contain
      0.10 backstopped recall       DeterministicEngine already catches these,
                                    so a miss is usually harmless
      0.10 output reliability       parse cleanliness, contract shape and the
                                    absence of truncation, that is integration
                                    cost rather than correctness
      0.10 throughput               normalized against the fastest model in the
                                    comparison, a tiebreaker not a gate
    """
    best_throughput = max(
        (s["cost"]["mean_gen_tok_per_s"] or 0.0) for s in summaries
    ) if summaries else 0.0

    for summary in summaries:
        parse = summary["parse"]
        quality = summary["quality"]
        over = summary["over_extraction"]
        cost = summary["cost"]

        reliability = (
            0.5 * parse["clean_rate"]
            + 0.3 * parse["contract_shape_rate"]
            + 0.2 * (1.0 - parse["truncation_rate"])
        )
        throughput = ((cost["mean_gen_tok_per_s"] or 0.0) / best_throughput) if best_throughput else 0.0

        composite = (
            0.40 * quality["critical_strict"]["recall"]
            + 0.15 * quality["critical_strict"]["precision"]
            + 0.15 * (1.0 - over["decoy_hit_rate"])
            + 0.10 * quality["backstopped_strict"]["recall"]
            + 0.10 * reliability
            + 0.10 * throughput
        )

        gates = {
            "G1_all_docs_parse": parse["tiers"]["unparseable"] == 0,
            "G2_critical_strict_recall_ge_0.80": quality["critical_strict"]["recall"] >= 0.80,
            "G3_critical_lenient_recall_ge_0.90": quality["critical_lenient_recall"] >= 0.90,
            "G4_decoy_hit_rate_le_0.25": over["decoy_hit_rate"] <= 0.25,
            "G5_fits_32gb": bool(cost["fits_32gb"]),
            "G6_truncation_rate_le_0.10": parse["truncation_rate"] <= 0.10,
        }

        summary["scorecard"] = {
            "reliability_subscore": round(reliability, 4),
            "throughput_subscore": round(throughput, 4),
            "composite": round(composite * 100, 2),
            "gates": gates,
            "gates_failed": [name for name, ok in gates.items() if not ok],
            "verdict": "PASS" if all(gates.values()) else "FAIL",
            "fits_16gb": bool(cost["fits_16gb"]),
        }


# ------------------------------------------------------------------ reporting

def fmt(value, width: int = 12, digits: int = 3) -> str:
    """Format one cell for the comparison table."""
    if value is None:
        return "n/a".rjust(width)
    if isinstance(value, bool):
        return ("yes" if value else "no").rjust(width)
    if isinstance(value, float):
        return "{:.{}f}".format(value, digits).rjust(width)
    return str(value).rjust(width)


def print_report(summaries: list[dict]) -> None:
    """Print the human readable side by side comparison."""
    # Long labels are clipped so adjacent columns never run together.
    col = max(14, min(22, max(len(s["label"]) for s in summaries) + 2))
    labels = [s["label"][: col - 2] for s in summaries]
    name_width = 34

    def header(title: str) -> None:
        print()
        print(title)
        print("-" * (name_width + col * len(labels)))
        print("".ljust(name_width) + "".join(label.rjust(col) for label in labels))
        print("-" * (name_width + col * len(labels)))

    def row(name: str, getter, digits: int = 3) -> None:
        print(name.ljust(name_width) + "".join(fmt(getter(s), col, digits) for s in summaries))

    print("=" * (name_width + col * len(labels)))
    print("LDA small model benchmark, {} model(s), {} document(s)".format(len(summaries), summaries[0]["docs_total"]))
    print("=" * (name_width + col * len(labels)))

    header("Verdict")
    row("composite score (0 to 100)", lambda s: s["scorecard"]["composite"], 2)
    row("verdict", lambda s: s["scorecard"]["verdict"])
    row("gates failed", lambda s: len(s["scorecard"]["gates_failed"]))
    row("fits 16 GB Mac", lambda s: s["scorecard"]["fits_16gb"])

    header("Output hygiene, the integration cost")
    row("parse success rate", lambda s: s["parse"]["parse_success_rate"])
    row("clean JSON rate", lambda s: s["parse"]["clean_rate"])
    row("  tier clean", lambda s: s["parse"]["tiers"]["clean"])
    row("  tier stripped_fence", lambda s: s["parse"]["tiers"]["stripped_fence"])
    row("  tier extracted_substring", lambda s: s["parse"]["tiers"]["extracted_substring"])
    row("  tier repaired", lambda s: s["parse"]["tiers"]["repaired"])
    row("  tier unparseable", lambda s: s["parse"]["tiers"]["unparseable"])
    row("contract shape rate", lambda s: s["parse"]["contract_shape_rate"])
    row("truncation rate", lambda s: s["parse"]["truncation_rate"])

    header("Extraction quality, strict match")
    row("micro precision", lambda s: s["quality"]["micro_strict"]["precision"])
    row("micro recall", lambda s: s["quality"]["micro_strict"]["recall"])
    row("micro F1", lambda s: s["quality"]["micro_strict"]["f1"])
    row("critical recall (PER/CO/ADDR)", lambda s: s["quality"]["critical_strict"]["recall"])
    row("critical precision", lambda s: s["quality"]["critical_strict"]["precision"])
    row("critical lenient recall", lambda s: s["quality"]["critical_lenient_recall"])
    row("surface drift (len minus str)", lambda s: s["quality"]["surface_drift"])
    row("backstopped recall", lambda s: s["quality"]["backstopped_strict"]["recall"])

    header("Per type strict F1")
    for entity_type in SEVEN_TYPES:
        row("  " + entity_type, lambda s, t=entity_type: s["quality"]["per_type_strict"][t]["f1"])

    header("Over extraction, the review burden")
    row("decoy hit rate", lambda s: s["over_extraction"]["decoy_hit_rate"])
    row("decoy hit rate, adversarial", lambda s: s["over_extraction"]["adversarial_decoy_hit_rate"])
    row("decoy share of predictions", lambda s: s["over_extraction"]["decoy_share_of_predictions"])
    row("control FP per 1k chars", lambda s: s["over_extraction"]["control_fp_per_1k_chars"])
    row("production UNKNOWN type rate", lambda s: s["over_extraction"]["production_unknown_type_rate"])
    row("duplicate rate", lambda s: s["over_extraction"]["duplicate_rate"])

    header("Cost")
    row("weights MB", lambda s: s["cost"]["weights_mb"], 0)
    row("peak RSS GB", lambda s: s["cost"]["peak_rss_gb"], 2)
    row("mean latency s", lambda s: s["cost"]["mean_latency_s"], 2)
    row("mean gen tok/s", lambda s: s["cost"]["mean_gen_tok_per_s"], 2)
    row("thinking share of chars", lambda s: s["cost"]["thinking_share_chars"])
    row("est reasoning tokens", lambda s: s["cost"]["reasoning_est_tokens"], 0)

    print()
    print("Parse tier by language (clean / fence / substring / repaired / unparseable)")
    print("-" * (name_width + col * len(labels)))
    for summary in summaries:
        print("  " + summary["label"])
        for lang in sorted(summary["parse"]["tiers_by_lang"]):
            counts = summary["parse"]["tiers_by_lang"][lang]
            print(
                "    {:<8} {} / {} / {} / {} / {}".format(
                    lang,
                    counts["clean"],
                    counts["stripped_fence"],
                    counts["extracted_substring"],
                    counts["repaired"],
                    counts["unparseable"],
                )
            )

    print()
    print("Schema deviations observed")
    print("-" * (name_width + col * len(labels)))
    for summary in summaries:
        deviations = summary["parse"]["schema_deviations"]
        shapes = summary["parse"]["shapes"]
        print("  " + summary["label"])
        print("    shapes: " + (", ".join("{}={}".format(k, v) for k, v in sorted(shapes.items())) or "none"))
        print("    deviations: " + (", ".join("{}={}".format(k, v) for k, v in sorted(deviations.items())) or "none"))

    failing = [s for s in summaries if s["scorecard"]["gates_failed"]]
    if failing:
        print()
        print("Gate failures")
        print("-" * (name_width + col * len(labels)))
        for summary in failing:
            print("  {}: {}".format(summary["label"], ", ".join(summary["scorecard"]["gates_failed"])))

    print()
    ranked = sorted(summaries, key=lambda s: s["scorecard"]["composite"], reverse=True)
    print("Ranking by composite score")
    print("-" * (name_width + col * len(labels)))
    for index, summary in enumerate(ranked, start=1):
        print(
            "  {}. {:<28} {:>6.2f}  {}".format(
                index, summary["label"], summary["scorecard"]["composite"], summary["scorecard"]["verdict"]
            )
        )
    print()


# ------------------------------------------------------------------ entrypoint

def load_corpus(path: pathlib.Path) -> dict:
    corpus = {}
    for file in sorted(path.glob("*.json")):
        doc = json.loads(file.read_text(encoding="utf-8"))
        corpus[doc["id"]] = doc
    return corpus


def main() -> int:
    root = pathlib.Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description="Score model runs against the LDA golden corpus.")
    parser.add_argument("--corpus", type=pathlib.Path, default=root / "corpus")
    parser.add_argument("--results", type=pathlib.Path, default=root / "results")
    parser.add_argument("--out", type=pathlib.Path, default=None, help="write scores.json here")
    parser.add_argument("--verbose", action="store_true", help="include full per document detail in the JSON")
    args = parser.parse_args()

    if not args.corpus.is_dir():
        print("ERROR corpus directory not found: {}".format(args.corpus), file=sys.stderr)
        return 1
    if not args.results.is_dir():
        print("ERROR results directory not found: {}".format(args.results), file=sys.stderr)
        return 1

    corpus = load_corpus(args.corpus)
    if not corpus:
        print("ERROR no corpus documents found in {}".format(args.corpus), file=sys.stderr)
        return 1

    run_files = sorted(args.results.glob("*.raw.json"))
    if not run_files:
        print("ERROR no *.raw.json run files found in {}".format(args.results), file=sys.stderr)
        return 1

    summaries = []
    for run_file in run_files:
        try:
            run = json.loads(run_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            print("ERROR {} is not valid JSON: {}".format(run_file.name, exc), file=sys.stderr)
            return 1
        label = run.get("label") or run_file.name[: -len(".raw.json")]
        summaries.append(aggregate(label, run, corpus, args.verbose))

    apply_composite(summaries)
    print_report(summaries)

    payload = {
        "corpus": {
            "path": str(args.corpus),
            "documents": len(corpus),
            "gold_entities": sum(len(d["gold"]) for d in corpus.values()),
            "gold_negatives": sum(len(d["gold_negatives"]) for d in corpus.values()),
        },
        "models": summaries,
    }

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("wrote {}".format(args.out))

    return 0


if __name__ == "__main__":
    sys.exit(main())
