# LDACore

LDACore is the headless Swift core of LDA.app, a native macOS legal-document
anonymizer that runs fully offline and on-device.

This package contains no UI and no network access. It is the single shared core
beneath three later faces: a SwiftUI app, a CLI, and an MCP stdio server.

## What lives here

- `Sources/LDACore/Domain/` holds the frozen public domain types (entity types,
  spans, mappings, token grammar, role labels). These are the contract that
  every engine and every face agrees on.
- `Sources/LDACore/Engine/` holds the pure, synchronous engines:
  DeterministicEngine, SpanMerger, Tokenizer, Restorer, and PromptStore. The LLM
  engine is built in a later phase and is not part of this package.

## Design

- Hybrid detection: deterministic regex plus checksum for structured PII
  (EMAIL, PHONE, BANK_ACCOUNT, USCC, DATE, AMOUNT, NATIONAL_ID), and an LLM (in a
  later phase) for fuzzy entities (PERSON, COMPANY, ADDRESS).
- On a type conflict, deterministic wins.
- Role labels (Buyer, Seller, 甲方, 乙方, and the rest) are never redacted.
- Restore is pure deterministic token substitution plus an orphan-token guard.
- Token grammar: `{TYPE_N}` where `TYPE` matches `[A-Z][A-Z0-9]*` and `N` is a
  positive integer. Canonical detection regex: `\{[A-Z][A-Z0-9]*_\d+\}`.

All offsets in the public API are UTF-16 code-unit offsets, NSRange-compatible,
because the deterministic engine runs `NSRegularExpression` over the text as
`NSString`.

The full design specification lives at
`docs/superpowers/specs/2026-06-06-lda-app-design.md` in the repo root.

## House rules

All code comments, docstrings, and strings are in English. No em-dash and no
en-dash-as-separator anywhere.
