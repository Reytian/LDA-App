"""
File handler — reads/writes txt/doc/docx files and mapping JSON files.
Supports same-format output: input DOCX -> output DOCX, etc.
Processes headers, footers, tables, and document properties.
"""

import os
import io
import re
import json
import subprocess
import tempfile
from datetime import datetime
from docx import Document
from docx.oxml.ns import qn

MAPPINGS_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "mappings")


def read_uploaded_file(uploaded_file) -> str:
    """
    Read uploaded file content. Supports .txt / .doc / .docx.

    Args:
        uploaded_file: Streamlit UploadedFile object

    Returns:
        File content as string
    """
    filename = uploaded_file.name.lower()

    if filename.endswith(".docx"):
        return _read_docx(uploaded_file)
    elif filename.endswith(".doc"):
        return _read_doc(uploaded_file)
    else:
        return _read_txt(uploaded_file)


def get_uploaded_bytes(uploaded_file) -> bytes:
    """
    Get raw bytes from an uploaded file (resets read position afterward).

    Args:
        uploaded_file: Streamlit UploadedFile object

    Returns:
        Raw file bytes
    """
    uploaded_file.seek(0)
    data = uploaded_file.read()
    uploaded_file.seek(0)
    return data


def _read_txt(uploaded_file) -> str:
    """Read a .txt file with UTF-8/GBK fallback."""
    content = uploaded_file.read()
    try:
        return content.decode("utf-8")
    except UnicodeDecodeError:
        return content.decode("gbk")


def _read_docx(uploaded_file) -> str:
    """Read a .docx file, extracting all paragraph text."""
    content = uploaded_file.read()
    doc = Document(io.BytesIO(content))
    paragraphs = [para.text for para in doc.paragraphs]
    return "\n".join(paragraphs)


