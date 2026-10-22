#!/usr/bin/env bash
# Run the opt-in live API tests (PLAN §1.6) against Anthropic and OpenAI, with keys read
# from the macOS login Keychain. Spends a few cents per run. Never prints a key.
#
# Store each key once. The command prompts for the value, so it stays out of shell history:
#   security add-generic-password -U -a "$USER" -s AIQuiz_Ant_test_key -w
#   security add-generic-password -U -a "$USER" -s AIQuiz_Oai_test_key -w
#
# Usage:
#   scripts/live-test.sh                      # Anthropic only
#   scripts/live-test.sh -m <openai-model>    # also OpenAI, with this chat model
#   AIQuiz_Oai_test_model=<model> scripts/live-test.sh
#   AIQuiz_Ant_test_model=claude-haiku-5-5 scripts/live-test.sh   # override the Anthropic model
#
# Remove the keys:
#   security delete-generic-password -s AIQuiz_Ant_test_key
#   security delete-generic-password -s AIQuiz_Oai_test_key

set -euo pipefail
cd "$(dirname "$0")/.."

OPENAI_MODEL_ARG=""
while getopts "m:" opt; do
  case "$opt" in
    m) OPENAI_MODEL_ARG="$OPTARG" ;;
    *) echo "usage: $0 [-m openai-model]" >&2; exit 2 ;;
  esac
done

read_key() {
  security find-generic-password -s "$1" -w 2>/dev/null || true
}

ANT_KEY="$(read_key AIQuiz_Ant_test_key)"
OAI_KEY="$(read_key AIQuiz_Oai_test_key)"
OAI_MODEL="${OPENAI_MODEL_ARG:-${AIQuiz_Oai_test_model:-}}"
ANT_MODEL="${AIQuiz_Ant_test_model:-}"

if [ -n "$ANT_KEY" ]; then
  echo "Anthropic: key found in Keychain (model ${ANT_MODEL:-claude-opus-5-5})"
else
  echo "Anthropic: no AIQuiz_Ant_test_key in Keychain, skipping"
fi

if [ -n "$OAI_KEY" ] && [ -n "$OAI_MODEL" ]; then
  echo "OpenAI: key found in Keychain (model $OAI_MODEL)"
elif [ -n "$OAI_KEY" ]; then
  echo "OpenAI: key found but no model given; pass -m <chat-model> to include it. Skipping."
  OAI_KEY=""
else
  echo "OpenAI: no AIQuiz_Oai_test_key in Keychain, skipping"
fi

if [ -z "$ANT_KEY" ] && [ -z "$OAI_KEY" ]; then
  echo "Nothing to test. Store a key with the security commands at the top of this script."
  exit 1
fi

set +e
AIQUIZ_LIVE_TESTS=1 \
AIQuiz_Ant_test_key="$ANT_KEY" AIQuiz_Ant_test_model="$ANT_MODEL" \
AIQuiz_Oai_test_key="$OAI_KEY" AIQuiz_Oai_test_model="$OAI_MODEL" \
  swift test --package-path Packages/LLMKit --filter Live 2>&1 \
  | grep -E "✔ Test|✘|Issue|error:|Test run with" | grep -v "started"
STATUS=${PIPESTATUS[0]}
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "✅ Live tests passed"
else
  echo "✗ Live tests failed (status $STATUS)"
fi
exit "$STATUS"
