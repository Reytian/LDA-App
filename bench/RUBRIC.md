# LDA small model benchmark: scoring rubric and pass/fail thresholds

How a candidate model is measured against the fine tuned `lda-v2-Q4_K_M`, what each
number means, which numbers can veto a candidate outright, and how the survivors are
ranked.

Companion files:

| File | Role |
|------|------|
| `bench/corpus/*.json` | 12 labelled fragments, 143 gold entities, 198 decoys |
| `bench/harness/validate_corpus.py` | structural gate on the corpus itself |
| `bench/harness/score.py` | computes every metric below, emits `scores.json` |
| `bench/harness/selftest_score.py` | 33 assertions over 5 synthetic runs |

---

## 1. What is being tested

The contract under test is the one the fine tune was trained on, read from
`macos/LDACore/Sources/LDACore/Engine/PromptStore.swift` and `LLMEngine.swift`:

- SYSTEM is `PromptStore.defaultExtractionSystem`
- USER is `"Anonymize. Return ONLY JSON with key entities (array of {value,type}).\n\nTEXT:\n" + chunk`
- output is `{"entities":[{"value":"...","type":"..."}]}`
- seven types only: `PERSON, COMPANY, DATE, AMOUNT, EMAIL, PHONE, ADDRESS`
- ChatML with thinking forced off by a pre closed `<think>\n\n</think>\n\n` block

The SYSTEM prompt also carries explicit exclusions: contract role labels and defined
terms, job titles, generic groups, statutes, courts and agencies, and countries or
states cited as governing law. The gold labels enforce those exclusions, so a model is
never credited for extracting `the Company`, `General Counsel`, `JAMS` or a bare
`Delaware`.

### Statistical honesty

12 documents is a **screening** instrument, not an estimator. One failed document out
of twelve is an 8.3 percent point estimate with a 95 percent upper bound near 26
percent. Thresholds below are therefore written as counts where the count is what
matters, and any candidate that clears screening must be confirmed on a larger run
before it replaces anything.

---

## 2. Reference baseline: `lda-v2-Q4_K_M` on M4 / 32 GB

Every threshold in this document is anchored to this measured run.

| Dimension | Measured |
|-----------|----------|
| Weights | 2583 MB |
| Server | `llama-server -c 4096 -ngl 99` |
| Peak RSS | **5.65 GB** |
| Load time | 2.0 s |
| Wall clock, 12 docs | 164.9 s (13.7 s per doc) |
| Generated tokens | 3793 |
| Throughput | **23.0 tok/s** |
| Truncated documents | **0 of 12** (`finish_reason` always `stop`) |
| Doc 008, the Delaware trap | **11 of 11 gold**, and correctly rejected `the Company`, `the Purchaser`, `General Counsel`, `Delaware`, `State of Delaware`, `Delaware Court of Chancery`, `SEC`, `JAMS` |
| Doc 011, English zero PII control | returned `[]`, **zero false positives** |

### The two known defects, and the metric that catches each

**Defect 1, language conditional format drift.** Every Chinese and mixed document
(001, 002, 003, 007, 009, 012) came back wrapped in a ```json fence. English was mostly
clean, with 010 the exception. Same weights, same prompt, format decided by input
language.

Caught by `parse.tiers_by_lang`, which reports the rescue ladder split by `zh`, `en`
and `mixed`. A single aggregate clean rate hides this completely.

Resolved against the scored run: `parse.tiers_by_lang` reports `en` 5 clean and 1
fenced, `zh` 0 clean and 4 fenced, `mixed` 0 clean and 2 fenced. So **7 of 12** were
fenced, not 6, and the split is absolute by language: every Chinese and mixed document
was fenced, and 5 of 6 English documents were not. Aggregate clean rate is 0.417, which
on its own would look like ordinary noise rather than a deterministic language switch.

**Defect 2, out of vocabulary type plus false positive.** On 012, the Chinese zero PII
control, the model emitted `{"value":"中华人民共和国","type":"COUNTRY"}`.

This is two independent failures in one item, and it is the reason over extraction is
measured three separate ways:

1. `COUNTRY` is not one of the seven types. `EntityJSONParser.mapType` maps it to
   `.unknown`. Caught by `over_extraction.out_of_vocab_type_rate`.
2. A country cited as governing law is explicitly excluded by the SYSTEM prompt, and
   012 has no gold at all, so this is a pure false positive. Caught by
   `over_extraction.control_fp_per_1k_chars`.
3. It is **not** caught by `decoy_hit_rate`, because 012 lists `中华人民共和国法律`
   rather than the bare country name, and decoys match on exact equality. That is by
   design: exact equality is what stops a correct long address from being punished for
   containing a decoy token. It is also why decoy hit rate alone is not sufficient.

**Why the out of vocabulary type is worse than it looks.** `LegalBoilerplate.shouldDrop`
scopes its geography and head noun filters by type:

```swift
guard type == .person || type == .company else {
    return false
}
```

An `.unknown` span therefore skips the head noun rule, the dangling tail rule and the
lowercase heuristic entirely. `geographicTerms` only lists romanized jurisdictions
(`china`, `people's republic of china`, `prc`), not `中华人民共和国`. So this span is
not dropped, reaches `EntityLocator`, and every occurrence of the country name gets
redacted in the delivered document. An out of vocabulary type is not a cosmetic
schema issue; it punches straight through the engine side guardrail.

