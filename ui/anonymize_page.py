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
from core.anonymizer import (
    run_first_pass,
    run_second_pass,
    execute_replacement,
    count_effective_occurrences,
    safe_doc_type,
)
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

    # Sticky error surface (F7): surface the last failure at the top of the page
    # so a mid-workflow exception is never lost when the user scrolls or reruns.
    # The key is PAGE-SCOPED (an anonymize failure must not haunt the restore
    # page) and is cleared whenever a new attempt starts (new upload, Pass 1,
    # Pass 2, or the execute step), so the banner always describes the LATEST
    # attempt instead of a failure the user already recovered from.
    if st.session_state.get("ui_error_anonymize"):
        st.error(st.session_state["ui_error_anonymize"])

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
            # Clear data_editor widget state so a previous file's edit deltas
            # (added / deleted / edited rows) do not bleed onto the new file.
            st.session_state.pop("alias_editor", None)
            st.session_state.pop("entity_editor", None)
            # A new document is a new attempt: drop the previous file's error.
            st.session_state.pop("ui_error_anonymize", None)

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
            st.session_state.pop("ui_error_anonymize", None)
            with st.spinner("Scanning key sections for entity definitions..."):
                try:
                    result = run_first_pass(st.session_state.uploaded_text)
                    st.session_state.pass1_result = result
                    st.rerun()
                except Exception as e:
                    # Record and rerun so the sticky banner at the top of the
                    # page is the SINGLE renderer. Rendering inline here too
                    # showed two red banners at once: the top one still held the
                    # PREVIOUS attempt's message (it rendered before this
                    # handler cleared the key) while this one showed the new
                    # failure. The rerun cannot loop: the button reads False on
                    # the next run, so this handler is not re-entered.
                    st.session_state["ui_error_anonymize"] = f"Pass 1 scan failed: {e}"
                    st.rerun()
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
            st.session_state.pop("ui_error_anonymize", None)
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
                # See the Pass 1 handler: sticky key plus a rerun, so exactly
                # one banner renders the current failure.
                st.session_state["ui_error_anonymize"] = f"Pass 2 scan failed: {e}"
                st.rerun()
        return

    # Editable full entity list
    st.write("**All sensitive items:**")

    # "Occurrences" must reflect the replacements that will ACTUALLY be made
    # (non-overlapping, longest-match-wins), not naive substring frequency,
    # which over-counts a short entity that is a substring of a longer one
    # (e.g. "Aaa" inside "Aaa Corp") and misleads the coverage check (bug #15).
    try:
        effective_counts = count_effective_occurrences(
            st.session_state.uploaded_text,
            st.session_state.pass2_result,
            st.session_state.pass1_result,
        )
    except Exception:
        effective_counts = {}

    entity_list_data = []
    for entity in st.session_state.pass2_result:
        entity_text = entity.get("text", "")
        count = effective_counts.get(
            entity_text,
            st.session_state.uploaded_text.count(entity_text) if entity_text else 0,
        )
        entity_list_data.append({
            "Text": entity_text,
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

    # This step is NOT button-gated: it runs on every rerun while
    # anonymized_text is nil, so it retries by itself and re-renders its own
    # error each run. It therefore uses the inline st.error only, with no sticky
    # key and no rerun: a sticky copy would duplicate an already-current
    # message, and a rerun here would loop forever on a persistent failure.
    if st.session_state.anonymized_text is None:
        st.session_state.pop("ui_error_anonymize", None)
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

    # Slugify the model-supplied document_type into a safe, length-capped token
    # so an over-described type ("... between Acme Corp and John Smith") or a
    # type containing "/" or a newline cannot leak party names into the
    # "generic" filename or produce an illegal Content-Disposition value (#13).
    doc_type = st.session_state.pass1_result.get("document_type", "Document")
    doc_type_slug = safe_doc_type(doc_type)
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

    # Opt-in disk save (default off). The mapping is the most sensitive
    # artifact (full plaintext PII), so it is only persisted when the user
    # explicitly asks. Failures are surfaced, never swallowed silently.
    save_to_disk = st.checkbox(
        "Also save the mapping to disk (data/mappings/)",
        value=False,
        help=(
            "Writes the full plaintext PII mapping to local disk. "
            "The download button above already provides this file. "
            "Leave off unless you need a server-side copy."
        ),
    )
    if save_to_disk:
        try:
            save_path = save_mapping(st.session_state.mapping_data, "anonymized")
            st.caption(f"Mapping saved to: {save_path}")
        except Exception as e:
            st.warning(f"Failed to save mapping to disk: {e}")
