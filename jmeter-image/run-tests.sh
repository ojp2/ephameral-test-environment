#!/usr/bin/env bash
# run-tests.sh
# Runs JMeter test plan and uploads JTL results as a GitHub Release asset

set -euo pipefail

: "${BASE_URL:?BASE_URL is required}"
: "${GAME_CODE:?GAME_CODE is required}"
: "${EXPECTED_STATUS:?EXPECTED_STATUS is required}"
: "${EXPECTED_RESULT:?EXPECTED_RESULT is required}"
: "${WAGER_AMOUNT:?WAGER_AMOUNT is required}"
: "${TEST_CASE:?TEST_CASE is required}"
: "${RUN_ID:?RUN_ID is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"  # e.g. sg-is-devops/helm

GITHUB_PAT="${GITHUB_PAT:-}"

RESULTS_DIR=/jmeter/results
mkdir -p "${RESULTS_DIR}/html-report"

echo "========================================"
echo "  Wager JMeter Test"
echo "  Test case   : ${TEST_CASE}"
echo "  Game code   : ${GAME_CODE}"
echo "  Target URL  : ${BASE_URL}"
echo "  Expected    : HTTP ${EXPECTED_STATUS} / ${EXPECTED_RESULT}"
echo "========================================"

# ── Wait for wager app ────────────────────────────────────────────────────────
echo "Waiting for wager app at ${BASE_URL}/health..."
for i in $(seq 1 30); do
  if curl -sf "${BASE_URL}/health" > /dev/null 2>&1; then
    echo "Wager app is healthy after ${i}s"
    break
  fi
  echo "  attempt ${i}/30 — not ready, waiting 5s..."
  sleep 5
done

curl -sf "${BASE_URL}/health" || {
  echo "ERROR: Wager app not healthy"
  exit 1
}

# ── Run JMeter ────────────────────────────────────────────────────────────────
echo "Running JMeter test plan..."
jmeter -n \
  -t  /jmeter/test-plan.jmx \
  -l  "${RESULTS_DIR}/test-results.jtl" \
  -e -o "${RESULTS_DIR}/html-report" \
  -JBASE_URL="${BASE_URL}" \
  -JGAME_CODE="${GAME_CODE}" \
  -JEXPECTED_STATUS="${EXPECTED_STATUS}" \
  -JEXPECTED_RESULT="${EXPECTED_RESULT}" \
  -JWAGER_AMOUNT="${WAGER_AMOUNT}" \
  -JTEST_CASE="${TEST_CASE}"

JMETER_EXIT=$?

# ── Parse results ─────────────────────────────────────────────────────────────
TOTAL=$(awk -F',' 'NR>1{c++} END{print c+0}' "${RESULTS_DIR}/test-results.jtl")
FAILED=$(awk -F',' 'NR>1 && $8=="false"{c++} END{print c+0}' "${RESULTS_DIR}/test-results.jtl")
PASSED=$(awk -F',' 'NR>1 && $8=="true"{c++} END{print c+0}' "${RESULTS_DIR}/test-results.jtl")

echo "========================================"
echo "  Results: ${PASSED}/${TOTAL} passed | ${FAILED} failed"
echo "========================================"

# ── Upload results to GitHub Release ──────────────────────────────────────────
if [ -n "${GITHUB_PAT}" ]; then
  echo "Uploading results to GitHub Release..."

  RELEASE_TAG="test-results-${RUN_ID}"
  RELEASE_NAME="Test Results | ${TEST_CASE} | ${RUN_ID}"
  RELEASE_BODY="Test Case: ${TEST_CASE}\nRun ID: ${RUN_ID}\nGame: ${GAME_CODE}\nExpected: HTTP ${EXPECTED_STATUS} / ${EXPECTED_RESULT}\nResults: ${PASSED}/${TOTAL} passed | ${FAILED} failed"

  # Create a release
  RELEASE_RESPONSE=$(curl -sf -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Content-Type: application/json" \
    "https://api.github.com/repos/${GITHUB_REPO}/releases" \
    -d "{
      \"tag_name\": \"${RELEASE_TAG}\",
      \"name\": \"${RELEASE_NAME}\",
      \"body\": \"${RELEASE_BODY}\",
      \"draft\": false,
      \"prerelease\": true
    }" 2>/dev/null || echo "FAILED")

  if [ "${RELEASE_RESPONSE}" != "FAILED" ]; then
    UPLOAD_URL=$(echo "${RELEASE_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# strip the {?name,label} suffix
url = d.get('upload_url', '').split('{')[0]
print(url)
" 2>/dev/null || echo "")

    RELEASE_URL=$(echo "${RELEASE_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('html_url', 'unknown'))
" 2>/dev/null || echo "unknown")

    if [ -n "${UPLOAD_URL}" ]; then
      # Upload JTL file
      curl -sf -X POST \
        -H "Authorization: token ${GITHUB_PAT}" \
        -H "Content-Type: text/plain" \
        "${UPLOAD_URL}?name=test-results-${TEST_CASE}.jtl" \
        --data-binary @"${RESULTS_DIR}/test-results.jtl" > /dev/null

      echo "========================================"
      echo "  Results uploaded:"
      echo "  ${RELEASE_URL}"
      echo "========================================"

      # Save URL for pipeline to read
      echo "${RELEASE_URL}" > "${RESULTS_DIR}/results-url.txt"
    fi
  else
    echo "WARNING: Failed to create GitHub Release"
  fi
else
  echo "WARNING: GITHUB_PAT not set — skipping upload"
fi

# ── Exit ──────────────────────────────────────────────────────────────────────
if [ "${FAILED}" -gt 0 ]; then
  echo "RESULT: FAIL — ${FAILED} assertion(s) failed"
  exit 1
fi

echo "RESULT: PASS — all ${PASSED} assertions passed"
exit 0