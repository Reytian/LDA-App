"""
Offline unit tests for core/llm_client.py.

All tests monkeypatch requests.post and set the module-level config globals so
they never touch the network or a real LLM. Covers bugs #5 (single-entity array
parsing), #6 (defensive choices parsing), and #7 (bounded retry on transient
failures).
"""

import json

import pytest
import requests

from core import llm_client


class FakeResponse:
    """Minimal stand-in for requests.Response used by call_llm."""

    def __init__(self, status_code: int, payload, text: str = ""):
        self.status_code = status_code
        self._payload = payload
        self.text = text or json.dumps(payload) if payload is not None else text

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise requests.HTTPError(f"status {self.status_code}")


@pytest.fixture(autouse=True)
def _config(monkeypatch):
    """Set valid config globals and a no-op sleep so retries do not stall."""
    monkeypatch.setattr(llm_client, "LLM_API_BASE", "http://localhost:9999/v1")
    monkeypatch.setattr(llm_client, "LLM_API_KEY", "test-key")
    monkeypatch.setattr(llm_client, "LLM_MODEL", "test-model")
    monkeypatch.setattr(llm_client.time, "sleep", lambda _seconds: None)


def _ok_payload(content: str = "hello"):
    return {"choices": [{"message": {"content": content}}]}


def _ollama_payload(content: str = "hello"):
    return {"message": {"role": "assistant", "content": content}}


# --- Bug #6: defensive choices parsing ---------------------------------------


def test_error_envelope_raises_descriptive_error(monkeypatch):
    # Arrange
    resp = FakeResponse(200, {"error": {"message": "rate limited", "code": 429}})
    monkeypatch.setattr(requests, "post", lambda *a, **k: resp)

    # Act / Assert
    with pytest.raises(ValueError) as exc:
        llm_client.call_llm([{"role": "user", "content": "hi"}])
    assert "error envelope" in str(exc.value).lower()


def test_empty_choices_raises_descriptive_error(monkeypatch):
    # Arrange
    resp = FakeResponse(200, {"choices": []})
    monkeypatch.setattr(requests, "post", lambda *a, **k: resp)

    # Act / Assert
    with pytest.raises(ValueError) as exc:
        llm_client.call_llm([{"role": "user", "content": "hi"}])
    assert "no choices" in str(exc.value).lower()


def test_missing_content_raises_descriptive_error(monkeypatch):
    # Arrange
    resp = FakeResponse(200, {"choices": [{"message": {}}]})
    monkeypatch.setattr(requests, "post", lambda *a, **k: resp)

    # Act / Assert
    with pytest.raises(ValueError) as exc:
        llm_client.call_llm([{"role": "user", "content": "hi"}])
    assert "content" in str(exc.value).lower()


def test_valid_response_returns_content(monkeypatch):
    # Arrange
    resp = FakeResponse(200, _ok_payload("anonymized output"))
    monkeypatch.setattr(requests, "post", lambda *a, **k: resp)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert
    assert result == "anonymized output"


# --- Bug #7: bounded retry on transient failures -----------------------------


def test_retry_then_success_on_transient_500(monkeypatch):
    # Arrange: first call returns 500, second returns a healthy 200.
    responses = [
        FakeResponse(500, {"error": "server error"}),
        FakeResponse(200, _ok_payload("recovered")),
    ]
    calls = {"n": 0}

    def fake_post(*_args, **_kwargs):
        resp = responses[calls["n"]]
        calls["n"] += 1
        return resp

    monkeypatch.setattr(requests, "post", fake_post)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert
    assert result == "recovered"
    assert calls["n"] == 2


def test_retry_then_success_on_timeout(monkeypatch):
    # Arrange: first call raises Timeout, second succeeds.
    calls = {"n": 0}

    def fake_post(*_args, **_kwargs):
        calls["n"] += 1
        if calls["n"] == 1:
            raise requests.Timeout("read timed out")
        return FakeResponse(200, _ok_payload("after timeout"))

    monkeypatch.setattr(requests, "post", fake_post)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert
    assert result == "after timeout"
    assert calls["n"] == 2


def test_persistent_500_eventually_raises(monkeypatch):
    # Arrange: every attempt returns 500.
    calls = {"n": 0}

    def fake_post(*_args, **_kwargs):
        calls["n"] += 1
        return FakeResponse(500, {"error": "down"})

    monkeypatch.setattr(requests, "post", fake_post)

    # Act / Assert
    with pytest.raises(requests.HTTPError):
        llm_client.call_llm([{"role": "user", "content": "hi"}])
    assert calls["n"] == llm_client.MAX_RETRIES


def test_persistent_timeout_eventually_raises(monkeypatch):
    # Arrange: every attempt times out.
    calls = {"n": 0}

    def fake_post(*_args, **_kwargs):
        calls["n"] += 1
        raise requests.Timeout("read timed out")

    monkeypatch.setattr(requests, "post", fake_post)

    # Act / Assert
    with pytest.raises(requests.Timeout):
        llm_client.call_llm([{"role": "user", "content": "hi"}])
    assert calls["n"] == llm_client.MAX_RETRIES


# --- Native Ollama backend (LLM_BACKEND="ollama") ----------------------------


@pytest.fixture
def _ollama_backend(monkeypatch):
    """Select the native Ollama backend and pin a known base URL."""
    monkeypatch.setattr(llm_client, "LLM_BACKEND", "ollama")
    monkeypatch.setattr(llm_client, "LLM_OLLAMA_BASE", "http://127.0.0.1:11434")
    monkeypatch.setattr(llm_client, "LLM_MODEL", "gemma4-v4")
    monkeypatch.setattr(llm_client, "LLM_NUM_CTX", 32768)
    monkeypatch.setattr(llm_client, "LLM_NUM_PREDICT", 4096)


