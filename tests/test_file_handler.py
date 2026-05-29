"""
Tests for core.file_handler same-format DOCX replacement logic.

Covers the bugs fixed in file_handler.py:
  #1  PII inside hyperlink runs must be anonymized.
  #8  Single-pass replacement must not corrupt placeholders.
  #9  Nested tables (table inside a cell) must be processed.
  #10 Per-run formatting of untouched runs must be preserved.
  #16 _read_doc temp path derivation (suffix-only).

All tests build DOCX bytes in memory with python-docx and run fully offline.
The textutil-dependent .doc paths (apply_replacements_to_doc, _read_doc) are
environment-sensitive (require /usr/bin/textutil and macOS) and are left
untested here, except for the pure-Python path-derivation logic of bug #16.
"""

import io

import pytest
from docx import Document
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

from core.file_handler import apply_replacements_to_docx


def _docx_bytes(doc) -> bytes:
    buf = io.BytesIO()
    doc.save(buf)
    return buf.getvalue()


def _all_text(doc) -> str:
    """Join body paragraph text plus all table cell text (recursively)."""
    parts = [p.text for p in doc.paragraphs]

    def _walk_tables(container):
        for table in getattr(container, "tables", []):
            for row in table.rows:
                for cell in row.cells:
                    for p in cell.paragraphs:
                        parts.append(p.text)
                    _walk_tables(cell)

    _walk_tables(doc)
    return "\n".join(parts)


def _add_hyperlink_run(paragraph, text: str) -> None:
    """
    Craft a <w:hyperlink> element containing a single <w:r><w:t> run and append
    it to the paragraph. python-docx's Paragraph.runs does NOT include this run.
    """
    hyperlink = OxmlElement("w:hyperlink")
    run = OxmlElement("w:r")
    t = OxmlElement("w:t")
    t.text = text
    t.set(qn("xml:space"), "preserve")
    run.append(t)
    hyperlink.append(run)
    paragraph._p.append(hyperlink)


# ---------------------------------------------------------------------------
# Bug #1: PII inside hyperlink runs must be anonymized.
# ---------------------------------------------------------------------------

def test_hyperlink_run_pii_is_replaced():
    # Arrange: a paragraph with a normal run plus a hyperlink run carrying PII.
    doc = Document()
    para = doc.add_paragraph()
    para.add_run("Contact ")
    _add_hyperlink_run(para, "John Smith")

    # Sanity check: the hyperlink run is invisible to Paragraph.runs.
    assert [r.text for r in para.runs] == ["Contact "]
    assert "John Smith" in para.text

    # Act
    out = apply_replacements_to_docx(
        _docx_bytes(doc), [("John Smith", "[PERSON_1]")]
    )

    # Assert: the delivered document no longer leaks the hyperlink PII.
    result = Document(io.BytesIO(out))
    assert "John Smith" not in _all_text(result)
    assert "[PERSON_1]" in _all_text(result)


# ---------------------------------------------------------------------------
# Bug #8: single-pass replacement must not corrupt an inserted placeholder.
# ---------------------------------------------------------------------------

def test_single_pass_does_not_corrupt_placeholder():
    # Arrange: "John" -> "{PERSON_1}" and the short value "1" -> "{AMOUNT_1}".
    # A chained str.replace would rewrite the "1" inside "{PERSON_1}".
    doc = Document()
    doc.add_paragraph("John owes 1 unit.")

    replacements = [("John", "{PERSON_1}"), ("1", "{AMOUNT_1}")]

    # Act
    out = apply_replacements_to_docx(_docx_bytes(doc), replacements)

    # Assert: the PERSON placeholder is intact (its trailing "1" untouched).
    text = _all_text(Document(io.BytesIO(out)))
    assert "{PERSON_1}" in text
    assert "{PERSON_{AMOUNT_1}}" not in text
    assert text.strip() == "{PERSON_1} owes {AMOUNT_1} unit."


