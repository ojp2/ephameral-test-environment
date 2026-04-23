#!/usr/bin/env bash
# scripts/validate-results.sh
# Parses JMeter JTL (CSV) and exits non-zero on any assertion failure.
# Teardown job uses if: always() so cleanup still runs on test failure.

set -euo pipefail

JTL_FILE="${1:-results/test-results.jtl}"
TEST_CASE="${TEST_CASE:-unknown}"

sep() { printf '%0.s─' {1..56}; echo; }

sep
echo "  JMeter results — ${TEST_CASE}"
echo "  File: ${JTL_FILE}"
sep

[[ ! -f "${JTL_FILE}" ]] && { echo "ERROR: JTL not found"; exit 1; }

TOTAL=0; PASSED=0; FAILED=0
declare -a FAILURES=()

while IFS=',' read -r ts elapsed label code msg thread dtype success failMsg rest; do
  [[ "${ts}" == "timeStamp" || -z "${label}" ]] && continue
  TOTAL=$((TOTAL+1))
  if [[ "${success}" == "true" ]]; then
    PASSED=$((PASSED+1))
  else
    FAILED=$((FAILED+1))
    FAILURES+=("  FAIL | ${label} | HTTP ${code} | ${failMsg}")
  fi
done < "${JTL_FILE}"

printf "\n  Total:  %d\n  Passed: %d\n  Failed: %d\n\n" "${TOTAL}" "${PASSED}" "${FAILED}"

if [[ "${FAILED}" -gt 0 ]]; then
  echo "Failed samples:"
  printf '%s\n' "${FAILURES[@]}"
  echo ""
  sep
  echo "RESULT: FAIL — ${FAILED} failure(s) | test case: ${TEST_CASE}"
  sep
  exit 1
fi

sep
echo "RESULT: PASS — ${PASSED}/${TOTAL} | test case: ${TEST_CASE}"
sep
