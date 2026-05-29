"""
LLM API client. Supports two backends selected via LLM_BACKEND:
- "openai" (default): OpenAI-compatible /chat/completions.
- "ollama": native /api/chat (required to disable thinking for models like
  gemma4-v4 via think:false).
Configured through .env file (see .env.example).
"""

import os
import re
import json
import time
import requests
from dotenv import load_dotenv

load_dotenv()

# Backend selection. "openai" (default) keeps the existing OpenAI-compatible
# /chat/completions path. "ollama" uses the native /api/chat path, which is the
# only path where thinking can be disabled (think:false) for thinking models
# such as gemma4-v4.
DEFAULT_BACKEND = "openai"
DEFAULT_OLLAMA_BASE = "http://127.0.0.1:11434"
DEFAULT_TIMEOUT_SECONDS = 120
DEFAULT_NUM_CTX = 32768
DEFAULT_NUM_PREDICT = 4096

LLM_BACKEND = os.getenv("LLM_BACKEND", DEFAULT_BACKEND)
LLM_API_BASE = os.getenv("LLM_API_BASE", "")
LLM_API_KEY = os.getenv("LLM_API_KEY", "")
LLM_MODEL = os.getenv("LLM_MODEL", "")
LLM_OLLAMA_BASE = os.getenv("LLM_OLLAMA_BASE", DEFAULT_OLLAMA_BASE)
LLM_TIMEOUT = int(os.getenv("LLM_TIMEOUT", str(DEFAULT_TIMEOUT_SECONDS)))
LLM_NUM_CTX = int(os.getenv("LLM_NUM_CTX", str(DEFAULT_NUM_CTX)))
LLM_NUM_PREDICT = int(os.getenv("LLM_NUM_PREDICT", str(DEFAULT_NUM_PREDICT)))

# Bounded retry policy for transient failures (timeouts, connection errors,
# 429, and 5xx). These are the failure modes that benefit from a retry; other
# errors (4xx other than 429, malformed envelopes) fail fast.
MAX_RETRIES = 3
RETRY_BACKOFF_SECONDS = 1.0
RETRYABLE_STATUS_CODES = (429, 500, 502, 503, 504)

# Reasoning/thinking tags some models emit even when thinking is disabled. The
# ollama path strips these defensively so leftover scaffolding never leaks into
# anonymized output.
_THINK_TAG_PATTERN = re.compile(
    r"<(think|reasoning)>.*?</\1>", re.DOTALL | re.IGNORECASE
)


def reload_config():
    """Reload LLM config from .env file. Called after settings change."""
    global LLM_BACKEND, LLM_API_BASE, LLM_API_KEY, LLM_MODEL
    global LLM_OLLAMA_BASE, LLM_TIMEOUT, LLM_NUM_CTX, LLM_NUM_PREDICT
    load_dotenv(override=True)
    LLM_BACKEND = os.getenv("LLM_BACKEND", DEFAULT_BACKEND)
    LLM_API_BASE = os.getenv("LLM_API_BASE", "")
    LLM_API_KEY = os.getenv("LLM_API_KEY", "")
    LLM_MODEL = os.getenv("LLM_MODEL", "")
    LLM_OLLAMA_BASE = os.getenv("LLM_OLLAMA_BASE", DEFAULT_OLLAMA_BASE)
    LLM_TIMEOUT = int(os.getenv("LLM_TIMEOUT", str(DEFAULT_TIMEOUT_SECONDS)))
    LLM_NUM_CTX = int(os.getenv("LLM_NUM_CTX", str(DEFAULT_NUM_CTX)))
    LLM_NUM_PREDICT = int(os.getenv("LLM_NUM_PREDICT", str(DEFAULT_NUM_PREDICT)))