*Follow up, not blocking:* adding bare `中华人民共和国` to 012's `gold_negatives` and
the CJK jurisdiction names to `LegalBoilerplate.geographicTerms` would both be cheap.
Corpus and engine were out of scope for this pass.

### Cross model validation of this rubric

Scoring the first real challenger, `qwen3-4b-base-nothink`, produced exactly the
situation the gates exist for.

| | finetune-lda-v2 | qwen3-4b-base-nothink |
|---|---|---|
| micro F1, strict | 0.850 | **0.855** |
| micro precision | 0.814 | **0.913** |
| **critical recall** | **0.910** | 0.851 |
| **critical lenient recall** | **0.970** | 0.851 |
| decoy hit rate | 0.051 | **0.005** |
| control FP per 1k chars | 0.329 | **0.000** |
| clean JSON rate | 0.417 | **1.000** |
| peak RSS GB | 5.65 | **4.48** |
| composite | 84.19 | **88.07** |
| gates failed | **none** | G3 |
| **verdict** | **PASS** | **REJECTED** |

The challenger wins on aggregate F1, precision, decoy avoidance, format stability, memory
and speed, and it outranks the incumbent on the composite by nearly 4 points. It is still
rejected, because it misses roughly 15 percent of PERSON, COMPANY and ADDRESS entities
and no regex layer recovers those. Its higher precision is bought with recall on exactly
the types where a miss is a disclosure incident.

Read that as the standing warning about this benchmark: **the composite would have picked
the wrong model.** Gates first, ranking second, always.

Note also that its critical lenient recall equals its strict recall (0.851), meaning the
entities it missed were not surface drift, it simply never reported them. The fine tune's
0.970 lenient against 0.910 strict says the opposite: it found nearly everything and lost
6 points to surface form, which is promptable. Those are very different failure modes
behind similar looking F1.

### Known calibration caveat

`contract_shape_rate` is 0.000 for both models above, because both return a bare array
rather than `{"entities": [...]}`. That term carries 0.3 of the `reliability` subscore,
so it costs both about 3 composite points, yet `EntityJSONParser.extractEntities` accepts
a bare array natively and the shape is harmless in production. It does not change the
ranking here since both models are affected identically, but when comparing a bare array
model against an object shaped one, subtract the difference before treating a small
composite gap as meaningful. `score.py` is frozen for this pass, so this is documented
rather than fixed.

---

## 3. Metric definitions

### 3.1 Output hygiene: the integration cost

Every raw output is pushed through an escalating rescue ladder, and the first rung that
yields a usable entity container is recorded.

| Tier | Meaning | Already handled by `EntityJSONParser`? |
|------|---------|-----------------------------------------|
| `clean` | `json.loads` on the trimmed output worked | yes |
| `stripped_fence` | a Markdown fence had to come off first | **yes**, fence stripping is a shipped fallback |
| `extracted_substring` | JSON had to be cut out of surrounding prose | **yes**, `largestBalancedRegion` |
| `repaired` | structural repair: truncation salvage, bracket closing, Python literal syntax, concatenated NDJSON | **partly**, only truncation salvage ships |
| `unparseable` | nothing worked, the chunk is unscanned | no |

This mapping is the point. `stripped_fence` costs nothing in production because the
shipped parser already strips fences, so the fine tune's Chinese fencing is a curiosity
rather than a defect to pay for. `bracket_close`, `python_literal` and `ndjson_objects`
have no production equivalent and mean new parser code.

Related fields:

- `parse.parse_success_rate` fraction of documents that parsed at any tier
- `parse.clean_rate` fraction at `clean`
- `parse.contract_shape_rate` fraction that returned the contracted
  `{"entities": [...]}` object rather than a bare array or an alternate container
