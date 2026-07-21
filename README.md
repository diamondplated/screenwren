<p align="center">
  <img src="Resources/ScreenWrenIconMaster.png" width="144" alt="ScreenWren app icon">
</p>

<h1 align="center">ScreenWren</h1>

<p align="center"><strong>Capture. Copy. Keep moving.</strong></p>

<p align="center">
  A fast, private, native screen-capture loop for macOS 26 and newer.
</p>

<p align="center">
  <a href="PRIVACY.md">Privacy</a> ·
  <a href="SECURITY.md">Security</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="DESIGN.md">Product design</a>
</p>

ScreenWren is a menu-bar utility for the work between seeing something and using
it. Press **Control-P**, click a highlighted window or drag an exact region, and
release. The capture is copied immediately and opened in a native PaperKit editor.

There is no account, cloud library, analytics service, subscription, or third-party
package dependency. Screen capture, OCR, subject lifting, and editing use Apple
frameworks on your Mac.

<p align="center">
  <img src="Resources/ScreenWrenReadiness.png" width="620" alt="ScreenWren Readiness showing screen-capture permission, configurable global shortcuts, and Launch at Login">
</p>

## The fast path

1. Press `⌃P` from any app.
2. Click a highlighted window, or drag a region.
3. Paste immediately, or continue in the editor that opens.

While the selector is open:

- Press `Space` to switch between window snapping and region-only selection.
- Press `Tab` or `⇧Tab` to move through eligible windows.
- Press `Return` to capture the highlighted window.
- Press `Esc` to cancel without changing the clipboard.

## What it can do

### Capture

- Exact region and native ScreenCaptureKit window capture.
- Capture the frontmost eligible window immediately, with no selector.
- Freeze the display first, then select from the frozen pixels.
- A pixel loupe, live dimensions, and hold-Space repositioning for precise regions.
- Direct OCR to text without first putting an image on the clipboard.
- Repeat the last valid region or exact window without reopening the selector.
- Three-second timed capture for menus, tooltips, and hover states.
- Guided scrolling capture with conservative seam detection.
- Session-only recent captures—never a hidden screenshot library.

### Edit and finish

- Apple PaperKit and PencilKit markup.
- Keyboard-first arrow, rectangle, highlighter, text, and numbered-step markup.
- Instant Inspect: select recognized text directly and act on detected codes.
- Local text recognition and foreground-subject lifting; when several subjects are
  found, choose the one to copy.
- Opaque rectangular redaction.
- Visual blur, explicitly labeled **not secure**.
- Crop, aspect-preserving resize, 90-degree rotation, and reset.
- Pin a flattened capture above ordinary windows.
- Copy, save as PNG, drag as PNG, or use the native Share menu.
- Copy the finished image and close its editor in one command.

### Default shortcuts

| Action | Shortcut |
| --- | --- |
| Capture a window or region | `⌃P` |
| Copy text from a selected target | `⌥⌘⇧2` |
| Repeat the last valid region or window | `⌃⌘⇧2` |
| Toggle Instant Inspect in the editor | `⇧⌘I` |
| Copy text from the editor | `⇧⌘T` |
| Copy a transparent subject from the editor | `⇧⌘L` |
| Copy the edited image | `⇧⌘C` |
| Copy the edited image and close its editor | `⌘Return` |

The same capture commands are available from ScreenWren's menu-bar icon. Open
**ScreenWren Readiness…** to change global shortcuts, see conflicts, restore the
defaults, and control Launch at Login. Front Window and Freeze start unassigned so
they do not take over another global key without your choice.

In an editor, **Inspect** exposes native Live Text selection/data detectors and
outlines detected QR/barcodes. `⇧⌘T` copies the exact selection when one is active,
or the full recognized text otherwise. Click a code to open its action menu, then
choose **Copy Value** or, for a validated `http` or `https` value, **Open** in your
default app. The same actions are available under **••• → Detected Codes**. Press
`Esc` to return to editing.
ScreenWren analyzes the image locally and does not fetch a detected URL itself.

When an editor canvas is active and you are not typing into a text box, press `A`
for an arrow, `R` for a rectangle, `H` for a yellow highlighter, `T` for text, or
`N` for the next numbered step. `Esc` returns to selection mode. These keys drive
the same native PaperKit canvas shown in the toolbar.

## Privacy by construction

ScreenWren does not upload captures. It has no analytics or advertising SDK and
no network service of its own. OCR and subject lifting run through Apple's local
Vision frameworks.

- Captures and pins live in process memory.
- Precision loupe and Freeze may hold one full display frame transiently in memory;
  only the selected region or requested window is delivered.
- Recents are capped at five images and approximately 128 MB, then disappear when
  ScreenWren quits.
- ScreenWren writes an image file only when you complete Save or a file drag. A Share
  service may send or persist it only after you choose that service.
- Clipboard contents are system-wide and may be read or retained by other apps,
  clipboard managers, or macOS.
- ScreenWren requests Screen Recording access, not Accessibility or microphone access.

The full data boundary is documented in [PRIVACY.md](PRIVACY.md).

## Requirements

- macOS 26 or newer.
- Xcode 26 with the macOS 26 SDK to build from source.
- Screen Recording permission to capture pixels.

ScreenWren uses macOS 26's PaperKit APIs and intentionally does not carry a
compatibility editor for older macOS releases.

## Build from source

The project is a Swift package with no external package dependencies.

```sh
swift test --parallel
./build-app.sh
open dist/ScreenWren.app
```

The build script creates a Universal 2 `dist/ScreenWren.app` and a versioned ZIP.
Local builds are ad-hoc signed by default. A public distribution build must set
`SCREENWREN_SIGNING_IDENTITY` to a Developer ID Application identity and be
notarized.

On first launch, **ScreenWren Readiness** explains the required Screen Recording
permission and shows shortcut status. If capture is still blocked after enabling
ScreenWren in **System Settings → Privacy & Security → Screen & System Audio
Recording**, choose **Quit & Reopen ScreenWren** in Readiness.

Run the repository's headless native verification harness with:

```sh
./qa.sh
```

It runs tests, rebuilds the app, and verifies the archive, both architectures,
property lists, nested login item, signatures, and executable self-checks. A real
pixel capture is opt-in because macOS grants Screen Recording permission to an
exact signed app in a logged-in user session:

```sh
SCREENWREN_LIVE_QA=1 ./qa.sh
```

For editor work, open any local image without capturing the screen:

```sh
open -n dist/ScreenWren.app --args --open-image /path/to/image.png
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and
[DESIGN.md](DESIGN.md) for behavioral invariants and acceptance boundaries.

## Deliberate limits

ScreenWren is a capture loop, not a document suite:

- Region selection is limited to one display at a time.
- Scrolling is guided and manual; ScreenWren does not control another app or request
  Accessibility access.
- Protected or DRM-restricted content may capture as black.
- OCR and subject detection can fail on ambiguous imagery.
- There is no video/GIF capture, cloud sync, account system, or persistent library.

The source currently identifies as a pre-1.0 build. Behavior and file formats may
change before the first stable release.

## License

ScreenWren is available under the [MIT License](LICENSE).
