#!/bin/bash
# Creates a drag-to-Applications DMG for Shhhcribble.
# Run from the project root: bash Distribution/create-dmg.sh
#
# Signing / notarization (required for a shippable, auto-updatable build):
#   export DEVID_APP_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   export NOTARY_PROFILE="shhhcribble-notary"   # a notarytool keychain profile
#
# Create the notarytool profile once (stores creds in the Keychain, never here):
#   xcrun notarytool store-credentials shhhcribble-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# If DEVID_APP_IDENTITY / NOTARY_PROFILE are unset, the script falls back to an
# ad-hoc, un-notarized DMG for LOCAL TESTING ONLY — that build will NOT pass
# Gatekeeper on another machine and Sparkle cannot ship it. See CLAUDE.md.
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Shhhcribble"
DERIVED_DATA="/tmp/FW-build"
BUILD_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
DMG_STAGING="/tmp/FW-dmg"
DMG_RW="/tmp/FW-rw"        # hdiutil appends .dmg automatically
OUT_DMG=~/Desktop/"${APP_NAME}.dmg"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "▶ Building Release..."
xcodebuild \
  -project "${PROJECT_ROOT}/Shhhcribble.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

if [ ! -d "${BUILD_APP}" ]; then
  echo "❌ Build failed — ${BUILD_APP} not found."
  exit 1
fi

# ── 2. Sign ───────────────────────────────────────────────────────────────────
# Developer ID + Hardened Runtime is required so (a) the embedded Sparkle helpers
# (Autoupdate.app / Updater.app / XPC services) are Developer-ID signed for
# notarization, and (b) Gatekeeper accepts the downloaded build.
#
# Signed INSIDE-OUT, not --deep. Two hard-won reasons (v1.7.0 release, 2026-07):
#   1. `codesign --force` STRIPS existing entitlements unless told otherwise.
#      With Hardened Runtime on (-o runtime), a mic app without the
#      com.apple.security.device.audio-input entitlement is denied the
#      microphone BEFORE TCC is consulted — "permission denied" no reset can
#      fix. The app must be re-signed WITH --entitlements.
#   2. --deep would stamp those same app entitlements over Sparkle's nested
#      helpers (whose XPC services carry their own) — Apple and Sparkle both
#      say: sign nested code individually, preserving its metadata.
ENTITLEMENTS="${PROJECT_ROOT}/Shhhcribble/Resources/Shhhcribble.entitlements"
SPARKLE_FW="${BUILD_APP}/Contents/Frameworks/Sparkle.framework"
if [ -n "${DEVID_APP_IDENTITY}" ]; then
  echo "▶ Signing with Developer ID: ${DEVID_APP_IDENTITY}"
  if [ -d "${SPARKLE_FW}" ]; then
    # Sparkle helpers first (inside-out), preserving their own entitlements.
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
      --sign "${DEVID_APP_IDENTITY}" "${SPARKLE_FW}/Versions/B/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
      --sign "${DEVID_APP_IDENTITY}" "${SPARKLE_FW}/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp \
      --sign "${DEVID_APP_IDENTITY}" "${SPARKLE_FW}/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp \
      --sign "${DEVID_APP_IDENTITY}" "${SPARKLE_FW}/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp \
      --sign "${DEVID_APP_IDENTITY}" "${SPARKLE_FW}"
  fi
  # Main app last, WITH the app entitlements (audio-input for Hardened Runtime).
  codesign --force --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${DEVID_APP_IDENTITY}" "${BUILD_APP}"
  echo "▶ Verifying signature + entitlements..."
  codesign --verify --deep --strict --verbose=2 "${BUILD_APP}"
  if ! codesign -d --entitlements - "${BUILD_APP}" 2>/dev/null | grep -q "audio-input"; then
    echo "❌ audio-input entitlement missing after signing — mic would be denied under Hardened Runtime."
    exit 1
  fi
else
  echo "⚠️  DEVID_APP_IDENTITY unset — AD-HOC signing (LOCAL TEST ONLY, not shippable)."
  codesign --force --deep --sign - "${BUILD_APP}"
fi

# ── 3. Notarize the app (before packaging, so we can staple the .app) ──────────
if [ -n "${NOTARY_PROFILE}" ] && [ -n "${DEVID_APP_IDENTITY}" ]; then
  echo "▶ Notarizing app (this can take a few minutes)..."
  NOTARIZE_ZIP="/tmp/${APP_NAME}-notarize.zip"
  rm -f "${NOTARIZE_ZIP}"
  ditto -c -k --keepParent "${BUILD_APP}" "${NOTARIZE_ZIP}"
  xcrun notarytool submit "${NOTARIZE_ZIP}" \
    --keychain-profile "${NOTARY_PROFILE}" --wait
  echo "▶ Stapling notarization ticket to app..."
  xcrun stapler staple "${BUILD_APP}"
  xcrun stapler validate "${BUILD_APP}"
  rm -f "${NOTARIZE_ZIP}"
