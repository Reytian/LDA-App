# Rebuild the illustrated tutorials

These videos are generated from the fictional text in `storyboards.json`. The renderer does not capture the screen, read accounts or documents, generate speech, or create an audio track. All subtitles are embedded in the picture. Subtitle timing allows at least four seconds per cue, increasing with its word count.

Requires macOS with Apple's Swift command-line tools. No third-party media packages are required. Run in a new output directory outside iCloud:

```sh
swiftc -O render.swift -o /tmp/lda-tutorial-render
/tmp/lda-tutorial-render storyboards.json /tmp/lda-tutorial-output
```

The output includes H.264 MP4 files, posters, one PNG per scene, WebVTT captions, and Markdown transcripts. A repeated run refuses to overwrite existing MP4 files; choose a fresh output directory.

To update the app, copy each final MP4 and poster into `macos/LDACore/Sources/LDAUI/Resources`, and copy the transcript there as plain text with the same basename and a `.txt` extension. Keep the WebVTT and Markdown transcript under `docs/tutorials`. Update the displayed durations and rebuild the offline kit after changing subtitle text or timing.

The initial editions were generated on a Mac Mini. The source is portable across compatible Macs and contains no machine-specific paths, screenshots or credentials.
