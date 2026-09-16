# ScreenWren application review

Reviewed September 15, 2026. Scope: capture coordination, selection, editing,
shortcuts, local analysis, export, retention, login helper, tests, and packaging.

The app has a clear purpose and useful boundaries: local processing, explicit
exports, session-only history, and checks that preserve newer clipboard content.
The highest-value next work is reliability and interaction polish within that
capture loop.

## Fixes made

| Priority | Finding | Change and evidence |
| --- | --- | --- |
| High | The borderless capture selector could not become the key window, so its Escape, Space, Tab, and Return handlers could not reliably receive input. | Added a selector-specific key-capable window. A regression test failed on the original implementation. |
| Medium | The editor's event monitor replaced a handled `nil` result with the original event, forwarding consumed shortcuts to the responder again. | Preserve `nil` for handled events. A native event-dispatch regression reproduced handled Escape still reaching the responder and now passes. |
| Medium | Shortcut conflict checks included display labels, so the same physical key and modifiers with a different label escaped conflict detection. | Compare key code and modifier identity. Tests cover both duplicate detection and rejecting updates before altering stored state. |
| Medium | The first scrolling frame bypassed the documented 256 MB session limit. | Apply a shared, overflow-checked memory budget to the initial and subsequent frames. Tests cover the exact limit, excess, and integer overflow. |
| Medium | AppKit automatically re-enabled menu actions that the app explicitly disabled. | Disable automatic validation for the manually managed capture and editor overflow menus. A regression reproduced unavailable Undo/Redo becoming enabled after menu update. |
| Medium | The installed `lipo` rejected verification of two architectures in one invocation, preventing app packaging. | Verify arm64 and x86_64 separately in both build and QA scripts. |

Also added native Cut, Copy, Paste, and Select All menu commands, routed through
the first responder, with tests for their selectors and shortcuts.

## Recommended next work

1. **Add capture-coordinator integration tests.** Existing tests largely exercise
   helpers and components. Inject screenshot acquisition, OCR, pasteboard access,
   and time into `CaptureCoordinator` so tests can complete requests out of order.
   Cover cancellation, a newer capture overtaking an older one, clipboard changes
   during OCR, display removal, and finishing while a scrolling frame is pending.
   Assert editor, Recents, repeat-target, and clipboard effects together.

2. **Make the editor toolbar adapt to narrow windows.** The window declares a
   minimum width of 720 points, but one row contains PaperKit tools, status, three
   analysis buttons, Copy, Drag, and More. Consider icon-only secondary actions or
   moving them into More at narrow widths. Check keyboard focus, accessibility
   labels, and localization at the minimum size. In the packaged app, narrowing
   the window to approximately 855 points hid the status text and prevented
   further shrinking, even though the code declares a smaller minimum.

3. **Show capture errors where users will notice them.** Capture status is mostly
   a menu-bar tooltip, an icon, a beep, and an accessibility announcement. Add a
   short status row in the capture menu or a transient status panel for vanished
   windows, permission errors, ambiguous scrolling seams, and clipboard failures.
   Include a relevant retry action without exposing capture contents.

4. **Split the main application file along existing responsibilities.**
   `ScreenWrenApp.swift` contains roughly 3,000 lines spanning application setup,
   capture coordination, selectors, editor rendering, and interactions. Extract
   these components without changing behavior. This makes async state and
   privacy-sensitive export paths easier to test and review.

5. **Make long operations and memory use easier to manage.** Scrolling stitch work
   uses detached tasks and explicitly refuses cancellation once stitching begins.
   Consider cooperative cancellation between frames, visible progress, and a
   memory-pressure policy for open editors and their Undo snapshots. Recents and
   scrolling limits do not bound all image memory retained by the process.

6. **Complete release and desktop acceptance checks.** Exercise Screen Recording
   denial/approval/relaunch, mixed-scale displays, disappearing windows, login
   launch, multiple-subject selection, drag destinations, and real Share services.
   The repository describes ad-hoc distribution and a manual notarization flow;
   verify that flow with maintainer credentials before promising a notarized build.

## Verification

- Follow-up interaction changes make launch and reopen quiet, start selection in
  region mode, and dismiss the selector on a repeated capture shortcut or app switch.
  Readiness is created only when explicitly needed.
- Permission recovery now offers Settings, Check Again, the exact app location,
  and Restart whenever blocked. Denied ScreenCaptureKit operations cancel pending
  work and override stale allowed status. Local ad-hoc builds still need a stable
  signing certificate to preserve permission grants across executable changes;
  this Mac had no valid code-signing identities when checked.
- 40 XCTest tests passed after the Swift changes, including permission request,
  denial, recovery, no automatic capture on approval, quiet launch/reopen,
  region-first selection, Escape cancellation, native keyboard event
  dispatch, menu behavior, OCR, image operations, file promises, and share data.
- Shell syntax and Git whitespace checks passed.
- The Universal 2 app and ZIP were built successfully with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools` and
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` using
  `./build-app.sh`. Both the main executable and login helper contain arm64 and
  x86_64 code.
