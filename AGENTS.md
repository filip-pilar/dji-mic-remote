# Working in DJI Mic Remote

Read README.md for installation, runtime behavior, troubleshooting, and validation commands. This is a small native Swift/AppKit executable, built with SwiftPM; there are no external package dependencies.

## Changes

- Keep the app focused on receiver-button → keyboard-shortcut delivery. Audio/transcription belong to Flow.
- Match the receiver by vendor/product; never install global HID mappings or overwrite an existing mapping. Treat unknown parser output as a failure, not an empty mapping.
- Preserve saved shortcut decoding, including the `directHIDUsage` field used to migrate legacy settings. It is compatibility data, not unused code.
- Keep shortcut key-down/up and injected modifier release balanced across cancellation, disable, disconnect, and quit. Preserve modifiers the user already holds.
- Keep the launch-disabled behavior and explicit re-enable after changing/resetting shortcuts.
- Use native macOS frameworks. Do not add CI, workflows, dependency managers, or speculative abstractions unless explicitly requested.
- Keep README.md an agent setup/reference entry point. Update current behavior and limitations instead of appending dated work logs. Keep maintenance rules here; avoid duplicating the README.

## Validation and delivery

- Run the README's release build, parser checks, and signature verification after source/build changes. Documentation-only edits need link/command consistency checks.
- Do not launch the app or post keys merely to validate a build; those actions can affect the user's active apps and receiver mapping.
- Hardware claims require observed physical receiver/Flow results. Report untested permission, reconnect, hold, and shortcut behavior explicitly.
- Keep generated `.build/` and `build/` output out of Git. Preserve LICENSE and reference attribution.
- Report changes, checks actually run, and remaining limitations. Do not claim a clean GitHub state until changes are committed and pushed.
