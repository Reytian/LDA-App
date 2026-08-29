#!/usr/bin/env python3
"""Self-test for score.py using synthetic model outputs.

Builds five fake model runs whose correct scores are known by construction,
runs the scorer over them, and asserts that the rescue ladder, the schema
deviation tracking and the metric arithmetic all behave. The fakes cover the
dirty output shapes actually seen on device:

    fake-perfect        contract-shaped clean JSON, echoes gold exactly
    fake-bare-fence     bare array on English input, fenced bare array on
                        Chinese and mixed input, which is the language
                        conditional format drift observed on the finetune,
                        plus honorific prefixes that make lenient beat strict
    fake-truncated      output cut mid array with finish_reason "length"
    fake-garbage        prose apology, no JSON anywhere
    fake-alt-schema     alternate container, value and type keys, lowercase
                        and Chinese and ORG style types, with thinking content

Run:
    python3 bench/harness/selftest_score.py

Writes its fixtures to a temporary directory so bench/results stays reserved
for real runs. Exit status 0 means every assertion held.
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile

HARNESS = pathlib.Path(__file__).resolve().parent
CORPUS = HARNESS.parent / "corpus"

HONORIFIC_DOCS = {"008-en-adversarial-defined-terms", "009-mixed-adversarial-roles"}


def load_corpus() -> list[dict]:
    return [json.loads(p.read_text(encoding="utf-8")) for p in sorted(CORPUS.glob("*.json"))]


def entity_objects(doc: dict, drop_first_company: bool = False, honorific: bool = False) -> list[dict]:
    """Build the entity list a fake model would report for one document."""
    items = []
    dropped = False
    for entry in doc["gold"]:
        if drop_first_company and entry["type"] == "COMPANY" and not dropped:
            dropped = True
            continue
        value = entry["value"]
        if honorific and entry["type"] == "PERSON" and doc["id"] in HONORIFIC_DOCS:
            value = "Ms. " + value if doc["lang"] != "zh" else value + "先生"
        items.append({"value": value, "type": entry["type"]})
    return items


def make_perfect(corpus: list[dict]) -> dict:
    docs = []
    for doc in corpus:
        payload = {"entities": entity_objects(doc)}
        docs.append({
            "id": doc["id"],
            "latency_s": 6.0,
            "raw_output": json.dumps(payload, ensure_ascii=False),
            "reasoning_content": "",
            "finish_reason": "stop",
            "prompt_tokens": 500,
            "completion_tokens": 180,
            "gen_tok_per_s": 30.0,
        })
    return {
        "label": "fake-perfect", "weights_mb": 2583.0, "load_seconds": 1.0,
        "peak_rss_mb": 3354.0, "peak_rss_gb": 3.28, "docs": docs,
    }


def make_bare_fence(corpus: list[dict]) -> dict:
    """Case A and case B together: bare array, fenced only for zh and mixed."""
    docs = []
    for doc in corpus:
        items = entity_objects(doc, drop_first_company=True, honorific=True)
        if doc["gold_negatives"]:
            items.append({"value": doc["gold_negatives"][0], "type": "COMPANY"})
        body = json.dumps(items, ensure_ascii=False, indent=2)
        raw = "```json\n" + body + "\n```" if doc["lang"] in ("zh", "mixed") else body
        docs.append({
            "id": doc["id"],
            "latency_s": 9.0,
            "raw_output": raw,
            "reasoning_content": "",
            "finish_reason": "stop",
            "prompt_tokens": 500,
            "completion_tokens": 210,
            "gen_tok_per_s": 22.0,
        })
    return {
        "label": "fake-bare-fence", "weights_mb": 2583.0, "load_seconds": 1.0,
        "peak_rss_mb": 3354.0, "peak_rss_gb": 3.28, "docs": docs,
    }


def make_truncated(corpus: list[dict]) -> dict:
    """Half the entities emitted, then the completion hits the token cap."""
    docs = []
    for doc in corpus:
        items = entity_objects(doc)
        keep = items[: max(1, len(items) // 2)] if items else []
        body = ",\n".join(json.dumps(i, ensure_ascii=False) for i in keep)
        raw = '{"entities": [\n' + body + (',\n{"value": "上海星辰科' if keep else "")
        docs.append({
            "id": doc["id"],
            "latency_s": 20.0,
            "raw_output": raw,
            "reasoning_content": "",
            "finish_reason": "length",
            "prompt_tokens": 500,
            "completion_tokens": 512,
            "gen_tok_per_s": 12.0,
        })
    return {
        "label": "fake-truncated", "weights_mb": 4100.0, "load_seconds": 2.0,
        "peak_rss_mb": 5200.0, "peak_rss_gb": 5.08, "docs": docs,
    }


def make_garbage(corpus: list[dict]) -> dict:
    docs = []
    for doc in corpus:
        docs.append({
            "id": doc["id"],
            "latency_s": 4.0,
            "raw_output": "I am sorry, but I cannot help with anonymizing this document "
                          "because it appears to contain personal data.",
            "reasoning_content": "",
            "finish_reason": "stop",
            "prompt_tokens": 500,
            "completion_tokens": 24,
            "gen_tok_per_s": 40.0,
        })
    return {
        "label": "fake-garbage", "weights_mb": 1900.0, "load_seconds": 0.8,
        "peak_rss_mb": 2600.0, "peak_rss_gb": 2.54, "docs": docs,
    }


def make_alt_schema(corpus: list[dict]) -> dict:
    """Alternate keys, alias type vocabulary, and a thinking model's overhead."""
    alias = {
        "PERSON": "person", "COMPANY": "ORG", "ADDRESS": "地址",
        "DATE": "date", "AMOUNT": "money", "EMAIL": "email", "PHONE": "tel",
    }
    docs = []
    for doc in corpus:
        items = [{"text": g["value"], "label": alias[g["type"]]} for g in doc["gold"]]
        payload = {"entity": items}
        docs.append({
            "id": doc["id"],
            "latency_s": 30.0,
            "raw_output": json.dumps(payload, ensure_ascii=False),
            "reasoning_content": "Let me carefully look through the document for names. " * 12,
            "finish_reason": "stop",
            "prompt_tokens": 500,
            "completion_tokens": 190,
            "gen_tok_per_s": 8.0,
        })
    return {
        "label": "fake-alt-schema", "weights_mb": 7800.0, "load_seconds": 4.0,
        "peak_rss_mb": 9100.0, "peak_rss_gb": 8.89, "docs": docs,
    }


