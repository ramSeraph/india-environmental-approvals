#!/bin/bash

set -uo pipefail

STATE=${1:-""}
FORCE=${FORCE:-0}
FAILURES=0
SKIPPED=0
FETCHED=0
STAGE_ROOT=${STAGE_ROOT:-${RUNNER_TEMP:-${PWD}/.staging}/india-environmental-approvals-staging}
SEARCH_PARTITION_START_DATE=${SEARCH_PARTITION_START_DATE:-2021-01-01}
SEARCH_PARTITION_END_DATE=${SEARCH_PARTITION_END_DATE:-$(date -u +%Y-%m-%d)}
CURL_MAX_TIME=${CURL_MAX_TIME:-30}
CURL_HTTP_CODE=""
CURL_EXIT_CODE=0

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

build_api_url() {
  local clearance="$1"
  local start_date="${2:-}"
  local end_date="${3:-}"

  printf '%s?majorClearanceType=%s&state=%s&sector=&proposalStatus=&proposalType=&issuingAuthority=&activityId=&category=&startDate=%s&endDate=%s&areaMin=&areaMax=&text=' \
    "https://parivesh.nic.in/parivesh_api/trackYourProposal/advanceSearchData" \
    "$clearance" \
    "$STATE" \
    "$start_date" \
    "$end_date"
}

fetch_url_to_file() {
  local url="$1"
  local output_file="$2"
  local http_code_file
  local curl_exit_code

  http_code_file="$(mktemp "${STAGE_DIR}/http-code.XXXXXX")"
  rm -f "$output_file"

  curl --silent --show-error --location --max-time "$CURL_MAX_TIME" --write-out '%{http_code}' -o "$output_file" "$url" >"$http_code_file"
  curl_exit_code=$?

  if [ "$curl_exit_code" -eq 0 ]; then
    CURL_HTTP_CODE="$(tr -d '\r\n' <"$http_code_file")"
    CURL_EXIT_CODE=0
    rm -f "$http_code_file"
    return 0
  fi

  CURL_HTTP_CODE="$(tr -d '\r\n' <"$http_code_file" 2>/dev/null || true)"
  CURL_EXIT_CODE="$curl_exit_code"
  rm -f "$http_code_file"
  return 1
}

should_partition_failure() {
  [ "${CURL_HTTP_CODE:-}" = "504" ] || [ "${CURL_EXIT_CODE:-0}" = "28" ]
}

partition_failure_label() {
  if [ "${CURL_EXIT_CODE:-0}" = "28" ]; then
    printf 'curl timeout'
  else
    printf '504'
  fi
}

midpoint_date() {
  python3 - <<'PY' "$1" "$2"
from datetime import date, timedelta
import sys

start = date.fromisoformat(sys.argv[1])
end = date.fromisoformat(sys.argv[2])
delta_days = (end - start).days
print((start + timedelta(days=delta_days // 2)).isoformat())
PY
}

offset_date() {
  python3 - <<'PY' "$1" "$2"
from datetime import date, timedelta
import sys

base = date.fromisoformat(sys.argv[1])
offset_days = int(sys.argv[2])
print((base + timedelta(days=offset_days)).isoformat())
PY
}

merge_search_json_files() {
  local output_file="$1"
  shift

  python3 - <<'PY' "$output_file" "$@"
import json
import sys

output_file = sys.argv[1]
input_files = sys.argv[2:]

merged = {"data": []}
seen = set()

def row_key(row):
    if isinstance(row, dict):
        for key in ("id", "proposal_id", "proposalNo", "application_id", "cafnumber"):
            value = row.get(key)
            if value is not None:
                return (key, str(value))
    return ("json", json.dumps(row, sort_keys=True, ensure_ascii=False))

for input_file in input_files:
    with open(input_file, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if isinstance(payload, dict):
        for key in ("status", "message", "error"):
            if key in payload and key not in merged:
                merged[key] = payload[key]
        rows = payload.get("data") or []
    else:
        rows = []
    for row in rows:
        key = row_key(row)
        if key in seen:
            continue
        seen.add(key)
        merged["data"].append(row)

merged.setdefault("status", 200)
merged.setdefault("message", "success")
merged.setdefault("error", False)

with open(output_file, "w", encoding="utf-8") as handle:
    json.dump(merged, handle, ensure_ascii=False)
PY
}

fetch_clearance_range() {
  local clearance="$1"
  local start_date="$2"
  local end_date="$3"
  local output_file="$4"
  local url
  local temp_file

  url="$(build_api_url "$clearance" "$start_date" "$end_date")"
  temp_file="$(mktemp "${STAGE_DIR}/search-${clearance}.XXXXXX")"

  echo "Fetching clearance type $clearance for state '$STATE' from ${start_date} to ${end_date}..."

  if fetch_url_to_file "$url" "$temp_file" && [ "$CURL_HTTP_CODE" = "200" ] && is_valid_json_file "$temp_file"; then
    mv "$temp_file" "$output_file"
    return 0
  fi

  rm -f "$temp_file"

  if ! should_partition_failure; then
    echo "Warning: Failed to fetch valid data for clearance type $clearance from ${start_date} to ${end_date} (http=${CURL_HTTP_CODE:-curl-error} curl_exit=${CURL_EXIT_CODE:-unknown})"
    return 1
  fi

  if [ "$start_date" = "$end_date" ]; then
    echo "Warning: Received $(partition_failure_label) for single-day range ${start_date}; cannot partition further for clearance type $clearance"
    return 1
  fi

  local mid_date
  local next_start_date
  local left_file
  local right_file

  mid_date="$(midpoint_date "$start_date" "$end_date")"
  next_start_date="$(offset_date "$mid_date" 1)"
  left_file="$(mktemp "${STAGE_DIR}/search-${clearance}.left.XXXXXX")"
  right_file="$(mktemp "${STAGE_DIR}/search-${clearance}.right.XXXXXX")"

  echo "Received $(partition_failure_label) for clearance type $clearance; partitioning ${start_date}..${end_date} into ${start_date}..${mid_date} and ${next_start_date}..${end_date}"

  if fetch_clearance_range "$clearance" "$start_date" "$mid_date" "$left_file" && \
     fetch_clearance_range "$clearance" "$next_start_date" "$end_date" "$right_file" && \
     merge_search_json_files "$output_file" "$left_file" "$right_file"; then
    rm -f "$left_file" "$right_file"
    return 0
  fi

  rm -f "$left_file" "$right_file" "$output_file"
  return 1
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
  API_URL="$(build_api_url "$clearance" "" "")"

  if [ "$FORCE" != "1" ] && is_valid_json_file "$OUTPUT_FILE"; then
    echo "Skipping clearance type $clearance; valid output already exists at $OUTPUT_FILE"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  rm -f "$TEMP_FILE"

  echo "Fetching clearance type $clearance for state '$STATE'..."
  if fetch_url_to_file "$API_URL" "$TEMP_FILE" && [ "$CURL_HTTP_CODE" = "200" ] && is_valid_json_file "$TEMP_FILE"; then
    mv "$TEMP_FILE" "$OUTPUT_FILE"
    echo "Successfully fetched data for clearance type $clearance"
    FETCHED=$((FETCHED + 1))
  elif should_partition_failure && fetch_clearance_range "$clearance" "$SEARCH_PARTITION_START_DATE" "$SEARCH_PARTITION_END_DATE" "$OUTPUT_FILE"; then
    echo "Successfully fetched data for clearance type $clearance via date partitioning"
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
