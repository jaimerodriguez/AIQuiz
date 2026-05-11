#!/usr/bin/env bash
# Build AIQuiz and install it on the connected iPad.
#
# First-time setup (already done):
#   1. brew install xcodegen
#   2. Sign in to Apple ID in Xcode → Settings → Accounts
#   3. Run ⌘R from Xcode once to create the provisioning profile
#   4. Trust "jaimer@live.com" on the iPad under
#      Settings → General → VPN & Device Management
#
# Override the device UDID by exporting DEVICE_ID before running.

set -euo pipefail

DEVICE_ID="${DEVICE_ID:-00008103-0001194C0107001E}"
SCHEME="AIQuiz"
PROJECT="AIQuiz.xcodeproj"
DERIVED="./build-device"
APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/AIQuiz.app"

cd "$(dirname "$0")/.."

DEVICES_OUTPUT=$(xcrun xctrace list devices 2>&1 || true)
if ! grep -q "$DEVICE_ID" <<<"$DEVICES_OUTPUT"; then
  echo "Device $DEVICE_ID not connected. Connect the iPad (unlocked, trusted)."
  echo "Available devices:"
  awk '/== Devices ==/,/== Simulators ==/' <<<"$DEVICES_OUTPUT"
  exit 1
fi

# Keep the Xcode project in sync with Project.yml.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen >/dev/null
fi

echo "→ Building for iPad ($DEVICE_ID)…"
BUILD_CMD=(xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "platform=iOS,id=$DEVICE_ID"
  -configuration Debug
  -derivedDataPath "$DERIVED"
  -allowProvisioningUpdates
  build)

if command -v xcbeautify >/dev/null 2>&1; then
  "${BUILD_CMD[@]}" | xcbeautify
else
  "${BUILD_CMD[@]}"
fi

echo "→ Installing ${APP_PATH}…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "✅ Deployed. Launch AIQuiz from the iPad Home screen."
