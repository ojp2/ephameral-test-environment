#!/usr/bin/env bash
# run-tests.sh
# Runs JMeter test plan and uploads results to GitHub Gist using PAT from Vault secret

set -euo pipefail

# ── Required env vars ─────────────────────────────────────────────────────────
: "${BASE_URL:?BASE_URL is required}"
: "${GAME_CODE:?GAME_CODE is required}"
: "${EXPECTED_STATUS:?EXPECTED_STATUS is required}"
: "${EXPECTED_RESULT:?EXPECTED_RESULT is required}"
: "${WAGER_AMOUNT:?WAGER_AMOUNT is required}"
: "${TEST_CASE:?TEST_CASE is required}"
: "${RUN_ID:?RUN_ID is required}"

# GitHub PAT — injected from Vault secret mounted as env var
# Secret key name from vault secret gh-devops-token
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

# ── Wait for wager app to be healthy ──────────────────────────────────────────
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

# ── Upload results to GitHub Gist ─────────────────────────────────────────────
if [ -n "${GITHUB_PAT}" ]; then
  echo "Uploading results to GitHub Gist..."

  # Read JTL content — escape for JSON
  JTL_CONTENT=$(cat "${RESULTS_DIR}/test-results.jtl" | python3 -c "
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
")

  # Build summary content
  SUMMARY="Test Case: ${TEST_CASE}
Run ID: ${RUN_ID}
Game Code: ${GAME_CODE}
Expected: HTTP ${EXPECTED_STATUS} / ${EXPECTED_RESULT}
Results: ${PASSED}/${TOTAL} passed | ${FAILED} failed
JMeter Exit Code: ${JMETER_EXIT}
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  SUMMARY_JSON=$(echo "${SUMMARY}" | python3 -c "
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
")

  # Create GitHub Gist with both files
  GIST_RESPONSE=$(curl -sf -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Content-Type: application/json" \
    https://api.github.com/gists \
    -d "{
      \"description\": \"JMeter Results | ${TEST_CASE} | ${RUN_ID} | $(date -u +%Y-%m-%d)\",
      \"public\": false,
      \"files\": {
        \"summary.txt\": {
          \"content\": ${SUMMARY_JSON}
        },
        \"test-results.jtl\": {
          \"content\": ${JTL_CONTENT}
        }
      }
    }" || echo "GIST_FAILED")

  if [ "${GIST_RESPONSE}" != "GIST_FAILED" ]; then
    GIST_URL=$(echo "${GIST_RESPONSE}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('html_url', 'unknown'))
" 2>/dev/null || echo "unknown")
    echo "========================================"
    echo "  Results uploaded to GitHub Gist:"
    echo "  ${GIST_URL}"
    echo "========================================"

    # Write gist URL to a file so it can be read by other processes
    echo "${GIST_URL}" > "${RESULTS_DIR}/gist-url.txt"
  else
    echo "WARNING: Failed to upload results to GitHub Gist"
  fi
else
  echo "WARNING: GITHUB_PAT not set — skipping Gist upload"
fi

# ── Exit with failure if any assertions failed ─────────────────────────────────
if [ "${FAILED}" -gt 0 ]; then
  echo "RESULT: FAIL — ${FAILED} assertion(s) failed"
  exit 1
fi

echo "RESULT: PASS — all ${PASSED} assertions passed"
exit 0