"""
Anonymize page — Streamlit UI

Workflow:
1. Upload a document (.txt / .doc / .docx)
2. Pass 1 scan -> display entity definitions (editable)
3. User confirms -> Pass 2 scan -> display full entity list (editable)
4. User confirms -> execute anonymization -> download anonymized file + mapping

Output filenames are generic (no original identifying info).
"""

import json
from datetime import datetime
import streamlit as st
import pandas as pd
from core.anonymizer import run_first_pass, run_second_pass, execute_replacement
from core.file_handler import (
    read_uploaded_file,
    get_uploaded_bytes,
    save_mapping,
    apply_replacements_to_docx,
    apply_replacements_to_doc,
    build_replacement_pairs,
)


def render():
    """Render the anonymize page."""

    st.header("Document Anonymization")

    # Initialize session_state
    for key, default in [
        ("uploaded_text", None),
        ("uploaded_filename", None),
        ("uploaded_bytes", None),
        ("uploaded_ext", None),
        ("pass1_result", None),
        ("pass1_confirmed", False),
        ("pass2_result", None),
        ("pass2_confirmed", False),
        ("anonymized_text", None),
        ("anonymized_file_bytes", None),
        ("mapping_data", None),
    ]:
        if key not in st.session_state:
            st.session_state[key] = default

    # ---- Step 1: Upload file ----
    st.subheader("Step 1: Upload Document")

    uploaded_file = st.file_uploader(
        "Drag and drop a file here (.txt / .doc / .docx)",
        type=["txt", "doc", "docx"],
        key="anon_file_uploader",
    )

    if uploaded_file is not None:
        if st.session_state.uploaded_filename != uploaded_file.name:
            # New file — store bytes first, then extract text
            st.session_state.uploaded_bytes = get_uploaded_bytes(uploaded_file)
            st.session_state.uploaded_ext = uploaded_file.name.rsplit(".", 1)[-1].lower()
            st.session_state.uploaded_text = read_uploaded_file(uploaded_file)
            st.session_state.uploaded_filename = uploaded_file.name
            st.session_state.pass1_result = None
            st.session_state.pass1_confirmed = False
            st.session_state.pass2_result = None
            st.session_state.pass2_confirmed = False
            st.session_state.anonymized_text = None
            st.session_state.anonymized_file_bytes = None
            st.session_state.mapping_data = None

        with st.expander("File preview", expanded=False):
            text = st.session_state.uploaded_text
            st.text(text[:2000] + "..." if len(text) > 2000 else text)

    if st.session_state.uploaded_text is None:
        return

    st.divider()

    # ---- Step 2: Pass 1 scan ----
    st.subheader("Step 2: Pass 1 Scan (Extract Entity Definitions)")

    if st.session_state.pass1_result is None:
        if st.button("Start Pass 1 Scan", type="primary"):
            with st.spinner("Scanning key sections for entity definitions..."):
                try:
                    result = run_first_pass(st.session_state.uploaded_text)
                    st.session_state.pass1_result = result
                    st.rerun()
                except Exception as e:
                    st.error(f"Pass 1 scan failed: {e}")
        return

    # Editable entity definition table
    st.write("**Entity definitions:**")

    alias_data = []
    for alias_group in st.session_state.pass1_result.get("aliases", []):
        alias_data.append({
            "Canonical Name": alias_group.get("canonical", ""),
            "Type": alias_group.get("type", ""),
            "Aliases": ", ".join(alias_group.get("aliases", [])),
        })

    if alias_data:
        df_aliases = pd.DataFrame(alias_data)
        edited_aliases = st.data_editor(
            df_aliases,
            num_rows="dynamic",
            key="alias_editor",
        )
    else:
        st.info("No entity definitions detected")
        edited_aliases = pd.DataFrame(columns=["Canonical Name", "Type", "Aliases"])

    with st.expander("Sensitive items found in Pass 1", expanded=False):
        entity_data = []
        for entity in st.session_state.pass1_result.get("entities", []):
            entity_data.append({
                "Text": entity.get("text", ""),
                "Type": entity.get("type", ""),
            })
        if entity_data:
            st.dataframe(pd.DataFrame(entity_data))
        else:
            st.info("No sensitive items detected")

    if not st.session_state.pass1_confirmed:
        if st.button("Confirm entities, proceed to Pass 2", type="primary"):
            updated_aliases = []
            for _, row in edited_aliases.iterrows():
                if pd.notna(row["Canonical Name"]) and str(row["Canonical Name"]).strip():
                    updated_aliases.append({
                        "canonical": str(row["Canonical Name"]).strip(),
                        "type": str(row["Type"]).strip() if pd.notna(row["Type"]) else "",
                        "aliases": [
                            a.strip()
                            for a in str(row["Aliases"]).split(",")
                            if a.strip()
                        ] if pd.notna(row["Aliases"]) else [],
                    })
            st.session_state.pass1_result["aliases"] = updated_aliases
            st.session_state.pass1_confirmed = True
            st.rerun()
        return

    st.success("Entity definitions confirmed")
    st.divider()

    # ---- Step 3: Pass 2 scan ----
    st.subheader("Step 3: Pass 2 Scan (Full Document)")

    if st.session_state.pass2_result is None:
        if st.button("Start Pass 2 Scan", type="primary"):
            progress_bar = st.progress(0, text="Scanning document segments...")

            def update_progress(current, total):
                progress_bar.progress(
                    current / total,
                    text=f"Scanning segment {current}/{total}...",
                )

            try:
                result = run_second_pass(
                    st.session_state.uploaded_text,
                    st.session_state.pass1_result,
                    progress_callback=update_progress,
                )
                st.session_state.pass2_result = result
                progress_bar.progress(1.0, text="Scan complete!")
                st.rerun()
            except Exception as e:
                st.error(f"Pass 2 scan failed: {e}")
        return

    # Editable full entity list
    st.write("**All sensitive items:**")

    entity_list_data = []
    for entity in st.session_state.pass2_result:
        count = st.session_state.uploaded_text.count(entity.get("text", ""))
        entity_list_data.append({
            "Text": entity.get("text", ""),
            "Type": entity.get("type", ""),
            "Canonical Name": entity.get("canonical", ""),
            "Occurrences": count,
        })

    if entity_list_data:
        df_entities = pd.DataFrame(entity_list_data)
        edited_entities = st.data_editor(
            df_entities,
            num_rows="dynamic",
            key="entity_editor",
        )
    else:
        st.warning("No sensitive items detected. Check the file content.")
        edited_entities = pd.DataFrame(columns=["Text", "Type", "Canonical Name", "Occurrences"])

    if not st.session_state.pass2_confirmed:
        if st.button("Confirm entities, execute anonymization", type="primary"):
            updated_entities = []
            for _, row in edited_entities.iterrows():
                if pd.notna(row["Text"]) and str(row["Text"]).strip():
                    updated_entities.append({
                        "text": str(row["Text"]).strip(),
                        "type": str(row["Type"]).strip() if pd.notna(row["Type"]) else "",
                        "canonical": str(row["Canonical Name"]).strip() if pd.notna(row["Canonical Name"]) else "",
                    })
            st.session_state.pass2_result = updated_entities
            st.session_state.pass2_confirmed = True
            st.rerun()
        return

    st.success("Entity list confirmed")
    st.divider()

    # ---- Step 4: Execute anonymization ----
    st.subheader("Step 4: Execute Anonymization")

    if st.session_state.anonymized_text is None:
        with st.spinner("Executing anonymization..."):
            try:
                anonymized_text, mapping = execute_replacement(
                    st.session_state.uploaded_text,
                    st.session_state.pass2_result,
                    st.session_state.pass1_result,
                    source_filename=st.session_state.uploaded_filename,
                )
                st.session_state.anonymized_text = anonymized_text
                st.session_state.mapping_data = mapping

                # Generate same-format output for doc/docx
                ext = st.session_state.uploaded_ext
                if ext in ("docx", "doc"):
                    pairs = build_replacement_pairs(mapping, reverse=False)
                    if ext == "docx":
                        st.session_state.anonymized_file_bytes = apply_replacements_to_docx(
                            st.session_state.uploaded_bytes, pairs
                        )
                    else:
                        st.session_state.anonymized_file_bytes = apply_replacements_to_doc(
                            st.session_state.uploaded_bytes, pairs
                        )

                st.rerun()
            except Exception as e:
                st.error(f"Anonymization failed: {e}")
                return

    # Show results
    replacement_count = len(st.session_state.mapping_data.get("replacement_log", []))
    entity_count = st.session_state.mapping_data.get("metadata", {}).get("entity_count", 0)

    st.success(f"Anonymization complete! {entity_count} entities identified, {replacement_count} replacements made.")

    with st.expander("Anonymized text preview", expanded=True):
        preview = st.session_state.anonymized_text
        if len(preview) > 3000:
            preview = preview[:3000] + "\n\n... (showing first 3000 characters)"
        st.text(preview)

    # Download buttons — filename based on detected document type (no original info)
    col1, col2 = st.columns(2)
    ext = st.session_state.uploaded_ext
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    doc_type = st.session_state.pass1_result.get("document_type", "Document")
    doc_type_slug = doc_type.upper().replace(" ", "_")
    anon_filename = f"ANONYMIZED_{doc_type_slug}.{ext}"

    with col1:
        if ext in ("docx", "doc") and st.session_state.anonymized_file_bytes:
            mime = (
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                if ext == "docx"
                else "application/msword"
            )
            st.download_button(
                label=f"Download anonymized file (.{ext})",
                data=st.session_state.anonymized_file_bytes,
                file_name=anon_filename,
                mime=mime,
            )
        else:
            st.download_button(
                label="Download anonymized file (.txt)",
                data=st.session_state.anonymized_text.encode("utf-8"),
                file_name=f"ANONYMIZED_{doc_type_slug}.txt",
                mime="text/plain",
            )

    with col2:
        mapping_json = json.dumps(
            st.session_state.mapping_data, ensure_ascii=False, indent=2
        )
        st.download_button(
            label="Download mapping table (.json)",
            data=mapping_json.encode("utf-8"),
            file_name=f"mapping_{timestamp}.json",
            mime="application/json",
        )

    try:
        save_path = save_mapping(st.session_state.mapping_data, "anonymized")
        st.caption(f"Mapping saved to: {save_path}")
    except Exception:
        pass
