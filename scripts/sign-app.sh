#!/bin/bash
set -euo pipefail
APP_TO_SIGN="${1:?Pass the app bundle path}"
SIGNING_ROOT="$HOME/Library/Application Support/DJI Mic Remote/Signing"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
    SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
    if [ -n "${SIGNING_KEYCHAIN:-}" ]; then SIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN"); fi
    codesign "${SIGN_ARGS[@]}" "$APP_TO_SIGN"
elif [ -f "$SIGNING_ROOT/identity.txt" ]; then
    IDENTITY=$(cat "$SIGNING_ROOT/identity.txt")
    if ! [[ "$IDENTITY" =~ ^[0-9A-F]{40}$ ]]; then
        echo 'Invalid local signing identity. Repair it; refusing to fall back to ad-hoc signing.' >&2
        exit 1
    fi
    security unlock-keychain -p "$(cat "$SIGNING_ROOT/keychain-password")" "$SIGNING_ROOT/development.keychain-db"
    codesign --force --sign "$IDENTITY" --keychain "$SIGNING_ROOT/development.keychain-db" --timestamp=none "$APP_TO_SIGN"
elif [ -d "$SIGNING_ROOT" ]; then
    echo 'Local signing setup is incomplete. Finish it before building; refusing to change identity.' >&2
    exit 1
else
    codesign --force --sign - "$APP_TO_SIGN"
    echo 'Ad-hoc build: rebuilt versions need renewed macOS permissions. See README: Signing and permission identity.' >&2
fi
codesign --verify --strict "$APP_TO_SIGN"
