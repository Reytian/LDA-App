"""
De-anonymize page — Streamlit UI

Workflow:
1. Upload the AI-modified anonymized file (.txt / .doc / .docx)
2. Upload the mapping table (.json)
3. Execute 3-step restoration
4. Display stats + download restored file in the same format
"""

import streamlit as st
from core.deanonymizer import run_deanonymize
from core.file_handler import (
    read_uploaded_file,
    get_uploaded_bytes,
    load_mapping,
    apply_replacements_to_docx,
    apply_replacements_to_doc,
    build_replacement_pairs,
)


def render():
    """Render the de-anonymize page."""

    st.header("De-anonymize / Restore")

    st.info(
        "Upload the AI-modified anonymized file and its mapping table. "
        "The system will automatically restore sensitive information."
    )

    # File upload
    col1, col2 = st.columns(2)

    with col1:
        anonymized_file = st.file_uploader(
            "Upload anonymized file (.txt / .doc / .docx)",
            type=["txt", "doc", "docx"],
            key="deanon_file_uploader",
        )

    with col2:
        mapping_file = st.file_uploader(
            "Upload mapping table (.json)",
            type=["json"],
            key="deanon_json_uploader",
        )

    if anonymized_file is None or mapping_file is None:
        if anonymized_file is None and mapping_file is None:
            st.caption("Please upload both the anonymized file and mapping table")
        elif anonymized_file is None:
            st.caption("Please upload the anonymized file")
        else:
            st.caption("Please upload the mapping table")
        return

    # Read files
    try:
        file_ext = anonymized_file.name.rsplit(".", 1)[-1].lower()
        file_bytes = get_uploaded_bytes(anonymized_file)
        anonymized_text = read_uploaded_file(anonymized_file)
    except Exception as e:
        st.error(f"Failed to read anonymized file: {e}")
        return

    try:
        mapping_data = load_mapping(mapping_file)
    except Exception as e:
        st.error(f"Failed to read mapping table: {e}")
        return

    # Previews
    with st.expander("Anonymized file preview", expanded=False):
        preview = anonymized_text[:2000]
        if len(anonymized_text) > 2000:
            preview += "\n\n... (showing first 2000 characters)"
        st.text(preview)

    with st.expander("Mapping table summary", expanded=False):
        metadata = mapping_data.get("metadata", {})
        mappings = mapping_data.get("mappings", {})
        replacement_log = mapping_data.get("replacement_log", [])

        st.write(f"- Source file: {metadata.get('source_file', 'Unknown')}")
        st.write(f"- Created: {metadata.get('created_at', 'Unknown')}")
        st.write(f"- Entity count: {metadata.get('entity_count', 0)}")
        st.write(f"- Replacement records: {len(replacement_log)}")

        for placeholder, info in mappings.items():
            st.write(
                f"  `{placeholder}` -> {info.get('value', '')} "
                f"({info.get('type', '')})"
            )

    st.divider()

    # Execute restoration
    if st.button("Execute Restoration", type="primary"):
        with st.spinner("Running 3-step restoration..."):
            try:
                restored_text, stats = run_deanonymize(anonymized_text, mapping_data)
            except Exception as e:
                st.error(f"Restoration failed: {e}")
                return

        # Generate same-format output for doc/docx
        restored_file_bytes = None
        if file_ext in ("docx", "doc"):
            try:
                pairs = build_replacement_pairs(mapping_data, reverse=True)
                if file_ext == "docx":
                    restored_file_bytes = apply_replacements_to_docx(file_bytes, pairs)
                else:
                    restored_file_bytes = apply_replacements_to_doc(file_bytes, pairs)
            except Exception as e:
                st.warning(f"Could not generate .{file_ext} output: {e}. Falling back to .txt.")

        # Results
        st.subheader("Restoration Results")

        col1, col2, col3 = st.columns(3)
        with col1:
            st.metric("Position-matched", stats["position_matched"])
        with col2:
            st.metric("Context-matched", stats["context_matched"])
        with col3:
            st.metric("Fallback", stats["fallback_count"])

        if stats["fallback_count"] > 0:
            st.warning(
                f"{stats['fallback_count']} items used fallback restoration (canonical name). "
                "These may be AI-added content — please review carefully."
            )

        if stats["remaining_placeholders"] > 0:
            st.error(
                f"{stats['remaining_placeholders']} placeholders could not be restored. "
                "Please check the file manually."
            )

        with st.expander("Restored text preview", expanded=True):
            preview = restored_text[:3000]
            if len(restored_text) > 3000:
                preview += "\n\n... (showing first 3000 characters)"
            st.text(preview)

        # Download
        source_file = mapping_data.get("metadata", {}).get("source_file", "document")
        base_name = source_file.rsplit(".", 1)[0] if "." in source_file else source_file

        if restored_file_bytes and file_ext in ("docx", "doc"):
            mime = (
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                if file_ext == "docx"
                else "application/msword"
            )
            st.download_button(
                label=f"Download restored file (.{file_ext})",
                data=restored_file_bytes,
                file_name=f"{base_name}_restored.{file_ext}",
                mime=mime,
            )
        else:
            st.download_button(
                label="Download restored file (.txt)",
                data=restored_text.encode("utf-8"),
                file_name=f"{base_name}_restored.txt",
                mime="text/plain",
            )