- `parse.truncation_rate` fraction with `finish_reason == "length"`
- `parse.truncated_detected_by_parser` documents whose entity array never closed, which
  catches a truncation the server failed to report
- `parse.tiers_by_lang` the same ladder split by language

### 3.2 Schema deviations: where the scorer is more generous than production

`score.py` deliberately accepts alternate keys so a model is measured on what it found
rather than on how it spelled the wrapper. Production does not. `EntityJSONParser`
reads only `dict["entities"]`, only `entry["value"]`, and only `entry["type"]`.

Consequences, and they are severe:

| Deviation reported | What production actually does |
|--------------------|-------------------------------|
| `bare_array` | fine, `extractEntities` accepts a bare array |
| `alt_container_key:*` | returns **zero entities** for that document |
| `alt_value_key:*` | entry skipped, **zero entities** |
| `alt_type_key:*` | type becomes `.unknown`, filter bypassed as in section 2 |
| `type_keyed_map`, `string_array` | **zero entities** |
| `type_alias` (`ORG`, `公司`, `person`) | `.unknown`, filter bypassed |

Note that plain case differences are **not** a deviation: `mapType` uppercases the wire
string, so `company` and `COMPANY` are equally valid and neither is penalized.

`over_extraction.production_unknown_type_rate` is the honest number here: the share of
accepted predictions that production would have degraded to `.unknown`.

### 3.3 Extraction quality: strict versus lenient

`EntityLocator` re-anchors a reported value by **case insensitive verbatim substring
search** over the source, with a Latin word boundary guard. That single fact decides the
matching rule:

- a value that drifts long (`Ms. Jane Roe`, `程立衡先生`) fails to anchor at all, and the
  entity is left in the document
- a value that drifts short (`Jane` for `Jane Roe`) anchors on the fragment, and the
  surname is left in the document

Both are leaks. **Strict equality after normalization is therefore the production
faithful metric.** Normalization is NFKC, zero width removal, whitespace collapsing,
outer punctuation stripping, and case folding, which makes full width and half width
forms comparable without forgiving real surface drift.

Lenient matching (bidirectional containment on the whitespace stripped key, one to one,
guarded at 2 characters and a 0.5 length ratio) is reported **only as a diagnostic**.
`quality.surface_drift` is lenient recall minus strict recall, and it reads as: the
share of entities the model conceptually located but reported in a form that would
still leak. It is never a pass.

### 3.4 Critical versus backstopped types

`DeterministicEngine.swift` states it plainly:

> PERSON, COMPANY, and ADDRESS are intentionally NOT detected here. Those fuzzy entity
> types are owned by the LLM engine.

| Group | Types | Consequence of a miss |
|-------|-------|-----------------------|
| **Critical** | PERSON, COMPANY, ADDRESS | no other detector exists, the miss is an unrecoverable leak |
| **Backstopped** | DATE, AMOUNT, EMAIL, PHONE | regex catches it and `SpanMerger` gives the regex span priority |

This is the single most important asymmetry in the whole benchmark. A candidate with
excellent EMAIL recall and mediocre COMPANY recall is worse than its aggregate F1
suggests, because the EMAIL half of that F1 is work the regex layer already does for
free. `quality.critical_strict` and `quality.backstopped_strict` are reported
separately for exactly this reason, and the composite weights them 4 to 1.

### 3.5 Over extraction: the review burden

Missing PII leaks it. Over reporting PII floods the review queue until nobody reads it,
and then the next miss goes unnoticed too. Four independent measures, because as
section 2 showed, no single one catches everything:

- `decoy_hit_rate` distinct `gold_negatives` predicted, over all decoys. Matched by
  **normalized exact equality only**, so a correct full address that happens to contain
  `Delaware` never trips the `Delaware` decoy, while a bare `Delaware` always does.
- `adversarial_decoy_hit_rate` the same restricted to 008, 009, 010, where decoy density
  is highest and 010 alone carries 25 decoys against 12 gold items.
- `control_fp_per_1k_chars` predictions on the two zero PII controls (011 English, 012
  Chinese, 3040 characters combined) per 1000 characters. Recall is undefined there, so
  every prediction is a false positive and this is the cleanest read on baseline over
  extraction. Splitting the controls by language separates a genuine CJK weakness from a
  general over extraction habit.
- `out_of_vocab_type_rate` and `production_unknown_type_rate`, per section 3.2.

`duplicate_rate` is reported alongside as a verbosity signal. Duplicates are deduped
before scoring, since `EntityLocator` locates every occurrence of a distinct value
anyway.

