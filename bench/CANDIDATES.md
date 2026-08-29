# Small LLM Benchmark Candidates (Mac mini M4, 32GB)

Feasibility and capacity investigation for the LDA legal-PII extraction benchmark.
Every repo id and file name below was verified against the HuggingFace public API
(HTTP 200 plus the named `.gguf` actually present in the repo tree). Byte sizes are
the API-reported sizes, not estimates.

Verified 2026-08-28. Runtime: llama.cpp master `866322481` (2026-08-28) on the mini,
driven as `llama-server --jinja` plus `/v1/chat/completions`.

---

## 0. Finding that changes the control group

**The fine-tune base is `Qwen/Qwen3.5-4B`, not `Qwen3-4B`.**

Parsed directly from the incumbent GGUF header at
`~/Developer/lda-models/lda-v2-Q4_K_M.gguf`:

| GGUF metadata key | Value |
|---|---|
| `general.architecture` | `qwen35` |
| `general.size_label` | 4.2B |
| `qwen35.block_count` | 32 |
| `qwen35.embedding_length` | 2560 |
| `qwen35.attention.head_count` / `head_count_kv` | 16 / 4 |
| `qwen35.attention.key_length` / `value_length` | 256 / 256 |
| `qwen35.full_attention_interval` | 4 |
| `qwen35.ssm.state_size` / `ssm.inner_size` | 128 / 4096 |
| `qwen35.context_length` | 262144 |
| vocab (`token_embd.weight` dims) | 2560 x **248320** |

Every one of those matches `Qwen/Qwen3.5-4B` `text_config` exactly (vocab 248320,
32 layers, hidden 2560, 16 heads, 4 KV heads, head_dim 256, full_attention_interval 4,
intermediate 9216, max_position 262144).

This matters because **Qwen3-4B is a different architecture generation**:

| | Qwen3-4B (in flight) | Qwen3.5-4B (actual base) |
|---|---|---|
| Architecture | dense transformer | hybrid attention + SSM |
| Attention layers | 36 of 36 | 8 of 32 (rest are gated linear/SSM) |
| head_dim | 128 | 256 |
| Vocab | 151,936 | 248,320 |
| Max position | 40,960 | 262,144 |
| KV cache @ 4096 ctx | 0.56 GiB | 0.18 GiB |

Benchmarking the fine-tune against Qwen3-4B and calling the gap "fine-tuning value"
would attribute a full architecture-generation jump to the fine-tune. Qwen3-4B is
still worth keeping as a generational reference (it is already downloading, so the
cost is sunk), but **`unsloth/Qwen3.5-4B-GGUF` is the control group** and is P0.

Corroborating evidence for the quant lineage: the incumbent is 2,708,804,096 bytes
and unsloth's stock Qwen3.5-4B Q4_K_M is 2,740,937,888 bytes, a 1.2% difference.
bartowski's build of the same model is 3,013,027,808 bytes (10.7% larger, different
imatrix recipe). unsloth is therefore the like-for-like quant source.

---

## 1. Shortlist (all API-verified)

| # | Model | Repo id | GGUF file | Bytes (API) | GB | Tier | Reasoning model? | Thinking-off method |
|---|---|---|---|---|---|---|---|---|
| REF | lda-v2 (incumbent) | local | `lda-v2-Q4_K_M.gguf` | 2,708,804,096 | 2.71 | 16GB | Yes | `chat_template_kwargs {"enable_thinking": false}` (verified in embedded template) |
| 1 | **Qwen3.5-4B (CONTROL)** | `unsloth/Qwen3.5-4B-GGUF` | `Qwen3.5-4B-Q4_K_M.gguf` | 2,740,937,888 | 2.74 | 16GB | Yes | `enable_thinking: false` |
| 2 | **NuExtract3** | `numind/NuExtract3-GGUF` | `NuExtract3-Q4_K_M.gguf` | 2,783,445,984 | 2.78 | 16GB | Yes | `enable_thinking: false` (template retains the switch) |
| 3 | Qwen3-4B (gen reference) | `Qwen/Qwen3-4B-GGUF` | `Qwen3-4B-Q4_K_M.gguf` | 2,497,280,256 | 2.50 | 16GB | Yes | `enable_thinking: false`, or `/no_think` in prompt |
| 4 | Qwen3.5-9B | `unsloth/Qwen3.5-9B-GGUF` | `Qwen3.5-9B-Q4_K_M.gguf` | 5,680,522,464 | 5.68 | 16GB (tight) | Yes | `enable_thinking: false` |
| 5 | Ministral-3-8B-Instruct-2512 | `mistralai/Ministral-3-8B-Instruct-2512-GGUF` | `Ministral-3-8B-Instruct-2512-Q4_K_M.gguf` | 5,198,911,904 | 5.20 | 16GB | **No** | nothing to do |
| 6 | gemma-4-E4B-it | `unsloth/gemma-4-E4B-it-GGUF` | `gemma-4-E4B-it-Q4_K_M.gguf` | 4,977,171,584 | 4.98 | 16GB | **No** | nothing to do |
| 7 | ERNIE-4.5-21B-A3B-PT | `unsloth/ERNIE-4.5-21B-A3B-PT-GGUF` | `ERNIE-4.5-21B-A3B-PT-Q4_K_M.gguf` | 13,331,015,456 | 13.33 | 32GB | **No** (`-PT`, not `-Thinking`) | nothing to do |

