#!/usr/bin/env bash
# Run every test layer: package unit tests on macOS, then app unit tests and UI tests
# on the iPad Pro simulator. See CLAUDE.md and PLAN.md §1.
#
#   scripts/test.sh                 # everything
#   ONLY=AIQuizTests scripts/test.sh   # one xcodebuild test bundle
#   SKIP_UI=1 scripts/test.sh       # skip the UI test bundle
#   SIM_UDID=<udid> scripts/test.sh # another simulator

set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${SIM_UDID:-D62334E0-1BBB-4781-A549-36CFD4B56907}"
DERIVED="${DERIVED:-./build/test}"
mkdir -p "$(dirname "$DERIVED")"

echo "→ Package tests (AIQuizCore)"
swift test --package-path Packages/AIQuizCore 2>&1 | tail -n 3

if [ -d Packages/LLMKit ]; then
  echo "→ Package tests (LLMKit)"
  swift test --package-path Packages/LLMKit 2>&1 | tail -n 3
fi

echo "→ Regenerating Xcode project"
xcodegen >/dev/null

ONLY_ARGS=()
if [ -n "${ONLY:-}" ]; then
  ONLY_ARGS+=(-only-testing:"$ONLY")
elif [ -n "${SKIP_UI:-}" ]; then
  ONLY_ARGS+=(-only-testing:AIQuizTests)
fi

echo "→ App tests on simulator $SIM"
set +e
xcodebuild test \
  -project AIQuiz.xcodeproj \
  -scheme AIQuiz \
  -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$DERIVED" \
  ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"} 2>&1 | tee "$DERIVED.log" | grep -E "^(Test Suite|Test Case|Executed|\*\* TEST)|error:|failed"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "✗ xcodebuild test failed (status $STATUS). Full log: $DERIVED.log"
  exit "$STATUS"
fi
echo "✅ All tests passed"
