# Release setup on a fresh machine

Written 2026-08-30, the evening before this Mac was wiped, so that setting the
signing chain up again is a checklist rather than an archaeology exercise.

**The move being made here: off Tiuri Hartog's Apple Developer account
(`9W82X49JZS`) and onto Hendri's own.** Nothing of the old chain is carried
across — that's the point, and the wipe is what makes it cheap.

## Why nothing needed exporting

Two credentials existed only in the old login Keychain, and both were
deliberately abandoned rather than migrated:

- **The Developer ID certificate** belonged to another person's team. Replacing
  it is the whole objective.
- **The Sparkle EdDSA private key.** Losing this normally strands every install
  that has the matching `SUPublicEDKey` compiled in — they can never verify
  another update. Here the entire installed base was one Mac, and it was being
  erased, so re-keying cost nothing. **This will not be true a second time.**
  Once other people run Shhhcribble, back that key up before any machine move.

## Setup, in order

1. **Developer ID certificate.** In Xcode → Settings → Accounts, sign in with
   the Apple ID that holds the developer membership, then Manage Certificates →
   **+** → *Developer ID Application*. Confirm it landed:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID"
   ```

   Note the team ID in the output — it replaces `9W82X49JZS` everywhere below.

2. **Notary credentials.** Generate an app-specific password at
   appleid.apple.com (the one this repo used had expired, which is what blocked
   the 1.15.0 release), then:

   ```bash
   xcrun notarytool store-credentials shhhcribble-notary --apple-id <apple-id> --team-id <TEAM_ID> --password <app-specific-password>
   ```

   Verify before relying on it — a stale profile fails at the *end* of a long
   build otherwise:

   ```bash
   xcrun notarytool history --keychain-profile shhhcribble-notary
   ```

3. **A fresh Sparkle key.** `generate_keys` appears after Xcode resolves
   packages:

   ```bash
   ~/Library/Developer/Xcode/DerivedData/Shhhcribble-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   It prints a **public** key and stores the private half in the login Keychain.
   Put the public key in `Shhhcribble/Resources/Info.plist` under
   `SUPublicEDKey`, replacing the old one, and commit that. The private key must
   never reach the repo — this is a public repository.

4. **Environment, per release:**

   ```bash
   export DEVID_APP_IDENTITY="Developer ID Application: <Your Name> (<TEAM_ID>)"
   export NOTARY_PROFILE="shhhcribble-notary"
   ```

   Without both, `create-dmg.sh` silently falls back to an ad-hoc, un-notarized
   DMG that Sparkle cannot install.

## What to expect the first time

- **macOS treats it as a different app.** Permissions bind to bundle id *plus*
  code identity, so microphone, Accessibility and Screen Recording all need
  granting again. Nothing is wrong.
- **The first build is a manual install.** Sparkle cannot update across a
  changed signing identity or a changed EdDSA key, and this changes both. Mount
  the DMG and drag it over. Auto-update resumes normally from the release after.

## Then cut the release

`main` was left tagged-ready at **1.15.0** (`CFBundleShortVersionString` 1.15.0,
`CFBundleVersion` 18, CHANGELOG graduated). Steps 5–8 of the release workflow in
[CLAUDE.md](../CLAUDE.md) are unchanged: `create-dmg.sh`, then
`generate-appcast.sh v1.15.0`, then tag and `gh release create` with both the
DMG and `appcast.xml` attached.
