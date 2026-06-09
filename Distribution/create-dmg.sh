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
# notarization, and (b) Gatekeeper accepts the downloaded build. --options runtime
# keeps Hardened Runtime on; --deep signs nested code (Sparkle.framework + helpers).
if [ -n "${DEVID_APP_IDENTITY}" ]; then
  echo "▶ Signing with Developer ID: ${DEVID_APP_IDENTITY}"
  codesign --force --deep --options runtime --timestamp \
    --sign "${DEVID_APP_IDENTITY}" "${BUILD_APP}"
  echo "▶ Verifying signature..."
  codesign --verify --deep --strict --verbose=2 "${BUILD_APP}"
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

# ── 5. Create writable DMG ────────────────────────────────────────────────────
# UDRW (writable) so we can mount and write DS_Store to the live volume path.
# We never convert — avoids the hdiutil convert EAGAIN bug on macOS 26 Tahoe.
echo "▶ Creating DMG..."
rm -f "${DMG_RW}.dmg"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -format UDRW \
  "${DMG_RW}"

# ── 6. Mount, write Finder layout, unmount ────────────────────────────────────
echo "▶ Configuring Finder layout..."
MOUNT_POINT=$(hdiutil attach "${DMG_RW}.dmg" -readwrite -noverify -noautoopen \
              | grep "/Volumes" | awk '{print $NF}')
python3 "${PROJECT_ROOT}/Distribution/set-dmg-layout.py" "${MOUNT_POINT}"
hdiutil detach "${MOUNT_POINT}" -force

# ── 7. Move finished DMG to Desktop ───────────────────────────────────────────
rm -f "${OUT_DMG}"
mv "${DMG_RW}.dmg" "${OUT_DMG}"

# ── 8. Notarize + staple the DMG itself ───────────────────────────────────────
# Stapling the DMG lets it pass Gatekeeper on first download without an online
# notarization check. (The app inside was already stapled in step 3.)
if [ -n "${NOTARY_PROFILE}" ] && [ -n "${DEVID_APP_IDENTITY}" ]; then
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
