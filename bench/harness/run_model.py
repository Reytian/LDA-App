#!/usr/bin/env python3
"""
Run one GGUF model over the golden corpus via llama-server and record raw
outputs plus resource telemetry.

Every model is driven through /v1/chat/completions with --jinja so each one
gets the chat template embedded in its own GGUF. That is the only fair way to
compare models whose templates differ. Validated against the production path:
for the fine-tuned model this produces byte-identical output to the raw ChatML
prompt that LDACore.LLMEngine builds.

Usage:
  run_model.py --model <path.gguf> --label <name> --corpus <dir> --out <dir>
"""
import argparse, json, os, re, signal, subprocess, sys, time, urllib.request, urllib.error
from pathlib import Path

SERVER = os.path.expanduser("~/llama.cpp-bench/build/bin/llama-server")
PORT = 8099
BASE = f"http://127.0.0.1:{PORT}"
CTX = 4096


def log(msg):
    print(f"[runner] {msg}", flush=True)


def wait_health(timeout=600):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with urllib.request.urlopen(f"{BASE}/health", timeout=2) as r:
                if json.load(r).get("status") == "ok":
                    return time.time() - start
        except Exception:
            pass
        time.sleep(1)
    return None


def rss_mb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
        return int(out) / 1024.0 if out else 0.0
    except Exception:
        return 0.0


def post(path, payload, timeout=600):
    req = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--no-think", action="store_true",
                    help="send chat_template_kwargs.enable_thinking=false")
    ap.add_argument("--max-tokens", type=int, default=1024)
    ap.add_argument("--ctx", type=int, default=CTX,
                    help="context size; full agreements need more than the 4096 default")
    args = ap.parse_args()

    docs = []
    for p in sorted(Path(args.corpus).glob("*.json")):
        docs.append(json.loads(p.read_text()))
    if not docs:
        log("FATAL: no corpus documents found")
        return 2
    log(f"{len(docs)} corpus documents")

    weights_mb = os.path.getsize(args.model) / (1024 * 1024)
    cmd = [SERVER, "--model", args.model, "--host", "127.0.0.1", "--port", str(PORT),
           "-ngl", "99", "-c", str(args.ctx), "-np", "1", "--jinja", "--no-webui", "--slots"]
    log(f"starting server: {Path(args.model).name} ({weights_mb:.0f} MB weights)")
    logf = open(Path(args.out) / f"{args.label}.server.log", "w")
    t0 = time.time()
    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT)

    result = {"label": args.label, "model_path": args.model,
              "weights_mb": round(weights_mb, 1), "ctx": args.ctx, "docs": []}
    peak_rss = 0.0
    try:
        load_s = wait_health()
        if load_s is None:
            log("FATAL: server never became healthy")
            result["fatal"] = "server_start_timeout"
            return 1
        result["load_seconds"] = round(load_s, 2)
        peak_rss = max(peak_rss, rss_mb(proc.pid))
        log(f"ready in {load_s:.1f}s, RSS after load {peak_rss:.0f} MB")

        sys_prompt = Path(os.path.expanduser("~/lda-bench/system.txt")).read_text().rstrip("\n")
        think_kwargs = {"chat_template_kwargs": {"enable_thinking": False}} if args.no_think else {}

        for i, d in enumerate(docs, 1):
            user = ("Anonymize. Return ONLY JSON with key entities "
                    "(array of {value,type}).\n\nTEXT:\n" + d["text"])
            payload = {"messages": [{"role": "system", "content": sys_prompt},
                                    {"role": "user", "content": user}],
                       "temperature": 0, "max_tokens": args.max_tokens,
                       "cache_prompt": False}
            payload.update(think_kwargs)
            entry = {"id": d["id"]}
            t = time.time()
            try:
                r = post("/v1/chat/completions", payload)
            except urllib.error.HTTPError as e:
                body = e.read().decode()[:400]
                if think_kwargs:
                    log(f"  {d['id']}: thinking kwarg rejected, retrying without")
                    payload.pop("chat_template_kwargs", None)
                    think_kwargs = {}
                    t = time.time()
                    r = post("/v1/chat/completions", payload)
                else:
                    entry.update({"error": f"HTTP {e.code}: {body}", "latency_s": round(time.time()-t, 2)})
                    result["docs"].append(entry)
                    log(f"  {d['id']}: HTTP {e.code}")
                    continue
            except Exception as e:
                entry.update({"error": repr(e)[:300], "latency_s": round(time.time()-t, 2)})
                result["docs"].append(entry)
                log(f"  {d['id']}: {type(e).__name__}")
                continue

            dt = time.time() - t
            msg = r["choices"][0]["message"]
            usage = r.get("usage", {})
            entry.update({
                "latency_s": round(dt, 2),
                "raw_output": msg.get("content") or "",
                "reasoning_content": msg.get("reasoning_content") or "",
                "finish_reason": r["choices"][0].get("finish_reason"),
                "prompt_tokens": usage.get("prompt_tokens"),
                "completion_tokens": usage.get("completion_tokens"),
            })
            ct = usage.get("completion_tokens") or 0
            entry["gen_tok_per_s"] = round(ct / dt, 2) if dt > 0 else None
            result["docs"].append(entry)
            peak_rss = max(peak_rss, rss_mb(proc.pid))
            log(f"  [{i}/{len(docs)}] {d['id']}: {dt:.1f}s, {ct} tok, "
                f"finish={entry['finish_reason']}, RSS {peak_rss:.0f} MB")
    finally:
        result["peak_rss_mb"] = round(peak_rss, 1)
        result["peak_rss_gb"] = round(peak_rss / 1024, 2)
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        logf.close()
        Path(args.out).mkdir(parents=True, exist_ok=True)
        # Never persist a failed run. run_all.sh treats an existing result file
        # as "already done", so a fatal result would permanently block the retry
        # once the real cause (for example an incomplete download) is resolved.
        reason = result.get("fatal") or ("no docs" if not result["docs"] else None)
        if reason:
            log("NOT writing result for %s: %s" % (args.label, reason))
            return 1
        outp = Path(args.out) / f"{args.label}.raw.json"
        outp.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        log(f"wrote {outp}  (peak RSS {result['peak_rss_gb']} GB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
