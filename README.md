<p align="center">
  <img src="Resources/ScreenWrenIconMaster.png" width="144" alt="ScreenWren app icon">
</p>

<h1 align="center">ScreenWren</h1>

<p align="center"><strong>Capture. Copy. Keep moving.</strong></p>

<p align="center">
  A fast, private, native screen-capture loop for macOS 26 and newer.
</p>

<p align="center">
  <a href="https://github.com/diamondplated/screenwren/actions/workflows/ci.yml"><img src="https://github.com/diamondplated/screenwren/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg" alt="macOS 26+">
  <img src="https://img.shields.io/badge/dependencies-0-brightgreen.svg" alt="Zero dependencies">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="#the-fast-path">Quick start</a> ·
  <a href="#what-it-can-do">Features</a> ·
  <a href="#privacy-by-construction">Privacy</a> ·
  <a href="PRIVACY.md">Privacy policy</a> ·
  <a href="SECURITY.md">Security</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="DESIGN.md">Design</a>
</p>

---

## Install

```sh
brew install --cask diamondplated/tap/screenwren
```

Or grab the zip from [Releases](https://github.com/diamondplated/screenwren/releases/latest).

**macOS will block the first launch** — this build is ad-hoc signed, not notarized, because the
project has no Apple Developer ID. Approve it once under **System Settings → Privacy & Security**,
or strip the quarantine attribute yourself if you trust the build:

```sh
xattr -dr com.apple.quarantine /Applications/ScreenWren.app
```

Building from source avoids the question entirely — see [below](#build-from-source).

---

## The work between seeing something and using it

ScreenWren starts quietly in the menu bar. Press **`⌃P`** from any app for crosshairs,
drag an exact region, and release. Press Space first if you want to select a window.

It's already on your clipboard. A successful default capture opens no editor or preview.
Open **Capture Preferences…** to choose another destination or enable an optional thumbnail.
If copying fails, an editor preserves the capture. When newer clipboard content
prevents copying, the capture stays in Recents; images too large for Recents open in an editor.

- ⚡ **One keystroke to clipboard.** No save dialog, no file to find, no "where did that go".
- 🔒 **Nothing leaves your Mac.** No account, no cloud library, no analytics, no network service of
  its own. OCR and subject lifting run through Apple's local Vision frameworks.
- 📦 **Zero third-party packages.** Capture, OCR, subject lifting, and editing are all Apple
  frameworks.
- 🧹 **No hidden screenshot library.** Recents live in memory and vanish when ScreenWren quits.
- 🔤 **Text, not just pixels.** Pull copyable text straight out of a region without ever putting an
  image on the clipboard.

<p align="center">
  <img src="Resources/ScreenWrenReadiness.png" width="620" alt="ScreenWren Readiness showing screen-capture permission, configurable global shortcuts, and Launch at Login">
</p>

---

## The fast path

1. Press `⌃P` from any app.
2. Drag a region with the crosshairs, or press Space and click a highlighted window.
3. Paste immediately. To edit a capture, press `⌃⇧P`, select its thumbnail, and choose **Edit**.

While the selector is open:

| Key | Does |
|---|---|
| `Space` | switch between window snapping and region-only selection |
| `Tab` / `⇧Tab` | move through eligible windows in window-selection mode |
| `Return` | capture the highlighted window in window-selection mode |
| `Shift` when releasing | keep the selection open for adjustments |
| Arrow keys / `Option` + arrows | move / resize an adjustable selection; `Shift` uses larger steps |
| `Return` in adjustment mode | capture the adjusted selection |
| `Esc` / capture shortcut again | cancel without touching the clipboard |

---

## What it can do

### Capture

- **Windows and regions.** Native ScreenCaptureKit window capture, or an exact drag across one or several displays. Mixed-scale captures use a common pixel scale; gaps between displays are transparent.
- **Front window, no selector.** Capture the frontmost eligible window immediately.
- **Freeze first.** Freeze the display, then select from the frozen pixels — for menus and hover
  states that vanish the moment you move.
- **Precision tools.** A pixel loupe, live dimensions, hold-`Space` repositioning, keyboard adjustment, exact pixel sizes, aspect-ratio locking, and saved size presets.
- **Straight to text.** OCR a region without putting an image on the clipboard at all.
- **Repeat.** Re-run the last valid region or exact window without reopening the selector.
- **Timed.** Three-second delay for menus, tooltips, and hover states.
- **Scrolling capture.** Guided, with conservative seam detection.
- **Session-only recents.** A visual picker (`⌃⇧P`) for copying, editing, pinning, exporting, removing, and combining captures. Never a hidden screenshot library.

### Edit and finish

- **Native markup.** Apple PaperKit and PencilKit.
- **Keyboard-first annotation.** Arrow, rectangle, highlighter, text, and numbered steps.
- **Instant Inspect.** Select recognized text directly and act on detected QR/barcodes.
- **Subject lifting.** Local foreground extraction; when several subjects are found, pick one.
- **Redaction.** Opaque rectangular redaction — plus a visual blur that is explicitly labeled
  **not secure**.
- **Geometry.** Crop, aspect-preserving resize, 90° rotation, reset.
- **Pin.** Float a flattened capture with opacity, zoom, and click-through controls. `⌃⌥P` hides or restores all pins. **Unlock All Pins** in the menu restores mouse interaction.
- **Finish.** Copy, export PNG/JPEG with original or 1× resolution and an encoded-size preview,
  drag out as PNG, or use the native Share menu. Copy and close the editor in one command.
- **Redaction assistance.** Review suggested email, phone, and literal-text masks; draw additional
  masks on the preview. Suggestions cover whole recognized lines and can miss content.
- **Structured OCR.** Preview and correct plain text, tab-separated tables, or code with inferred
  spacing before copying. Available from the capture menu and the editor's More menu.
- **Combine.** Command-select two or more Recents and create a vertical, side-by-side, or grid
  composition. The result opens for editing without changing the clipboard.

### Capture preferences

Choose **Capture Preferences…** from the menu-bar menu or the app menu (`⌥⌘,`).
After capture, choose Copy only (default), Copy and open editor, Copy and pin,
Save (opens an export window), or Review redactions before copying.
The optional thumbnail offers Edit, Save, Pin, and PNG drag; it never takes keyboard
focus and closes after six seconds. Starting another selection dismisses it.

Review mode withholds the unreviewed image from the clipboard and Recents. Approving
copies the flattened reviewed image, unless another clipboard action has overtaken
it; in that case the reviewed image opens in the editor. Cancel leaves the clipboard
unchanged. Use this mode **before** capturing private content: reviewing an image
later in the editor cannot retract a copy already placed on the system clipboard.

Exact sizes and presets are in physical output pixels. Oversized selections fit to
the available desktop. Freeze and scrolling capture still use one display; ordinary,
timed, and text selection can span displays. Display slices are captured sequentially,
so moving content may differ slightly in time between monitors.

### Default shortcuts

| Action | Shortcut |
| --- | --- |
| Capture a window or region | `⌃P` |
| Copy text from a selected target | `⌥⌘⇧2` |
| Repeat the last valid region or window | `⌃⌘⇧2` |
| Browse recent captures | `⌃⇧P` |
| Hide / restore all pins | `⌃⌥P` |
| Toggle Instant Inspect in the editor | `⇧⌘I` |
| Copy text from the editor | `⇧⌘T` |
| Copy a transparent subject from the editor | `⇧⌘L` |
| Copy the edited image | `⇧⌘C` |
| Copy the edited image and close its editor | `⌘Return` |

Every capture command is also in the menu-bar icon. Open **ScreenWren Readiness…** to change global
shortcuts, see conflicts, restore defaults, and control Launch at Login. Front Window and Freeze
start unassigned, so they don't claim a global key without your say-so.
On upgrade, saved custom shortcuts take precedence: conflicting new defaults start
unassigned until you assign a key or restore defaults.

<details>
<summary><strong>Inspect and canvas keys, in detail</strong></summary><br>

In an editor, **Inspect** exposes native Live Text selection/data detectors and outlines detected
QR/barcodes. `⇧⌘T` copies the exact selection when one is active, or the full recognized text
otherwise. Click a code to open its action menu, then choose **Copy Value** or, for a validated
`http` or `https` value, **Open** in your default app. The same actions are available under
**••• → Detected Codes**. Press `Esc` to return to editing. ScreenWren analyzes the image locally
and does not fetch a detected URL itself.

When an editor canvas is active and you are not typing into a text box, press `A` for an arrow, `R`
for a rectangle, `H` for a yellow highlighter, `T` for text, or `N` for the next numbered step.
`Esc` returns to selection mode. These keys drive the same native PaperKit canvas shown in the
toolbar.
</details>

---

## Privacy by construction

ScreenWren does not upload captures. It has no analytics or advertising SDK and no network service
of its own. OCR and subject lifting run through Apple's local Vision frameworks.

- Captures and pins live in process memory.
- Precision loupe and Freeze may hold one full display frame transiently in memory; only the
  selected region or requested window is delivered.
- Recents are capped at five images and approximately 128 MB, then disappear when ScreenWren quits.
- ScreenWren writes an image file only when you complete Save or a file drag. A Share service may
  send or persist it only after you choose that service.
- Clipboard contents are system-wide and may be read or retained by other apps, clipboard managers,
  or macOS.
- ScreenWren requests Screen Recording access — not Accessibility, not microphone.

The full data boundary is documented in [PRIVACY.md](PRIVACY.md).

---

## Requirements

- macOS 26 or newer.
- Xcode 26 with the macOS 26 SDK to build from source.
- Screen Recording permission to capture pixels.

ScreenWren uses macOS 26's PaperKit APIs and intentionally does not carry a compatibility editor for
older macOS releases.

---

## Build from source

A Swift package with no external package dependencies.

```sh
swift test --parallel
./build-app.sh
open dist/ScreenWren.app
```

The build script creates a Universal 2 `dist/ScreenWren.app` and a versioned ZIP. Local builds are
ad-hoc signed by default. A public distribution build must set `SCREENWREN_SIGNING_IDENTITY` to a
Developer ID Application identity and be notarized.

Launch stays quiet. If your first capture needs permission, **ScreenWren Readiness** explains
Screen Recording access and shows shortcut status. You can also open it from the menu-bar menu
or **ScreenWren → Settings…** (⌘,) while an editor is open.
If capture is still blocked after enabling ScreenWren in **System Settings →
Privacy & Security → Screen & System Audio Recording**, choose **Quit & Reopen ScreenWren** in
Readiness.

If Settings already shows ScreenWren enabled but capture remains blocked, remove
that old ScreenWren entry and add the running copy again using **Show This Copy in
Finder** in Readiness. Then choose **Quit & Reopen ScreenWren**. **Check Again**
refreshes the displayed status without starting a capture.

Local ad-hoc signing changes the app's identity when its executable changes, so
Screen Recording permission may need to be granted again after rebuilding. A
consistent signing certificate avoids that identity change:

```sh
SCREENWREN_SIGNING_IDENTITY="Your code-signing certificate name" ./build-app.sh
```

This requires an existing valid code-signing certificate in your keychain.

For development, the certificate name or SHA-1 fingerprint can also be saved as
plain text in `.screenwren-signing-identity` at the repository root. This local
file is ignored by Git and used by subsequent builds, including `qa.sh`, so they
keep the same signing identity. `SCREENWREN_SIGNING_IDENTITY` overrides the saved
value. An empty saved value fails the build instead of reverting to ad-hoc signing.
The file contains only the certificate selector; the private key stays in Keychain.

<details>
<summary><strong>Verification harness</strong></summary><br>

```sh
./qa.sh
```

Runs tests, rebuilds the app, and verifies the archive, both architectures, property lists, nested
login item, signatures, and executable self-checks. A real pixel capture is opt-in, because macOS
grants Screen Recording permission to an exact signed app in a logged-in user session:

```sh
SCREENWREN_LIVE_QA=1 ./qa.sh
```

For editor work, open any local image without capturing the screen:

```sh
open -n dist/ScreenWren.app --args --open-image /path/to/image.png
```
</details>

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and [DESIGN.md](DESIGN.md) for
behavioral invariants and acceptance boundaries.

---

## Deliberate limits

ScreenWren is a capture loop, not a document suite:

- Region selection is limited to one display at a time.
- Scrolling is guided and manual; ScreenWren does not control another app or request Accessibility
  access.
- Protected or DRM-restricted content may capture as black.
- OCR and subject detection can fail on ambiguous imagery.
- There is no video/GIF capture, cloud sync, account system, or persistent library.

The source currently identifies as a pre-1.0 build. Behavior and file formats may change before the
first stable release.

---

## License

[MIT](LICENSE).
