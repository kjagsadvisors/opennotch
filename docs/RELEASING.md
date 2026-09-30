# Releasing OpenNotch

Releases are Developer ID–signed, notarized by Apple, shipped as a DMG, and delivered to existing
users through [Sparkle](https://sparkle-project.org). Every update is verified twice: macOS checks
Apple's notarization, and Sparkle checks our EdDSA signature. An update signed by anyone else
is rejected.

Users get a daily check (Sparkle's default, `SUScheduledCheckInterval` = 86400 s). Nothing
installs without a click unless they turn on "Download and install automatically" in Settings.
System profiling is off.

## One-time setup

### 1. Xcode

Install Xcode from the App Store, then point the command-line tools at it:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

### 2. Developer ID certificate

Xcode → Settings → Accounts → your Apple ID → Manage Certificates → **+** → *Developer ID Application*. Check it's there:

```bash
security find-identity -v -p codesigning
```

Copy the full `Developer ID Application: Name (TEAMID)` string. Local builds can use it too, which keeps
macOS permissions across rebuilds:

```bash
export OPENNOTCH_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
```

### 3. Notarization credentials

Create an app-specific password at [account.apple.com](https://account.apple.com), then store it in your keychain
(notarytool prompts for the password; it never goes in a file):

```bash
xcrun notarytool store-credentials opennotch-notary --apple-id you@example.com --team-id TEAMID
```

### 4. Sparkle signing key

```bash
~/Library/Caches/opennotch-build/Sparkle-2.10.0/bin/generate_keys
```

This keeps the private key in your login keychain and prints the public key. Paste the public key into
`Resources/Info.plist` as `SUPublicEDKey` and commit it. **Back up the private key**; if it's lost, existing
users can't receive updates:

```bash
~/Library/Caches/opennotch-build/Sparkle-2.10.0/bin/generate_keys -x sparkle_private_key.txt
```

Put that file in your password manager and then delete it. Never commit it.

### 5. The update feed

`SUFeedURL` is `https://opennotch.ai/appcast.xml`. The simplest hosting is a redirect on the website to the
appcast attached to the latest GitHub release. For a site on Vercel, `vercel.json`:

```json
{ "redirects": [{ "source": "/appcast.xml", "destination": "https://github.com/kjagsadvisors/opennotch/releases/latest/download/appcast.xml" }] }
```

## Releasing from your Mac

```bash
DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
DOWNLOAD_PREFIX="https://github.com/kjagsadvisors/opennotch/releases/download/v0.2.0/" \
scripts/release.sh 0.2.0
```

This builds the app (with Parakeet and Sparkle), signs everything inside out with the hardened runtime,
notarizes and staples the app and the DMG, and writes `dist/appcast.xml`. Then:

```bash
gh release create v0.2.0 dist/OpenNotch-0.2.0.dmg dist/appcast.xml --generate-notes
```

## Releasing from CI

`.github/workflows/release.yml` does the same on a `v*` tag push. Add these repository secrets:

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Your Developer ID certificate + key exported from Keychain Access as .p12, then `base64 -i cert.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set on that export |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect API key (Users and Access → Integrations → Keys, "Developer" role), `base64 -i AuthKey_XXXX.p8` |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | The issuer ID shown on the same page |
| `SPARKLE_PRIVATE_KEY` | Contents of the file from `generate_keys -x` |

Then turn CI releases on (they're skipped until this variable exists):

```bash
gh variable set CI_RELEASES --body true
```

and release with:

```bash
git tag v0.2.0 && git push origin v0.2.0
```
