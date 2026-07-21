# Demo video script

Target length: 2 minutes 40 seconds. Keep the final upload under 3 minutes.
Use only the included fictional sample document. Do not show real client data,
Keychain prompts, personal browser tabs, or private repository settings.

## 0:00 to 0:18: The problem

### Screen

Show the LDA welcome screen, then the sample legal document.

### Narration

"Legal teams want to use AI, but contracts contain client names, financial
terms, addresses, signatures, and personal data. LDA creates a privacy boundary
on the lawyer's Mac before any document reaches a cloud service."

## 0:18 to 0:42: Guided workflow

### Screen

Show the guided home screen and choose Anonymize. Import
`docs/hackathon/sample-matter.txt`.

### Narration

"The guided workflow starts with the task, not technical settings. I can
anonymize a document, restore a protected result, fill a draft from an encrypted
profile, or return to a saved matter."

## 0:42 to 1:15: Local detection and review

### Screen

Run detection, show the entity review sidebar, deselect one non-sensitive item,
then create the protected output.

### Narration

"LDA combines deterministic detection with a bundled local language model.
Everything runs on-device through llama.cpp and Metal. The app has no macOS
network entitlement. I review every proposed entity before LDA replaces it with
typed placeholders and stores the mapping in an encrypted container."

## 1:15 to 1:40: Matter rename and archive

### Screen

Open Matters. Rename the matter to `Meridian acquisition demo`, archive it,
show the Archived filter, then restore it.

### Narration

"Build Week added a privacy-safe matter workspace. Matters can be renamed,
archived, restored, and reopened without placing document contents in ordinary
preferences or logs. Interrupted work is parked safely for recovery."

## 1:40 to 2:03: Restore

### Screen

Open the protected output and encrypted mapping in Restore. Show the restored
text next to the original.

### Narration

"After an external AI workflow, Restore reverses the placeholders locally. The
original values never need to be sent to the external service. LDA also fills
draft DOCX files and PDF forms from encrypted profiles."

## 2:03 to 2:30: Codex and GPT-5.6

### Screen

Show the Build Week commit summary, the test result, and the notarized app
verification. Do not show terminal secrets or Apple account details.

### Narration

"During Build Week, I used Codex with GPT-5.6 [confirm before recording] to
turn an existing native engine into this guided product. Codex helped trace the
architecture, implement the matter workspace and rename/archive flows, design
regression tests, review privacy edge cases, and automate signing and
notarization. I made the product decisions and kept the app review-first and
fully offline. The extension changed 43 files and the final suite passes 808
tests."

## 2:30 to 2:40: Close

### Screen

Return to the LDA home screen and show the Offline badge.

### Narration

"LDA gives legal professionals a practical way to use modern AI while reducing
unnecessary disclosure of confidential information. Your documents stay local;
your workflow stays useful."
