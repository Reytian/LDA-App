# LDA user guide

[Back to the project page](../README.md) · [Privacy and license Q&A](../README.md#questions-and-answers)

This guide covers the native Mac app. Start with a fictional document so you can
check the complete process before working with client material. The core flow is
**scan, review, export, work with AI, restore**. Optional integration controls
require a build that includes them; see the separate integration section below.

## 1. Install LDA

You need an Apple Silicon Mac with **macOS 14 or later and at least 16 GB of
memory**. In the Apple menu, choose **About This Mac** to check your chip, memory,
and macOS version.

1. Open the [latest app release](https://github.com/Reytian/LDA-App/releases/latest).
2. Under **Assets**, download **LDA-notarized.zip**. The automatically generated
   **Source code** archives are for developers, not the ready-to-run app.
3. Double-click the ZIP in Finder to extract it.
4. Drag **LDA.app** to **Applications** and open it from there.

The official release is Developer ID signed and notarized. macOS may still ask
you to confirm opening an app downloaded from the internet. If it instead reports
a damaged app or an unverified developer, stop and check the download and release
instructions rather than disabling macOS security controls.

### Verify the download (optional)

Download **SHA256SUMS.txt** from the same release into the folder containing the
original ZIP. If that folder is Downloads, open Terminal and run:

```bash
cd ~/Downloads
shasum -a 256 -c SHA256SUMS.txt
```

The line for **LDA-notarized.zip** should say **OK**. Use the unchanged filenames
and the checksum file for that exact release. A mismatch means you should
download the files again before opening the app.

## 2. Choose a language and install a model

1. Choose your language in the first-run wizard.
2. Choose an available detection model. **Quick** is the starting option for a
   Mac with 16 GB of memory; larger choices require more memory and disk space.
3. Start the download and wait for verification and installation to complete.
   Quick is approximately **2.74 GB**, separate from the much smaller app archive.
4. If you already have a compatible model, use **Add Model File** instead.
5. Finish setup. You can change models later in **Settings > AI > Manage Models**.

For a Mac kept offline, download the model on another machine and carry it over.
The [offline model instructions](../macos/LDACore/README.md#installing-a-detection-model)
explain how to join the split download and verify it before import.

**Check model readiness before scanning.** Patterns only detects structured
items such as emails, phones, dates, amounts, IDs, and case numbers. It does not
detect people's names, company names, or addresses. A completed pattern-only scan
does not mean those details were protected.

## 3. Add a document and scan

1. Open **De-identify**. An older version may label this **Anonymize**.
2. Choose **Choose Files**, or drag your document into the drop area. For your
   first attempt, use a single Word `.docx` or text file with fictional details.
3. Choose **Scan for PII**. PII means personally identifiable information; LDA
   also looks for other potentially sensitive items, such as company names and
   financial amounts.
4. Wait for the scan to complete. Check any model, import, or coverage warnings.
5. If you add several documents, review each one and confirm that all intended
   documents have been scanned before exporting. Resolve any rescan warnings.

Matters help group related work locally. Use **Matters** to start or revisit a
matter when you want its documents and handoffs kept together. A Matter label
is organizational context, not permission to disclose its contents.

## 4. Review what will be protected

1. Read the document and the findings list. Check that each selected item is one
   you want replaced, and correct any mistaken classification.
2. If LDA missed a sensitive detail, select the text and use **Protect** in the
   context menu. The manual-protection shortcut is **Command + Shift + P**.
3. Keep a value visible only when you have decided that sharing it is appropriate.
4. Open **Safe Preview** and read the protected version from beginning to end.
5. Look beyond direct identifiers. A rare transaction, distinctive quotation,
   date and location combination, or negotiating position may still identify a
   client or reveal confidential information. Protect additional text or remove
   unnecessary passages from the copy you plan to share.

For example, replacing a company name does not necessarily conceal the identity
of the only company in a small town acquiring a particular hospital. Review the
remaining facts as well as the highlighted items.

## 5. Export and check the actual file

1. Choose **Export for AI**.
2. Choose a local folder and a neutral filename. The default is
   **Redacted for AI.md**.
3. LDA saves the Markdown document and an encrypted **.ldamap** file beside it.
   Wait for confirmation that the export succeeded and check whether any
   documents were skipped.
4. Open the Markdown file locally and read the exact content you intend to
   upload. Review its filename, headings, remaining facts, and any warnings.
5. Keep the `.ldamap` on this Mac, with its existing name. It contains the
   information needed for restoration and is protected using the Mac's Keychain.

| File | How to handle it |
|---|---|
| Reviewed redacted `.md` | Share only after deciding the remaining content is appropriate for the recipient. |
| `.ldamap` mapping | Keep local and protected. Do not upload it to the AI service. |
| Original document | Keep in your controlled matter storage. Do not attach it alongside the redacted copy. |
| Restored document | Contains real values again. Treat it as confidential client material. |

The Markdown file itself is readable text, not an encrypted file. A synced folder
may upload either file through your sync service. Use a suitable local folder if
the material must stay off cloud storage.

## 6. Work with your chosen AI service

1. Open the AI service approved for your matter and check its applicable privacy
   settings. LDA does not set the service's retention controls for you.
2. Attach only the reviewed redacted document, or paste its reviewed text if the
   service does not accept Markdown files.
3. Give the task without adding real names or confidential background into the
   prompt. For example:

   ```text
   Summarize the renewal and termination provisions in the attached document.
   Preserve every placeholder and stand-in name exactly as written.
   Do not infer, expand, translate, or replace the hidden identities.
   ```

4. Review the answer for accuracy and changed or invented placeholders.
5. Save the result as a Markdown or plain-text file that LDA can open. If the
   service provides only a chat answer, copy that answer into a local plain-text
   editor and save it as `.txt`. Avoid rich-text `.rtf` for this route.

The AI receives the remaining document text and everything else supplied in its
conversation. De-identification does not make unrelated attachments, chat
history, or newly typed client facts private.

## 7. Restore the original values locally

1. Return to LDA and open **Restore**.
2. Choose or drop the returned Word, Markdown, or text file. The file-selection
   button's wording varies by version.
3. Let LDA locate the corresponding mapping. If it cannot, choose the original
   `.ldamap` or saved workspace when prompted. Match the file to the export that
   produced it, not merely to another document about the same client.
4. If prompted, authenticate or enter the mapping/workspace passphrase locally.
   Never put a password in an AI chat. The default Export for AI mapping normally
   uses this Mac's Keychain without a separate passphrase.
5. Follow Restore's prompts and save a new copy. On versions with a restoration
   preview, inspect it before saving. Then open the saved result and check names,
   amounts, dates, and every unresolved or damaged-placeholder warning.

Restoration replaces placeholders; it does not verify the AI's legal analysis or
repair an incorrect substantive edit. A missing mapping or inaccessible key can
make automatic restoration impossible. Keep the original source, mapping, and
appropriate protected backups until the work is complete.

## 8. Fill a draft from a saved profile

This is a separate local workflow for reusing client facts.

1. Open **Fill** and create or select a portfolio from the library. Portfolios
   can describe a company, an individual, or a general collection of facts.
2. To create one from documents, use **Add Sources** to add source material,
   such as a company certificate, then choose **Extract Profile** (or **Extract**
   in older versions). Alternatively, load
   a saved `.ldaprofile`.
3. Review the extracted fields against the source. Correct errors, resolve
   conflicting values, and add missing facts before saving to the library.
4. Use **Save & Choose Target** or **Choose Target** to select the Word document
   or fillable PDF.
5. Review the proposed fills one blank at a time. Confirm the intended values,
   leave unsupported blanks unfilled, and choose **Apply Fill**.
6. Save a new copy and open it to check both content and layout.

Word filling targets supported text blanks. PDF filling targets supported
AcroForm text fields; a flat scan is not a fillable form. Profiles are encrypted,
but the completed document contains actual client details.

## Optional: connect LDA to an AI app

**Requires a setup-enabled build with Settings > MCP Setup, the bundled helper,
and the LDA workflow skill.** The September 4 version 1.1 release predates these
setup controls. If they are absent, use the manual export-and-restore steps above;
this guide does not add the integration to an older app.

For a compatible Codex build:

1. Keep **LDA.app** in its final location, normally Applications.
2. Open LDA's **Settings > MCP Setup**, choose **Codex**, save its setup script,
   and open that script in Terminal. Complete the setup and restart Codex.
3. Check that the LDA connection is enabled. In the slash menu, select **LDA**
   and enter an instruction such as `/LDA Summarize the renewal terms.`
4. Choose the original document in LDA's local picker, not by attaching it to the
   chat. Enable the optional PII review to inspect and add protection, then select
   the Matter locally. Review is recommended for client material.
5. Read the protected answer and any coverage warnings. For an answer based on
   one document, ask: `Restore this summary locally and export it.` Review the
   result on your Mac.

Keep separate documents' mappings separate. A combined multi-document answer
cannot safely use one unrelated mapping. Any Matter name typed in chat is already
visible to that service; omit it from the command and choose it locally if private.
If LDA asks for fresh local approval to disclose partially protected text, inspect
exactly what will be shared before deciding. Other AI-app tools and file access
remain outside LDA's controls.

## File formats and layout

| Task | What to expect |
|---|---|
| Import for de-identification | Word `.docx`, PDF, and text. Review extraction or OCR results where applicable. |
| Export for AI | A redacted Markdown document and an encrypted `.ldamap`. Word/PDF page layout is not preserved in this route. |
| Restore | Word `.docx`, Markdown `.md`, or plain text `.txt`, using the correct mapping. |
| Fill from profile | Supported Word text blanks and PDF AcroForm text fields. |

Reading a PDF or a scan does not guarantee coverage of every image, annotation,
or hidden element. Upload the reviewed export, not the original PDF. If you need
a Word-to-Word workflow, consult the
[Word round-trip documentation](../macos/LDACore/README.md#word-round-trip-docx-in-restored-docx-out)
and verify the saved file's text, comments, metadata, and layout before sharing.

## Common problems

| Problem | What to do |
|---|---|
| Names or addresses were not found | Check that a model is installed and selected. Patterns only cannot detect these types. Review and protect missed text. |
| Model download or verification failed | Retry or follow the offline import instructions. Do not treat a checksum failure as a successful installation. |
| Export is unavailable | Finish scanning and reviewing the selected documents, then resolve the explanation shown by LDA. |
| A document was skipped during export | Scan and review that document, then export again. Check the resulting file contains everything intended. |
| Restore cannot find the key or mapping | Locate the matching `.ldamap` or workspace. Keep the original mapping name and use the Mac/account or passphrase that can unlock it. |
| Some placeholders remain | Check whether the AI changed them or whether the mapping belongs to another export. Correct against the original locally; do not guess identities. |
| MCP Setup or the LDA command is missing | Use a compatible setup-enabled build, complete setup, and restart the AI app. Otherwise use the manual workflow. |

For a bug report, open a [GitHub issue](https://github.com/Reytian/LDA-App/issues)
with your LDA version, macOS version, model choice, and a fictional example that
reproduces the problem. Remove client names, private filenames, original
documents, mappings, passwords, and sensitive logs before posting.
