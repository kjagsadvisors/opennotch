#!/bin/bash
# Records the onboarding narration with Kokoro (open-source, Apache-2.0, via FluidAudio's CLI) into
# Resources/Narration/<id>.m4a. Re-run after changing a line; the app plays whatever is bundled.
#
#   scripts/make-narration.sh            all lines
#   scripts/make-narration.sh greeting   one line
#
# Needs FluidAudio's CLI:  swift build -c release --product fluidaudiocli  (in the FluidAudio checkout)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/Narration"
CLI="${FLUIDAUDIO_CLI:-$HOME/Library/Caches/opennotch-build/fluidcli/out/Products/Release/fluidaudiocli}"
VOICE="${NARRATION_VOICE:-af_heart}"
TMP="$(mktemp -d)"
mkdir -p "$OUT"

# id|line. "Open Notch" is spelled as two words so it's pronounced right.
LINES='welcome|Welcome to Open Notch.
askName|I'"'"'m your voice for this Mac. What should I call you?
greeting|It'"'"'s great to meet you.
permissions|First, a few permissions. I only listen while you hold your key.
keyCheck|Let'"'"'s check your talk keys. Hold each one down.
dictationIntro|Dictation. Talk naturally, and I'"'"'ll clean up the ums and the corrections.
tryDictation|Your turn. Hold the key, read the message out loud, then let go.
speed|That was a lot faster than typing.
command|Commands. Hold the keys on screen, and tell your Mac what to do.
account|Last step. Create your free account, so Open Notch knows it'"'"'s you.
paywall|One more thing. Try Pro free for seven days, and I'"'"'ll clean up everything you say.
done|You'"'"'re all set.'

while IFS='|' read -r id text; do
  [[ -n "${1:-}" && "$1" != "$id" ]] && continue
  "$CLI" tts "$text" --voice "$VOICE" --output "$TMP/$id.wav" >/dev/null 2>&1
  afconvert -f m4af -d aac -b 64000 "$TMP/$id.wav" "$OUT/$id.m4a"
  echo "✓ $id: $text"
done <<< "$LINES"
rm -rf "$TMP"
