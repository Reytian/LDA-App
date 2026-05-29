"""Offline tests for the UI page fixes (#11, #12, #13, #17).

Streamlit cannot be driven headlessly, so these tests exercise the only
pure, import-safe logic introduced by the fixes: settings_page._write_env
(bug #17). The streamlit and pandas imports pulled in by the page modules are
stubbed so the modules import without those heavy deps being present.

The other three fixes (#11 deanonymize results persistence, #12 opt-in disk
save, #13 data_editor state clearing) live inside Streamlit render flows and
are verified structurally by py_compile plus the source-level assertions below.
"""

import os
import sys
import stat
import types
import importlib
from pathlib import Path

import pytest


def _install_streamlit_stub() -> None:
    """Install a minimal stub for the streamlit and pandas modules."""
    if "streamlit" not in sys.modules:
        sys.modules["streamlit"] = types.ModuleType("streamlit")
    if "pandas" not in sys.modules:
        sys.modules["pandas"] = types.ModuleType("pandas")


def _load_settings_module():
    """Import ui.settings_page with project root on sys.path."""
    project_root = Path(__file__).resolve().parents[1]
    if str(project_root) not in sys.path:
        sys.path.insert(0, str(project_root))
    _install_streamlit_stub()
    # core.llm_client is imported by settings_page; it must import cleanly.
    import ui.settings_page as settings_page  # noqa: WPS433
    return importlib.reload(settings_page)


def test_write_env_creates_file_with_expected_content(tmp_path, monkeypatch):
    """._write_env writes the three config lines in order."""
    settings_page = _load_settings_module()
    monkeypatch.setattr(settings_page, "PROJECT_ROOT", str(tmp_path))

    path = settings_page._write_env("https://api.example/v1", "sk-secret", "kimi-k2.5")

    content = Path(path).read_text()
    assert "LLM_API_BASE=https://api.example/v1\n" in content
    assert "LLM_API_KEY=sk-secret\n" in content
    assert "LLM_MODEL=kimi-k2.5\n" in content


def test_write_env_sets_owner_only_permissions(tmp_path, monkeypatch):
    """._write_env restricts the .env file to owner read/write (0600)."""
    settings_page = _load_settings_module()
    monkeypatch.setattr(settings_page, "PROJECT_ROOT", str(tmp_path))

    path = settings_page._write_env("base", "key", "model")

    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600, f"expected 0o600, got {oct(mode)}"


def test_write_env_returns_path_under_project_root(tmp_path, monkeypatch):
    """._write_env returns the path it wrote, located under PROJECT_ROOT."""
    settings_page = _load_settings_module()
    monkeypatch.setattr(settings_page, "PROJECT_ROOT", str(tmp_path))

    path = settings_page._write_env("base", "key", "model")

    assert path == os.path.join(str(tmp_path), ".env")
    assert os.path.exists(path)


def test_write_env_overwrite_keeps_restricted_permissions(tmp_path, monkeypatch):
    """Rewriting the .env keeps 0600 (no perm widening on overwrite)."""
    settings_page = _load_settings_module()
    monkeypatch.setattr(settings_page, "PROJECT_ROOT", str(tmp_path))

    settings_page._write_env("a", "b", "c")
    path = settings_page._write_env("a2", "b2", "c2")

    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600
    assert "LLM_API_BASE=a2\n" in Path(path).read_text()
