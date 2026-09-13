# DJI Mic Remote

Native macOS menu-bar MVP that maps the DJI Mic Series Mobile Receiver link-button event to a Wispr Flow hands-free shortcut. No audio processing, network requests, Raycast, Kanata, or Nix dependency.

## Build and run

Requires Xcode Command Line Tools and macOS 13+.

```sh
bash build.sh
open "build/DJI Mic Remote.app"
```

### Default and custom shortcuts

The default is **Control–Option–Command (⌃⌥⌘)**. Flow accepted this modifier-only combination in its shortcut settings. Playback from the remote still needs end-to-end validation; the previous Control–Option–F20 shortcut was confirmed working.

1. New installations start with the default. Existing saved shortcuts stay unchanged; click **Reset to default** to switch to Control–Option–Command.
2. In Flow → Settings → Shortcuts, add a shortcut under **Hands-free mode**. Press Control, Option, and Command together on your keyboard, then release them. The mic button is not needed for setup.
3. Grant Accessibility to DJI Mic Remote and enable it. Ad-hoc rebuilds may require removing and re-adding the permission entry.
4. Select **Wireless Mic Rx (USB)** as Flow’s microphone.
5. In a blank document, press the mic button, speak a harmless test phrase, and press again. Confirm Flow starts, stops, and inserts text. The delayed test button also sends the selected shortcut after three seconds.

**Change shortcut** supports Control, Option, Shift, and Command combinations, either alone or with a regular key. To record modifiers alone, press the combination and release all modifiers. To record a regular key combination, hold the modifiers and press the key. Escape or losing window focus cancels. Changing or resetting the shortcut turns the remote off until explicitly re-enabled.

Choose a shortcut that isn’t used by your other apps, and set the same shortcut in Wispr Flow. There is no guarantee a custom combination is conflict-free. Fn/Globe, Caps Lock, and mouse buttons are not supported by this recorder.

The app launches disabled and remembers the shortcut. Keep it at a stable path.

## Architecture

- AppKit status item and settings panel; Swift Package Manager build.
- IOHIDManager detects vendor 11427 / product 16401. A two-second refresh handles reconnects.
- Device-scoped hidutil maps Consumer Volume Up (0x0C/0xE9) to F18. A session event tap consumes F18 and emits the configured shortcut with a 120 ms press and 350 ms debounce.
- Shortcut emission includes modifier flagsChanged events and releases injected modifiers in reverse order after 120 ms. Regular-key shortcuts also include key-down/key-up. Modifier-only shortcuts send no regular key. Already-held modifiers are not pressed or released by the app; if the whole modifier-only shortcut is already held, the app asks the user to release it first.
- Normal disable/quit clears the mapping applied by the app. Existing nonempty mappings are conservatively rejected; mapping-read errors also prevent changes.
- The hidutil parser handles table headers, registry IDs, and multiline empty arrays.

## Validation

On September 13, 2026:

- Release build and ad-hoc signing succeeded.
- Verified settings, shortcut recording/cancellation, receiver detection, and Accessibility gating in recorded mode.
- Confirmed receiver-button events reached the F18 event tap. Command–Option–T delivery to Flow was inconclusive.
- Set Flow’s microphone to Wireless Mic Rx (USB).
- Verified F20 mode selection, enable, mapping read-back (51539607785 → 30064771183), disable cleanup, and re-enable after a multiline empty mapping.
- Bare F20 reached Flow’s shortcut validation but was rejected because it lacked a modifier. F24 was not captured. Both temporary direct mappings have been removed.
- The Control–Option–F20 build and signature passed, and UI verification confirmed saved-mode migration. After refreshing Accessibility, the app reached Ready. Flow captured Control–Option–F20 from the physical mic button, and the user confirmed the subsequent dictation test worked end to end.
- Nine parser regression checks passed. Run them with:

```sh
swiftc -module-cache-path /tmp/dji-module-cache Sources/DJIMicRemote/MappingOutput.swift Tests/MappingChecks.swift -o /tmp/dji-mapping-checks
/tmp/dji-mapping-checks
```

The Control–Option–F20 button-to-Flow path is confirmed working. The new modifier-only default builds successfully and passes saved-shortcut compatibility and persistence checks, but needs a fresh end-to-end test. Receiver reconnect and button holding also remain to be checked.

## MVP limits

- The receiver button behavior is undocumented and firmware-dependent.
- F18 is reserved globally while active, including physical F18 keys. Hold-to-talk shortcuts are not supported.
- Flow accepted the Control–Option–F20 sequence with explicit modifier events in end-to-end testing. Other shortcut combinations are unverified. A “Sent” diagnostic alone confirms posting, not Flow acknowledgment.
- Force quit/crash can leave the HID mapping behind until receiver reconnection. Normal quit removes it. Do not change receiver mappings in another tool while enabled.
- No launch-at-login integration, installer, notarization, or auto-update yet.

## Reference

Architecture informed by Igor Bedesqui’s public implementation:
https://github.com/bdsqqq/dots/tree/main/modules/dji-mic

Our implementation is standalone Swift. His Raycast integration uses Kanata to dispatch shortcuts through a virtual keyboard.
