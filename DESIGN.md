# ScreenWren 0.5 product design

Status: implemented product contract

App version: 0.5.0 (13)

Platform: macOS 26 and newer

ScreenWren is a fast, private screen-capture loop. Its primary promise is:

```text
⌃P → select exact pixels → clipboard
```

The ordinary path must remain faster than opening a document editor. Capture
variants belong in the menu-bar menu or configurable shortcuts; image actions
belong in the editor. ScreenWren has no account, cloud library, subscription,
telemetry, or persistent capture history.

## Product rules

- Prefer native macOS behavior and Apple frameworks over custom substitutes.
- Capture only after an explicit command.
- Preserve newer clipboard content instead of overwriting it after delayed work.
- Keep image capture recoverable when clipboard delivery is unavailable. Copy
  failures open an editor. If newer clipboard content prevents delivery, retain
  the capture in Recents or open an editor when it exceeds the Recents memory cap.
- Never silently substitute a different target when an exact repeat target is gone.
- Treat opaque Redact as the privacy tool; label Blur as visual and not secure.
- Keep cancellation and failure visible, bounded, and free of hidden disk writes.

## App surfaces

ScreenWren is a menu-bar app with focused native surfaces:

1. **Readiness** explains Screen Recording permission, records global shortcuts,
   reports unavailable shortcuts, restores defaults, and controls Launch at Login.
2. **Selector** captures a window or exact region with a loupe and physical-pixel
   dimensions.
3. **Editor** provides PaperKit markup, local image intelligence, destructive image
   operations, and explicit export actions.

4. **Capture Preferences** chooses delivery behavior, the optional thumbnail, exact sizes,
   aspect ratio, and saved size presets.
5. **Recent Captures** browses the existing five-image, memory-only collection and combines
   selected captures. Export, text preview, and redaction review are explicit action windows.

Recents, pins, and review windows exist only for the current process.

## Readiness, permission, and shortcuts

Ordinary launch and reopening stay quiet in the menu bar. **ScreenWren Readiness**
opens only from its menu command or when an explicit capture needs permission. It says
what Screen Recording access enables, links to the relevant System Settings pane,
distinguishes allowed, required, and relaunch-required states, and rechecks after
ScreenWren becomes active. When macOS requires a restart after approval, Readiness
offers a helper-mediated **Quit & Reopen ScreenWren** action that waits for the old
process to exit before starting the replacement. Starting through the login item
stays quiet.

Restart remains available whenever access is blocked; it does not depend on the
system permission request returning a particular Boolean. An explicit permission
request that leaves access unavailable opens System Settings. Check Again performs
only a status check. Recovery instructions can reveal the exact running app copy
for replacing a stale permission entry. A ScreenCaptureKit permission denial
invalidates pending capture work, dismisses the selector, and overrides an allowed
preflight result until relaunch. Approval never starts capture automatically.

Screen Recording is the only capture permission. ScreenWren does not request
Accessibility, microphone, Contacts, or Photos access. The wording remains honest
that the precision loupe and Freeze feature temporarily inspect one display frame.

Capture commands, the recent picker, and pin visibility can have global shortcuts:

| Command | Default |
| --- | --- |
| Capture Window or Region | `⌃P` |
| Copy Text from Target | `⌥⌘⇧2` |
| Repeat Last Capture | `⌃⌘⇧2` |
| Capture Front Window | Unassigned |
| Freeze Screen and Select | Unassigned |
| Browse Recent Captures | `⌃⇧P` |
| Hide / Restore All Pins | `⌃⌥P` |

A recorded shortcut requires Command, Control, or Option. Escape cancels recording;
Delete clears it. Conflicts within ScreenWren and registration failures are shown
without discarding the prior working shortcut. Every command remains available from
the menu when its shortcut is unassigned.
On initialization, saved assignments take precedence over conflicting unconfigured
defaults. Those defaults remain unassigned until explicitly changed or reset.

Launch at Login uses macOS ServiceManagement and a bundled helper. The helper opens
the main app only when it is not already running.

## Capture model

Each command supersedes older pending capture work. Before delayed work writes to
the General pasteboard, ScreenWren verifies both that the command is still current
and that another owner has not replaced the clipboard. A stale or cancelled command
must not write, open an editor, add a Recent, or change the repeat target.

An ordinary image capture produces one image, attempts one clipboard delivery, and
adds one memory-only Recent. The default opens no editor or thumbnail. Preferences
can instead open an editor, pin the result, open an export window, or require
redaction review. Review captures do not copy or enter Recents until explicit approval;
Save mode opens an export window without copying. Direct OCR produces text only. A
scrolling session collects frames without writing the clipboard and opens its
stitched result for review before the user copies it.

