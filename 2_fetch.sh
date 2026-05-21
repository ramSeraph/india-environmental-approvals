#!/bin/bash

set -uo pipefail

# State parameter - should match the one used in initialize.sh
STATE=${1:-""}
FAILURES=0
SEARCH_FILES_FOUND=0
TEMP_FILES=()
STAGE_ROOT=${STAGE_ROOT:-${RUNNER_TEMP:-${PWD}/.staging}/india-environmental-approvals-staging}

# Parallelization parameters
MIN_BATCH_SIZE=${MIN_BATCH_SIZE:-37}
MAX_BATCH_SIZE=${MAX_BATCH_SIZE:-153}
MIN_DELAY=${MIN_DELAY:-0.1}
MAX_DELAY=${MAX_DELAY:-2}
MAX_CONCURRENT=${MAX_CONCURRENT:-35}
MIN_RETRY_DELAY=${MIN_RETRY_DELAY:-1}
MAX_RETRY_DELAY=${MAX_RETRY_DELAY:-3}

IFS=$'\n'

cleanup_temp_files() {
  local temp_file
  for temp_file in "${TEMP_FILES[@]}"; do
    rm -f "$temp_file"
  done
}

check_runtime_budget() {
  local context="$1"

  if [ -z "${PIPELINE_DEADLINE_EPOCH:-}" ]; then
    return 0
  fi

  local now
  now=$(date +%s)
  if [ "$now" -ge "$PIPELINE_DEADLINE_EPOCH" ]; then
    echo "Pipeline runtime budget exceeded before ${context}" >&2
    exit 1
  fi
}

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

# Determine search directory based on state parameter
if [ -n "$STATE" ]; then
  SEARCH_DIR="raw/search_${STATE}"
  CAF_DIR="raw/caf_${STATE}"
  STAGE_DIR="${STAGE_ROOT}/fetch-${STATE}"
  URL_FILE="${STAGE_DIR}/urls_${STATE}.txt"
  echo "Processing data for state: $STATE"
else
  SEARCH_DIR="raw/search"
  CAF_DIR="raw/caf"
  STAGE_DIR="${STAGE_ROOT}/fetch-all"
  URL_FILE="${STAGE_DIR}/urls_all.txt"
  echo "Processing data for all states"
fi

# Check if search directory exists
if [ ! -d "$SEARCH_DIR" ]; then
  echo "Error: Search directory $SEARCH_DIR not found. Please run initialize.sh first."
  exit 1
fi

mkdir -p "$CAF_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

trap cleanup_temp_files EXIT

# Check if uv is available for the inline-dependency downloader script
if ! command -v uv &> /dev/null; then
  echo "Error: uv is required to run request.py"
  exit 1
fi

echo "Generating URL list for parallel downloading..."
check_runtime_budget "building CAF URL list"

# Create combined timestamp file for comparison
if [ -n "$STATE" ]; then
  TIMESTAMP_FILE="${STAGE_DIR}/timestamps_${STATE}.json"
else
  TIMESTAMP_FILE="${STAGE_DIR}/timestamps_all.json"
fi

echo "Creating combined timestamp file: $TIMESTAMP_FILE"

URL_FILE_TMP="$(mktemp "${URL_FILE}.XXXXXX.tmp")"
TIMESTAMP_FILE_TMP="$(mktemp "${TIMESTAMP_FILE}.XXXXXX.tmp")"
TEMP_FILES+=("$URL_FILE_TMP" "$TIMESTAMP_FILE_TMP")

VALID_SEARCH_FILES=()
for clearance in {1..4}; do
  check_runtime_budget "processing clearance type ${clearance} search results"
  SEARCH_FILE="$SEARCH_DIR/${clearance}.json"

  if [ ! -e "$SEARCH_FILE" ]; then
    echo "Warning: No data file found at $SEARCH_FILE, skipping clearance type $clearance"
    continue
  fi

  SEARCH_FILES_FOUND=$((SEARCH_FILES_FOUND + 1))

  if ! is_valid_json_file "$SEARCH_FILE"; then
    echo "Warning: Invalid JSON in $SEARCH_FILE, skipping clearance type $clearance"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  VALID_SEARCH_FILES+=("$SEARCH_FILE")
