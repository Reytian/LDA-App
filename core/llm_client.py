"""
LLM API client — calls external LLM via OpenAI-compatible format.
Configured through .env file (LLM_API_BASE, LLM_API_KEY, LLM_MODEL).
"""

import os
import re
import json
import requests
from dotenv import load_dotenv

load_dotenv()

LLM_API_BASE = os.getenv("LLM_API_BASE", "")
LLM_API_KEY = os.getenv("LLM_API_KEY", "")
LLM_MODEL = os.getenv("LLM_MODEL", "")


def reload_config():
    """Reload LLM config from .env file. Called after settings change."""
    global LLM_API_BASE, LLM_API_KEY, LLM_MODEL
    load_dotenv(override=True)
    LLM_API_BASE = os.getenv("LLM_API_BASE", "")
    LLM_API_KEY = os.getenv("LLM_API_KEY", "")
    LLM_MODEL = os.getenv("LLM_MODEL", "")


def call_llm(messages: list[dict], temperature: float = None) -> str:
    """
    Call the LLM API and return the text response.

    Args:
        messages: Chat messages list [{"role": "...", "content": "..."}, ...]
        temperature: Generation temperature (None = model default).
                     Some models (e.g. kimi-k2.5) only allow default temperature.

    Returns:
        LLM text response
    """
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

    response = requests.post(
        f"{LLM_API_BASE}/chat/completions",
        headers={
            "Authorization": f"Bearer {LLM_API_KEY}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=120,
    )
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]


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

    for start_char, end_char in [("{", "}"), ("[", "]")]:
        start_idx = text.find(start_char)
        if start_idx == -1:
            continue
        end_idx = text.rfind(end_char)
        if end_idx == -1 or end_idx <= start_idx:
            continue
        json_str = text[start_idx : end_idx + 1]
        try:
            return json.loads(json_str)
        except json.JSONDecodeError:
            continue

    raise ValueError(f"Failed to parse JSON from LLM response:\n{text[:500]}")