def call_llm(messages: list[dict], temperature: float = None) -> str:
    """
    Call the configured LLM backend and return the text response.

    The backend is selected by LLM_BACKEND ("openai" default, or "ollama").
    Both backends share the same bounded retry policy and the LLM_TIMEOUT
    per-request timeout.

    Args:
        messages: Chat messages list [{"role": "...", "content": "..."}, ...]
        temperature: Generation temperature (None = model default).
                     Some models (e.g. kimi-k2.5) only allow default temperature.

    Returns:
        LLM text response
    """
    if LLM_BACKEND == "ollama":
        return _call_ollama(messages, temperature)
    return _call_openai(messages, temperature)


def _call_openai(messages: list[dict], temperature: float = None) -> str:
    """OpenAI-compatible /chat/completions backend (default)."""
    if not LLM_API_BASE or not LLM_API_KEY or not LLM_MODEL:
        raise ValueError(
            "LLM API config incomplete. Check LLM_API_BASE, LLM_API_KEY, LLM_MODEL in .env"
        )

    body = {
        "model": LLM_MODEL,
        "messages": messages,
    }
    if temperature is not None:
        body["temperature"] = temperature

    url = f"{LLM_API_BASE}/chat/completions"
    headers = {
        "Authorization": f"Bearer {LLM_API_KEY}",
        "Content-Type": "application/json",
    }

    response = _request_with_retry(url, headers, body)
    return _extract_content(response)


def _call_ollama(messages: list[dict], temperature: float = None) -> str:
    """
    Native Ollama /api/chat backend.

    Sends think:false so thinking models (e.g. gemma4-v4) do not exhaust
    num_predict on a reasoning trace and return empty content. The system
    message is preserved at the head of the messages list.
    """
    if not LLM_MODEL:
        raise ValueError(
            "LLM config incomplete. Check LLM_MODEL (and LLM_OLLAMA_BASE) in .env"
        )

    body = {
        "model": LLM_MODEL,
        "messages": messages,
        "stream": False,
        # CRITICAL: gemma4-v4 is a thinking model; without think:false it spends
        # its whole num_predict budget thinking and returns empty content.
        "think": False,
        "options": {
            "temperature": temperature if temperature is not None else 0.0,
            "num_ctx": LLM_NUM_CTX,
            "num_predict": LLM_NUM_PREDICT,
        },
    }

    url = f"{LLM_OLLAMA_BASE}/api/chat"
    headers = {"Content-Type": "application/json"}

    response = _request_with_retry(url, headers, body)
    return _extract_ollama_content(response)


def _request_with_retry(
    url: str, headers: dict, body: dict
) -> requests.Response:
    """
    POST with the shared bounded retry policy.

    Retries on Timeout/ConnectionError and on retryable HTTP statuses (429,
    5xx) with exponential backoff, then gives up. Uses LLM_TIMEOUT as the
    per-request timeout (also covers cold-start latency).
    """
    last_error: Exception | None = None
    response: requests.Response | None = None
    for attempt in range(MAX_RETRIES):
        try:
            response = requests.post(
                url, headers=headers, json=body, timeout=LLM_TIMEOUT
            )
        except (requests.Timeout, requests.ConnectionError) as exc:
            # Transient network failure: retry with backoff, then give up.
            last_error = exc
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_BACKOFF_SECONDS * (2**attempt))
                continue
            raise

        # Retry transient HTTP statuses (429, 5xx) before treating them as fatal.
        if response.status_code in RETRYABLE_STATUS_CODES and attempt < MAX_RETRIES - 1:
            time.sleep(RETRY_BACKOFF_SECONDS * (2**attempt))
            continue

        response.raise_for_status()
        return response

    # Loop only falls through here if every attempt hit a retryable status.
    if last_error is not None:
        raise last_error
    response.raise_for_status()
    return response


