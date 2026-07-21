# Security Policy

Screen-capture software handles sensitive pixels, clipboard content, and exported
files. Please report security problems privately and avoid attaching real private
captures when a synthetic image can reproduce the issue.

## Supported versions

Security fixes are made against the latest source and, after public releases
exist, the latest published release. Pre-1.0 builds may change quickly and should
not be assumed to receive long-term support.

## Report a vulnerability

Use the repository's **Security → Report a vulnerability** form (GitHub private
vulnerability reporting). Do not open a public issue for an unpatched security
problem.

If private vulnerability reporting is unavailable, contact the maintainer through
a private channel listed on the repository owner's GitHub profile. Include:

- the affected ScreenWren version or commit;
- macOS version and hardware architecture;
- clear reproduction steps using nonsensitive sample content;
- expected and observed security boundaries;
- whether the issue requires Screen Recording permission or user interaction; and
- any proposed mitigation, if known.

Do not send passwords, signing certificates, Apple credentials, private keys, or
unredacted personal captures.

## Relevant security boundaries

Reports are especially useful when they concern:

- capture occurring without an explicit user command;
- pixels outside the selected region or window entering output;
- redacted source pixels surviving in a flattened export;
- unexpected clipboard replacement or disclosure;
- unsafe handling of detected barcode/QR values or external URLs;
- hidden persistence of captures, OCR text, or window metadata;
- unsafe file export paths or file-promise behavior;
- permission, signing, update, notarization, or login-item integrity; or
- a path by which untrusted input can execute code.

Visual Blur is explicitly not a redaction feature. Reports that blur leaves visual
structure recoverable are expected behavior unless the UI presents it as secure.
Likewise, macOS clipboard history, Universal Clipboard, system swap, third-party
Share services, and DRM-protected capture behavior are outside ScreenWren's direct
control, though confusing or unsafe ScreenWren behavior around those boundaries is
still worth reporting.

## Disclosure process

Maintainers will confirm receipt when possible, investigate, and coordinate a fix
and disclosure based on severity and available release channels. No bug bounty or
fixed response-time commitment is currently offered. Please allow a reasonable
private remediation period before public disclosure.
