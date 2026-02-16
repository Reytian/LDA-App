"""
Legal Document Anonymizer

Main entry point:
- Sidebar navigation (Anonymize / De-anonymize / Settings)
- LLM API connection status
- Page routing

Run: streamlit run app.py
"""

import streamlit as st
from core import llm_client
from ui.anonymize_page import render as render_anonymize
from ui.deanonymize_page import render as render_deanonymize
from ui.settings_page import render as render_settings

st.set_page_config(
    page_title="Legal Document Anonymizer",
    page_icon="🔒",
    layout="wide",
)

with st.sidebar:
    st.title("Legal Document Anonymizer")
    st.caption("PoC v0.1")

    st.divider()

    st.subheader("Navigation")
    page = st.radio(
        "Select function",
        ["Anonymize", "De-anonymize", "Settings"],
        label_visibility="collapsed",
    )

    st.divider()

    st.subheader("LLM Status")

    if "api_connected" not in st.session_state:
        with st.spinner("Checking API connection..."):
            st.session_state.api_connected = llm_client.check_api_connection()

    if st.session_state.api_connected:
        st.success("API: Connected")
        st.caption(f"Model: {llm_client.LLM_MODEL}")
    else:
        st.error("API: Connection failed")
        st.caption("Go to Settings to configure")

    if st.button("Re-check connection"):
        with st.spinner("Checking..."):
            llm_client.reload_config()
            st.session_state.api_connected = llm_client.check_api_connection()
            st.rerun()

    st.divider()

    st.warning(
        "**PoC Version**\n\n"
        "For testing only. Do not process real client files.\n\n"
        "Production version will use a local LLM."
    )

if page == "Anonymize":
    render_anonymize()
elif page == "De-anonymize":
    render_deanonymize()
elif page == "Settings":
    render_settings()
