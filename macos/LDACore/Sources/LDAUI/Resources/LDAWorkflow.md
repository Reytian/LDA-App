---
name: lda
description: Use LDA MCP for /LDA or $lda followed by an LDA Matter/workspace name and a document instruction. Choose documents locally, offer optional PII review, work only on redacted text, and restore the result locally. Replaces the legacy OpenClaw CLI workflow.
---

# LDA document workflow

The user gives a short request such as `/LDA "Cedar transaction" Review the documents and summarize the risks.` The quoted first phrase is the LDA Matter name; the rest is the document instruction. A Matter is separate from the Codex project or working folder. If the name is unquoted and its boundary is unclear, ask only which words form the workspace name. If no name is given, omit the hint and let the local Matter picker decide.

1. Discover the connected LDA MCP tools. Use `prepare_documents` with only the user-provided `workspaceName`, if any. Do not send the document instruction as the workspace name. Do not search the filesystem for documents.
2. Tell the user briefly that a local file picker is opening. It offers an optional checkbox to review and add PII. The local Matters picker confirms the association; a name in chat is only a hint. Do not confirm, skip or operate these local controls for the user.
3. If the user cancels selection or review, stop that document workflow. Do not retry or switch to a lower-level tool to bypass the choice. Report a safe tool error without inspecting local logs or original files.
4. Keep each returned redacted handle with its own source and mapping. Read its redacted text with `read_redacted`, then carry out the user's document instruction. Report if detection used patterns only, since that does not reliably find names, companies or addresses. Never describe output as guaranteed free of PII.
5. For edited text or a drafted answer derived from one document, use `restore` with its redacted handle and `editedText`, then `export` the restored handle. Restored text stays local. Keep separate mappings separate; do not restore a combined multi-document answer using one unrelated mapping. For cross-document summaries, provide the redacted answer and explain that restoration needs the relevant document mappings.
6. To preserve Word formatting, export the redacted Word file and work only on that safe file using an explicitly authorized workflow. An edited Word file must be staged locally and restored via `editedHandle`. Do not silently replace a Word document with plain text. If this request only needs a redacted summary, there is no need to restore it automatically.
7. Report completion plainly, with counts and local export status. Do not invent filenames, paths, Matter UUIDs or artifact handles. `attest` provides session accounting; the authenticated audit journal records the LDA boundary. Neither is a general leak detector.

Never read originals, mappings, vault internals or private document paths using shell commands, filesystem tools, browser tools, screenshots, or another connector. Do not ask for passwords in chat or put mapping passphrases into tool arguments. Do not run the old OpenClaw LDA wrapper as a fallback. If LDA is not connected or prepare_documents is unavailable, direct the user to LDA Settings > MCP Setup and restart the AI app after setup or update.

Known partially redacted output requires fresh local confirmation and macOS authentication for each response. Optional review is separate from that approval. Do not infer approval from the chat or suppress the local authentication step.

Any workspace name the user types in the AI chat is already visible to that service. To keep a Matter label out of chat, omit it and select the Matter locally.