A region target retains each intersected display's ID, frame, scale, and selected
rectangle. Cross-display capture acquires the intersecting slices sequentially and
composites them at the selector's common scale (the highest attached display scale).
Lower-density slices are upscaled and gaps remain transparent. Geometry is checked
before and after acquisition. Output is capped at 64 million pixels. A window target
is a ScreenCaptureKit window, not a crop of visible desktop pixels.

## Selector and precision behavior

The selector starts with region crosshairs and no highlighted window. Space enables
window snapping, highlighting the topmost eligible window under the pointer. In
that mode, click captures that exact window, Tab and Shift-Tab cycle eligible
windows, and Return captures the highlighted window. Drag always creates a region.
Escape, pressing the capture shortcut again, or switching apps cancels the selector.

Space has two deliberate meanings:

- Before a drag, it toggles window snapping for the current selector.
- During a drag, holding it moves the fixed-size region. Releasing it resumes
  resizing without a jump.

The selector reports live physical-pixel dimensions. Its pixel loupe is filled from
one transient full-display frame and keeps its crosshair aligned at display edges.
Ordinary, timed, and text selectors use synchronized windows on all displays. Freeze
and scrolling selectors remain on one display. Only the current pointer display's
loupe frame is retained; moving to another display requests a replacement.

Holding Shift on release or enabling adjustment mode keeps a region active. Arrows
move by one output pixel, Option–arrows resize, and Shift uses ten-pixel steps. Return
confirms. Exact dimensions and named size presets are in Capture Preferences; aspect
ratio constraints apply to free drags and keyboard resize.

## Capture modes

### Front Window

Captures the first eligible non-ScreenWren window immediately. If no eligible window
exists, it reports failure and does not fall back to the desktop or a region.

### Freeze Screen and Select

Captures the pointer's display, then presents that frozen frame behind a region-only
selector. The delivered pixels come from the frozen frame even if the live desktop
changes underneath it. Only the chosen crop proceeds to clipboard, Recents, editor,
and repeat state.

### Repeat Last Capture

Successful ordinary, front-window, freeze, and timed image captures may become the
repeat target. Direct OCR, scrolling capture, Recents, and editor exports do not.

- A region repeat requires the same display, frame, scale, and containment.
- An exact-window repeat retains the window ID, process ID, and bundle ID and
  resolves that same window again.
- A missing or changed target fails visibly. It never falls back to another window.
- Repeat state is process-memory-only and disappears when ScreenWren quits.

### Timed Capture

The user selects a region, ScreenWren removes the overlay, restores the previous app
when possible, counts down for three seconds in its menu-bar status, then performs a
normal image capture. Starting another command or choosing Cancel invalidates it.

### Copy Text from Target

The selector accepts a region or eligible window. ScreenWren runs local Vision OCR
and writes only recognized text after the clipboard-supersession checks. It does not
write an image, add a Recent, open an editor, or change the repeat target.

### Scrolling Capture

The user selects a fixed viewport, scrolls the source with overlap, and invokes
`⌃P` to add each next frame. ScreenWren uses conservative local seam detection and
rejects ambiguous overlap or changed geometry. The session is limited to 20 frames
and 256 MB of uncompressed frame data. Finish stitches off the main interaction path
and opens an editor; Cancel discards the session. ScreenWren never drives the source
app and therefore needs no Accessibility permission.

## Editor

The editor shows the captured image, the native PaperKit toolbar, focused finish
actions, and a single overflow menu. PaperKit/PencilKit markup remains editable
until a destructive pixel operation flattens it into the base image.

Keyboard markup works only while the canvas is active and no text field, sheet, or
region-operation overlay owns input:

| Key | Action |
| --- | --- |
| `A` | Arrow |
| `R` | Rectangle |
| `H` | Yellow highlighter |
| `T` | Text box |
| `N` | Next sequential numbered step |
| `Esc` | Selection mode, or leave Inspect |

Redact, Blur, Crop, Resize, Rotate, and Reset use the same flattened render path as
export. Destructive operations register Undo first. Redact replaces selected pixels
with opaque pixels. Blur is an appearance effect and is never presented as secure
redaction.

Finish actions are explicit:

- **Copy** places the flattened edited image on the clipboard.
- **Copy and Close** (`⌘Return`) closes only after a successful image clipboard
  write and does not intercept text entry or an attached sheet.
- **Export Image** previews PNG/JPEG, original/1× dimensions, JPEG quality, and encoded size before Save. Direct PNG save, PNG file drag, and a chosen Share service remain available.
- **Pin Above Windows** creates a flattened, session-only floating image with opacity, zoom, and click-through controls. A global shortcut hides/restores pins; the menu can unlock them.

## Review, text preview, and composition