Verified alternates, not in the default plan:

| Model | Repo id | GGUF file | Bytes | GB | Note |
|---|---|---|---|---|---|
| Qwen3.5-27B | `unsloth/Qwen3.5-27B-GGUF` | `Qwen3.5-27B-Q4_K_M.gguf` | 16,740,812,704 | 16.74 | Swap for #7 if "can params replace tuning" matters more than Chinese lineage independence |
| gemma-4-12b-it | `unsloth/gemma-4-12b-it-GGUF` | `gemma-4-12b-it-Q4_K_M.gguf` | 7,121,861,440 | 7.12 | Second Western model, 32GB tier. Repo id is lowercase `12b`; the uppercase `12B` form 307-redirects |

### Category coverage against the brief

| Required | Covered by |
|---|---|
| Same family, same size as the base | #1 Qwen3.5-4B (proven identical architecture) |
| Larger same family | #4 Qwen3.5-9B (2.2x params); alternate Qwen3.5-27B |
| Purpose-built structured extraction / NER | #2 NuExtract3 |
| Chinese-strong domestic | #7 ERNIE-4.5-21B-A3B (Baidu, independent lineage); Qwen3.5 family is also domestic |
| Western mainstream small | #5 Ministral-3-8B, #6 gemma-4-E4B |

### Why NuExtract3 is the highest-value single candidate

`numind/NuExtract3` declares `base_model: Qwen/Qwen3.5-4B` and its `config.json`
matches (vocab 248320, 32 layers, hidden 2560, head_dim 256). It is tagged
`structured-extraction`, `information-extraction`, `document-understanding`,
Apache-2.0, and the GGUF repo was updated 2026-08-25.

That yields a three-way comparison in which base, size, architecture and quant are
all held constant, and only the post-training differs:

| Variant | Post-training | Weights |
|---|---|---|
| `unsloth/Qwen3.5-4B` | none (stock instruct) | 2.55 GiB |
| `numind/NuExtract3` | third-party, generic extraction | 2.59 GiB |
| `lda-v2` | in-house, legal PII | 2.52 GiB |

This is the cleanest possible read on "did my fine-tune add value, and does a generic
extraction tune already get there". Note NuExtract3 is a VLM: use the text-only GGUF
and ignore `mmproj-NuExtract3-BF16.gguf` for this benchmark.

---

## 2. Memory account

### Calibration against the measured baseline

The measured incumbent run (`-c 4096 -ngl 99`) is weights 2583 MiB, peak RSS 3.28 GiB,
which is the stated 1.30x multiplier. Decomposing that measurement:

```
3.28 GiB (measured peak)
  - 2.523 GiB (weights)
  - 0.180 GiB (KV @4096 + SSM recurrent state, computed from the architecture)
  ---------------------
  = 0.578 GiB fixed runtime overhead (Metal scratch, compute buffers, logits)
```

So there are two ways to project the other candidates:

- **Flat 1.30x** on weights, as instructed.
- **Additive**: `weights + KV(architecture, 4096 ctx) + 0.578 GiB`.

Both reproduce the incumbent exactly, but they diverge for larger models, because
the 0.578 GiB overhead is roughly **constant**, not proportional. Applying 1.30x to a
15.6 GiB model implies 4.7 GiB of overhead plus KV, which the measurement does not
support. The two also diverge for dense full-attention models, where the flat factor
under-counts a much larger KV cache.