# ---------------------------------------------------------------------------
# Bug #9: nested tables (table inside a cell) must be processed.
# ---------------------------------------------------------------------------

def test_nested_table_cell_is_redacted():
    # Arrange: an outer 1x1 table whose cell contains direct PII plus a nested
    # table that also contains PII.
    doc = Document()
    outer = doc.add_table(rows=1, cols=1)
    cell = outer.cell(0, 0)
    cell.paragraphs[0].add_run("John Smith")
    nested = cell.add_table(rows=1, cols=1)
    nested.cell(0, 0).paragraphs[0].add_run("Jane Doe")

    replacements = [("John Smith", "[PERSON_1]"), ("Jane Doe", "[PERSON_2]")]

    # Act
    out = apply_replacements_to_docx(_docx_bytes(doc), replacements)

    # Assert: both the direct cell and the nested table cell are redacted.
    text = _all_text(Document(io.BytesIO(out)))
    assert "John Smith" not in text
    assert "Jane Doe" not in text
    assert "[PERSON_1]" in text
    assert "[PERSON_2]" in text


# ---------------------------------------------------------------------------
# Bug #10: per-run formatting of untouched runs must be preserved.
# ---------------------------------------------------------------------------

def test_unaffected_bold_run_keeps_formatting():
    # Arrange: a paragraph with a plain run holding PII, then a separate bold run.
    doc = Document()
    para = doc.add_paragraph()
    para.add_run("Name John Smith. ")
    bold_run = para.add_run("CONFIDENTIAL")
    bold_run.bold = True

    # Act
    out = apply_replacements_to_docx(
        _docx_bytes(doc), [("John Smith", "[PERSON_1]")]
    )

    # Assert: replacement applied and the bold run still bold and unchanged.
    result = Document(io.BytesIO(out))
    p = result.paragraphs[0]
    assert "John Smith" not in p.text
    assert "[PERSON_1]" in p.text

    bold_runs = [r for r in p.runs if r.text == "CONFIDENTIAL"]
    assert len(bold_runs) == 1
    assert bold_runs[0].bold is True


# ---------------------------------------------------------------------------
# Bug #16: _read_doc must derive the txt temp path by suffix only.
# ---------------------------------------------------------------------------

def test_read_doc_txt_path_suffix_only(monkeypatch, tmp_path):
    """
    Verify the temp .txt path is derived by stripping only the trailing ".doc",
    even when the directory component itself contains the substring ".doc".
    We stub out tempfile and subprocess so no real textutil/macOS call happens.
    """
    import os
    from core import file_handler

    # A temp directory whose name contains ".doc".
    spooky_dir = tmp_path / "my.docs"
    spooky_dir.mkdir()
    fake_doc_path = str(spooky_dir / "tmpXXXX.doc")

    class _FakeTmp:
        def __init__(self):
            self.name = fake_doc_path

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def write(self, _data):
            return None

    def _fake_named_tmp(*_args, **_kwargs):
        return _FakeTmp()

    captured = {}

    def _fake_run(cmd, **_kwargs):
        # The output path is the argument after "-output".
        out_path = cmd[cmd.index("-output") + 1]
        captured["out_path"] = out_path
        # Materialize the file textutil would have written.
        with open(out_path, "w", encoding="utf-8") as f:
            f.write("converted text")

        class _Result:
            returncode = 0
            stderr = ""

        return _Result()

    monkeypatch.setattr(file_handler.tempfile, "NamedTemporaryFile", _fake_named_tmp)
    monkeypatch.setattr(file_handler.subprocess, "run", _fake_run)

    class _Upload:
        def read(self):
            return b"binary-doc-bytes"

    # Act
    text = file_handler._read_doc(_Upload())

    # Assert: only the trailing suffix changed; the directory name is intact.
    assert captured["out_path"] == str(spooky_dir / "tmpXXXX.txt")
    assert text == "converted text"
    # Cleanup created the file; ensure no leftover.
    assert not os.path.exists(captured["out_path"])