done

if [ "$SEARCH_FILES_FOUND" -eq 0 ]; then
  echo "Error: No search files found in $SEARCH_DIR. Please run initialize.sh first."
  exit 1
fi

if [ "${#VALID_SEARCH_FILES[@]}" -gt 0 ]; then
  jq -s '{"data": ([.[] | .data // []] | add)}' "${VALID_SEARCH_FILES[@]}" > "$TIMESTAMP_FILE_TMP"
else
  printf '{"data":[]}\n' > "$TIMESTAMP_FILE_TMP"
fi

# First pass: count total proposals and generate URL file
total_proposals_all=0
for clearance in {1..4}; do
  SEARCH_FILE="$SEARCH_DIR/${clearance}.json"
  
  if [ ! -e "$SEARCH_FILE" ]; then
    continue
  fi

  if ! is_valid_json_file "$SEARCH_FILE"; then
    continue
  fi
  
  mkdir -p "$CAF_DIR/${clearance}"
  
  echo "Processing clearance type $clearance..."
  
  # Extract all proposal IDs and generate URLs
  proposal_ids=$(jq -r '.data[]? | select(.id != null) | .id' "$SEARCH_FILE" 2>/dev/null || echo "")
  
  if [ -z "$proposal_ids" ]; then
    echo "  No valid proposal IDs found in $SEARCH_FILE"
    continue
  fi
  
  for proposal_id in $proposal_ids; do
    url="https://parivesh.nic.in/parivesh_api/proponentApplicant/getCafDataByProposalNo?proposal_id=${proposal_id}"
    output_path="$CAF_DIR/${clearance}/${proposal_id}.json"
    
    # Add to URL file (tab-separated)
    printf "%s\t%s\n" "$url" "$output_path" >> "$URL_FILE_TMP"
    total_proposals_all=$((total_proposals_all + 1))
  done
done

mv "$URL_FILE_TMP" "$URL_FILE"
mv "$TIMESTAMP_FILE_TMP" "$TIMESTAMP_FILE"
echo "Generated URL list with $total_proposals_all proposals"
echo ""

# Check if URL file was created and has content
if [ ! -s "$URL_FILE" ]; then
  if [ "$FAILURES" -gt 0 ]; then
    echo "Error: No URLs generated because all valid search files were skipped or invalid."
    exit 1
  fi

  echo "No proposal URLs found. Nothing to fetch."
  exit 0
fi

# Run the parallel downloader
echo "Starting parallel download with configuration:"
echo "  Batch size: $MIN_BATCH_SIZE-$MAX_BATCH_SIZE"
echo "  Delay between batches: ${MIN_DELAY}s-${MAX_DELAY}s" 
echo "  Retry delay on 5xx: ${MIN_RETRY_DELAY}s-${MAX_RETRY_DELAY}s"
echo "  Max concurrent downloads: $MAX_CONCURRENT"
echo ""

deadline_args=()
if [ -n "${PIPELINE_DEADLINE_EPOCH:-}" ]; then
  deadline_args+=(--deadline-epoch "$PIPELINE_DEADLINE_EPOCH")
fi

uv run request.py "$URL_FILE" \
  --min-batch-size "$MIN_BATCH_SIZE" \
  --max-batch-size "$MAX_BATCH_SIZE" \
  --min-delay "$MIN_DELAY" \
  --max-delay "$MAX_DELAY" \
  --min-retry-delay "$MIN_RETRY_DELAY" \
  --max-retry-delay "$MAX_RETRY_DELAY" \
  --max-concurrent "$MAX_CONCURRENT" \
  --staging-root "$STAGE_DIR/downloads" \
  --timestamp-file "$TIMESTAMP_FILE" \
  "${deadline_args[@]}"

download_exit_code=$?

# Clean up temporary files
rm -f "$URL_FILE"
rm -f "$TIMESTAMP_FILE"

if [ $download_exit_code -eq 0 ]; then
  echo ""
  echo "Data fetching completed successfully. Files saved to: $CAF_DIR"
else
  echo ""
  echo "Warning: Parallel download script exited with code $download_exit_code"
  echo "Some downloads may have failed. You may want to re-run this script."
  exit "$download_exit_code"
fi