Both columns are given below. **Tier placement uses the higher of the two**, which is
the conservative choice.

### Per-candidate account, 4096 ctx, Q4_K_M

KV formula: `n_full_attention_layers x n_kv_heads x (k_dim + v_dim) x 2 bytes x ctx`,
plus a constant SSM recurrent state for the hybrid Qwen3.5 models, plus window-capped
KV for Gemma sliding layers.

| Model | Weights GiB | KV @4096 GiB | Additive peak | 1.30x peak | **Used** | Tier |
|---|---|---|---|---|---|---|
| lda-v2 (incumbent) | 2.52 | 0.18 | 3.28 | 3.28 | **3.28** (measured) | 16GB |
| Qwen3.5-4B (CONTROL) | 2.55 | 0.18 | 3.31 | 3.32 | **3.32** | 16GB |
| NuExtract3 | 2.59 | 0.18 | 3.35 | 3.37 | **3.37** | 16GB |
| Qwen3-4B | 2.33 | 0.56 | 3.47 | 3.02 | **3.47** | 16GB |
| Ministral-3-8B-2512 | 4.84 | 0.53 | 5.95 | 6.29 | **6.29** | 16GB |
| gemma-4-E4B-it | 4.64 | 0.09 | 5.30 | 6.03 | **6.03** | 16GB |
| Qwen3.5-9B | 5.29 | 0.18 | 6.05 | 6.88 | **6.88** | 16GB, tight |
| gemma-4-12b-it | 6.63 | 0.56 | 7.77 | 8.62 | **8.62** | 32GB |
| ERNIE-4.5-21B-A3B-PT | 12.42 | 0.22 | 13.21 | 16.14 | **16.14** | 32GB |
| Qwen3.5-27B | 15.59 | 0.39 | 16.56 | 20.27 | **20.27** | 32GB, at the line |

Notes on individual rows:

- **Qwen3-4B has 3x the KV cache of Qwen3.5-4B** despite being a smaller file, because
  all 36 layers are full attention. It is the one candidate where flat 1.30x
  *under*-predicts (3.02 vs 3.47 actual-model).
- **Qwen3.5-9B at 6.88 GiB sits exactly on the 16GB ceiling.** The additive model says
  6.05 GiB. Measure it before trusting either. If it exceeds 7 GiB in practice, it
  becomes a 32GB-tier model and the 16GB tier tops out at Ministral-3-8B.
- **Qwen3.5-27B** is the case where the flat multiplier is misleading: 20.27 GiB by
  1.30x (which would drop it) versus 16.56 GiB additive. The architecture-grounded
  number has 3.4 GiB of headroom against the 20 GiB ceiling. It is listed as an
  alternate rather than a default, and should be RSS-measured before committing.

### Dropped for exceeding the 20 GiB ceiling

| Model | Repo (verified to exist) | Weights GiB | KV GiB | Peak | Reason |
|---|---|---|---|---|---|
| Qwen3.5-35B-A3B | `unsloth/Qwen3.5-35B-A3B-GGUF` | 20.50 | 0.14 | 21.2 to 26.7 | Weights alone exceed the 20 GiB budget |
| GLM-4.7-Flash | `unsloth/GLM-4.7-Flash-GGUF` | 17.05 | 1.84 | 19.5 to 22.2 | `num_key_value_heads = 20 = num_attention_heads`, so no GQA at all across 47 layers. KV cache is 1.84 GiB at only 4096 ctx. No headroom |

### macOS unified memory ceiling

`iogpu.wired_limit_mb` defaults to about 75% of physical RAM:

- 16GB Mac: about 12 GiB GPU-wired ceiling, versus a 6 to 7 GiB coexistence budget
- 32GB Mac: about 24 GiB GPU-wired ceiling, versus an 18 to 20 GiB coexistence budget

In both tiers the app-coexistence budget binds first, so **the wired limit is not the
constraint at any size on this shortlist** and no `sysctl iogpu.wired_limit_mb` tuning
is needed. It would only become relevant above roughly 24 GiB, which is past the point
where every candidate is already dropped.

---

## 3. Download budget and order

Measured throughput is 6.8 MB/s, so wall-clock is about 2.45 minutes per GB.
`Qwen3-4B` (2.50 GB) is already in flight and is treated as sunk.