- After the separate test and build runs, the remaining `qa.sh` checks passed:
  archive integrity, property lists, version/identity matching, architectures,
  hardened-runtime signatures, nested signing, and executable self-checks.
- Opened the packaged app with the repository's Readiness image using
  `--open-image`. Checked the default and narrow layouts, unavailable Undo/Redo,
  Rotate Left, keyboard Undo restoring the original dimensions, and the text
  annotation shortcut. Closed the temporary app instance afterward.
- Verified the rebuilt app's Settings menu opens permission recovery, including
  Check Again, Show This Copy in Finder, Settings, and Quit & Reopen. Check Again
  kept the window idle. Clicking Quit & Reopen replaced the process and launched
  the app without the test-image argument. Native hotkey automation did not
  establish a capture result; actual permission approval and capture remain
  unverified on this build.
- The ordinary `./qa.sh` invocation is blocked by this Mac's unaccepted Xcode
  license. No license acceptance or global developer-directory change was made.
- Tests were built with the installed Command Line Tools and macOS 26.5 SDK,
  linking Xcode's installed XCTest framework and Swift overlay, then run directly
  with Xcode's `xctest` runner. This was a serial XCTest run; the normal parallel
  SwiftPM invocation still needs verification with a fully configured Xcode.

Live screen capture, permission changes, login registration, and notarization are
not established by these automated checks.

## Requested feature follow-up

Implemented the ten requested additions: configurable capture destinations with
copy-only defaults, an optional nonactivating thumbnail, a visual session picker,
precision selection and size presets, cross-display selection, reviewed redaction
suggestions and drawn masks, PNG/JPEG export controls, screenshot composition,
pin controls, and editable plain/table/code OCR previews. README, DESIGN, and
PRIVACY describe the resulting behavior and limits.

- 60 tests pass, including coordinator delivery for copy-only mode, preserving a
  newer clipboard owner, withholding review-mode images from clipboard/Recents,
  physical-pixel selection, mixed-scale composition and transparent display gaps,
  export dimensions/transparency, composition ordering and limits, redaction
  pixels, table/code formatting, and new-window layout constraints. Applying masks
  to an editor does not supersede an unrelated pending clipboard delivery.
- Inspected all seven new window types with synthetic images. Verified that
  export and thumbnail windows keep their intended widths and pin sliders remain
  usable. Image content does not force these windows to expand to capture size.
- The final Universal 2 app and ZIP passed the repository's remaining bundle QA:
  archive integrity, property lists, matching identities/versions, arm64 and
  x86_64 executables, hardened-runtime signatures, nested helper signing, and
  executable self-checks. Updated the self-check's expected export menu labels
  to match the new commands. Shell syntax and Git whitespace checks also pass.
- In the packaged app, verified Copy only and thumbnail-off defaults; opened the
  structured text preview and switched to tab-separated output; reviewed detected
  email and phone masks, applied them to the editor, and used Undo successfully.
  Also checked JPEG format selection and encoded-size feedback, plus resizing a
  reference pin with its zoom slider. OCR output remains an editable approximation
  and requires checking.
- Selection, clipboard, and image-processing tests do not establish real
  multi-monitor event delivery or ScreenCaptureKit permission recovery on physical
  displays. Those desktop acceptance checks still require granted permission and
  appropriate display hardware. Display slices are acquired sequentially.
- Developer signing remains pending: no valid signing identity was available and
  Xcode requires license acceptance. The build script can use a locally saved
  identity once one exists; current artifacts remain ad-hoc signed.

## Feature review corrections

Addressed all five findings from the follow-up review:

- Preserve saved shortcut assignments when new default keys collide on upgrade.
  Conflicting defaults stay unassigned until changed or reset.
- Convert window-local pointer coordinates before hit-testing desktop-relative
  window frames, including when asynchronous window discovery finishes after Space.
- Clear preset hover selections when entering window mode. A click selects the
  highlighted window; an actual drag still selects a region.
- Align fixed-size selection origins to output pixels, including Space moves,
  so odd-sized presets do not gain a pixel when cropped from a frozen image.
- Open a recovery editor if a newer clipboard owner prevents delivery and the
  image cannot fit in Recents. Successful clipboard-only captures remain quiet.

All 68 tests pass. Eight new regression tests exercise shortcut migration/reset,
offset display bounds with native selection events, window snapping with presets,
actual frozen-image crop dimensions at 1×/2× and display edges, and the coordinator's
over-budget recovery path using an isolated pasteboard. Physical multi-monitor
event delivery and Screen Recording permission recovery remain unverified.

The rebuilt Universal 2 app and ZIP pass archive integrity, bundle metadata,
both architecture checks, hardened-runtime signatures, nested helper signing,
and executable self-checks. Shell syntax and Git whitespace checks pass. Tests
used the same Command Line Tools/XCTest workaround described above; these checks
do not establish Developer ID signing or notarization.
