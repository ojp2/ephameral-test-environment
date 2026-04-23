#!/usr/bin/env bash
# run-tests.sh
# Runs JMeter test plan, uploads results to S3, exits with JMeter exit code
# All config comes from environment variables injected by the K8s Job

set -euo pipefail

# ── Required env vars (injected by Helm) ──────────────────────────────────────
: "${BASE_URL:?BASE_URL is required}"
: "${GAME_CODE:?GAME_CODE is required}"
: "${EXPECTED_STATUS:?EXPECTED_STATUS is required}"
: "${EXPECTED_RESULT:?EXPECTED_RESULT is required}"
: "${WAGER_AMOUNT:?WAGER_AMOUNT is required}"
: "${TEST_CASE:?TEST_CASE is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:?S3_PREFIX is required}"

RESULTS_DIR=/jmeter/results
mkdir -p "${RESULTS_DIR}/html-report"

echo "========================================"
echo "  Wager JMeter Test"
echo "  Test case   : ${TEST_CASE}"
echo "  Game code   : ${GAME_CODE}"
echo "  Target URL  : ${BASE_URL}"
echo "  Expected    : HTTP ${EXPECTED_STATUS} / ${EXPECTED_RESULT}"
echo "========================================"

# ── Wait for wager app to be healthy ─────────────────────────────────────────
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
  echo "ERROR: Wager app not healthy after 150s"
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
echo "JMeter exit code: ${JMETER_EXIT}"

# ── Validate results ──────────────────────────────────────────────────────────
TOTAL=$(awk -F',' 'NR>1{count++} END{print count+0}' "${RESULTS_DIR}/test-results.jtl")
FAILED=$(awk -F',' 'NR>1 && $8=="false"{count++} END{print count+0}' "${RESULTS_DIR}/test-results.jtl")
PASSED=$(awk -F',' 'NR>1 && $8=="true"{count++} END{print count+0}' "${RESULTS_DIR}/test-results.jtl")

echo "========================================"
echo "  Results: ${PASSED}/${TOTAL} passed | ${FAILED} failed"
echo "  Test case: ${TEST_CASE}"
echo "========================================"

# ── Upload results to S3 ──────────────────────────────────────────────────────
echo "Uploading results to s3://${S3_BUCKET}/${S3_PREFIX}/"

aws s3 cp "${RESULTS_DIR}/test-results.jtl" \
  "s3://${S3_BUCKET}/${S3_PREFIX}/test-results.jtl"

aws s3 sync "${RESULTS_DIR}/html-report" \
  "s3://${S3_BUCKET}/${S3_PREFIX}/html-report/"

echo "Results uploaded to s3://${S3_BUCKET}/${S3_PREFIX}/"

# ── Exit with failure if any assertions failed ────────────────────────────────
if [ "${FAILED}" -gt 0 ]; then
  echo "RESULT: FAIL — ${FAILED} assertion(s) failed"
  exit 1
fi

echo "RESULT: PASS — all ${PASSED} assertions passed"
exit 0