| Order | Model | GB | Minutes | Cumulative GB | Cumulative min | Question it answers |
|---|---|---|---|---|---|---|
| P0-a | **Qwen3.5-4B (CONTROL)** | 2.74 | 6.7 | 2.74 | 7 | Did the fine-tune beat its own untouched base? |
| P0-b | **NuExtract3** | 2.78 | 6.8 | 5.52 | 14 | Does an off-the-shelf extraction tune on the same base already match it? |
| P1 | Qwen3.5-9B | 5.68 | 13.9 | 11.20 | 27 | Does 2.2x params substitute for tuning? |
| P2 | Ministral-3-8B-2512 | 5.20 | 12.7 | 16.40 | 40 | Western non-reasoning baseline, and a JSON-compliance check with no thinking to suppress |
| P3 | gemma-4-E4B-it | 4.98 | 12.2 | 21.38 | 52 | Second Western reference, different tokenizer family |
| P4 | ERNIE-4.5-21B-A3B-PT | 13.33 | 32.7 | 34.71 | 85 | Chinese capability from a lineage independent of Qwen |
| (sunk) | Qwen3-4B | 2.50 | 6.1 | 37.21 | 91 | Already downloading. Generational reference only |

**Total 37.21 GB, under the 40 GB cap, about 91 minutes of transfer.**
Disk headroom after: about 170 GB of the 207 GB free.

The ordering is deliberately front-loaded: **after P0-a and P0-b (5.52 GB, about 14
minutes) the headline question is already answerable**, because those two plus the
incumbent form the controlled triad where only post-training differs. Everything after
P1 is breadth rather than decisiveness, so the run can be cut at any line.

If the 32GB-tier question shifts toward "can raw parameter count replace the fine-tune":
swap P4 for `Qwen3.5-27B` (16.74 GB) to land at 40.62 GB, marginally over the cap; or
drop P3 as well to land at 35.64 GB.

Do **not** download these, they are speculative-decoding sidecars and not standalone
models: `unsloth/Qwen3.5-4B-MTP-GGUF`, `mtp-gemma-4-*.gguf`, and any `MTP/` subfolder.

---

## 4. Per-model runner notes

All models run through `llama-server --jinja` so each uses its own embedded template.
Suggested common flags for parity with the production engine, which decodes greedily:

```
llama-server -m <model>.gguf -c 4096 -ngl 99 --jinja --temp 0 --top-k 1
```

| Model | Template family | System role? | Thinking control | Watch out for |
|---|---|---|---|---|
| lda-v2, Qwen3.5-4B, NuExtract3, Qwen3.5-9B, Qwen3.5-27B | ChatML (`<\|im_start\|>`) | Yes | `chat_template_kwargs: {"enable_thinking": false}`. Confirmed present in the incumbent template (7992 chars) and in NuExtract3's `chat_template.jinja` (4 occurrences) | Defaults to thinking ON. If the kwarg is dropped, `<think>` text lands in the reply and destroys strict JSON parsing |
| Qwen3-4B | ChatML | Yes | `enable_thinking: false`, or append `/no_think` to the user turn | Same thinking risk. Different tokenizer (151936 vocab) so token counts are not comparable to Qwen3.5 |
| Ministral-3-8B-Instruct-2512 | Mistral v13 tekken (`[INST]`) | Folded into first user turn | None needed. This is the Instruct build; `Ministral-3-8B-Reasoning-2512` is the separate thinking variant, do not use it | Whitespace-sensitive template. Always `--jinja`, never hand-build |
| gemma-4-E4B-it, gemma-4-12b-it | Gemma (`<start_of_turn>`) | **No system role.** The template prepends system text to the first user turn | Not a reasoning model | E4B is a nested/MatFormer build with `num_kv_shared_layers: 18` and 35 of 42 layers on a 512 sliding window. Ignore `mmproj-*` and `mtp-*` files |
| ERNIE-4.5-21B-A3B-PT | ERNIE 4.5 | Yes | Not a reasoning model. `-PT` is the non-thinking post-trained build; `-Thinking` is separate | MoE, 3B active of 21B. Fast decode, large resident weights |
| NuExtract3 | ChatML, Qwen3.5-derived | Yes | `enable_thinking: false` | It is a VLM. Use the text-only GGUF, skip `mmproj-NuExtract3-BF16.gguf`. It is also trained to accept an explicit output schema, so it deserves a second run in its native schema-prompt mode alongside the LDA prompt |

**Do not enable GBNF/JSON grammar for the primary run.** Forcing valid JSON with
`--grammar-file` would mask exactly the capability under test (does the model obey the
strict JSON contract on its own). Run grammar-free for the headline metric, and
optionally re-run with grammar as a separate ceiling measurement.