def _extract_content(response: requests.Response) -> str:
    """
    Defensively extract the assistant text from an OpenAI-compatible response.

    OpenAI-compatible gateways (Ollama, OpenRouter proxies) can return HTTP 200
    with an error envelope (`{"error": {...}}`), an empty `choices` list, or a
    choice with no message content. Indexing blindly would raise an opaque
    KeyError/IndexError, so validate the body and raise a descriptive error.

    Args:
        response: The HTTP response from the chat/completions endpoint.

    Returns:
        The assistant message content string.

    Raises:
        ValueError: If the body is not JSON, carries an error envelope, has no
                    usable choices, or is missing message content.
    """
    try:
        data = response.json()
    except ValueError as exc:
        raise ValueError(
            f"LLM response body was not valid JSON: {response.text[:200]}"
        ) from exc

    if not isinstance(data, dict):
        raise ValueError(f"LLM response was not a JSON object: {str(data)[:200]}")

    if "error" in data and data["error"]:
        raise ValueError(f"LLM API returned an error envelope: {data['error']}")

    choices = data.get("choices")
    if not choices:
        raise ValueError(
            f"LLM response contained no choices (got: {str(data)[:200]})"
        )

    message = choices[0].get("message") if isinstance(choices[0], dict) else None
    content = message.get("content") if isinstance(message, dict) else None
    if content is None:
        raise ValueError(
            f"LLM response choice had no message content (got: {str(choices[0])[:200]})"
        )

    return content


def _extract_ollama_content(response: requests.Response) -> str:
    """
    Defensively extract the assistant text from a native Ollama /api/chat
    response (`{"message": {"content": ...}}`).

    Strips any leftover <think>/<reasoning> scaffolding the model may emit even
    with think:false, then raises if nothing usable remains so run_second_pass
    fails loud rather than silently leaking PII.

    Raises:
        ValueError: If the body is not JSON, carries an error field, is missing
                    message content, or is empty after stripping reasoning tags.
    """
    try:
        data = response.json()
    except ValueError as exc:
        raise ValueError(
            f"Ollama response body was not valid JSON: {response.text[:200]}"
        ) from exc

    if not isinstance(data, dict):
        raise ValueError(f"Ollama response was not a JSON object: {str(data)[:200]}")

    if data.get("error"):
        raise ValueError(f"Ollama API returned an error: {data['error']}")

    message = data.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if content is None:
        raise ValueError(
            f"Ollama response had no message content (got: {str(data)[:200]})"
        )

    stripped = _THINK_TAG_PATTERN.sub("", content).strip()
    if not stripped:
        raise ValueError(
            "Ollama response was empty after stripping reasoning tags. "
            "Ensure think:false is honored by the model (e.g. gemma4-v4)."
        )

    return stripped


def check_api_connection() -> bool:
    """
    Test whether the LLM API connection is working.

    Returns:
        True if connected, False otherwise
    """
    try:
        result = call_llm(
            [{"role": "user", "content": "Reply OK"}],
        )
        return len(result) > 0
    except Exception:
        return False


def parse_json_response(text: str) -> dict | list:
    """
    Extract JSON data from an LLM response.

    Handles various formats: raw JSON, markdown-wrapped JSON,
    JSON embedded in explanatory text.

    Args:
        text: Raw LLM response text

    Returns:
        Parsed dict or list
    """
    try:
        return json.loads(text.strip())
    except json.JSONDecodeError:
        pass

    cleaned = re.sub(r"```(?:json)?\s*", "", text)
    cleaned = cleaned.strip()
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass

    # Collect both candidate slices (the outermost {..} and the outermost [..])
    # then prefer the one that starts earliest in the text. This stops a {..}
    # object that lives INSIDE a [..] array from winning: when the response is a
    # single-entity array wrapped in prose, the array begins before its lone
    # object, so the list is returned rather than the bare dict (bug #5).
    candidates: list[tuple[int, str]] = []
    for start_char, end_char in [("[", "]"), ("{", "}")]:
        start_idx = text.find(start_char)
        if start_idx == -1:
            continue
        end_idx = text.rfind(end_char)
        if end_idx == -1 or end_idx <= start_idx:
            continue
        candidates.append((start_idx, text[start_idx : end_idx + 1]))

    # Earliest-starting slice first; the outer container always begins before
    # anything nested inside it.
    candidates.sort(key=lambda pair: pair[0])
    for _, json_str in candidates:
        try:
            return json.loads(json_str)
        except json.JSONDecodeError:
            continue

    raise ValueError(f"Failed to parse JSON from LLM response:\n{text[:500]}")
