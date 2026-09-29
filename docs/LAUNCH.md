# MVP launch checklist

What ships: the open-source app (free, bring your own key or fully on-device) plus **OpenNotch Pro**,
$9.99/month or $79.99/year with a 7-day free trial, sold through Polar. Pro users get Claude Haiku
cleanup and commands through the opennotch.ai proxy, with no API key.

## Accounts and keys (you)

- [ ] **Domain**: opennotch.ai on Vercel (team `kjagsadvisors-projects`).
- [ ] **Anthropic key for the app** (your own testing): a key in the *Default workspace*, saved with
      `security add-generic-password -U -s app.opennotch.OpenNotch -a anthropic -w`.
- [ ] **Anthropic key for the server** (Pro traffic): a second workspace key, used only as the Vercel env var below,
      so you can see and cap Pro spend separately (Console → Workspaces → Limits).
- [ ] **Xcode** installed, then `sudo xcode-select -s /Applications/Xcode.app`.
- [ ] **Developer ID certificate**: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application.
- [ ] **Notarization**: `xcrun notarytool store-credentials opennotch-notary --apple-id YOU --team-id TEAMID`.
- [ ] **Sparkle key**: `generate_keys` (see RELEASING.md); paste the public key into `Resources/Info.plist`.

## Polar (done 2026-09-29)

Selling as **Rankee LLC** (org id `75661d8b-d7e6-4180-964c-306197322d32`, slug `rankee-llc`):
- Benefit "OpenNotch Pro license key": License Keys, prefix `OPENNOTCH`, 3 activations, visible to customers.
- "OpenNotch Pro" $9.99/month and "OpenNotch Pro (Yearly)" $79.99/year, both with a 7-day trial and the benefit.
- Checkout links wired into `web/vercel.json` (`/pro/monthly`, `/pro/yearly`); success page `/pro/thanks`.
- Still to do in Polar (you): Settings → add the website (https://opennotch.ai) and a support email, then finish
  identity/payout verification so it can go live.

## Wiring (me, once the above arrives)

- `ProConfig.polarOrganizationID` in `Sources/OpenNotch/App/Pro.swift`.
- The `/pro/*` redirects in `web/vercel.json`, and `OWNER` in the GitHub redirects.
- Vercel project `opennotch-web` from `web/`, domain opennotch.ai. **You** add the env vars in the Vercel dashboard
  (Project → Settings → Environment Variables): `ANTHROPIC_API_KEY` (the server key), `AI_GATEWAY_API_KEY`
  (Jev decisions for Pro users) and `POLAR_ORGANIZATION_ID` = `75661d8b-d7e6-4180-964c-306197322d32`.
- GitHub repo, first signed release (`v0.1.0`), and the appcast.

## Smoke test before announcing

- [ ] Download the DMG from opennotch.ai on a second Mac or user account; Gatekeeper opens it without warnings.
- [ ] Onboarding end to end: permissions, Parakeet download, key test, dictation, command.
- [ ] Buy Pro with a real card (then refund it in Polar), paste the license key, and check cleanup works with no Anthropic key set.
- [ ] Cancel the subscription and confirm Pro turns off within a day (or on relaunch).
- [ ] Publish v0.1.1 and confirm v0.1.0 offers the update.