def check(name: str, condition: bool, detail: str = "") -> bool:
    status = "PASS" if condition else "FAIL"
    print("  [{}] {}{}".format(status, name, ("  " + detail) if detail else ""))
    return condition


def main() -> int:
    corpus = load_corpus()
    if not corpus:
        print("ERROR corpus is empty", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        results = pathlib.Path(tmp) / "results"
        results.mkdir()
        for builder in (make_perfect, make_bare_fence, make_truncated, make_garbage, make_alt_schema):
            run = builder(corpus)
            (results / (run["label"] + ".raw.json")).write_text(
                json.dumps(run, ensure_ascii=False, indent=2), encoding="utf-8"
            )

        out = pathlib.Path(tmp) / "scores.json"
        proc = subprocess.run(
            [sys.executable, str(HARNESS / "score.py"),
             "--corpus", str(CORPUS), "--results", str(results), "--out", str(out)],
            capture_output=True, text=True,
        )
        print(proc.stdout)
        if proc.returncode != 0:
            print(proc.stderr, file=sys.stderr)
            return 1

        payload = json.loads(out.read_text(encoding="utf-8"))

    models = {m["label"]: m for m in payload["models"]}
    total_docs = len(corpus)
    ok = True

    print("Assertions")
    print("-" * 72)

    perfect = models["fake-perfect"]
    ok &= check("perfect: strict precision is 1.0", perfect["quality"]["micro_strict"]["precision"] == 1.0,
                str(perfect["quality"]["micro_strict"]["precision"]))
    ok &= check("perfect: strict recall is 1.0", perfect["quality"]["micro_strict"]["recall"] == 1.0,
                str(perfect["quality"]["micro_strict"]["recall"]))
    ok &= check("perfect: every doc parses clean", perfect["parse"]["tiers"]["clean"] == total_docs)
    ok &= check("perfect: contract shape everywhere", perfect["parse"]["contract_shape_rate"] == 1.0)
    ok &= check("perfect: no decoys hit", perfect["over_extraction"]["decoy_hit_rate"] == 0.0)
    ok &= check("perfect: verdict PASS", perfect["scorecard"]["verdict"] == "PASS")

    drift = models["fake-bare-fence"]
    lang_tiers = drift["parse"]["tiers_by_lang"]
    ok &= check("drift: English parses clean", lang_tiers["en"]["clean"] == 6 and lang_tiers["en"]["stripped_fence"] == 0,
                str(lang_tiers["en"]))
    ok &= check("drift: Chinese needs the fence stripped",
                lang_tiers["zh"]["stripped_fence"] == 4 and lang_tiers["zh"]["clean"] == 0, str(lang_tiers["zh"]))
    ok &= check("drift: mixed needs the fence stripped",
                lang_tiers["mixed"]["stripped_fence"] == 2, str(lang_tiers["mixed"]))
    ok &= check("drift: shape recorded as bare array",
                drift["parse"]["shapes"].get("bare_array") == total_docs, str(drift["parse"]["shapes"]))
    ok &= check("drift: contract shape rate is zero", drift["parse"]["contract_shape_rate"] == 0.0)
    ok &= check("drift: decoys were hit", drift["over_extraction"]["decoy_hit_rate"] > 0.0,
                str(drift["over_extraction"]["decoy_hit_rate"]))
    ok &= check("drift: lenient recall beats strict (honorifics)",
                drift["quality"]["surface_drift"] > 0.0, str(drift["quality"]["surface_drift"]))
    ok &= check("drift: company recall below 1.0",
                drift["quality"]["per_type_strict"]["COMPANY"]["recall"] < 1.0,
                str(drift["quality"]["per_type_strict"]["COMPANY"]["recall"]))

    truncated = models["fake-truncated"]
    ok &= check("truncated: repaired tier used", truncated["parse"]["tiers"]["repaired"] == total_docs,
                str(truncated["parse"]["tiers"]))
    ok &= check("truncated: truncation rate is 1.0", truncated["parse"]["truncation_rate"] == 1.0)
    ok &= check("truncated: parser flagged the cut",
                truncated["parse"]["truncated_detected_by_parser"] > 0,
                str(truncated["parse"]["truncated_detected_by_parser"]))
    ok &= check("truncated: shape reported as contract, not bare array",
                truncated["parse"]["shapes"].get("object_entities") == total_docs,
                str(truncated["parse"]["shapes"]))
    ok &= check("truncated: fails the truncation gate",
                "G6_truncation_rate_le_0.10" in truncated["scorecard"]["gates_failed"],
                str(truncated["scorecard"]["gates_failed"]))
    ok &= check("truncated: partial recall recovered",
                0.0 < truncated["quality"]["micro_strict"]["recall"] < 1.0,
                str(truncated["quality"]["micro_strict"]["recall"]))

    garbage = models["fake-garbage"]
    ok &= check("garbage: nothing parses", garbage["parse"]["tiers"]["unparseable"] == total_docs)
    ok &= check("garbage: parse success rate is zero", garbage["parse"]["parse_success_rate"] == 0.0)
    ok &= check("garbage: recall is zero", garbage["quality"]["micro_strict"]["recall"] == 0.0)
    ok &= check("garbage: fails gate G1", "G1_all_docs_parse" in garbage["scorecard"]["gates_failed"])
    ok &= check("garbage: verdict FAIL", garbage["scorecard"]["verdict"] == "FAIL")

    alt = models["fake-alt-schema"]
    deviations = alt["parse"]["schema_deviations"]
    ok &= check("alt: alternate container key seen",
                any(k.startswith("alt_container_key") for k in alt["parse"]["shapes"]), str(alt["parse"]["shapes"]))
    ok &= check("alt: alternate value key seen",
                any(k.startswith("alt_value_key") for k in deviations), str(sorted(deviations)))
    ok &= check("alt: alternate type key seen", any(k.startswith("alt_type_key") for k in deviations))
    ok &= check("alt: alias types counted as production UNKNOWN",
                alt["over_extraction"]["production_unknown_type_rate"] > 0.0,
                str(alt["over_extraction"]["production_unknown_type_rate"]))
    ok &= check("alt: aliases still scored, recall is 1.0",
                alt["quality"]["micro_strict"]["recall"] == 1.0,
                str(alt["quality"]["micro_strict"]["recall"]))
    ok &= check("alt: thinking overhead measured", alt["cost"]["thinking_share_chars"] > 0.0,
                str(alt["cost"]["thinking_share_chars"]))

    ok &= check("ranking: perfect outranks garbage",
                perfect["scorecard"]["composite"] > garbage["scorecard"]["composite"])
    ok &= check("ranking: perfect outranks drift",
                perfect["scorecard"]["composite"] > drift["scorecard"]["composite"])

    print()
    print("SELF-TEST {}".format("PASSED" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
