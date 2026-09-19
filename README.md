# DJI Mic Remote

Native macOS menu-bar app that turns the DJI receiver button into dictation control. Choose **Wispr Flow** or **Local · Parakeet**, then press once to start and again to finish.

| Mode | Transcription | Text delivery and history |
| --- | --- | --- |
| **Wispr Flow** | The remote triggers Flow’s existing hands-free shortcut. Flow handles audio and transcription. | Flow handles insertion and keeps its own history. |
| **Local · Parakeet** | DJI Mic Remote records the selected input and transcribes English on this Mac. Wispr Flow is not required. | Pastes into the focused editor while preserving your clipboard. Includes optional Auto-send, saved transcripts, playback, retranscription, and recovery Paste. |

Local audio is never uploaded. Parakeet runs on Apple Silicon; its verified model downloads on first use or can be bundled for offline setup. **Auto-send** optionally presses Return after Local dictation; it is off by default and never runs during history recovery.

Agent entry point: read [AGENTS.md](AGENTS.md) for maintenance rules. This README covers [building](#build-and-install), [setup](#setup-and-controls), [permissions](#permissions), [delivery](#local-insertion-and-auto-send), [recovery](#history-and-recovery), and [validation](#validation).

## Build and install

Requirements: macOS 14+, Swift 6.2+ / Xcode Command Line Tools. Local inference requires Apple Silicon and roughly 614 MB of model assets plus runtime memory. The supported receiver identity is DJI USB vendor `11427`, product `16401`; other receivers/firmware are unverified. Wispr Flow is required only for Flow mode.

```sh
git clone https://github.com/filip-pilar/dji-mic-remote.git
cd dji-mic-remote
bash build.sh
open "build/DJI Mic Remote.app"
```

Quit DJI Mic Remote before building. `build.sh` stages the bundle, verifies its signature, and refuses to replace a running app. Keep the install at a stable path. Builds use `SIGNING_IDENTITY`, the configured local identity, or ad-hoc signing when neither exists. Ad-hoc rebuilds can invalidate privacy grants; see [signing](#signing-and-permission-identity). There is no notarization, auto-update, or launch-at-login integration.

## Setup and controls

The app launches paused. Choose **Wispr Flow** or **Local**, select a microphone for Local, and click **Start remote**. Grant the requested permissions; the same start request continues automatically. When it shows **Ready to dictate**, focus an editor and press the receiver button once to start, once to finish. **Pause remote** disables receiver control.

- **Wispr Flow:** the app reads Flow’s compatible hands-free binding. If offered, **Set up Flow & start** quits Flow, privately backs up its settings, adds a nonconflicting binding, verifies the write, and reopens Flow. Finish Flow’s onboarding and select your DJI audio input in Flow (observed name: `Wireless Mic Rx (USB)`).
- **Local:** microphone selection and Auto-send stay visible. A connected DJI input is suggested when no input is saved. Choose a microphone if prompted; the same start request continues. Startup checks Accessibility and microphone permission before downloading/loading Parakeet. Preparation is automatic. The model stays warm across pause/resume and later recordings; relaunching loads it again from disk.
- **History…:** Local transcripts, delivery details, Copy, recovery Paste, playback, and retry. The main panel/icon show current readiness; a blocking save failure shows **Open History…**.
- **Shortcut settings…:** Flow’s binding, diagnostics, and optional manual recording. Disable **Follow Flow’s shortcut automatically** to record a custom binding, then match it in Flow. Changing/resetting shortcuts or switching engines pauses the remote. **Test in 3 seconds** emits a Flow shortcut for manual testing; **Cancel test** cancels it.
- **About → Licenses…:** bundled model, dependency, and paste implementation notices. **Quit** exits; closing panels leaves the app running.

Pause before changing microphones. A missing saved device is never silently replaced. **Finish & save** in the Local menu transcribes to History without inserting; finishing with the receiver button uses normal insertion. Recording is limited to five minutes.

The menu-bar slot is always 36 points wide. Its outlined wireless microphone stays consistent: red dot = recording, centered ring = work in progress, amber = permission/connection/unsaved-history issue, brief green check = transcript saved locally. The check does not prove insertion. Paused dims the mark; Reduce Motion disables ring animation.

## Permissions

Accessibility Settings opens directly after the app’s panels close; the app does not also request an AX system alert. Enable DJI Mic Remote, or add it with **+** if absent. **Already enabled or missing?** explains recovery; **Show this app in Finder** reveals the running bundle. If access remains denied despite an enabled entry, remove that stale entry with **−**, add the current bundle with **+**, and enable it. Toggling an old entry does not repair a changed code identity.

An explicit start request watches for permission grants even with the menu closed and continues automatically. Passive checks never reopen Settings. **Cancel setup**, engine changes, or quitting prevent late enablement and stop the watcher. Microphone denial leaves an explicit Settings action instead of immediately opening another window. Flow and History retranscription do not request microphone permission.

## Local insertion and Auto-send

Opening/closing the popover restores only the editor it displaced. Deliberate app switches and opening History/Settings take precedence. A receiver press closes the popover and allows focus to return before capturing or using the target.

Delivery saves the transcript first, then checks the captured app/window/field and available selection. Secure Input, protected/read-only fields, changed targets, and held modifiers block delivery. Opaque editors need not expose AX text. [Electron’s AXManualAccessibility opt-in](https://www.electronjs.org/docs/latest/tutorial/accessibility#within-third-party-software) prepares supported editors; initial target capture retries briefly within the original app.

The shared paste implementation:

1. Snapshots every clipboard item/type. If a representation cannot be preserved, or another copy arrives during the snapshot, it leaves the clipboard untouched.
2. Publishes temporary, transient/concealed text and posts one balanced Command–V pair using the active keyboard layout. It never writes `AXSelectedText`, which can acknowledge a write without inserting text.
3. Restores the original clipboard after consumption settles, with a three-second wait bound. A newer user copy is never overwritten. Restoration is independent of editor read-back.
4. Reports **Inserted** only for exact text/caret read-back; otherwise it reports **Paste sent**. Clipboard consumption and key posting are not proof of insertion. There is no automatic second paste.

Pinned upstream references and MIT notices are bundled in [Resources/Licenses](Sources/DJIMicRemote/Resources/Licenses/PasteReferences.txt): Maccy event delivery, Handy clipboard transactions, and OpenWhispr keyboard-layout resolution. No extra package is required.

**Auto-send** is saved, Local-only, and off by default. New dictation attempts one plain Return after clipboard consumption settles for 350 ms or exact AX read-back confirms insertion. After restoration it waits another 200 ms and rechecks destination, available caret, cancellation, and hardware modifiers. Unreadable text contents alone do not block it. The result is **Paste and Return sent**, not confirmed message delivery; Return may submit or add a newline depending on the editor. History pastes/retries never auto-send; Flow retains its own behavior.

Missing AX field/window/caret readings get a bounded retry, up to three seconds before Return. They do not trigger early clipboard restoration. Actual destination changes, protected controls, edits, cancellation, held modifiers, or absent paste-consumption/verification stop Auto-send. History distinguishes these reasons. The synthetic Command–V is excluded from held-modifier checks; only hardware state is used.

## History and recovery

History is one scrolling list of selectable transcript cards. Long text expands in place. Each card offers **Copy**, **Paste to [app]** when an editor is remembered, **Play/Stop**, and **More → Transcribe again / Retry saving / Delete**. Previous text versions remain selectable. Delivery details belong to their transcript.

Recovery Paste returns to the editor focused before opening the DJI UI, rechecks focus/caret, and pastes once without a countdown or Return. If the destination changed, use Copy and normal ⌘V. Retrying transcription automatically loads the model if needed, preserves prior text, clears the old delivery outcome on successful recognition, and never inserts automatically. Flow history stays in Flow.

Data lives in `~/Library/Application Support/DJI Mic Remote/History/`: directory mode 0700, audio/metadata mode 0600, atomic JSON writes. Audio older than seven days expires at launch, before recording, and during hourly idle cleanup; text remains until deleted. Delete removes audio and all transcript versions. Interrupted sessions can be retried, though damaged/incomplete audio may be unrecoverable. Save failures retain text in memory for Copy/Retry saving, block automatic delivery, and warn before quitting. Keep the app open until unsaved text is recovered.

Disable, disconnect, engine/input changes, event-tap interruption, and quit cancel pending work and preserve recoverable audio. Core ML cancellation can wait for an inference call to finish, but its late result cannot trigger insertion. Local does not provide Flow’s rewriting, multilingual recognition, or spoken “press Enter” commands.

## Signing and permission identity

macOS grants access to a code-signing requirement, not merely an app name/path. Reuse an existing Apple identity with `SIGNING_IDENTITY="certificate name or SHA-1" bash build.sh` and optional `SIGNING_KEYCHAIN`. Without one, this explicit, one-time command creates a persistent personal development identity:

```sh
python3 scripts/setup-local-signing.py
```

Agents must obtain approval before running it: it creates a private key/keychain, preserves and extends the user keychain search list, and adds user-domain trust restricted to code signing by `/usr/bin/codesign`. It does not change SSL/system trust, Gatekeeper, or TCC grants. Files stay private under `~/Library/Application Support/DJI Mic Remote/Signing/`, outside Git. Configured signing failures stop the build rather than silently switching to ad-hoc. Migration from ad-hoc signing needs the Accessibility entry replaced once as described above. Do not distribute the personal identity or treat self-signing as Developer ID/notarization. [Apple: stable code identity](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Model packaging

`Package.resolved` pins FluidAudio to `b68f484789d81fda21efbf81e2ca9fcfd9dc22aa`; optional traits are disabled. [ModelManifest.json](Sources/DJIMicRemote/Resources/ModelManifest.json) pins the Core ML conversion revision and every offline INT8 asset’s size/SHA-256. Downloads use revision URLs and verify before installation; inference never uses the SDK’s unpinned downloader. Verified files survive cancellation.

The default build downloads on first Local start or History retry into `~/Library/Application Support/DJI Mic Remote/Models/<revision>/`. To bundle already downloaded assets for offline use:

```sh
PARAKEET_MODEL_DIR="/absolute/path/to/verified-model-directory" bash build.sh
```

Python 3 is required for packaging. The script verifies every file before copying. Weights never enter Git. A damaged bundled model fails closed. Preserve FluidAudio’s Apache-2.0 license, dependency notices, NVIDIA Open Model License/Notice, and the conversion’s CC BY 4.0 attribution; the conversion license does not replace NVIDIA’s terms.

## Runtime map and troubleshooting

All source paths below are under `Sources/DJIMicRemote/`.

| Files | Responsibility |
| --- | --- |
| `DJIMicRemoteApp.swift`, `Remote.swift` | App entry point, shared controller state, lifecycle, engine switching |
| `RemoteUI.swift`, `MenuFocus.swift` | Native panels, state presentation, focus restoration |
| `RemoteStartup.swift` | Start/stop coordination, permission requests and grant monitoring |
| `RemoteFlow.swift`, `RemoteReceiver.swift` | Flow setup/shortcut controls, receiver event routing |
| `LocalDictation.swift`, `LocalHistory.swift`, `HistoryWindow.swift` | Recording lifecycle, durable history, retries, recovery UI |
| `AudioCapture.swift` | UID-selected AVCaptureSession, serial PCM writing, interruption handling |
| `ModelAssets.swift` | Pinned downloads, checksums, warm Parakeet inference |
| `TextDelivery.swift`, `ClipboardPaste.swift`, `AutoSend.swift` | Target guards, clipboard preservation, read-back, optional Return |
| `FlowSettings.swift`, `ShortcutEmitter.swift` | Flow bindings/setup and balanced key emission |
| `ReceiverMonitor.swift`, `ReceiverMapping.swift`, `ButtonPress.swift` | Device events, owned HID mapping, press/release/debounce |
| `MenuBarIcon.swift` | Fixed-width microphone and state badge |

Flow’s private settings schema was inspected in version 1.6.827: `~/Library/Application Support/Wispr Flow/config.json`, `prefs.user.shortcuts` maps keycode combinations to actions (`popo` = hands-free), and `prefs.cache.splitKeybinds` must agree. Unknown/inconsistent schemas fail closed; use Shortcut settings for manual bindings. Setup adds at most one nonconflicting binding, preserves the four-binding limit and unrelated settings, checks for concurrent writes, and verifies read-back. Private backups live under `~/Library/Application Support/DJI Mic Remote/Flow Backups/`; quit Flow before restoring one. Normal detection never writes settings. Fn/Globe, right-side modifiers, Caps Lock, mouse buttons, and F18 are unsupported for automatic shortcut emission. Release all modifiers to finish recording a modifier-only binding; Escape or focus loss cancels.

Receiver Consumer Volume Up (`0xC000000E9`) maps to F18 (`0x70000006D`, keycode 79). F18 is reserved globally while active. Held presses trigger once; Flow emission uses a 120 ms press and 350 ms debounce. Hold-to-talk is unsupported. Modifiers already held by the user are preserved. Device detection is event-driven, and tap recovery waits for release.

Existing nonempty/unreadable HID mappings block setup. Close other receiver remappers; installation and cleanup require exact read-back and matching registry service IDs. Changed mappings are left untouched. Concurrent remappers remain unsupported because hidutil reads/writes are not atomic. After a crash or failed cleanup, reconnect the receiver; never reset mappings for every keyboard.

Audio capture never switches the system-default microphone. PCM format comes from the first buffer, and stop drains/closes the file before recognition. Device loss, capture errors, and format changes save audio without delivery. No audio within five seconds interrupts recording. Metadata-only diagnostics use log subsystem `com.phil.dji-mic-remote`, categories `AudioCapture` and `TextDelivery`; never log transcript contents.

## Validation

```sh
bash build.sh
swift test
codesign --verify --deep --strict "build/DJI Mic Remote.app"
```

Tests are grouped by component, with shared recording/recognition fakes and an async wait helper in `Tests/DJIMicRemoteTests/TestSupport.swift`. They use fake target capture, keyboard posting, and mapping commands; Flow settings use temporary fixtures. They do not remap hardware, post real keys, or edit user settings. There is no CI.

Optional offscreen UI and real-model validation use explicit fixtures only:

```sh
say -o /tmp/dji-fixture.aiff 'Testing the wireless microphone. This recording stays on my computer.'
DJI_MODEL_SMOKE_DIR="/absolute/path/to/verified-model-directory" \
DJI_MODEL_SMOKE_AUDIO=/tmp/dji-fixture.aiff \
DJI_UI_SNAPSHOT_DIR=/tmp/dji-ui swift test
```

The model fixture expects “microphone” and “recording”; optional checks skip without their environment variables. Generated speech validates inference, not real microphone quality. Physical receiver start/stop, permissions, reconnect, held buttons, Flow delivery, and cross-app insertion require observed manual checks; a passing build/test suite does not establish those results.

MIT: [LICENSE](LICENSE). Original architecture reference: [bdsqqq/dots DJI module](https://github.com/bdsqqq/dots/tree/main/modules/dji-mic).
