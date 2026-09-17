# Working in DJI Mic Remote

Read README.md for installation, runtime behavior, troubleshooting, and validation commands. This is a small native Swift/AppKit executable, built and tested with SwiftPM; there are no external package dependencies.

## Changes

- Keep the app focused on receiver-button → keyboard-shortcut delivery. Audio/transcription belong to Flow.
- Match the receiver by vendor/product; never install global HID mappings or overwrite an existing mapping. Treat unknown parser output as a failure, not an empty mapping. Verify installation and cleanup with read-back; cleanup requires the same mapping and registry service IDs owned by this process.
- Preserve saved shortcut decoding, including the `directHIDUsage` field used to migrate legacy settings. It is compatibility data, not unused code.
- Keep shortcut key-down/up and injected modifier release balanced across cancellation, disable, disconnect, and quit. Preserve modifiers the user already holds.
- Keep receiver detection event-driven. Invalidate queued button actions on disconnect/disable and wait for release after event-tap interruption.
- Keep the launch-disabled behavior and explicit re-enable after changing/resetting shortcuts.
- Prefer reading Flow’s existing hands-free binding. Do not silently replace a custom shortcut or edit Flow’s settings during normal detection.
- Flow’s settings format is private: reject unknown/inconsistent schemas. Setup must stop Flow, preserve existing bindings, back up privately, check for concurrent changes, write atomically, and verify read-back. Test with temporary fixtures, never real user settings.
- Use native macOS frameworks. Do not add CI, workflows, dependency managers, or speculative abstractions unless explicitly requested.
- Keep README.md an agent setup/reference entry point. Update current behavior and limitations instead of appending dated work logs. Keep maintenance rules here; avoid duplicating the README.

## Validation and delivery

- Run the README's release build, `swift test`, and signature verification after source/build changes. Documentation-only edits need link/command consistency checks.
- Tests must inject fake mapping commands and event-posting closures; never use real hardware writes or keyboard delivery in unit tests.
- Do not launch the app or post keys merely to validate a build; those actions can affect the user's active apps and receiver mapping.
- Hardware claims require observed physical receiver/Flow results. Report untested permission, reconnect, hold, and shortcut behavior explicitly.
- Keep generated `.build/` and `build/` output out of Git. Preserve LICENSE and reference attribution.
- Report changes, checks actually run, and remaining limitations. Do not claim a clean GitHub state until changes are committed and pushed.
