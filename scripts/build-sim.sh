#!/usr/bin/env bash
# Build the app for the iPad Pro simulator and print the .app path.
# Treats warnings as failures so the "zero warnings" rule in CLAUDE.md is enforced.
#
#   scripts/build-sim.sh            # build
#   SIM_UDID=<udid> scripts/build-sim.sh

set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${SIM_UDID:-D62334E0-1BBB-4781-A549-36CFD4B56907}"
DERIVED="${DERIVED:-./build/sim}"
mkdir -p "$(dirname "$DERIVED")"

xcodegen >/dev/null

set +e
xcodebuild \
  -project AIQuiz.xcodeproj \
  -scheme AIQuiz \
  -destination "platform=iOS Simulator,id=$SIM" \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  build 2>&1 | tee "$DERIVED.log" | grep -E "warning:|error:|BUILD (SUCCEEDED|FAILED)" | grep -v "appintentsmetadataprocessor"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "✗ build failed. Full log: $DERIVED.log"
  exit "$STATUS"
fi

SWIFT_WARNINGS=$( (grep "warning:" "$DERIVED.log" || true) | (grep -v appintentsmetadataprocessor || true) | wc -l | tr -d ' ')
if [ "$SWIFT_WARNINGS" != "0" ]; then
  echo "✗ $SWIFT_WARNINGS compiler warning(s); CLAUDE.md requires zero."
  exit 1
fi

echo "✅ Build succeeded with zero warnings"
echo "$DERIVED/Build/Products/Debug-iphonesimulator/AIQuiz.app"
