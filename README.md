# DJI Mic Remote

Native macOS menu bar app that maps a DJI Mic Series Mobile Receiver button to Wispr Flow hands-free dictation. It detects Flow’s shortcut automatically and sends keyboard events; Flow handles audio and transcription. No network client or external package dependencies.

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

1. Click the wireless-mic icon. Controls open directly beneath it. Flow’s existing compatible hands-free shortcut is detected automatically; no manual matching is needed.
2. If offered, use **Set up Flow (restarts Flow)**. This quits Flow normally, backs up its settings, adds an unused compatible hands-free binding, verifies the saved file, and reopens Flow. Existing bindings remain. Finish Flow’s own onboarding first.
3. Choose the DJI audio input in Flow (observed name: `Wireless Mic Rx (USB)`).
4. Grant DJI Mic Remote Accessibility access, then enable the remote. It launches disabled. Enabling opens Flow in the background if needed.
5. In a blank document, press the receiver button, speak, press again, and verify Flow inserts the text. The app's “Sent” diagnostic only confirms event posting.

**Details…** contains diagnostics and **Test in 3 seconds**, which posts the selected shortcut after a delay; **Cancel test** cancels a pending test. For manual compatibility, turn off **Follow Flow’s shortcut automatically**, then use **Change…** to record Control/Option/Shift/Command alone or with a regular key; match that binding in Flow. Release all modifiers to save a modifier-only combination. **Cancel recording**, Escape, or loss of focus cancels. Fn/Globe, right-side modifier bindings, Caps Lock, mouse buttons, and F18 are not automatically emitted. Setup can add a separate compatible binding while keeping these bindings intact. Changing/resetting a shortcut or switching modes disables the remote. Existing saved custom shortcuts are retained. Closing the popover/details leaves the app running; use Quit to exit.

## Flow integration

`FlowSettings.swift` reads only shortcut fields from `~/Library/Application Support/Wispr Flow/config.json`: `prefs.user.shortcuts` maps macOS keycode combinations to actions; `popo` means hands-free. Its cached `prefs.cache.splitKeybinds` must agree. This private format was inspected in installed Flow **1.6.827**, not a supported public settings API. Missing/unrecognized settings fail closed; manual mode remains available in Details. The app rechecks settings on opening controls, enabling, and before delivery. A changed/unreadable binding or Flow quitting disables automatic mode’s remote delivery and requires re-enabling.

Automatic setup runs only from the explicit setup button, with Flow stopped. It adds at most one nonconflicting binding (preferring `⌃⌥⌘`, then combinations using F20), preserves other settings and the four-binding limit, checks for concurrent changes before writing, writes atomically, and reads back. Backups are private files under `~/Library/Application Support/DJI Mic Remote/Flow Backups/`. If recovery is needed, quit Flow and restore the appropriate backup before reopening it. Do not edit Flow’s store concurrently; there is no cross-process transaction with Flow. Normal automatic detection never writes Flow’s settings.

The installed Flow also handles `wispr-flow://start-hands-free` and `wispr-flow://stop-hands-free`. Its handler has no corresponding toggle/status operation; blindly alternating links would lose synchronization when dictation stops elsewhere. The app uses Flow’s own hands-free shortcut to let Flow determine start versus stop.

## Runtime and recovery

- `Sources/DJIMicRemote/DJIMicRemoteApp.swift`: direct menu bar popover, optional custom shortcut recording/persistence, event tap, and lifecycle coordination.
- `FlowSettings.swift`: strict automatic binding detection and backed-up, conflict-aware offline setup.
- `ReceiverMonitor.swift`: IOKit arrival/removal callbacks; no polling timer and no exclusive device access.
- `ReceiverMapping.swift`: strict mapping parser, installation/read-back, and cleanup ownership by registry service ID.
- `ButtonPress.swift`: press/release state and monotonic debounce.
- `ShortcutEmitter.swift`: complete key/modifier sequences, delayed release, and cancellation.
- `MenuBarIcon.swift`: native vector wireless-mic template. A filled mic means Ready; an outline means inactive. The tooltip and accessibility value distinguish Off, Waiting for receiver, and Ready.
- Receiver-scoped Consumer Volume Up (`0xC000000E9`) maps to F18 (`0x70000006D`, keycode `79`). A session event tap consumes it and posts the shortcut with a 120 ms press and 350 ms debounce. Receiver arrival/removal notifications replace the two-second polling loop. A held button triggers once until released, even if repeated downs lack the autorepeat flag.
- F18 is reserved globally while active. Hold-to-talk is unsupported. Already-held modifiers are preserved; a fully held modifier-only shortcut must be released before triggering. Every down and release event is allocated before posting, and disable/disconnect/quit releases any pending chord. Event-tap recovery waits for a button release before accepting another press.
- Existing nonempty mappings and unreadable mapping output block setup. Disable Computah's DJI control and other remappers first. Installation must read back the exact expected mapping before becoming Ready. Cleanup re-reads the mapping and only clears an exact match on the same registry services, then verifies removal. Changed/unreadable mappings are left untouched and reported. Concurrent remappers remain unsupported: hidutil read/write operations are not atomic.
- Normal disable/quit removes the mapping. After a crash, force quit, or failed cleanup, reconnect the receiver. Do not reset mappings for all keyboards.
- “Ready” requires receiver detection and successful setup; failed delivery usually needs Accessibility to be refreshed or the Flow shortcut to be matched.

## Validation

```sh
bash build.sh
swift test
codesign --verify --strict "build/DJI Mic Remote.app"
```

SwiftPM tests cover mapping formats/ownership/read-back failures, device identity changes, button hold/bounce/recovery, shortcut ordering, modifier preservation, cancellation, allocation failures, saved-shortcut compatibility, and Flow settings parsing/setup/backup/concurrent-change guards. Mapping commands and event posting are replaced by test doubles; Flow setup tests use temporary fixtures. Tests do not remap devices, send keys, or edit real Flow settings. There is no CI.

Historical hardware validation confirmed Control–Option–F20 through Flow. Automatic detection was checked against the installed Flow configuration; its existing `⌃⌥⌘` binding required no write. The setup writer was tested on fixtures, not by changing the user’s working Flow settings. Permission behavior, modifier-only delivery, arrival/removal, reconnect, and button-holding behavior still require a physical end-to-end check. Build/parser success does not establish those results. For changes to shortcut emission, verify record/cancel/reset, delayed delivery, physical button start/stop, and cleanup with the real receiver and Flow.

MIT: [LICENSE](LICENSE). Architecture reference: [bdsqqq/dots DJI module](https://github.com/bdsqqq/dots/tree/main/modules/dji-mic); this is a standalone Swift implementation.
