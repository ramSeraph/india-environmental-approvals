#!/bin/bash

set -uo pipefail

STATE=${1:-""}
FORCE=${FORCE:-0}
FAILURES=0
SKIPPED=0
FETCHED=0
STAGE_ROOT=${STAGE_ROOT:-${RUNNER_TEMP:-${PWD}/.staging}/india-environmental-approvals-staging}

is_valid_json_file() {
  local file_path="$1"

  [ -s "$file_path" ] || return 1

  python3 - <<'PY' "$file_path"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
}

# Create output directory with state suffix if filtering by state
if [ -n "$STATE" ]; then
  OUTPUT_DIR="raw/search_${STATE}"
  STAGE_DIR="${STAGE_ROOT}/initialize-${STATE}"
  echo "Fetching data for state: $STATE"
else
  OUTPUT_DIR="raw/search"
  STAGE_DIR="${STAGE_ROOT}/initialize-all"
  echo "Fetching data for all states"
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

for clearance in {1..4}; do
  OUTPUT_FILE="$OUTPUT_DIR/${clearance}.json"
  TEMP_FILE="${STAGE_DIR}/${clearance}.json"
  API_URL="https://parivesh.nic.in/parivesh_api/trackYourProposal/advanceSearchData?majorClearanceType=${clearance}&state=${STATE}&sector=&proposalStatus=&proposalType=&issuingAuthority=&activityId=&category=&startDate=&endDate=&areaMin=&areaMax=&text="

  if [ "$FORCE" != "1" ] && is_valid_json_file "$OUTPUT_FILE"; then
    echo "Skipping clearance type $clearance; valid output already exists at $OUTPUT_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  rm -f "$TEMP_FILE"

  echo "Fetching clearance type $clearance for state '$STATE'..."
  if curl --fail --silent --show-error --location "$API_URL" -o "$TEMP_FILE" && is_valid_json_file "$TEMP_FILE"; then
    mv "$TEMP_FILE" "$OUTPUT_FILE"
    echo "Successfully fetched data for clearance type $clearance"
    FETCHED=$((FETCHED + 1))
  else
    echo "Warning: Failed to fetch valid data for clearance type $clearance"
    rm -f "$TEMP_FILE"
    FAILURES=$((FAILURES + 1))
  fi
done

echo "Initialization summary: fetched=$FETCHED skipped=$SKIPPED failed=$FAILURES"
echo "Files saved to: $OUTPUT_DIR"

if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
