#!/bin/bash
# Builds, signs, notarizes and packages a release, and writes the Sparkle appcast.
#
#   scripts/release.sh 0.2.0
#
# One-time setup (see docs/RELEASING.md):
#   DEVELOPER_ID     "Developer ID Application: Your Name (TEAMID)"  (security find-identity -v -p codesigning)
#   NOTARY_PROFILE   keychain profile from `xcrun notarytool store-credentials` (default: opennotch-notary),
#                    or NOTARY_KEY / NOTARY_KEY_ID / NOTARY_ISSUER for an App Store Connect API key (CI)
#   Sparkle key      private key in your login keychain from `generate_keys`, or SPARKLE_KEY_FILE (CI)
#   DOWNLOAD_PREFIX  where the DMG will be downloadable, e.g. https://github.com/kjagsadvisors/opennotch/releases/download/v0.2.0/
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OPENNOTCH_BUILD_DIR:-$HOME/Library/Caches/opennotch-build}"
DIST="$ROOT/dist"
APP="$OUT/OpenNotch.app"
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"
NOTARY=(--keychain-profile "${NOTARY_PROFILE:-opennotch-notary}")
[[ -n "${NOTARY_KEY:-}" ]] && NOTARY=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
: "${DOWNLOAD_PREFIX:?Set DOWNLOAD_PREFIX to the URL folder the DMG will be served from}"

if grep -q "REPLACE_WITH_OUTPUT_OF_generate_keys" "$ROOT/Resources/Info.plist"; then
  echo "Set SUPublicEDKey in Resources/Info.plist first (run Sparkle's generate_keys)." >&2
  exit 1
fi

SPARKLE="$("$ROOT/scripts/fetch-sparkle.sh")"
KEY_ARGS=()
[[ -n "${SPARKLE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")

echo "▸ Building $VERSION"
"$ROOT/scripts/build.sh" release
# Sparkle compares CFBundleVersion, so it must always increase.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "▸ Signing with hardened runtime (inside out)"
sign() { codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SP" ]]; then
  for xpc in "$SP/XPCServices/"*.xpc; do [[ -e "$xpc" ]] && sign --preserve-metadata=entitlements "$xpc"; done
  sign "$SP/Autoupdate"
  sign "$SP/Updater.app"
fi
for fw in "$APP/Contents/Frameworks/"*.framework; do [[ -e "$fw" ]] && sign "$fw"; done
sign --entitlements "$ROOT/Resources/OpenNotch.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "▸ Notarizing the app"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$OUT/OpenNotch-notarize.zip"
xcrun notarytool submit "$OUT/OpenNotch-notarize.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"

echo "▸ Packaging the DMG"
DMG="$DIST/OpenNotch-$VERSION.dmg"
rm -f "$DMG"
# Finder only honours the window layout (background, hidden toolbar) that dmgbuild >= 1.6.7 writes;
# it needs Python 3.10+, so prefer Homebrew's over the system 3.9.
VENV="$OUT/venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  PY="$(ls /opt/homebrew/bin/python3.1[0-9] /usr/local/bin/python3.1[0-9] 2>/dev/null | tail -1)"
  "${PY:-python3}" -m venv "$VENV" && "$VENV/bin/pip" install -q "dmgbuild>=1.6.7"
fi
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D background="$ROOT/Resources/dmg-background.png" \
  "OpenNotch" "$DMG" >/dev/null
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"

echo "▸ Writing the appcast"
# generate_appcast signs each update with the EdDSA key and keeps history from an existing appcast.xml.
"$SPARKLE/bin/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --download-url-prefix "$DOWNLOAD_PREFIX" "$DIST"

echo "✓ $DMG"
echo "✓ $DIST/appcast.xml  → publish it at the SUFeedURL in Info.plist"
