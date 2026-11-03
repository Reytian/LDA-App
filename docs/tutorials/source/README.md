# Rebuild the LDA 2.0 tutorials

The tutorials combine recordings of the released LDA 2.0 window, held frames, focused crops, and clearly labeled explanatory cards. All captured documents were created for this tutorial and contain fictional names and reserved example contact details. AI prompts and responses are illustrative, not a recording of a private conversation. No desktop, account sidebar, notification or personal document appears in the videos.

The app walkthrough shows actual scanning, preview changes, export, and restoration. The MCP walkthrough shows the actual Settings > AI assistants page and explains the remaining connection and document workflow with labeled cards. It does not claim to show a live third-party AI session.

## Render

Requires macOS and Apple's Swift command-line tools. Run outside iCloud in a fresh output directory:

```sh
swiftc -O render.swift -o /tmp/lda-tutorial-render
/tmp/lda-tutorial-render storyboards.json /tmp/lda-tutorial-output
```

`assets/` contains only synthetic-document window captures. `assets/clips.json` preserves the relative capture times of the recorded interactions. Captures were sampled at approximately 10 frames per second and reduced to approximately 5 frames per second in the source. The output is 1920 by 1080 H.264 at 15 frames per second. Interactions retain their captured timing within each scene, with introductory and final holds for readability. Editing and capture timings are not performance benchmarks.

No audio input or track is created. English captions are embedded in the picture and also written as WebVTT. Every caption lasts at least four seconds, with more time for longer text. The renderer writes posters, scene previews, MP4 videos, captions and Markdown transcripts. It refuses to overwrite existing videos.

Use `python3 build-kit.py /tmp/lda-tutorial-output` to make the offline ZIP and SHA256SUMS.txt. Verify both videos with a full decoder pass, inspect the scene previews and the changing interaction frames, and confirm there is no audio stream before publishing.

## Update the product

Copy the final MP4 and poster into `macos/LDACore/Sources/LDAUI/Resources`, and copy each plain-text `.txt` transcript there. Keep transcripts and WebVTT files under `docs/tutorials`. Update durations and fixed tutorial links in the website, app, documentation and the fixed-link security test.

Publish tutorial assets under their own release tag, without marking that release as the latest application. Bundled video changes require a fresh signed and notarized application build. Do not modify an installed notarized bundle in place.