else
  echo "⚠️  NOTARY_PROFILE unset — skipping notarization (LOCAL TEST ONLY)."
fi

# ── 4. Stage DMG contents ─────────────────────────────────────────────────────
echo "▶ Staging DMG contents..."
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${BUILD_APP}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

# ── 5. Create scratch UDRW DMG for Finder layout ──────────────────────────────
# The UDRW image exists ONLY to generate the .DS_Store: Finder layout must be
# written to a live mounted volume. The final image is created fresh as UDZO in
# step 7 — `hdiutil convert` is NOT used anywhere because it fails persistently
# with EAGAIN on macOS 26 Tahoe (fails even on a trivial never-mounted image,
# sandboxed or not — verified 2026-07-07), while `hdiutil create -format UDZO`
# works fine. notarytool also rejects UDRW, so the shipped DMG must be UDZO.
echo "▶ Creating scratch DMG for Finder layout..."
rm -f "${DMG_RW}.dmg"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -format UDRW \
  "${DMG_RW}"

# ── 6. Mount, write Finder layout, harvest .DS_Store, unmount ─────────────────
echo "▶ Configuring Finder layout..."
MOUNT_POINT=$(hdiutil attach "${DMG_RW}.dmg" -readwrite -noverify -noautoopen \
              | grep "/Volumes" | awk '{print $NF}')
python3 "${PROJECT_ROOT}/Distribution/set-dmg-layout.py" "${MOUNT_POINT}"
# Copy the generated .DS_Store back into staging so the final UDZO image
# carries the same icon layout without ever mounting it.
cp "${MOUNT_POINT}/.DS_Store" "${DMG_STAGING}/.DS_Store"
hdiutil detach "${MOUNT_POINT}" -force
rm -f "${DMG_RW}.dmg"

# ── 7. Create the final compressed read-only DMG on the Desktop ───────────────
# The diskimages service holds a cooldown after the detach above, during which
# compressed creates fail with EAGAIN ("Resource temporarily unavailable") on
# macOS 26 Tahoe — it clears after a minute or two, so retry with real waits.
echo "▶ Creating final UDZO DMG..."
rm -f "${OUT_DMG}"
CREATED=0
for attempt in 1 2 3 4 5 6; do
  if hdiutil create \
       -volname "${APP_NAME}" \
       -srcfolder "${DMG_STAGING}" \
       -format UDZO \
       -imagekey zlib-level=9 \
       "${OUT_DMG}"; then
    CREATED=1
    break
  fi
  echo "  create attempt ${attempt} hit the post-detach cooldown — waiting 30s..."
  sleep 30
done
if [ "${CREATED}" -ne 1 ]; then
  echo "❌ hdiutil create (UDZO) failed after 6 attempts."
  exit 1
fi

# ── 8. Sign, notarize + staple the DMG itself ─────────────────────────────────
# The DMG must be codesigned BEFORE notarization — an unsigned DMG notarizes
# fine but assesses as "no usable signature" (spctl), while signing after
# stapling would invalidate the ticket. Signed + stapled, it passes Gatekeeper
# on first download without an online check. (The app inside was stapled in
# step 3.)
if [ -n "${NOTARY_PROFILE}" ] && [ -n "${DEVID_APP_IDENTITY}" ]; then
  echo "▶ Signing DMG..."
  codesign --force --sign "${DEVID_APP_IDENTITY}" --timestamp "${OUT_DMG}"
  echo "▶ Notarizing DMG..."
  xcrun notarytool submit "${OUT_DMG}" \
    --keychain-profile "${NOTARY_PROFILE}" --wait
  echo "▶ Stapling notarization ticket to DMG..."
  xcrun stapler staple "${OUT_DMG}"
  xcrun stapler validate "${OUT_DMG}"
fi

echo "✅ Done: ${OUT_DMG}"
echo ""
if [ -n "${DEVID_APP_IDENTITY}" ] && [ -n "${NOTARY_PROFILE}" ]; then
  echo "Signed + notarized. Next: generate the appcast and publish the release:"
  echo "  bash Distribution/generate-appcast.sh vX.Y.Z"
else
  echo "⚠️  This is an AD-HOC build for local testing only — set DEVID_APP_IDENTITY"
  echo "    and NOTARY_PROFILE to produce a shippable, auto-updatable release."
fi
