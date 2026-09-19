# Working in DJI Mic Remote

Read [README.md](README.md) for setup, runtime behavior, source map, troubleshooting, and validation commands. This is a native Swift/AppKit executable built with SwiftPM. Use native macOS frameworks; do not add CI, workflows, dependency managers, or speculative abstractions.

## Runtime and UI

- Flow routes receiver presses to Flow’s hands-free shortcut. Local owns capture, Parakeet inference, history, and text delivery. Local recordings never go to a cloud service.
- Keep the menu-bar slot fixed-width with one outlined wireless mic and small state badges. The compact Local panel keeps microphone selection and Auto-send visible. History is one scrolling list; transcript outcomes/recovery belong there, not in expanding Options or main-panel recovery buttons. Surface blocking unsaved history; keep licenses in About.
- Launch paused. Changing engines or changing/resetting shortcuts requires Start remote. One explicit start request handles preparation and continues after permission grants; cancellation prevents late enablement. Keep Parakeet warm across pause/resume.
- Check recording permissions before model loading. History retries need no microphone permission. Open Accessibility Settings directly after closing app panels, without AX’s system alert. Keep missing-entry recovery available; cached “prompted” state does not prove listing. Explain removing/re-adding stale enabled entries. Watch grants while a start request is pending, even with the menu closed; stop when it ends. Passive denied checks never open windows.

## Text delivery

- Save transcripts before delivery. Cancellation, engine changes, disconnect, disable, and quit prevent late insertion and preserve recoverable audio.
- Restore only the editor displaced by the popover; deliberate app switches and opening History/Settings take precedence. Recovery returns to a remembered editor without a countdown or Auto-send.
- Use clipboard-first Command–V in the active keyboard layout. `AXSelectedText` can acknowledge a no-op. Preserve every clipboard item/type or leave it untouched; never overwrite a newer user copy. Keep clipboard restoration independent of editor read-back and retain upstream paste notices.
- Allow opaque editors, scoped to the captured app/window/focus. Reject known secure/read-only controls. A posted paste without AX confirmation is not automatically a failed paste; only exact text/caret read-back earns verified insertion. Clipboard reads and event posting do not prove insertion or message delivery.
- Auto-send is opt-in and Local-only. Require settled clipboard consumption or exact read-back, then recheck app/window/focus, available caret, cancellation, and held modifiers before one Return. Unreadable AX text alone must not block it. Read hardware modifier state: combined session state includes the injected Command–V.
- Distinguish missing AX readings from known destination changes. Retry missing field/window/caret readings within a bounded wait without repasting or restoring the clipboard early. Preserve the post-paste caret/text baseline across retries; actual changes and cancellation are terminal. Keep diagnostic reasons specific and never log transcript contents.

## Models, data, and devices

- Pin FluidAudio, disable optional traits, and verify model revisions/per-file checksums before loading. Preserve upstream/conversion licenses. Keep weights, recordings, and signing keys out of Git.
- Keep recordings private, bounded, and recoverable. Preserve optional history metadata and saved-shortcut `directHIDUsage`; these support existing data, not dead code.
- Match the receiver by vendor/product. Never install global HID mappings or overwrite existing mappings. Unknown parser output is failure. Verify installation/cleanup by read-back; cleanup requires the exact mapping and registry service IDs owned by this process.
- Keep detection event-driven. Invalidate queued presses on disconnect/disable; after event-tap interruption, wait for release. Balance injected key/modifier releases on cancellation, disable, disconnect, and quit while preserving physically held modifiers.
- Read Flow’s existing hands-free binding without silently replacing custom shortcuts. Its private schema must fail closed when unknown/inconsistent. Explicit setup stops Flow, privately backs up settings, preserves bindings, checks concurrent edits, writes atomically, and verifies read-back. Test only with temporary settings fixtures.

## Validation and shipping

- Run the README’s release build, `swift test`, and signature verification after source/build changes. For documentation-only changes, check links/commands. Tests must inject mapping commands, recording, recognition, target capture, and event posting; never write real mappings or post real keys. Model tests require an explicit audio fixture.
- Do not launch or post keys merely to validate a build. Report hardware/permission/reconnect/hold/shortcut behavior as tested only when physically observed; automated checks cannot establish it.
- Stage bundles, verify signatures, and refuse to replace a running app. Reuse configured signing identity; never silently downgrade to ad-hoc or weaken the designated requirement to an identifier alone. Trust changes require approval; personal keys remain outside Git.
- Keep generated `.build/` and `build/` output out of Git. Preserve LICENSE and attribution. README is the current agent reference, not a dated work log; maintenance rules belong here.
- Report changes, checks actually run, and limitations. Claim a clean GitHub state only after committing and pushing.
