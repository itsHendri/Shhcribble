#!/bin/bash
# Creates a drag-to-Applications DMG for Shhhcribble.
# Run from the project root: bash Distribution/create-dmg.sh
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Shhhcribble"
DERIVED_DATA="/tmp/SC-build"
BUILD_APP="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
DMG_STAGING="/tmp/SC-dmg"
DMG_RW="/tmp/SC-rw"        # hdiutil appends .dmg automatically
OUT_DMG=~/Desktop/"${APP_NAME}.dmg"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "▶ Building Release..."
xcodebuild \
  -project "${PROJECT_ROOT}/${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" || true

if [ ! -d "${BUILD_APP}" ]; then
  echo "❌ Build failed — ${BUILD_APP} not found."
  exit 1
fi

# ── 2. Sign ───────────────────────────────────────────────────────────────────
echo "▶ Ad-hoc signing for distribution..."
codesign --force --deep --sign - "${BUILD_APP}"

# ── 3. Stage DMG contents ─────────────────────────────────────────────────────
echo "▶ Staging DMG contents..."
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${BUILD_APP}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"

# ── 4. Create writable DMG ────────────────────────────────────────────────────
# UDRW (writable) so we can mount and write DS_Store to the live volume path.
# We never convert — avoids the hdiutil convert EAGAIN bug on macOS 26 Tahoe.
echo "▶ Creating DMG..."
rm -f "${DMG_RW}.dmg"
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${DMG_STAGING}" \
  -format UDRW \
  "${DMG_RW}"

# ── 5. Mount, write Finder layout, unmount ────────────────────────────────────
echo "▶ Configuring Finder layout..."
MOUNT_POINT=$(hdiutil attach "${DMG_RW}.dmg" -readwrite -noverify -noautoopen \
              | grep "/Volumes" | awk '{print $NF}')
python3 "${PROJECT_ROOT}/Distribution/set-dmg-layout.py" "${MOUNT_POINT}"
hdiutil detach "${MOUNT_POINT}" -force

# ── 6. Move finished DMG to Desktop ───────────────────────────────────────────
rm -f "${OUT_DMG}"
mv "${DMG_RW}.dmg" "${OUT_DMG}"

echo "✅ Done: ${OUT_DMG}"
echo ""
echo "Share this DMG with your friends."
echo "They open it, drag Shhhcribble to Applications, then right-click → Open on first launch."
