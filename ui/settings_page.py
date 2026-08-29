"""
Settings page — configure LLM API connection and model.
"""

import os
import streamlit as st
from core import llm_client

PROJECT_ROOT = os.path.dirname(os.path.dirname(__file__))


def _write_env(api_base: str, api_key: str, model: str) -> str:
    """Write the LLM config to .env with owner-only (0600) permissions.

    Preserves the backend-selecting keys the form does not expose
    (LLM_BACKEND, LLM_OLLAMA_BASE, LLM_TIMEOUT, LLM_NUM_CTX, LLM_NUM_PREDICT),
    sourcing them from the live llm_client config (which reflects the current
    .env). Truncating the file to only the three form keys would silently revert
    an ollama / local-LLM user to the openai backend on the next launch -- and,
    if LLM_API_BASE then points at a reachable remote endpoint, ship plaintext
    PII off-box, defeating the offline guarantee (bug #7).

    Returns the path written. The file holds a secret (the API key), so it is
    restricted to the owner via os.chmod after writing.
    """
    env_path = os.path.join(PROJECT_ROOT, ".env")
    lines = [
        f"LLM_BACKEND={llm_client.LLM_BACKEND}",
        f"LLM_API_BASE={api_base}",
        f"LLM_API_KEY={api_key}",
        f"LLM_MODEL={model}",
        f"LLM_OLLAMA_BASE={llm_client.LLM_OLLAMA_BASE}",
        f"LLM_TIMEOUT={llm_client.LLM_TIMEOUT}",
        f"LLM_NUM_CTX={llm_client.LLM_NUM_CTX}",
        f"LLM_NUM_PREDICT={llm_client.LLM_NUM_PREDICT}",
    ]
    with open(env_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(env_path, 0o600)
    return env_path


def render():
    """Render the settings page."""

    st.header("Settings")

    st.subheader("LLM API Configuration")

    # Read current values from the module (reflects latest .env)
    current_base = llm_client.LLM_API_BASE
    current_key = llm_client.LLM_API_KEY
    current_model = llm_client.LLM_MODEL

    api_base = st.text_input(
        "API Base URL",
        value=current_base,
        placeholder="https://api.moonshot.ai/v1",
    )

    api_key = st.text_input(
        "API Key",
        value=current_key,
        type="password",
    )

    # Model input with common presets
    model_presets = [
        "kimi-k2.5",
        "gpt-4o",
        "gpt-4o-mini",
        "claude-sonnet-4-5-20250929",
        "deepseek-chat",
    ]

    # Use selectbox + custom input
    preset_options = model_presets + ["Custom..."]
    if current_model in model_presets:
        default_idx = model_presets.index(current_model)
    else:
        default_idx = len(model_presets)  # "Custom..."

    selected = st.selectbox("Model", preset_options, index=default_idx)

    if selected == "Custom...":
        model = st.text_input(
            "Custom model name",
            value=current_model if current_model not in model_presets else "",
            placeholder="model-name",
        )
    else:
        model = selected

    st.divider()

    col1, col2 = st.columns(2)

    with col1:
        if st.button("Save & Test Connection", type="primary"):
            if not api_base or not api_key or not model:
                st.error("All fields are required.")
                return

            # Write to .env (owner-only permissions)
            _write_env(api_base, api_key, model)

            # Reload config in the client module
            llm_client.reload_config()

            # Test connection
            with st.spinner("Testing connection..."):
                connected = llm_client.check_api_connection()

            st.session_state.api_connected = connected

            if connected:
                st.success(f"Connected to {model}!")
            else:
                st.error("Connection failed. Check your API base URL and key.")

    with col2:
        if st.button("Save Only"):
            if not api_base or not api_key or not model:
                st.error("All fields are required.")
                return

            _write_env(api_base, api_key, model)

            llm_client.reload_config()
            st.success("Settings saved.")

    # Show current config status
    st.divider()
    st.subheader("Current Configuration")
    key_display = "(not set)" if not llm_client.LLM_API_KEY else "\u2022" * 12
    st.code(
        f"API Base: {llm_client.LLM_API_BASE or '(not set)'}\n"
        f"API Key:  {key_display}\n"
        f"Model:    {llm_client.LLM_MODEL or '(not set)'}",
        language=None,
    )
