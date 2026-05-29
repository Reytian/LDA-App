#!/usr/bin/env python3
"""Command-line bridge for the Legal Document Anonymizer skill."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_REPO = Path("/Users/haotianyi/Documents/Vibe Code/Legal Document Anonymizer")


class LocalUploadedFile:
    """Small adapter for LDA functions that expect a Streamlit UploadedFile."""

    def __init__(self, path: Path):
        self.path = path
        self.name = path.name
        self._data = path.read_bytes()
        self._pos = 0

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            chunk = self._data[self._pos :]
            self._pos = len(self._data)
            return chunk
        chunk = self._data[self._pos : self._pos + size]
        self._pos += len(chunk)
        return chunk

    def seek(self, pos: int) -> int:
        self._pos = pos
        return self._pos


def resolve_repo(raw_repo: str | None) -> Path:
    repo = Path(raw_repo or os.getenv("LDA_REPO") or DEFAULT_REPO).expanduser()
    if not repo.exists():
        raise SystemExit(f"LDA repo not found: {repo}")
    if not (repo / "core" / "anonymizer.py").exists():
        raise SystemExit(f"Not an LDA repo: {repo}")
    sys.path.insert(0, str(repo))
    return repo


def ensure_out_dir(raw_out_dir: str | None, input_path: Path | None = None) -> Path:
    if raw_out_dir:
        out_dir = Path(raw_out_dir).expanduser()
    elif input_path:
        out_dir = input_path.parent / "lda_output"
    else:
        out_dir = Path.cwd() / "lda_output"
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d_%H%M%S")


def safe_doc_type(value: str | None) -> str:
    if not value:
        return "DOCUMENT"
    slug = re.sub(r"[^A-Za-z0-9]+", "_", value.upper()).strip("_")
    return slug or "DOCUMENT"


def write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_file(input_path: Path):
    from core.file_handler import get_uploaded_bytes, read_uploaded_file

    uploaded = LocalUploadedFile(input_path)
    file_bytes = get_uploaded_bytes(uploaded)
    text = read_uploaded_file(uploaded)
    return text, file_bytes


def same_format_anonymized(
    ext: str,
    original_bytes: bytes,
    anonymized_text: str,
    mapping: dict,
) -> bytes:
    if ext == "docx":
        from core.file_handler import apply_replacements_to_docx, build_replacement_pairs

        return apply_replacements_to_docx(
            original_bytes,
            build_replacement_pairs(mapping, reverse=False),
        )
    if ext == "doc":
        from core.file_handler import apply_replacements_to_doc, build_replacement_pairs

        return apply_replacements_to_doc(
            original_bytes,
            build_replacement_pairs(mapping, reverse=False),
        )
    return anonymized_text.encode("utf-8")


def same_format_restored(
    ext: str,
    anonymized_bytes: bytes,
    restored_text: str,
    mapping: dict,
) -> bytes:
    if ext == "docx":
        from core.file_handler import apply_replacements_to_docx, build_replacement_pairs

        return apply_replacements_to_docx(
            anonymized_bytes,
            build_replacement_pairs(mapping, reverse=True),
        )
    if ext == "doc":
        from core.file_handler import apply_replacements_to_doc, build_replacement_pairs

        return apply_replacements_to_doc(
            anonymized_bytes,
            build_replacement_pairs(mapping, reverse=True),
        )
    return restored_text.encode("utf-8")


def command_preflight(args: argparse.Namespace) -> None:
    repo = resolve_repo(args.repo)
    from core import llm_client

    api_base = llm_client.LLM_API_BASE
    local_markers = ("localhost", "127.0.0.1", "0.0.0.0", "::1")
    is_local = any(marker in api_base for marker in local_markers)
    result = {
        "repo": str(repo),
        "llm_api_base": api_base or None,
        "llm_model": llm_client.LLM_MODEL or None,
        "has_api_key": bool(llm_client.LLM_API_KEY),
        "scan_appears_local": is_local,
        "warning": None
        if is_local
        else "Scanning may send raw document text to a non-local LLM endpoint.",
    }
    write_json(Path(args.json_out), result) if args.json_out else print(
        json.dumps(result, ensure_ascii=False, indent=2)
    )


def run_scan(input_path: Path, out_dir: Path, source_filename: str) -> dict:
    from core.anonymizer import run_first_pass, run_second_pass

    text, _ = load_file(input_path)
    pass1 = run_first_pass(text)
    entities = run_second_pass(text, pass1)

    ts = timestamp()
    pass1_path = out_dir / f"pass1_{ts}.json"
    entities_path = out_dir / f"entities_{ts}.json"
    manifest_path = out_dir / f"manifest_scan_{ts}.json"

    write_json(pass1_path, pass1)
    write_json(entities_path, entities)

    manifest = {
        "operation": "scan",
        "source_file": source_filename,
        "document_type": pass1.get("document_type", "Document"),
        "alias_count": len(pass1.get("aliases", [])),
        "entity_count": len(entities),
        "pass1_path": str(pass1_path),
        "entities_path": str(entities_path),
    }
    write_json(manifest_path, manifest)
    manifest["manifest_path"] = str(manifest_path)
    return {"pass1": pass1, "entities": entities, "manifest": manifest}


def command_scan(args: argparse.Namespace) -> None:
    resolve_repo(args.repo)
    input_path = Path(args.input).expanduser()
    out_dir = ensure_out_dir(args.out_dir, input_path)
    result = run_scan(input_path, out_dir, input_path.name)
    print(json.dumps(result["manifest"], ensure_ascii=False, indent=2))


def command_anonymize(args: argparse.Namespace) -> None:
    resolve_repo(args.repo)
    input_path = Path(args.input).expanduser()
    out_dir = ensure_out_dir(args.out_dir, input_path)
    text, original_bytes = load_file(input_path)

    if args.auto_scan:
        scan = run_scan(input_path, out_dir, input_path.name)
        pass1 = scan["pass1"]
        entities = scan["entities"]
    else:
        if not args.pass1 or not args.entities:
            raise SystemExit("Provide --pass1 and --entities, or use --auto-scan.")
        pass1 = read_json(Path(args.pass1).expanduser())
        entities = read_json(Path(args.entities).expanduser())

    from core.anonymizer import execute_replacement

    anonymized_text, mapping = execute_replacement(
        text,
        entities,
        pass1,
        source_filename=input_path.name,
    )

    ts = timestamp()
    ext = input_path.suffix.lower().lstrip(".") or "txt"
    doc_type = safe_doc_type(pass1.get("document_type", "Document"))
    mapping_path = out_dir / f"mapping_{ts}.json"
    manifest_path = out_dir / f"manifest_anonymize_{ts}.json"

    # Persist the restoration key FIRST. The mapping is the only artifact that
    # can reverse the anonymization, and it is expensive to recompute (full LLM
    # cost). Writing it before generating the same-format output guarantees the
    # key survives even if same-format generation (e.g. textutil for .doc) fails.
    write_json(mapping_path, mapping)

    # Generate the same-format output. On failure (for example a textutil error
    # converting a .doc), fall back to a plain .txt file so the operation still
    # yields a usable anonymized artifact alongside the saved mapping.
    anon_path = out_dir / f"ANONYMIZED_{doc_type}.{ext}"
    anon_degraded = None
    try:
        anon_bytes = same_format_anonymized(ext, original_bytes, anonymized_text, mapping)
    except Exception as exc:  # noqa: BLE001 (degrade gracefully, never lose the mapping)
        anon_degraded = f"Could not generate .{ext} output ({exc}). Fell back to .txt."
        anon_path = out_dir / f"ANONYMIZED_{doc_type}.txt"
        anon_bytes = anonymized_text.encode("utf-8")
    anon_path.write_bytes(anon_bytes)

    manifest = {
        "operation": "anonymize",
        "source_file": input_path.name,
        "document_type": pass1.get("document_type", "Document"),
        "entity_count": mapping.get("metadata", {}).get("entity_count", 0),
        "replacement_count": len(mapping.get("replacement_log", [])),
        "anonymized_path": str(anon_path),
        "mapping_path": str(mapping_path),
        "mapping_custody": "Keep local. Do not send to third parties.",
    }
    if anon_degraded:
        manifest["anonymized_format_degraded"] = anon_degraded
    write_json(manifest_path, manifest)
    manifest["manifest_path"] = str(manifest_path)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


def command_restore(args: argparse.Namespace) -> None:
    resolve_repo(args.repo)
    input_path = Path(args.input).expanduser()
    out_dir = ensure_out_dir(args.out_dir, input_path)
    mapping = read_json(Path(args.mapping).expanduser())
    text, anonymized_bytes = load_file(input_path)

    from core.deanonymizer import run_deanonymize

    restored_text, stats = run_deanonymize(text, mapping)

    ts = timestamp()
    ext = input_path.suffix.lower().lstrip(".") or "txt"
    manifest_path = out_dir / f"manifest_restore_{ts}.json"

    # Generate the same-format output. On failure (for example a textutil error
    # converting a .doc), fall back to a plain .txt file so the already-computed
    # restored text is never discarded. This mirrors the .txt fallback in the
    # app's ui/deanonymize_page.py.
    restored_path = out_dir / f"RESTORED_DOCUMENT.{ext}"
    restored_degraded = None
    try:
        restored_bytes = same_format_restored(ext, anonymized_bytes, restored_text, mapping)
    except Exception as exc:  # noqa: BLE001 (degrade gracefully, never lose restored text)
        restored_degraded = f"Could not generate .{ext} output ({exc}). Fell back to .txt."
        restored_path = out_dir / "RESTORED_DOCUMENT.txt"
        restored_bytes = restored_text.encode("utf-8")
    restored_path.write_bytes(restored_bytes)

    manifest = {
        "operation": "restore",
        "input_file": input_path.name,
        "restored_path": str(restored_path),
        "stats": stats,
    }
    if restored_degraded:
        manifest["restored_format_degraded"] = restored_degraded
    write_json(manifest_path, manifest)
    manifest["manifest_path"] = str(manifest_path)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Legal Document Anonymizer skill helper")
    parser.add_argument("--repo", help="Path to the LDA project repo")

    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight", help="Show LDA config and locality warning")
    preflight.add_argument("--json-out", help="Optional path for JSON output")
    preflight.set_defaults(func=command_preflight)

    scan = subparsers.add_parser("scan", help="Run Pass 1 and Pass 2 entity scans")
    scan.add_argument("input", help="Document path")
    scan.add_argument("--out-dir", help="Local output directory")
    scan.set_defaults(func=command_scan)

    anonymize = subparsers.add_parser("anonymize", help="Create anonymized file and mapping")
    anonymize.add_argument("input", help="Document path")
    anonymize.add_argument("--out-dir", help="Local output directory")
    anonymize.add_argument("--pass1", help="Reviewed Pass 1 JSON")
    anonymize.add_argument("--entities", help="Reviewed entities JSON")
    anonymize.add_argument("--auto-scan", action="store_true", help="Scan and anonymize without pausing for review")
    anonymize.set_defaults(func=command_anonymize)

    restore = subparsers.add_parser("restore", help="Restore AI output using local mapping")
    restore.add_argument("input", help="AI output document path")
    restore.add_argument("--mapping", required=True, help="Local mapping JSON path")
    restore.add_argument("--out-dir", help="Local output directory")
    restore.set_defaults(func=command_restore)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
