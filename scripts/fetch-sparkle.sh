#!/bin/bash
# Downloads the pinned Sparkle release (framework + signing tools) and verifies its checksum.
# Prints the directory it unpacked to.
set -euo pipefail

VERSION="2.10.0"
SHA256="${SPARKLE_SHA256:-}"
DEST="${OPENNOTCH_BUILD_DIR:-$HOME/Library/Caches/opennotch-build}/Sparkle-$VERSION"

if [[ -d "$DEST/Sparkle.framework" ]]; then echo "$DEST"; exit 0; fi

mkdir -p "$DEST"
TARBALL="$DEST.tar.xz"
curl -fsSL -o "$TARBALL" "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
EXPECTED="$(cat "$(dirname "$0")/sparkle.sha256" 2>/dev/null || echo "$SHA256")"
if [[ -n "$EXPECTED" && "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Sparkle checksum mismatch: $ACTUAL" >&2
  rm -rf "$DEST" "$TARBALL"
  exit 1
fi
tar -xf "$TARBALL" -C "$DEST"
rm "$TARBALL"
echo "$DEST"