---

## 5. Confounders, ranked by how badly they would mislead

### C1. Wrong base model (highest risk, already triggered)

Treating **Qwen3-4B** as "the base" would compare the fine-tune against a previous
architecture generation: dense vs hybrid SSM, 151936 vs 248320 vocab, 40K vs 262K
context. Any win would read as "fine-tuning worked" when a large part is the
Qwen3 to Qwen3.5 jump. **Mitigation: `unsloth/Qwen3.5-4B-GGUF` is the control, and it
is P0. Qwen3-4B is reported separately and explicitly labelled a generational
reference.**

### C2. Thinking-mode asymmetry

The incumbent is always driven with `<think>` pre-closed. Four of the seven candidates
default to thinking ON. If the runner fails to pass `enable_thinking: false` to any of
them, that model emits reasoning prose, fails strict JSON parsing, and scores near zero
on format compliance. The fine-tune would then appear dramatically better because of a
harness flag, not capability. **Mitigation: assert on every response that no `<think>`
token appears, and fail the run rather than scoring it. Log the resolved template
kwargs per model.**

### C3. Prompt overfitting to the incumbent

The LDA Pass-1/Pass-2 prompts in `PromptStore.swift` are Chinese and were iterated
against this fine-tune. Scoring every candidate on a prompt tuned to the incumbent
systematically favours the incumbent. **Mitigation: run at least one neutral prompt
variant, and for NuExtract3 additionally run its native schema format. If the incumbent
only wins under its own prompt, that is a prompt result, not a model result.**

### C4. Harness prompt is not the production prompt

Production hand-builds ChatML and pre-closes `<think>`. The benchmark uses `--jinja`
with the GGUF's embedded template. For the incumbent these differ, so the benchmark
does not reproduce the shipped path byte for byte. **Mitigation: acceptable, since it
makes all models comparable, but do not report the incumbent's benchmark score as its
production score.**

### C5. Quant recipe is not a constant

"Q4_K_M" is a label, not a specification. bartowski's Qwen3.5-4B is 10.7% larger than
unsloth's from identical weights, and imatrix calibration sets are usually
English-heavy, which can measurably degrade Chinese. **Mitigation: the shortlist uses
unsloth for everything except the two official repos (`Qwen/Qwen3-4B-GGUF`,
`mistralai/...-GGUF`) and `numind/NuExtract3-GGUF`. Do not mix in bartowski builds.**

### C6. Tokenizer differences make "2K tokens" mean different amounts of Chinese

Vocab sizes span 103,424 (ERNIE) to 262,144 (Gemma), with Qwen3.5 at 248,320 and
Qwen3 at 151,936. The same Chinese contract segment becomes a materially different
token count per model. This distorts both throughput comparisons and how much text
fits in 4096 ctx. **Mitigation: hold the input constant in characters, not tokens, and
report tokens-per-character per model as its own column.**

### C7. Precision and recall must both be reported

The task explicitly cares about not over-extracting. An untuned base will happily
over-extract; a recall-only metric would rate it as fine. **Mitigation: report
precision, recall and a strict-JSON-validity rate separately. Never collapse to a
single score.**

### C8. Speed is not comparable across architectures at face value

Qwen3.5 hybrids carry a 0.18 GiB KV cache; Ministral-3-8B carries 0.53 GiB; ERNIE and
Qwen3.5-35B-A3B are MoE with roughly 3B active parameters. Decode speed will differ for
reasons unrelated to extraction quality, and MoE models will look fast per token while
holding far more resident memory. **Mitigation: report tokens/s alongside peak RSS,
and treat the pair as the cost metric rather than either alone.**

---

## 6. Preflight before the first run

1. Confirm the runtime loads a hybrid SSM arch:
   `llama-server -m Qwen3.5-4B-Q4_K_M.gguf -c 4096 -ngl 99` and check the log reports
   `qwen35` plus a recurrent/hybrid memory allocation. The vendored framework in this
   repo already carries `qwen35` symbols, and mini's master build is newer, so this is
   expected to pass.
2. Measure actual peak RSS per model rather than trusting either projection column:
   `/usr/bin/time -l llama-server ...`, or sample `ps -o rss= -p <pid>` during a run.
   Every peak figure in section 2 except the incumbent's is a projection.
3. Assert no `<think>` substring in any response before scoring it.
