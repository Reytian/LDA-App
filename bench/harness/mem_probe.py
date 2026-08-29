#!/usr/bin/env python3
"""
Measure realistic single-user deployment memory for one model.

The main benchmark runs llama-server at its default 4 slots, which sizes the KV
pool for 4 concurrent requests. A desktop app such as LDA serves one request at
a time, so this probe re-measures with -np 1 to get the number that actually
decides whether a model fits alongside the user's other apps.

Usage: mem_probe.py <label> <model_path> [ctx]
"""
import json, os, subprocess, signal, sys, time, urllib.request
from pathlib import Path

SERVER = os.path.expanduser("~/llama.cpp-bench/build/bin/llama-server")
PORT = 8099
BASE = "http://127.0.0.1:%d" % PORT

label, model = sys.argv[1], sys.argv[2]
ctx = int(sys.argv[3]) if len(sys.argv) > 3 else 4096

corpus = Path(os.path.expanduser("~/lda-bench/corpus"))
docs = [json.loads(p.read_text()) for p in corpus.glob("*.json")]
doc = max(docs, key=lambda d: len(d["text"]))
sys_p = Path(os.path.expanduser("~/lda-bench/system.txt")).read_text().rstrip("\n")

cmd = [SERVER, "--model", model, "--host", "127.0.0.1", "--port", str(PORT),
       "-ngl", "99", "-c", str(ctx), "-np", "1", "--jinja", "--no-webui"]
proc = subprocess.Popen(cmd, stdout=open(os.devnull, "w"), stderr=subprocess.STDOUT)


def rss():
    o = subprocess.run(["ps", "-o", "rss=", "-p", str(proc.pid)],
                       capture_output=True, text=True).stdout.strip()
    return int(o) / 1024.0 if o else 0.0


peak = 0.0
try:
    for _ in range(600):
        try:
            with urllib.request.urlopen(BASE + "/health", timeout=2) as r:
                if json.load(r).get("status") == "ok":
                    break
        except Exception:
            time.sleep(1)
    peak = max(peak, rss())
    after_load = peak

    user = ("Anonymize. Return ONLY JSON with key entities "
            "(array of {value,type}).\n\nTEXT:\n" + doc["text"])
    payload = {"messages": [{"role": "system", "content": sys_p},
                            {"role": "user", "content": user}],
               "temperature": 0, "max_tokens": 1024,
               "chat_template_kwargs": {"enable_thinking": False}}
    for attempt in (1, 2):
        try:
            req = urllib.request.Request(
                BASE + "/v1/chat/completions", data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=600).read()
            break
        except Exception as e:
            if attempt == 1:
                payload.pop("chat_template_kwargs", None)
            else:
                print("  warn: generation failed (%s); load-time RSS still valid"
                      % type(e).__name__)
    peak = max(peak, rss())

    wt = os.path.getsize(model) / (1024 ** 3)
    print("%-24s weights %5.2f GiB | after-load %5.2f GB | peak(np=1) %5.2f GB"
          % (label, wt, after_load / 1024, peak / 1024))
    print("JSON " + json.dumps({"label": label, "weights_gib": round(wt, 3),
                                "after_load_gb": round(after_load / 1024, 3),
                                "peak_np1_gb": round(peak / 1024, 3), "ctx": ctx}))
finally:
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