def _read_doc(uploaded_file) -> str:
    """Read a .doc file via macOS textutil conversion."""
    content = uploaded_file.read()

    with tempfile.NamedTemporaryFile(suffix=".doc", delete=False) as tmp_doc:
        tmp_doc.write(content)
        tmp_doc_path = tmp_doc.name

    # Derive the txt path by stripping only the trailing ".doc" suffix.
    # Using str.replace would corrupt the path if the temp directory itself
    # contains the substring ".doc" (e.g. a custom TMPDIR like /tmp/my.docs/).
    tmp_txt_path = tmp_doc_path[:-4] + ".txt"

    try:
        result = subprocess.run(
            ["textutil", "-convert", "txt", "-output", tmp_txt_path, tmp_doc_path],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(f"textutil conversion failed: {result.stderr}")

        with open(tmp_txt_path, "r", encoding="utf-8") as f:
            return f.read()
    finally:
        for path in [tmp_doc_path, tmp_txt_path]:
            if os.path.exists(path):
                os.unlink(path)


# ============================================================
# Same-format output: apply replacements to DOCX/DOC files
# ============================================================

def _build_replacement_regex(replacements: list[tuple[str, str]]):
    """
    Build a single combined regex and lookup table from replacement pairs.

    Keys are ordered longest-first so that, within a single non-overlapping
    left-to-right scan, the longest possible key wins at any position. Because
    a single re.sub pass never re-scans text it has already emitted, an inserted
    placeholder (e.g. "{PERSON_1}") can never be corrupted by a later, shorter
    key such as the bare digit "1".

    Args:
        replacements: List of (old_text, new_text) tuples.

    Returns:
        Tuple of (compiled_pattern, lookup_dict). The pattern is None when there
        are no non-empty keys to match.
    """
    lookup: dict[str, str] = {}
    for old, new in replacements:
        if old and old not in lookup:
            lookup[old] = new
    if not lookup:
        return None, lookup

    ordered_keys = sorted(lookup.keys(), key=len, reverse=True)
    pattern = re.compile("|".join(re.escape(key) for key in ordered_keys))
    return pattern, lookup


def _apply_single_pass(text: str, pattern, lookup: dict[str, str]) -> str:
    """
    Apply all replacements in one non-overlapping left-to-right pass.

    Args:
        text: Source text.
        pattern: Compiled regex from _build_replacement_regex (may be None).
        lookup: Mapping of matched key to its replacement.

    Returns:
        Text with all keys replaced exactly once per occurrence, with no
        re-scanning of already-substituted output.
    """
    if pattern is None or not text:
        return text
    return pattern.sub(lambda m: lookup[m.group(0)], text)


def apply_replacements_to_docx(docx_bytes: bytes, replacements: list[tuple[str, str]]) -> bytes:
    """
    Apply text replacements to a DOCX file while preserving formatting.
    Processes body paragraphs, tables, headers, footers, and core properties.

    Args:
        docx_bytes: Original DOCX file bytes
        replacements: List of (old_text, new_text) tuples, sorted by old_text length descending

    Returns:
        Modified DOCX as bytes
    """
    doc = Document(io.BytesIO(docx_bytes))
    pattern, lookup = _build_replacement_regex(replacements)

    def _xml_runs(para):
        """
        Return all <w:r> run elements under a paragraph, including runs nested
        inside <w:hyperlink>. python-docx's Paragraph.runs excludes hyperlink
        runs, so PII in hyperlink display text would otherwise never be rewritten.
        """
        return para._p.findall('.//' + qn('w:r'))

    def _run_text_elements(run_el):
        """Return the <w:t> text elements of a single run element (in order)."""
        return run_el.findall(qn('w:t'))

    def _replace_in_paragraph(para):
        # Operate over ALL runs (including hyperlink runs) via the XML layer.
        run_els = _xml_runs(para)
        if not run_els:
            return

        # Collect every <w:t> element across all runs together with the offset
        # of its text within the joined paragraph string. This lets us rewrite
        # only the text elements overlapping a replaced span and preserve the
        # per-run (bold/italic/font) formatting of untouched runs.
        segments = []  # list of (text_element, start_offset, original_text)
        offset = 0
        for run_el in run_els:
            for t_el in _run_text_elements(run_el):
                original = t_el.text or ""
                segments.append((t_el, offset, original))
                offset += len(original)

        full_text = "".join(seg[2] for seg in segments)
        if not full_text:
            return

        new_text = _apply_single_pass(full_text, pattern, lookup)
        if new_text == full_text:
            return

        # Map the rewritten string back onto the original text-element boundaries.
        # Each text element keeps its slice of the new string where its slice is
        # unchanged; the first element overlapping a changed region absorbs the
        # net difference so no characters are lost. Untouched elements (and thus
        # their parent runs' formatting) are left exactly as they were.
        _remap_text(segments, full_text, new_text)

    def _remap_text(segments, full_text, new_text):
        """
        Distribute new_text back across the original <w:t> elements, preserving
        the formatting of runs whose text did not change.
        """
        # Identify the contiguous changed region [lo, hi) in the old string by
        # trimming the common prefix and suffix shared with the new string.
        old_len = len(full_text)
        new_len = len(new_text)
        prefix = 0
        max_prefix = min(old_len, new_len)
        while prefix < max_prefix and full_text[prefix] == new_text[prefix]:
            prefix += 1
        suffix = 0
        max_suffix = min(old_len, new_len) - prefix
        while suffix < max_suffix and full_text[old_len - 1 - suffix] == new_text[new_len - 1 - suffix]:
            suffix += 1

        change_lo = prefix
        change_hi = old_len - suffix  # exclusive, in old-string coordinates
        delta = new_len - old_len

        for t_el, start, original in segments:
            end = start + len(original)
            if end <= change_lo or start >= change_hi:
                # Element lies entirely in an unchanged region: leave it intact.
                continue
            # This element overlaps the changed region. Rebuild its text from the
            # new string: keep the unchanged head (before change_lo) and tail
            # (after change_hi, shifted by delta), and let the first overlapping
            # element carry the replaced middle so total content is preserved.
            # Unchanged head: this element's chars before the changed region.
            head = original[: max(0, change_lo - start)]
            # Unchanged tail: this element's chars after the changed region
            # (in old-string coordinates the tail begins at change_hi).
            tail = original[max(0, change_hi - start):] if end > change_hi else ""

            middle = ""
            if start <= change_lo:
                # First element overlapping the change owns the replaced middle.
                middle = new_text[change_lo: change_hi + delta]

            t_el.text = head + middle + tail
            # Ensure whitespace is preserved for elements we touched.
            if t_el.text != t_el.text.strip():
                t_el.set(qn('xml:space'), 'preserve')

    def _replace_in_container(container):
        """
        Recursively process all paragraphs and tables in a container
        (body, header, footer, cell). Recurses into nested tables so PII inside
        a table nested within a cell is not left unredacted.
        """
        for para in container.paragraphs:
            _replace_in_paragraph(para)
        if hasattr(container, 'tables'):
            for table in container.tables:
                for row in table.rows:
                    for cell in row.cells:
                        _replace_in_container(cell)

    # Body paragraphs and tables
    _replace_in_container(doc)

    # Headers and footers (all sections)
    for section in doc.sections:
        for hf_attr in ['header', 'footer', 'first_page_header', 'first_page_footer',
                        'even_page_header', 'even_page_footer']:
            try:
                hf = getattr(section, hf_attr)
                _replace_in_container(hf)
            except Exception:
                continue

    # Core properties (title, author, subject, etc.)
    try:
        props = doc.core_properties
        for attr in ['title', 'subject', 'author', 'comments', 'description',
                     'last_modified_by', 'keywords', 'category']:
            try:
                val = getattr(props, attr, None)
                if val and isinstance(val, str):
                    new_val = _apply_single_pass(val, pattern, lookup)
                    if new_val != val:
                        setattr(props, attr, new_val)
            except Exception:
                continue
    except Exception:
        pass

    # Extended properties (company, manager) — modify raw XML
    try:
        for rel in doc.part.rels.values():
            if 'extended-properties' in str(getattr(rel, 'reltype', '')):
                app_part = rel.target_part
                xml_str = app_part.blob.decode('utf-8')
                new_xml = _apply_single_pass(xml_str, pattern, lookup)
                if new_xml != xml_str:
                    app_part._blob = new_xml.encode('utf-8')
                break
    except Exception:
        pass

    buf = io.BytesIO()
    doc.save(buf)
    return buf.getvalue()


def apply_replacements_to_doc(doc_bytes: bytes, replacements: list[tuple[str, str]]) -> bytes:
    """
    Apply text replacements to a .doc file.
    Converts .doc -> .docx, applies replacements, converts back to .doc.

    Args:
        doc_bytes: Original .doc file bytes
        replacements: List of (old_text, new_text) tuples

    Returns:
        Modified .doc as bytes
    """
    with tempfile.NamedTemporaryFile(suffix=".doc", delete=False) as tmp:
        tmp.write(doc_bytes)
        tmp_doc_path = tmp.name

    tmp_docx_path = tmp_doc_path + ".docx"
    modified_docx_path = tmp_doc_path + ".modified.docx"
    output_doc_path = tmp_doc_path + ".output.doc"

    try:
        result = subprocess.run(
            ["textutil", "-convert", "docx", "-output", tmp_docx_path, tmp_doc_path],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(f"textutil doc->docx failed: {result.stderr}")

        with open(tmp_docx_path, "rb") as f:
            docx_bytes = f.read()

        modified_docx = apply_replacements_to_docx(docx_bytes, replacements)

        with open(modified_docx_path, "wb") as f:
            f.write(modified_docx)

        result = subprocess.run(
            ["textutil", "-convert", "doc", "-output", output_doc_path, modified_docx_path],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(f"textutil docx->doc failed: {result.stderr}")

        with open(output_doc_path, "rb") as f:
            return f.read()
    finally:
        for path in [tmp_doc_path, tmp_docx_path, modified_docx_path, output_doc_path]:
            if os.path.exists(path):
                os.unlink(path)


def build_replacement_pairs(mapping_data: dict, reverse: bool = False) -> list[tuple[str, str]]:
    """
    Build a sorted list of (old_text, new_text) pairs from mapping data.

    Args:
        mapping_data: Full mapping dictionary with "mappings" key
        reverse: If False, entity->placeholder (anonymize).
                 If True, placeholder->entity (de-anonymize).

    Returns:
        List of (old, new) tuples sorted by old_text length descending
    """
    pairs = {}
    for placeholder, info in mapping_data.get("mappings", {}).items():
        value = info.get("value", "")
        if reverse:
            pairs[placeholder] = value
        else:
            if value:
                pairs[value] = placeholder
            for alias in info.get("aliases", []):
                if alias:
                    pairs[alias] = placeholder

    return sorted(pairs.items(), key=lambda x: len(x[0]), reverse=True)


def save_mapping(mapping_dict: dict, filename: str) -> str:
    """
    Save mapping table as a JSON file.

    Args:
        mapping_dict: Mapping dictionary
        filename: Base filename (without extension)

    Returns:
        Path to the saved file
    """
    os.makedirs(MAPPINGS_DIR, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    save_filename = f"{filename}_mapping_{timestamp}.json"
    filepath = os.path.join(MAPPINGS_DIR, save_filename)

    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(mapping_dict, f, ensure_ascii=False, indent=2)

    return filepath


def load_mapping(uploaded_file) -> dict:
    """
    Load mapping table from an uploaded JSON file.

    Args:
        uploaded_file: Streamlit UploadedFile object

    Returns:
        Mapping dictionary
    """
    content = uploaded_file.read()
    text = content.decode("utf-8")
    return json.loads(text)
