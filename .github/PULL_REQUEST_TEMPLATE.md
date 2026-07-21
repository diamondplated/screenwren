## Why

What user problem does this solve, and why does it belong in ScreenWren?

## What changed

-

## Verification

Commands run:

```sh
swift test --parallel
swift build -c release
.build/release/ScreenWren --self-check
```

Manual flows tested:

- [ ] Region capture
- [ ] Window capture
- [ ] Cancellation/failure leaves the clipboard unchanged
- [ ] Relevant editor/export flow
- [ ] Editor shortcut behavior does not intercept text entry
- [ ] Relevant permission or shortcut state
- [ ] Not applicable or explained below

## Product and safety review

- [ ] The ordinary `⌃P → select → clipboard + editor` path is not slower or more complicated.
- [ ] Stale or cancelled asynchronous work cannot deliver a result.
- [ ] Clipboard behavior is explicit and race-safe.
- [ ] No capture, OCR text, window metadata, or local path is newly logged or persisted.
- [ ] Secure Redact and visual Blur remain clearly distinguished.
- [ ] Keyboard, VoiceOver labels, and visible failure states were considered.
- [ ] No third-party dependency was added, or maintainer approval is linked.
- [ ] User-visible behavior is documented in `README.md`/`DESIGN.md` and `CHANGELOG.md`.

## Visual evidence

Attach synthetic-data screenshots or a short recording for visible changes. Do not include private captures, credentials, signing identities, or personal paths.

## Notes

Known limits, follow-up work, or checks that could not be run:
