# ScreenWren Privacy

ScreenWren is designed to capture only when you invoke it and to process captures
on your Mac. It has no account system, advertising SDK, analytics SDK, telemetry
endpoint, or cloud service of its own.

## What ScreenWren accesses

| Data | Why it is used | Where it goes | Lifetime |
| --- | --- | --- | --- |
| Selected region or exact-window pixels | Create the delivered capture you requested | Process memory, then the system clipboard and editor for ordinary image capture | Until replaced, closed, evicted, or ScreenWren quits; clipboard lifetime is controlled by macOS and other apps |
| Current pointer-display pixels | Supply the selector's precision loupe or a frozen screen from which you select afterward | Process memory only; only the final selection is delivered | Current selector/capture operation |
| Visible window metadata | Highlight and capture an eligible window | Process memory only | Current selection/capture operation |
| Last repeat target | Repeat the last successful region or exact window; an exact-window target retains its window ID, process ID, and bundle ID | Process memory only | Until replaced, invalidated, or ScreenWren quits |
| Recognized text | Fulfill direct OCR and make editor text selection or Copy Text immediate; local editor analysis starts automatically for every opened image | Apple's on-device Vision/VisionKit processing; process memory, then the system clipboard only after an explicit copy | Until the image revision is replaced, its editor closes, or ScreenWren quits; copied text follows clipboard lifetime |
| Detected code values and bounds | Make Instant Inspect code actions immediate; local detection starts automatically for every opened image | Apple's on-device Vision processing; process memory, then the system clipboard after Copy or the default app after an explicit Open action | Until the image revision is replaced, its editor closes, or ScreenWren quits; ScreenWren does not persist or fetch the value |
| Foreground-subject analysis, mask, and image | Make Copy Subject available; local subject analysis starts automatically for every opened image | Apple's on-device VisionKit processing; process memory, then the system clipboard only after an explicit copy | Until the image revision is replaced, its editor closes, or ScreenWren quits; copied image data follows clipboard lifetime |
| Edited image data | Render Copy, Save, Drag, Share, or Pin | Destination explicitly chosen by the user | Depends on the chosen destination |
| Shortcut and readiness preferences | Remember the global keys and completed readiness setup you chose | The app's local macOS preferences domain | Until reset or the app's preferences are removed |

ScreenWren does not intentionally log captured pixels, recognized text, window
titles, or capture geometry, and does not write them to its own on-disk store.

Launch at Login registration is managed by macOS ServiceManagement. Enabling it
registers ScreenWren's bundled login item; it does not transmit account or capture
data.

## macOS permission

ScreenWren needs the macOS permission named **Screen & System Audio Recording**
to read screen pixels. ScreenWren captures still images only. It does not record
audio, request microphone access, or request Accessibility access.

macOS controls permission approval and may require ScreenWren to be relaunched
after a change. You can revoke access at any time in System Settings.

## Clipboard

An ordinary image capture writes the resulting image to the General pasteboard.
Direct OCR and editor copy actions write only after their result is ready.
ScreenWren checks for a newer clipboard owner before delayed work completes so it
does not intentionally overwrite newer content.

The clipboard is a macOS-wide service. Other apps, clipboard managers, Universal
Clipboard, and macOS itself may read, synchronize, or retain its contents. Those
behaviors are outside ScreenWren's control.

## Memory-only features

- Recents retain at most five captures and approximately 128 MB of pixel data.
- Pins retain at most five flattened images.
- Editors retain the image and Undo state needed for the open window.
- An active scrolling-capture session retains at most 20 frames and 256 MB of
  uncompressed pixel data until it is finished, cancelled, or ScreenWren quits.
- Recents, pins, open editors, repeat state, and active scrolling sessions disappear
  when the ScreenWren process exits.

Releasing memory is not a claim of forensic secure erasure from RAM, swap, crash
reports, or system snapshots.

## Files and sharing

ScreenWren writes image data to a user-visible destination only when you:

- confirm Save PNG;
- complete a PNG file drag; or
- choose a macOS Share service that persists or transmits the item.

ScreenWren does not keep a private export copy. Share services are provided by
macOS or other installed apps and are governed by their own privacy practices.

Local developer and QA commands may intentionally write build products, ZIP
archives, or explicit test captures under their documented output paths.

## Network access

ScreenWren has no application network client and does not upload captures. A Share
service chosen by the user may use the network. Opening a detected `http` or
`https` code delegates its URL to the user's default app, which may use the
network. ScreenWren does not fetch the URL first. Apple system frameworks and
macOS services remain subject to Apple's software and privacy terms.

## Changes and questions

Privacy-impacting changes should be called out in pull requests and in the
changelog. For a suspected security vulnerability, follow [SECURITY.md](SECURITY.md)
instead of posting sensitive capture data in a public issue.
