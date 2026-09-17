# DJI Mic Remote

Native macOS menu bar app that maps a DJI Mic Series Mobile Receiver button to a configurable Wispr Flow hands-free shortcut. It sends keyboard events; Flow handles audio and transcription. No network access or external package dependencies.

Agents receiving this repository link: use the setup below to install/configure the app. Read [AGENTS.md](AGENTS.md) before changing code.

## Requirements and setup

- macOS 13+, Xcode Command Line Tools (`xcode-select -p`, `swift --version`).
- DJI Mic Series Mobile Receiver: USB vendor `11427`, product `16401`. Other receivers/firmware are unverified.
- Wispr Flow installed for the intended dictation workflow.

```sh
git clone https://github.com/filip-pilar/dji-mic-remote.git
cd dji-mic-remote
bash build.sh
open "build/DJI Mic Remote.app"
```

The script creates an ad-hoc-signed app. Keep it at a stable path; rebuilding may require removing/re-adding its Accessibility permission. There is no installer, notarization, auto-update, or launch-at-login integration.

1. In Flow's hands-free shortcut settings, record the same shortcut shown by DJI Mic Remote. The default is Control–Option–Command (`⌃⌥⌘`); existing saved shortcuts are retained.
2. Choose the DJI audio input in Flow (observed name: `Wireless Mic Rx (USB)`).
3. Grant DJI Mic Remote Accessibility access, then enable the remote. It launches disabled.
4. In a blank document, press the receiver button, speak, press again, and verify Flow inserts the text. The app's “Sent” diagnostic only confirms event posting.

Use **Change…** to record Control/Option/Shift/Command alone or with a regular key. Release all modifiers to save a modifier-only combination. Escape or loss of focus cancels. Fn/Globe, Caps Lock, mouse buttons, and F18 are unsupported. Changing/resetting a shortcut disables the remote. **Test in 3 seconds** posts the selected shortcut after a delay. Closing windows leaves the menu bar app running; use Quit to exit.

## Runtime and recovery

- `Sources/DJIMicRemote/main.swift`: AppKit UI, persisted shortcut, receiver detection, `hidutil`, event tap, shortcut emission.
- `Sources/DJIMicRemote/MappingOutput.swift`: conservative parser for `hidutil` mapping output.
- Receiver-scoped Consumer Volume Up (`0xC000000E9`) maps to F18 (`0x70000006D`, keycode `79`). A session event tap consumes it and posts the shortcut with a 120 ms press and 350 ms debounce. Detection refreshes every two seconds.
- F18 is reserved globally while active. Hold-to-talk is unsupported. Already-held modifiers are preserved; a fully held modifier-only shortcut must be released before triggering.
- Existing nonempty mappings and unreadable mapping output block setup. Disable Computah's DJI control and other remappers first. Do not change mappings from another tool while enabled: cleanup clears the receiver mapping this app installed without rechecking its contents.
- Normal disable/quit removes the mapping. After a crash, force quit, or failed cleanup, reconnect the receiver. Do not reset mappings for all keyboards.
- “Ready” requires receiver detection and successful setup; failed delivery usually needs Accessibility to be refreshed or the Flow shortcut to be matched.

## Validation

```sh
bash build.sh
swiftc Sources/DJIMicRemote/MappingOutput.swift Tests/MappingChecks.swift -o /tmp/dji-mapping-checks
/tmp/dji-mapping-checks
codesign --verify --strict "build/DJI Mic Remote.app"
```

The standalone runner covers nine mapping-parser cases; it is not a SwiftPM test target. There is no CI.

Historical hardware validation confirmed Control–Option–F20 through Flow. The current modifier-only default, receiver reconnect, and button holding still require a physical end-to-end check. Build/parser success does not establish those results. For changes to shortcut emission, verify record/cancel/reset, delayed delivery, physical button start/stop, and cleanup with the real receiver and Flow.

MIT: [LICENSE](LICENSE). Architecture reference: [bdsqqq/dots DJI module](https://github.com/bdsqqq/dots/tree/main/modules/dji-mic); this is a standalone Swift implementation.
