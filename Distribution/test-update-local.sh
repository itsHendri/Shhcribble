#!/bin/bash
# LOCAL SPARKLE UPDATE TEST (no Apple Developer cert / notarization needed).
#
# Proves the full update mechanism — detect → download → EdDSA-verify → install
# → relaunch — by serving a fake "v1.6.1" from localhost. The only layer this
# does NOT exercise is Apple notarization/Gatekeeper (that needs the Dev ID cert
# and a real GitHub release — see CLAUDE.md "Release workflow").
#
# It uses the EdDSA key already in your login Keychain (Sparkle's own signature).
# It temporarily edits Info.plist (local feed + ATS exception + bumped version)
# and RESTORES it on exit. Throwaway test builds — not shippable.
#
# Usage:  bash Distribution/test-update-local.sh
# Then follow the printed instructions, and run with --serve in another step.
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Shhhcribble"
INFO_PLIST="${PROJECT_ROOT}/Shhhcribble/Resources/Info.plist"
PB=/usr/libexec/PlistBuddy

PORT=8765
FEED="http://localhost:${PORT}/appcast.xml"
BASELINE_DIR="${HOME}/Desktop/ShhhUpdateTest"          # user-writable: Sparkle updates in place, no admin prompt
SERVE_DIR="/tmp/shhh-update-serve"                      # appcast.xml + the v1.6.1 DMG live here
BL_DERIVED="/tmp/FW-build-baseline"
UP_DERIVED="/tmp/FW-build-update"

# ── Restore Info.plist no matter how we exit ──────────────────────────────────
BACKUP="/tmp/Info.plist.testbackup"
cp "${INFO_PLIST}" "${BACKUP}"
restore() { cp "${BACKUP}" "${INFO_PLIST}"; echo "↩︎  Info.plist restored."; }
trap restore EXIT

build() {  # build($config_derivedpath) → echoes built .app path
  local derived="$1"
  xcodebuild -project "${PROJECT_ROOT}/Shhhcribble.xcodeproj" -scheme "${APP_NAME}" \
    -configuration Debug -derivedDataPath "${derived}" build \
    >/tmp/shhh-build.log 2>&1 || { echo "❌ build failed — see /tmp/shhh-build.log"; tail -15 /tmp/shhh-build.log; exit 1; }
  echo "${derived}/Build/Products/Debug/${APP_NAME}.app"
}

# ── Common test edits: point feed at localhost + allow http (ATS) ─────────────
echo "▶ Patching Info.plist for local test (feed → ${FEED}, allow http)..."
${PB} -c "Set :SUFeedURL ${FEED}" "${INFO_PLIST}"
${PB} -c "Delete :NSAppTransportSecurity" "${INFO_PLIST}" 2>/dev/null || true
${PB} -c "Add :NSAppTransportSecurity dict" "${INFO_PLIST}"
${PB} -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "${INFO_PLIST}"

# ── 1. BASELINE app (v1.6.0 / 7) — this is what you run ───────────────────────
echo "▶ Building BASELINE v1.6.0 (this is the 'installed' app)..."
BL_APP=$(build "${BL_DERIVED}")
rm -rf "${BASELINE_DIR}"; mkdir -p "${BASELINE_DIR}"
cp -R "${BL_APP}" "${BASELINE_DIR}/"
codesign --force --deep --sign - "${BASELINE_DIR}/${APP_NAME}.app"

# ── 2. UPDATE app (v1.6.1 / 8) → DMG ──────────────────────────────────────────
echo "▶ Bumping version → 1.6.1 (build 8) and building the UPDATE..."
${PB} -c "Set :CFBundleShortVersionString 1.6.1" "${INFO_PLIST}"
${PB} -c "Set :CFBundleVersion 8" "${INFO_PLIST}"
UP_APP=$(build "${UP_DERIVED}")

echo "▶ Packaging v1.6.1 DMG..."
rm -rf "${SERVE_DIR}"; mkdir -p "${SERVE_DIR}"
STAGE=/tmp/shhh-update-stage; rm -rf "${STAGE}"; mkdir -p "${STAGE}"
cp -R "${UP_APP}" "${STAGE}/"
codesign --force --deep --sign - "${STAGE}/${APP_NAME}.app"
hdiutil create -volname "${APP_NAME} 1.6.1" -srcfolder "${STAGE}" \
  -format UDZO -ov "${SERVE_DIR}/${APP_NAME}-1.6.1.dmg" >/dev/null

# ── 3. Appcast (EdDSA-signed with your Keychain key) ──────────────────────────
echo "▶ Generating EdDSA-signed appcast..."
GEN=$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)
[ -z "${GEN}" ] && { echo "❌ generate_appcast not found"; exit 1; }
"${GEN}" --download-url-prefix "http://localhost:${PORT}/" "${SERVE_DIR}" >/dev/null

echo ""
echo "✅ Built. Serve dir: ${SERVE_DIR}"
echo "   Baseline app:   ${BASELINE_DIR}/${APP_NAME}.app  (v1.6.0)"
echo "   Update DMG:      ${APP_NAME}-1.6.1.dmg  +  appcast.xml"
# Info.plist is restored by the trap here.