### 3.6 Type confusion

`confusion` is a gold type to predicted type matrix built only from predictions whose
**value** matched a gold value. It separates "did not find it" from "found it, labelled
it COMPANY instead of PERSON". The latter is far less severe: the span is still located
and still redacted, only the placeholder label is wrong.

### 3.7 Cost

`peak_rss_gb`, `weights_mb`, `load_seconds`, `mean_latency_s`, `mean_gen_tok_per_s`, and
for reasoning models `thinking_share_chars` plus `reasoning_est_tokens`. Token estimates
use a documented heuristic (CJK about one token per character, other text about four
characters per token) because no tokenizer is available under the standard library only
constraint. They are for reporting, never for scoring.

---

## 4. Veto gates

**A gate failure disqualifies a candidate no matter how good its F1 is.** Gates decide
survival; the weighted score in section 5 only ranks the survivors.

G1 through G6 are computed automatically and appear in `scorecard.gates`. G7 through G10
are read off named fields in `scores.json`, since `score.py` is frozen for this pass.

| # | Gate | Screening threshold | Production threshold | Baseline | Why |
|---|------|--------------------|--------------------|----------|-----|
| **G1** | `parse.tiers.unparseable` | **0 of 12** | 0 | 0 | An unparseable chunk is an unscanned chunk, which is a silent leak, exactly the LJE-001 failure the shipped parser was hardened against. At 1 failure in 12 the point estimate is 8.3 percent, and a realistic 30 chunk contract then has only a 7 percent chance of being fully scanned. Zero is the only defensible number. |
| **G2** | `quality.critical_strict.recall` | **>= 0.80** | **>= 0.95** | 11/11 on 008 | Critical types have no regex backstop. 0.80 is a screening floor for deciding who earns a full run, not a shipping bar. 0.95 is the de-identification norm and the level the fine tune already demonstrates. |
| **G3** | `quality.critical_lenient_recall` | **>= 0.90** | >= 0.97 | 11/11 on 008 | Lenient is a ceiling, not a pass. If even containment matching cannot find the entity, the model never saw it. A large G3 minus G2 gap means surface drift, which still leaks. |
| **G4** | `over_extraction.decoy_hit_rate` | **<= 0.25** | **<= 0.10** | rejected all 8 named decoys on 008 | Above roughly a quarter of decoys, an adversarial contract produces more junk flags than real ones and the review queue stops being read. |
| **G5** | `cost.peak_rss_gb` | **<= 24.0** | <= 12.0 for a 16 GB Mac | 5.65 GB | LDA is a desktop app running beside the user's real work. A 16 GB Mac needs roughly 4 GB for the OS and app, so 12 GB is the working budget; 24 GB is the 32 GB equivalent. The fine tune clears both with large headroom, which is a real part of its advantage. |
| **G6** | `parse.truncation_rate` | **<= 0.10** | **0** | 0 of 12 | A truncated completion is a partially scanned segment. The parser salvages what it can and flags the rest, but the unscanned tail is still a leak. The fine tune's 0 of 12 at 4096 context shows this is achievable, so any truncation is a regression against the incumbent. |
| **G7** | `over_extraction.out_of_vocab_type_rate` | **<= 0.05** | **<= 0.02** | 1 item (012 `COUNTRY`) | Not cosmetic. Per section 2, an out of vocabulary type becomes `.unknown` and bypasses the type scoped `LegalBoilerplate` filters entirely, so the junk it labels gets redacted into the delivered document. |
| **G8** | `over_extraction.control_fp_per_1k_chars` | **<= 2.0** | **<= 0.35** | 0.33 (1 FP over 3040 chars) | Screening rejects systemic over extraction (about 6 or more false positives across the two controls). The production figure is baseline parity: the fine tune's single `中华人民共和国` on 012 is the bar to beat. |
| **G9** | heavy rescue rate: `(tiers.extracted_substring + tiers.repaired) / docs_total` | **<= 0.25** | <= 0.10 | 0.00 | `stripped_fence` is deliberately excluded because production already strips fences. The upper rungs are where output is unstable enough that the parser will eventually meet a shape it cannot fix. |
| **G10** | production compatibility: no `alt_container_key:*`, `alt_value_key:*`, `alt_type_key:*`, `type_keyed_map` or `string_array` in `parse.shapes` or `parse.schema_deviations` | **must be clean for a drop in claim** | same | clean | Per section 3.2 these shapes yield **zero entities** under the shipped `EntityJSONParser`. The scorer's F1 for such a model describes a system that does not exist yet. |

