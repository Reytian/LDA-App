"""Offline tests for the LDA CLI bridge (skills/.../scripts/lda_skill.py).

These tests cover bugs #14 and #15:

- #15 (command_anonymize): the restoration mapping JSON must be written
  BEFORE (or independently of) the same-format anonymized output, and a
  same-format failure must degrade to a .txt file rather than losing the
  mapping after paying the full LLM cost.
- #14 (command_restore): a same-format failure must not discard the
  already-computed restored text; it must degrade to a .txt file.

The suite runs fully offline. The real ``core.*`` modules (which may reach an
LLM or call textutil) are replaced with lightweight stubs in ``sys.modules``,
and the module-level ``same_format_*`` / ``resolve_repo`` / ``load_file``
helpers are monkeypatched.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import types
from pathlib import Path

import pytest


# --------------------------------------------------------------------------- #
# Import the script under test by absolute path (it lives outside any package).
# --------------------------------------------------------------------------- #
SKILL_PATH = (
    Path(__file__).resolve().parent.parent
    / "skills"
    / "legal-document-anonymizer"
    / "scripts"
    / "lda_skill.py"
)


def _load_skill_module() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("lda_skill_under_test", SKILL_PATH)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lda = _load_skill_module()


# --------------------------------------------------------------------------- #
# Fixtures / helpers
# --------------------------------------------------------------------------- #
SAMPLE_MAPPING = {
    "metadata": {"entity_count": 2, "source_file": "deal.doc"},
    "mappings": {"{PERSON_1}": "Jane Roe"},
    "replacement_log": [{"placeholder": "{PERSON_1}", "original": "Jane Roe"}],
}


@pytest.fixture
def stub_core(monkeypatch):
    """Install fake ``core.anonymizer`` and ``core.deanonymizer`` modules.

    The fakes avoid any network / LLM / textutil activity so the command
    functions can run offline.
    """
    core_pkg = types.ModuleType("core")
    anonymizer_mod = types.ModuleType("core.anonymizer")
    deanonymizer_mod = types.ModuleType("core.deanonymizer")

    def fake_run_first_pass(text):
        return {"document_type": "Agreement", "aliases": []}

    def fake_run_second_pass(text, pass1):
        return [{"entity_type": "PERSON", "value": "Jane Roe"}]

    def fake_execute_replacement(text, entities, pass1, source_filename=""):
        return "ANON TEXT {PERSON_1}", dict(SAMPLE_MAPPING)

    anonymizer_mod.run_first_pass = fake_run_first_pass
    anonymizer_mod.run_second_pass = fake_run_second_pass

    def fake_run_deanonymize(text, mapping):
        stats = {
            "position_matched": 1,
            "context_matched": 0,
            "fallback_count": 0,
            "remaining_placeholders": 0,
        }
        return "RESTORED Jane Roe", stats

    anonymizer_mod.execute_replacement = fake_execute_replacement
    deanonymizer_mod.run_deanonymize = fake_run_deanonymize

    monkeypatch.setitem(sys.modules, "core", core_pkg)
    monkeypatch.setitem(sys.modules, "core.anonymizer", anonymizer_mod)
    monkeypatch.setitem(sys.modules, "core.deanonymizer", deanonymizer_mod)
    return anonymizer_mod, deanonymizer_mod


@pytest.fixture
def patch_helpers(monkeypatch):
    """Neutralize repo resolution and file loading for offline runs."""
    monkeypatch.setattr(lda, "resolve_repo", lambda repo: Path("/fake/repo"))
    monkeypatch.setattr(lda, "load_file", lambda input_path: ("RAW DOC TEXT", b"RAW BYTES"))


def _anon_args(input_path: Path, out_dir: Path) -> argparse.Namespace:
    return argparse.Namespace(
        repo=None,
        input=str(input_path),
        out_dir=str(out_dir),
        pass1=None,
        entities=None,
        auto_scan=True,
    )


def _restore_args(input_path: Path, out_dir: Path, mapping_path: Path) -> argparse.Namespace:
    return argparse.Namespace(
        repo=None,
        input=str(input_path),
        out_dir=str(out_dir),
        mapping=str(mapping_path),
    )


# --------------------------------------------------------------------------- #
# Bug #15: command_anonymize
# --------------------------------------------------------------------------- #
def test_anonymize_writes_mapping_even_when_same_format_fails(
    tmp_path, stub_core, patch_helpers, monkeypatch
):
    """A same-format failure must NOT lose the restoration mapping (bug #15)."""
    out_dir = tmp_path / "out"
    in_file = tmp_path / "deal.doc"
    in_file.write_bytes(b"binary doc payload")

    def boom(*_args, **_kwargs):
        raise RuntimeError("textutil exploded")

    monkeypatch.setattr(lda, "same_format_anonymized", boom)

    lda.command_anonymize(_anon_args(in_file, out_dir))

    mapping_files = list(out_dir.glob("mapping_*.json"))
    assert mapping_files, "mapping JSON must be written even when same-format fails"
    saved = json.loads(mapping_files[0].read_text(encoding="utf-8"))
    assert saved["mappings"] == SAMPLE_MAPPING["mappings"]

    # Anonymized output degrades to .txt.
    txt_files = list(out_dir.glob("ANONYMIZED_*.txt"))
    assert txt_files, "anonymized output should fall back to .txt"
    assert txt_files[0].read_bytes() == b"ANON TEXT {PERSON_1}"

    # No .doc artifact should remain from the failed same-format attempt.
    assert not list(out_dir.glob("ANONYMIZED_*.doc"))

    # Manifest records the degradation.
    manifest_files = list(out_dir.glob("manifest_anonymize_*.json"))
    manifest = json.loads(manifest_files[0].read_text(encoding="utf-8"))
    assert "anonymized_format_degraded" in manifest
    assert manifest["mapping_path"] == str(mapping_files[0])


def test_anonymize_mapping_written_before_same_format(
    tmp_path, stub_core, patch_helpers, monkeypatch
):
    """The mapping JSON must exist on disk by the time same-format runs (bug #15)."""
    out_dir = tmp_path / "out"
    in_file = tmp_path / "deal.doc"
    in_file.write_bytes(b"binary doc payload")

    seen = {"mapping_present": None}

    def record_then_fail(*_args, **_kwargs):
        seen["mapping_present"] = bool(list(out_dir.glob("mapping_*.json")))
        raise RuntimeError("fail after mapping should already be saved")

    monkeypatch.setattr(lda, "same_format_anonymized", record_then_fail)

    lda.command_anonymize(_anon_args(in_file, out_dir))

    assert seen["mapping_present"] is True, "mapping must be saved before same-format generation"


def test_anonymize_happy_path_writes_same_format(
    tmp_path, stub_core, patch_helpers, monkeypatch
):
    """When same-format succeeds, both the formatted output and mapping exist."""
    out_dir = tmp_path / "out"
    in_file = tmp_path / "deal.docx"
    in_file.write_bytes(b"docx payload")

    monkeypatch.setattr(
        lda, "same_format_anonymized", lambda *_a, **_k: b"DOCX BYTES"
    )

    lda.command_anonymize(_anon_args(in_file, out_dir))

    assert list(out_dir.glob("mapping_*.json"))
    docx_out = list(out_dir.glob("ANONYMIZED_*.docx"))
    assert docx_out and docx_out[0].read_bytes() == b"DOCX BYTES"
    manifest = json.loads(list(out_dir.glob("manifest_anonymize_*.json"))[0].read_text())
    assert "anonymized_format_degraded" not in manifest


# --------------------------------------------------------------------------- #
# Bug #14: command_restore
# --------------------------------------------------------------------------- #
def test_restore_falls_back_to_txt_when_same_format_fails(
    tmp_path, stub_core, patch_helpers, monkeypatch
):
    """A same-format failure must keep the restored text in a .txt file (bug #14)."""
    out_dir = tmp_path / "out"
    in_file = tmp_path / "ai_output.doc"
    in_file.write_bytes(b"anonymized doc payload")
    mapping_path = tmp_path / "mapping.json"
    mapping_path.write_text(json.dumps(SAMPLE_MAPPING), encoding="utf-8")

    def boom(*_args, **_kwargs):
        raise RuntimeError("textutil exploded on restore")

    monkeypatch.setattr(lda, "same_format_restored", boom)

    lda.command_restore(_restore_args(in_file, out_dir, mapping_path))

    txt_files = list(out_dir.glob("RESTORED_DOCUMENT.txt"))
    assert txt_files, "restored text must fall back to .txt"
    assert txt_files[0].read_bytes() == b"RESTORED Jane Roe"

    # No .doc artifact from the failed attempt.
    assert not list(out_dir.glob("RESTORED_DOCUMENT.doc"))

    manifest = json.loads(list(out_dir.glob("manifest_restore_*.json"))[0].read_text())
    assert "restored_format_degraded" in manifest
    assert manifest["stats"]["remaining_placeholders"] == 0


def test_restore_happy_path_writes_same_format(
    tmp_path, stub_core, patch_helpers, monkeypatch
):
    """When same-format succeeds, the formatted restored file is written."""
    out_dir = tmp_path / "out"
    in_file = tmp_path / "ai_output.docx"
    in_file.write_bytes(b"anonymized docx payload")
    mapping_path = tmp_path / "mapping.json"
    mapping_path.write_text(json.dumps(SAMPLE_MAPPING), encoding="utf-8")

    monkeypatch.setattr(
        lda, "same_format_restored", lambda *_a, **_k: b"RESTORED DOCX BYTES"
    )

    lda.command_restore(_restore_args(in_file, out_dir, mapping_path))

    docx_out = list(out_dir.glob("RESTORED_DOCUMENT.docx"))
    assert docx_out and docx_out[0].read_bytes() == b"RESTORED DOCX BYTES"
    manifest = json.loads(list(out_dir.glob("manifest_restore_*.json"))[0].read_text())
    assert "restored_format_degraded" not in manifest
