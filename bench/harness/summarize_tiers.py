#!/usr/bin/env python3
"""
Final tier table for the full-agreement run.

Memory here is the run's own peak RSS, which is already the realistic
single-slot figure because run_model.py pins -np 1. Tier placement is decided by
that MEASURED value against the stated budgets, never by prediction.

Budgets assume a normal office workload resident (macOS, Word, Chrome,
a messaging app and an AI app), which measured about 9 GB.
"""
import json, sys

BUDGETS = [(6.5, "16 GB"), (14.0, "24 GB"), (21.0, "32 GB")]


def tier_for(gb):
    for limit, name in BUDGETS:
        if gb <= limit:
            return name
    return "over 32 GB"


scores = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "bench/results/scores-full.json"))
rows = []
for m in scores["models"]:
    q, o, c, s, pa = (m["quality"], m["over_extraction"], m["cost"],
                      m["scorecard"], m["parse"])
    rss = c["peak_rss_gb"]
    rows.append({
        "label": m["label"].replace("-full", ""),
        "f1": q["micro_strict"]["f1"],
        "rec": q["micro_strict"]["recall"],
        "critR": q["critical_strict"]["recall"],
        "critLen": q["critical_lenient_recall"],
        "decoy": o["decoy_hit_rate"],
        "clean": pa["clean_rate"],
        "trunc": pa["truncation_rate"],
        "wt": c["weights_mb"] / 1024.0,
        "rss": rss,
        "tier": tier_for(rss),
        "lat": c["mean_latency_s"],
        "tps": c["mean_gen_tok_per_s"],
        "verdict": s.get("verdict", "?").upper(),
        "gates": len(s.get("gates_failed", [])),
    })

order = {"16 GB": 0, "24 GB": 1, "32 GB": 2, "over 32 GB": 3}
rows.sort(key=lambda r: (order[r["tier"]], -r["critLen"]))

print("%-22s %-9s %6s %6s %6s %6s %7s %8s %6s %6s %6s %7s" % (
    "model", "fits", "wt GiB", "RSS", "F1", "recall", "critRec", "critLen",
    "decoy", "clean", "lat s", "verdict"))
print("-" * 118)
cur = None
for r in rows:
    if r["tier"] != cur:
        cur = r["tier"]
        print("  -- %s tier --" % cur)
    print("%-22s %-9s %6.2f %6.2f %6.3f %6.3f %7.3f %8.3f %6.3f %6.2f %6.1f %7s" % (
        r["label"][:22], r["tier"], r["wt"], r["rss"], r["f1"], r["rec"],
        r["critR"], r["critLen"], r["decoy"], r["clean"], r["lat"], r["verdict"]))
