# Contributing to ScreenWren

Thanks for helping make the capture loop faster, safer, and simpler. ScreenWren is
small on purpose: a native macOS menu-bar app, no account or cloud service, and no
third-party package dependencies.

## Before starting

- Search existing issues and pull requests.
- Open a focused feature request before a large product or architecture change.
- Report vulnerabilities privately through [SECURITY.md](SECURITY.md).
- Use synthetic screenshots and OCR text in public issues and test fixtures.

## Development requirements

- macOS 26 or newer.
- Xcode 26 with the macOS 26 SDK.
- Swift 6.2 or the version shipped with the supported Xcode release.

Clone the repository through its GitHub page, then verify the package:

```sh
swift test --parallel
swift build -c release
.build/release/ScreenWren --self-check
```

Build an ad-hoc signed Universal 2 app for local use:

```sh
./build-app.sh
open dist/ScreenWren.app
```

Run the headless repository harness with:

```sh
./qa.sh
```

It runs Swift tests, rebuilds the app, and validates its archive, both executable
architectures, property lists, nested login item, signatures, and self-checks. To
compare an installed build against a fresh reference build, pass its app path:

```sh
./qa.sh /Applications/ScreenWren.app
```

Real screen capture requires a logged-in graphical macOS session and Screen
Recording permission for the exact app identity being tested. It is explicitly
opt-in:

```sh
SCREENWREN_LIVE_QA=1 ./qa.sh
```

## Project shape

- `Sources/ScreenWren/` — AppKit application, capture, editing, and export code.
- `Sources/ScreenWrenLoginItem/` — quiet native login-item launcher.
- `Tests/ScreenWrenTests/` — Swift XCTest coverage.
- `Resources/` — application icon assets.
- `Info.plist` and `LoginItem-Info.plist` — bundle identities and capabilities.
- `build-app.sh` — reproducible local app-bundle assembly.
- `qa.sh` — package, bundle, signing, and native behavior verification.
- `DESIGN.md` — product invariants, failure behavior, and acceptance gates.

## Design rules

Changes should preserve these boundaries:

1. `⌃P → select → clipboard + editor` remains the shortest ordinary path.
2. Cancellation and pre-delivery failures do not change the clipboard.
3. Stale asynchronous work does not open windows, add Recents, or overwrite newer
   clipboard content.
4. ScreenWren does not persist captures unless the user completes Save, Drag, or a
   chosen Share action.
5. Secure Redact and visual Blur remain clearly different operations.
6. Native Apple APIs and the standard library come before new dependencies.
7. Accessibility labels, keyboard cancellation, and clear failure states are part
   of the feature, not follow-up polish.

Read [DESIGN.md](DESIGN.md) and [PRIVACY.md](PRIVACY.md) before changing capture,
clipboard, export, retention, or permission behavior.

## Code and tests

- Keep UI and AppKit state on the main actor.
- Keep screenshot acquisition separate from clipboard/editor delivery.
- Prefer one shared implementation for Copy, Save, Drag, Share, and Pin rendering.
- Add the smallest runnable test or self-check that would fail if nontrivial logic
  regressed.
- Do not add a third-party dependency for behavior supplied by macOS, Swift, or the
  existing codebase without explicit maintainer agreement.
- Avoid logging captured content, OCR results, window titles, geometry, clipboard
  data, or local paths.

There is no mandatory formatter in the repository. Match the surrounding Swift
style and keep diffs focused.

## Maintainer release draft

`.github/workflows/release.yml` is intentionally manual. It expects an existing
tag that exactly matches `v` plus `CFBundleShortVersionString`, runs headless QA,
signs the nested login item and outer app through `build-app.sh`, submits the ZIP
to Apple's notary service, staples and assesses the app, generates a SHA-256 file,
and creates an **unpublished GitHub draft release**.

Configure a protected GitHub environment named `release` and these repository or
environment secrets before dispatching it:

- `MACOS_CERTIFICATE_P12` — base64-encoded Developer ID Application certificate.
- `MACOS_CERTIFICATE_PASSWORD` — password for that PKCS#12 file.
- `KEYCHAIN_PASSWORD` — ephemeral runner keychain password.
- `DEVELOPER_ID_APPLICATION` — exact codesign identity name.
- `APPLE_ID` — notarization Apple ID.
- `APPLE_TEAM_ID` — Apple Developer team ID.
- `APPLE_APP_SPECIFIC_PASSWORD` — notarization app-specific password.

Never place these values in source, workflow logs, issues, or pull requests. The
draft workflow still needs its first real repository run with valid maintainer
credentials before it can be considered release-proven.

## Pull requests

A useful pull request includes:

- the user problem and why the change belongs in ScreenWren;
- a concise description of behavior and failure handling;
- automated checks run, with their exact commands;
- manual macOS flows tested, including permission state where relevant;
- screenshots or a short recording for visible UI changes, using synthetic data;
- privacy, clipboard, accessibility, and persistence impact; and
- a changelog entry for user-visible changes.

Do not include signing identities, certificates, notarization credentials, private
captures, or generated `dist/` products. Contributions are licensed under the
project's [MIT License](LICENSE).
