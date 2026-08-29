#!/bin/bash
# Run every model in the manifest against a corpus directory.
# manifest line:  <label>|<model file or abs path>|<nothink 0|1>|<max_tokens optional>
# env: CORPUS (default corpus), CTX (default 4096), SUFFIX (label suffix)
set -uo pipefail
cd ~/lda-bench
MANIFEST=${1:-models.manifest}
CORPUS=${CORPUS:-corpus}
CTX=${CTX:-4096}
SUFFIX=${SUFFIX:-}
[ -f "$MANIFEST" ] || { echo "no manifest: $MANIFEST"; exit 1; }
echo "corpus=$CORPUS ctx=$CTX suffix=$SUFFIX"

while IFS="|" read -r LABEL MODEL NOTHINK MAXTOK; do
  case "$LABEL" in \#*|"") continue;; esac
  case "$MODEL" in /*) P="$MODEL";; *) P="$HOME/lda-bench/models/$MODEL";; esac
  FULL="${LABEL}${SUFFIX}"
  if [ ! -f "$P" ]; then echo "SKIP $FULL (missing $P)"; continue; fi
  # A download in flight writes the final filename progressively, so file
  # existence does NOT mean the file is complete. llama.cpp then fails with
  # "data is not within the file bounds, model is corrupted or incomplete".
  # Require the size to be stable across a short interval before running.
  SZ1=$(stat -f%z "$P"); sleep 4; SZ2=$(stat -f%z "$P")
  if [ "$SZ1" != "$SZ2" ]; then
    echo "SKIP $FULL (still downloading: $SZ1 -> $SZ2 bytes)"; continue
  fi
  if [ -f "results/$FULL.raw.json" ]; then echo "SKIP $FULL (already have results)"; continue; fi
  FLAG=""; [ "${NOTHINK:-0}" = "1" ] && FLAG="--no-think"
  MT=${MAXTOK:-1024}; [ -z "$MT" ] && MT=1024
  echo "==================== $FULL (ctx=$CTX max_tokens=$MT) ===================="
  python3 harness/run_model.py --model "$P" --label "$FULL" --corpus "$CORPUS" \
      --out results $FLAG --max-tokens "$MT" --ctx "$CTX"
  pkill -f llama-server 2>/dev/null; sleep 3
done < "$MANIFEST"
echo "ALL DONE"
