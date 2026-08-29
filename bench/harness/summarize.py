#!/usr/bin/env python3
"""Emit a compact final summary table from scores.json plus the single-slot memory probe."""
import json, sys, os

scores = json.load(open("bench/results/scores.json"))
mem = {}
p = "bench/results/mem_probe_results.txt"
if os.path.exists(p):
    for line in open(p):
        line = line.strip()
        if line.startswith("{"):
            try:
                d = json.loads(line); mem[d["label"]] = d
            except Exception:
                pass

ALIAS = {"finetune-lda-v2": "finetune-lda-v2", "qwen35-4b-control": "qwen35-4b-control",
         "qwen3-4b-base-nothink": "qwen3-4b-base", "qwen3-4b-base-think": "qwen3-4b-base",
         "qwen3-8b-nothink": "qwen3-8b", "qwen35-9b": "qwen35-9b", "nuextract3": "nuextract3"}

rows = []
for m in scores["models"]:
    q, o, c, s, pa = m["quality"], m["over_extraction"], m["cost"], m["scorecard"], m["parse"]
    mp = mem.get(ALIAS.get(m["label"], m["label"]), {})
    rows.append({
        "label": m["label"],
        "F1": q["micro_strict"]["f1"], "P": q["micro_strict"]["precision"], "R": q["micro_strict"]["recall"],
        "critR": q["critical_strict"]["recall"], "critLenR": q["critical_lenient_recall"],
        "decoy": o["decoy_hit_rate"], "clean": pa["clean_rate"],
        "wt_mb": c["weights_mb"], "rss4": c["peak_rss_gb"],
        "rss1": mp.get("peak_np1_gb"), "lat": c["mean_latency_s"], "tps": c["mean_gen_tok_per_s"],
        "comp": s["composite"], "gates": len(s.get("gates_failed", [])),
        "verdict": s.get("verdict", "?").upper(),
    })
rows.sort(key=lambda r: (-1 if r["verdict"] == "PASS" else 0, -r["critLenR"]))

hdr = ("model", "F1", "prec", "rec", "critR", "critLenR", "decoy", "clean", "wt MB",
       "RSS4", "RSS1", "lat s", "tok/s", "comp", "verdict")
print("%-22s %5s %5s %5s %6s %8s %6s %6s %7s %6s %6s %6s %6s %6s %7s" % hdr)
print("-" * 126)
for r in rows:
    print("%-22s %5.3f %5.3f %5.3f %6.3f %8.3f %6.3f %6.3f %7.0f %6.2f %6s %6.1f %6.1f %6.2f %7s" % (
        r["label"][:22], r["F1"], r["P"], r["R"], r["critR"], r["critLenR"], r["decoy"],
        r["clean"], r["wt_mb"], r["rss4"],
        ("%.2f" % r["rss1"]) if r["rss1"] else "-", r["lat"], r["tps"], r["comp"], r["verdict"]))