Redaction review detects email/phone patterns and literal text locally. Matching
recognized lines are masked conservatively, with optional manually drawn rectangles.
Approval burns opaque pixels into a new flattened image. Cancellation copies nothing.
The editor presents review as a sheet so edits cannot race with applying its snapshot.
A clipboard ticket prevents approval's asynchronous rendering from overwriting newer
clipboard ownership or a newer explicit copy. Suggestions are not a guarantee that
all sensitive data has been found.

Structured text preview infers table cells or code spacing from recognized word
positions. The preview remains editable and only the Copy button delivers text.
Combining two to five Recents retains chronological ordering and creates a vertical,
horizontal, or grid image, with a 64-million-pixel output bound. Combination opens an
editor and leaves the clipboard unchanged; closing the picker cancels pending work.

## Instant Inspect

Local text, code, and foreground-subject analysis begins automatically for every
image opened in an editor. Results are cached only for that pixel revision and are
invalidated when the base pixels change. PaperKit-only annotation changes do not
needlessly rerun pixel analysis.

`⇧⌘I` exposes native selectable text and data detectors and outlines detected
QR/barcodes. Clicking a code opens an action menu; it does not copy or navigate by
itself. **Copy Value** writes the value explicitly. Only a validated `http` or
`https` value offers **Open**, which delegates to the default app. ScreenWren never
fetches the URL.

`⇧⌘T` copies an active text selection or otherwise the full recognized text.
`⇧⌘L` copies a transparent subject immediately when there is exactly one; when
there are several, ScreenWren highlights them and requires the user to choose one.
Unsupported or ambiguous analysis fails without changing the image.

## Memory, files, and external boundaries

- Recents retain at most five images and approximately 128 MB total.
- Pins retain at most five flattened images.
- Scrolling capture retains at most 20 frames and 256 MB until finish or cancel.
- Editors, Recents, pins, analysis results, and repeat state disappear on process
  exit; ScreenWren makes no forensic secure-erasure claim for RAM or swap.
- Captures are not written to a private library. An image file is created only by
  Save, a completed file drag, or a Share service chosen by the user.
- Clipboard managers, Universal Clipboard, Share services, default URL handlers,
  system swap, and protected-content behavior are outside ScreenWren's control.

## Accessibility and failure behavior

Native controls have labels and ordinary keyboard focus. Capture status and errors
are announced through the app status and macOS accessibility announcements. Escape
cancels selectors and editor interaction modes. The menu remains a complete fallback
for capture commands whose global shortcuts are unavailable.

Failure messages must identify the boundary that failed: permission, vanished
target, changed display, ambiguous scrolling seam, empty OCR, superseded clipboard,
or export failure. Protected or DRM-restricted content may still produce black
pixels because that restriction belongs to the source/system path.

## Deliberate limits

ScreenWren does not include video or GIF capture, automatic scrolling, cloud sync, accounts, a persistent library, a browser extension,
or an updater. OCR, barcode recognition, seam detection, and foreground-subject
lifting are best-effort native analysis and can fail on ambiguous imagery.

## Acceptance and proof boundaries

The following checks establish different facts and must not be conflated:

| Evidence | What it proves | What it does not prove |
| --- | --- | --- |
| `swift test --parallel` | Pure helpers and native component contracts pass on the build machine | Screen Recording permission or real desktop capture |
| `./qa.sh` | Release build, Universal 2 app/helper, property lists, nested signing, ZIP, and executable self-checks | Visual polish, login launch, or notarized public distribution |
| `SCREENWREN_LIVE_QA=1 ./qa.sh` | A permitted signed app can acquire real pixels in the current user session | Every monitor layout, source app, or protected-content case |
| Manual macOS QA | Readiness, permission/relaunch, shortcut conflict, selector, editor, clipboard race, scrolling, and Launch at Login behavior on the tested machine | Untested hardware and OS combinations |
| Developer ID signing, notarization, and Gatekeeper verification | A particular release archive is suitable for public binary distribution | Correctness of a different local or rebuilt archive |

A green headless run is not a claim that the permission dialog or editor has been
visually inspected. An ad-hoc signed local ZIP is not a public release artifact.
Public binaries require a Developer ID Application signature, Apple notarization,
stapling, and Gatekeeper verification of the exact distributed archive.

## Release acceptance

Before a source release is marked public:

- tests and `./qa.sh` pass from a clean checkout;
- repository history and docs contain no private paths, credentials, signing
  fingerprints, captured user content, or generated build products;
- license, privacy, security, contributing, and changelog files match the shipped
  behavior; and
- CI uses a macOS 26-capable runner.

Before attaching a binary release, additionally complete Developer ID signing,
notarization, stapling, Gatekeeper verification, and bounded manual QA of the exact
archive. ScreenWren must be closed after QA rather than left running in the user's
session.
