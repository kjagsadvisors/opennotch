#!/bin/bash
# Builds OpenNotch.app.
#
#   scripts/build.sh            debug build
#   scripts/build.sh release    optimized build
#   scripts/build.sh run        debug build, then launch
#
# Uses SwiftPM when it works (full app: Parakeet speech + Sparkle updates). If SwiftPM can't
# build (e.g. a broken Command Line Tools install), falls back to plain swiftc: Apple's speech
# engine plus Sparkle from the pinned release.
#
# Products live outside the repo (cloud-synced folders mangle code signatures).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OPENNOTCH_BUILD_DIR:-$HOME/Library/Caches/opennotch-build}"
APP="$OUT/OpenNotch.app"
MODE="${1:-debug}"
CONFIG=debug
[[ "$MODE" == "release" ]] && CONFIG=release
mkdir -p "$OUT"

FRAMEWORKS=()
BUNDLES=()   # SwiftPM resource bundles; Bundle.module finds them in Contents/Resources
if swift build -c "$CONFIG" --package-path "$ROOT" --scratch-path "$OUT/spm" --product OpenNotch >"$OUT/spm.log" 2>&1; then
  echo "▸ Built with SwiftPM ($CONFIG)"
  BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --scratch-path "$OUT/spm" --show-bin-path)"
  BIN="$BIN_DIR/OpenNotch"
  while IFS= read -r -d '' fw; do FRAMEWORKS+=("$fw"); done < <(find "$BIN_DIR" -maxdepth 1 -name '*.framework' -print0)
  while IFS= read -r -d '' b; do BUNDLES+=("$b"); done < <(find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -print0)
else
  echo "▸ SwiftPM unavailable (log: $OUT/spm.log); building with swiftc, without Parakeet"
  SPARKLE_DIR="$("$ROOT/scripts/fetch-sparkle.sh")"
  FLAGS=(-Onone -g)
  [[ "$CONFIG" == "release" ]] && FLAGS=(-O -wmo)
  find "$ROOT/Sources/OpenNotch" -name '*.swift' -print0 | xargs -0 \
    swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx26.0 "${FLAGS[@]}" \
    -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$OUT/OpenNotch"
  BIN="$OUT/OpenNotch"
  FRAMEWORKS+=("$SPARKLE_DIR/Sparkle.framework")
fi

echo "▸ Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/OpenNotch"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do ditto "$fw" "$APP/Contents/Frameworks/$(basename "$fw")"; done
for b in ${BUNDLES[@]+"${BUNDLES[@]}"}; do ditto "$b" "$APP/Contents/Resources/$(basename "$b")"; done

# Dev builds sign with OPENNOTCH_SIGN_IDENTITY if set (a stable identity keeps macOS permissions
# across rebuilds), otherwise ad hoc. Release signing and notarization live in scripts/release.sh.
IDENTITY="${OPENNOTCH_SIGN_IDENTITY:--}"
for fw in "$APP/Contents/Frameworks/"*.framework; do
  [[ -e "$fw" ]] && codesign --force --deep --sign "$IDENTITY" "$fw" >/dev/null
done
codesign --force --sign "$IDENTITY" --entitlements "$ROOT/Resources/OpenNotch.entitlements" "$APP" >/dev/null
echo "✓ $APP"

if [[ "$MODE" == "run" ]]; then
  pkill -x OpenNotch 2>/dev/null || true
  open "$APP"
fi
