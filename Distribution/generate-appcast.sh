#!/bin/bash
# Generates/updates appcast.xml for a Shhhcribble release using Sparkle's
# generate_appcast (which EdDSA-signs each archive with the private key stored
# in your login Keychain — the key never touches disk or the repo).
#
# Usage:  bash Distribution/generate-appcast.sh vX.Y.Z
#
# Prereqs: ~/Desktop/Shhhcribble.dmg already built + notarized (create-dmg.sh),
# and the EdDSA key generated once via Sparkle's generate_keys (see CLAUDE.md).
#
# Output:  ~/Desktop/appcast.xml — attach it AND the DMG to the GitHub Release
# for tag vX.Y.Z. The app's SUFeedURL points at releases/latest/download/appcast.xml
# so every client always fetches the newest appcast; the enclosure URL below
# pins the DMG to this specific tag's release assets.
set -e

TAG="$1"
if [ -z "${TAG}" ]; then
  echo "Usage: bash Distribution/generate-appcast.sh vX.Y.Z"
  exit 1
fi

REPO="itsHendri/Shhhcribble"
APP_NAME="Shhhcribble"
DMG=~/Desktop/"${APP_NAME}.dmg"
ARCHIVES_DIR="/tmp/FW-appcast"
DOWNLOAD_URL_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

if [ ! -f "${DMG}" ]; then
  echo "❌ ${DMG} not found — run Distribution/create-dmg.sh first."
  exit 1
fi

# Locate Sparkle's generate_appcast from the resolved SPM artifact in DerivedData.
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)
if [ -z "${GENERATE_APPCAST}" ]; then
  echo "❌ generate_appcast not found. Resolve packages first:"
  echo "   xcodebuild -resolvePackageDependencies -scheme ${APP_NAME}"
  exit 1
fi

# Stage just this release's DMG. To publish a multi-version appcast, drop prior
# released DMGs into this dir too — generate_appcast lists every archive it finds.
rm -rf "${ARCHIVES_DIR}"
mkdir -p "${ARCHIVES_DIR}"
cp "${DMG}" "${ARCHIVES_DIR}/"

echo "▶ Generating appcast (EdDSA-signing ${APP_NAME}.dmg with Keychain key)..."
"${GENERATE_APPCAST}" \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX}" \
  "${ARCHIVES_DIR}"

cp "${ARCHIVES_DIR}/appcast.xml" ~/Desktop/appcast.xml
echo "✅ Done: ~/Desktop/appcast.xml"
echo ""
echo "Publish the release (DMG + appcast.xml both attached):"
echo "  gh release create ${TAG} ~/Desktop/${APP_NAME}.dmg ~/Desktop/appcast.xml \\"
echo "    --repo ${REPO} --title \"${APP_NAME} ${TAG}\" --notes-file <notes.md>"