def _capture_post(monkeypatch, resp):
    """Patch requests.post to record its call and return resp."""
    captured = {}

    def fake_post(url, headers=None, json=None, timeout=None):
        captured["url"] = url
        captured["headers"] = headers
        captured["json"] = json
        captured["timeout"] = timeout
        return resp

    monkeypatch.setattr(requests, "post", fake_post)
    return captured


def test_ollama_posts_to_api_chat_with_think_false(monkeypatch, _ollama_backend):
    # Arrange
    resp = FakeResponse(200, _ollama_payload("anon output"))
    captured = _capture_post(monkeypatch, resp)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}], temperature=0.2)

    # Assert: request shape matches the native /api/chat contract.
    assert captured["url"] == "http://127.0.0.1:11434/api/chat"
    body = captured["json"]
    assert body["model"] == "gemma4-v4"
    assert body["stream"] is False
    assert body["think"] is False
    assert isinstance(body["options"], dict)
    assert body["options"]["temperature"] == 0.2
    assert body["options"]["num_ctx"] == 32768
    assert body["options"]["num_predict"] == 4096
    # Extracts message.content correctly.
    assert result == "anon output"


def test_ollama_default_temperature_is_zero(monkeypatch, _ollama_backend):
    # Arrange
    resp = FakeResponse(200, _ollama_payload("ok"))
    captured = _capture_post(monkeypatch, resp)

    # Act: no temperature passed -> deterministic 0.0 for anonymization.
    llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert
    assert captured["json"]["options"]["temperature"] == 0.0


def test_ollama_strips_think_tags(monkeypatch, _ollama_backend):
    # Arrange: model leaks a reasoning trace despite think:false.
    payload = _ollama_payload(
        "<think>let me reason about this</think>\n[{\"text\":\"Acme\"}]"
    )
    resp = FakeResponse(200, payload)
    _capture_post(monkeypatch, resp)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert: scaffolding removed, only the real content remains.
    assert "<think>" not in result
    assert "reason about this" not in result
    assert result == '[{"text":"Acme"}]'


def test_ollama_empty_after_stripping_raises_loud(monkeypatch, _ollama_backend):
    # Arrange: the entire response is a reasoning trace, nothing usable remains.
    payload = _ollama_payload("<think>thinking forever, no answer</think>")
    resp = FakeResponse(200, payload)
    _capture_post(monkeypatch, resp)

    # Act / Assert: must fail loud so run_second_pass never leaks PII silently.
    with pytest.raises(ValueError) as exc:
        llm_client.call_llm([{"role": "user", "content": "hi"}])
    assert "empty" in str(exc.value).lower()


def test_ollama_uses_llm_timeout(monkeypatch, _ollama_backend):
    # Arrange
    monkeypatch.setattr(llm_client, "LLM_TIMEOUT", 99)
    resp = FakeResponse(200, _ollama_payload("ok"))
    captured = _capture_post(monkeypatch, resp)

    # Act
    llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert: the shared per-request timeout applies to the ollama path too.
    assert captured["timeout"] == 99


def test_ollama_retries_on_transient_500(monkeypatch, _ollama_backend):
    # Arrange: first attempt 500, second healthy 200.
    responses = [
        FakeResponse(500, {"error": "server error"}),
        FakeResponse(200, _ollama_payload("recovered")),
    ]
    calls = {"n": 0}

    def fake_post(*_args, **_kwargs):
        resp = responses[calls["n"]]
        calls["n"] += 1
        return resp

    monkeypatch.setattr(requests, "post", fake_post)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert: same retry policy as the openai path.
    assert result == "recovered"
    assert calls["n"] == 2


def test_default_backend_hits_chat_completions(monkeypatch):
    # Regression guard: the DEFAULT backend ("openai") MUST POST to
    # /chat/completions, not /api/chat, so the existing offline suite stays green.
    assert llm_client.DEFAULT_BACKEND == "openai"
    monkeypatch.setattr(llm_client, "LLM_BACKEND", "openai")
    resp = FakeResponse(200, _ok_payload("via openai"))
    captured = _capture_post(monkeypatch, resp)

    # Act
    result = llm_client.call_llm([{"role": "user", "content": "hi"}])

    # Assert
    assert captured["url"] == "http://localhost:9999/v1/chat/completions"
    assert captured["headers"]["Authorization"] == "Bearer test-key"
    assert result == "via openai"


# --- Bug #5: single-entity array wrapped in prose returns a list -------------


def test_single_entity_array_in_prose_returns_list():
    # Arrange
    text = (
        'I found one:\n[\n  {"text":"Acme Corp","type":"company","canonical":""}\n]\n'
        "Done."
    )

    # Act
    result = llm_client.parse_json_response(text)

    # Assert
    assert isinstance(result, list)
    assert len(result) == 1
    assert result[0]["text"] == "Acme Corp"


def test_object_in_prose_still_returns_dict():
    # Arrange: a bare object wrapped in prose has no array, should stay a dict.
    text = 'Here it is: {"text":"Acme Corp","type":"company"} thanks.'

    # Act
    result = llm_client.parse_json_response(text)

    # Assert
    assert isinstance(result, dict)
    assert result["text"] == "Acme Corp"


def test_clean_array_parses_directly():
    # Arrange
    text = '[{"text":"A","type":"person"},{"text":"B","type":"company"}]'

    # Act
    result = llm_client.parse_json_response(text)

    # Assert
    assert isinstance(result, list)
    assert len(result) == 2


def test_markdown_wrapped_array_parses():
    # Arrange
    text = '```json\n[{"text":"A","type":"person"}]\n```'

    # Act
    result = llm_client.parse_json_response(text)

    # Assert
    assert isinstance(result, list)
    assert result[0]["text"] == "A"