### Verdict levels

- **DROP IN**: passes G1 through G9 and G10 is clean. Can replace the fine tune with no
  code change.
- **NEEDS ADAPTER**: passes G1 through G9 but trips G10. Viable, but the reported F1 is
  contingent on writing a key mapping adapter, and that must be stated wherever the
  score is quoted.
- **REJECTED**: any of G1 through G9 fails.

`score.py`'s own `scorecard.verdict` covers G1 through G6 only. G7 through G10 are a
manual read, and a candidate is not cleared until all ten are checked.

### Not gates, but mandatory disclosures

- **Language conditional format drift.** Compare `parse.tiers_by_lang` across `zh`, `en`
  and `mixed`. The fine tune's Chinese fencing costs nothing in production, so this is
  not a veto. It is still a warning: a model whose output format depends on input
  language may have other language conditional behaviours, most dangerously dropping
  the non dominant language of a mixed chunk. Whenever the tier histograms differ by
  language, inspect 007 and 009 per document before trusting the aggregate.
- **`quality.surface_drift`.** Above roughly 0.05, report the specific values from
  `documents[].missed_gold`. Honorifics and titles glued onto names are the usual cause
  and are often promptable away.

---

## 5. Weighted composite for ranking survivors

```
composite = 100 x (
    0.40 x critical_strict_recall
  + 0.15 x critical_strict_precision
  + 0.15 x (1 - decoy_hit_rate)
  + 0.10 x backstopped_strict_recall
  + 0.10 x reliability
  + 0.10 x throughput_normalized
)

reliability          = 0.5 x clean_rate
                     + 0.3 x contract_shape_rate
                     + 0.2 x (1 - truncation_rate)

throughput_normalized = mean_gen_tok_per_s / best mean_gen_tok_per_s in this comparison
```

### Why these weights

**0.40, critical strict recall.** A missed PERSON, COMPANY or ADDRESS is PII shipped to
a counterparty. No regex layer covers these types, and the reviewer only ever sees what
was flagged, so a miss is invisible until it is a disclosure incident. It gets the
largest single weight, and it is deliberately larger than every precision term combined.

**0.15, critical precision. 0.15, decoy avoidance.** These are the counterweight, and
together they equal 0.30 against recall's 0.40. Over extraction does not leak PII
directly, but it is the failure mode that destroys the human review step, and once
review is abandoned the next miss ships unnoticed. Decoy avoidance is scored separately
from raw precision because the decoys are the specific classes the SYSTEM prompt
excludes and `LegalBoilerplate` exists to contain, so hitting them is a targeted,
diagnosable failure rather than generic noise.

**0.10, backstopped recall.** A quarter of critical recall's weight, because
`DeterministicEngine` already detects these types by regex and `SpanMerger` gives the
regex detection priority. Weighting DATE and EMAIL equally with COMPANY would reward a
model for redoing work the engine does for free, and would let a weak candidate hide a
COMPANY deficit behind easy EMAIL wins.

**0.10, reliability.** Parse cleanliness, contract shape and freedom from truncation.
Low weight on purpose: this is integration cost, and integration cost is engineering
that gets paid once. Correctness is not. Note that the catastrophic end of this axis is
already handled by G1, G6 and G9, so the weight only separates tidy candidates from
merely workable ones.

**0.10, throughput.** Normalized against the fastest model in the comparison, so it is a
tiebreaker between candidates of similar quality rather than something a fast, sloppy
model can win on. Memory is not weighted at all: it is a gate (G5), because a model that
does not fit is not slow, it is unusable.

### Reading the score

The composite is a ranking device for candidates that already passed every gate. It is
not a quality certificate. Two failure shapes it deliberately cannot express:

- a model that trips G10 can still score highly, because the scorer accepted keys that
  production would drop on the floor
- a model that returns nothing on one document out of twelve loses very little composite
  score, which is precisely why G1 is an absolute veto rather than a weighted term

Always read `scorecard.gates_failed`, `parse.shapes` and
`over_extraction.out_of_vocab_type_rate` before quoting a composite number.

---

## 6. Running it

```
python3 bench/harness/validate_corpus.py
python3 bench/harness/score.py --corpus bench/corpus --results bench/results \
    --out bench/results/scores.json
```

`validate_corpus.py` must exit 0 before any score is trusted. `selftest_score.py`
exercises the scorer itself against five synthetic runs with known correct answers,
including the fine tune's real bare array and language conditional fence behaviours.
