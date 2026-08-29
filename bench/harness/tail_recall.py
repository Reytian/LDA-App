#!/usr/bin/env python3
"""
Recall bucketed by where an entity first appears in the document.

The whole point of the full-agreement corpus: an entity that only appears in the
last quarter (signature block, notices clause, schedules) tests whether a model
loses attention late in a long document. Document-level recall hides this,
because the same parties were already captured from the preamble; what goes
missing is their contactable surface.

Also reports whitespace-only drift, which is found-but-unredactable.
"""
import glob, json, re, sys, unicodedata


def parse(raw):
    s = (raw or "").strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", s, re.S)
    if m:
        s = m.group(1).strip()
    try:
        o = json.loads(s)
    except Exception:
        m = re.search(r"[\[{].*[\]}]", s, re.S)
        if not m:
            return []
        try:
            o = json.loads(m.group(0))
        except Exception:
            return []
    if isinstance(o, dict):
        o = o.get("entities") or o.get("entity") or []
    return [e for e in o if isinstance(e, dict)]


def val(e):
    for k in ("value", "text", "name"):
        if k in e:
            return str(e[k])
    return ""


def nn(s):
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", str(s))).strip().lower()


def nospace(s):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", str(s))).lower()


corpus = {}
for f in glob.glob("bench/fulldocs/*.json"):
    d = json.load(open(f))
    corpus[d["id"]] = d

rows = []
CRITICAL = ("PERSON", "COMPANY", "ADDRESS")
for f in sorted(glob.glob("bench/results-full/*.raw.json")):
    d = json.load(open(f))
    agg = {"head": [0, 0], "tail": [0, 0]}
    crit = {"head": [0, 0], "tail": [0, 0]}
    drift = 0
    for x in d["docs"]:
        c = corpus.get(x["id"])
        if not c:
            continue
        preds = [val(e) for e in parse(x.get("raw_output", ""))]
        pn = {nn(p) for p in preds}
        pns = {nospace(p) for p in preds}
        cut = int(len(c["text"]) * 0.75)
        head_txt = c["text"][:cut]
        for g in c["gold"]:
            bucket = "head" if g["value"] in head_txt else "tail"
            hit = nn(g["value"]) in pn
            agg[bucket][1] += 1
            if hit:
                agg[bucket][0] += 1
            # Whitespace-only drift: semantically right, but a literal locator
            # can never anchor it, so it is found-but-unredactable.
            if (not hit) and nospace(g["value"]) in pns:
                drift += 1
            # EMAIL and PHONE gold sit only in this corpus's tail and are
            # near-trivial, so an all-types head/tail split flatters the tail.
            # Bucket the critical types separately for the fair comparison.
            if g["type"] in CRITICAL:
                crit[bucket][1] += 1
                if hit:
                    crit[bucket][0] += 1

    def rate(a):
        return a[0] / a[1] if a[1] else 0.0
    rows.append((d["label"].replace("-full", ""), rate(agg["head"]), agg["head"],
                 rate(agg["tail"]), agg["tail"], rate(crit["head"]), crit["head"],
                 rate(crit["tail"]), crit["tail"], drift,
                 d.get("peak_rss_gb", 0)))

rows.sort(key=lambda r: -r[7])
print("Recall by position. CRITICAL = PERSON/COMPANY/ADDRESS only, which is the")
print("fair comparison: all EMAIL and PHONE gold sit in the tail of this corpus")
print("and are near-trivial, so an all-types split flatters tail recall.")
print()
print("%-22s %-15s %-15s %9s %6s %7s" % (
    "model", "head crit", "tail crit", "tail drop", "drift", "RSS GB"))
print("-" * 82)
for (lbl, hr, h, tr, tl, chr_, ch, ctr, ct, drift, rss) in rows:
    drop = chr_ - ctr
    flag = "  <-- tail collapse" if drop >= 0.20 else ""
    print("%-22s %5.3f (%2d/%-2d) %5.3f (%2d/%-2d) %9.3f %6d %7.2f%s"
          % (lbl[:22], chr_, ch[0], ch[1], ctr, ct[0], ct[1], drop, drift, rss, flag))
print()
print("%-22s %-15s %-15s" % ("model", "head all-types", "tail all-types"))
print("-" * 56)
for (lbl, hr, h, tr, tl, chr_, ch, ctr, ct, drift, rss) in rows:
    print("%-22s %5.3f (%2d/%-2d) %5.3f (%2d/%-2d)" % (lbl[:22], hr, h[0], h[1], tr, tl[0], tl[1]))
