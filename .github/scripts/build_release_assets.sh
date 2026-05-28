#!/usr/bin/env bash

set -euo pipefail

STATE_CODE=${1:?state code is required}
STATE_NAME=${2:?state name is required}

GPIO_VERSION=${GPIO_VERSION:-0.9.0}
RUN_CONTEXT=${RUN_METADATA_CONTEXT:-${GITHUB_WORKFLOW:-manual}}
RUN_ID=${GITHUB_RUN_ID:-n/a}
RUN_ATTEMPT=${GITHUB_RUN_ATTEMPT:-n/a}
COMMIT_SHA=${GITHUB_SHA:-${SOURCE_COMMIT_SHA:-unknown}}
COMPLETED_AT=${RUN_METADATA_COMPLETED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
FORCE_REBUILD_RELEASE_ASSETS=${FORCE_REBUILD_RELEASE_ASSETS:-0}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

require_command tippecanoe
require_command pmtiles
require_command uvx
require_command 7z

create_flat_archive() {
  local archive_path="$1"
  local input_path="$2"
  local input_dir
  local input_name

  input_dir=$(dirname "$input_path")
  input_name=$(basename "$input_path")

  (
    cd "$input_dir"
    7z a -bd -mx=9 "$archive_path" "$input_name"
  )
}

mkdir -p dist

stage_root="${RUNNER_TEMP:-${PWD}/.staging}/india-environmental-approvals-staging"
mkdir -p "$stage_root"
stage_dir=$(mktemp -d "${stage_root}/release-assets-${STATE_CODE}.XXXXXX")

cleanup() {
  rm -rf "$stage_dir"
}

trap cleanup EXIT

csv_file="csv/Projects_${STATE_CODE}.csv"
geojsonl_file="geojson/Projects_${STATE_CODE}.geojsonl"
pmtiles_file="dist/Projects_${STATE_CODE}.pmtiles"
mbtiles_file="${stage_dir}/Projects_${STATE_CODE}.mbtiles"
pmtiles_stage_file="${stage_dir}/Projects_${STATE_CODE}.pmtiles"
parquet_file="dist/Projects_${STATE_CODE}.parquet"
parquet_stage_file="${stage_dir}/Projects_${STATE_CODE}.parquet"
csv_archive="dist/Projects_${STATE_CODE}.csv.7z"
geojsonl_archive="dist/Projects_${STATE_CODE}.geojsonl.7z"
csv_archive_stage="${stage_dir}/Projects_${STATE_CODE}.csv.7z"
geojsonl_archive_stage="${stage_dir}/Projects_${STATE_CODE}.geojsonl.7z"
run_info_file="dist/Projects_${STATE_CODE}_run.txt"
run_info_stage="${stage_dir}/Projects_${STATE_CODE}_run.txt"

if [ ! -f "$csv_file" ]; then
  echo "Missing expected CSV output: $csv_file" >&2
  exit 1
fi

if [ ! -f "$geojsonl_file" ]; then
  echo "Missing expected GeoJSONL output: $geojsonl_file" >&2
  exit 1
fi

if [ -f "$pmtiles_file" ] && [ "$FORCE_REBUILD_RELEASE_ASSETS" != "1" ]; then
  echo "Reusing cached PMTiles: $pmtiles_file"
else
  rm -f "$pmtiles_file" "$pmtiles_stage_file" "$mbtiles_file"
  tippecanoe \
    -P \
    -S 10 \
    --increase-gamma-as-needed \
    -zg \
    -o "$mbtiles_file" \
    --simplify-only-low-zooms \
    --coalesce-smallest-as-needed \
    # this was causing rajasthan to create a very deep pmtiles file which goes past 2 GB and then fail partitioning, so disabling.. unnecesarry in the first place i think
    # in the intital release only Rajasthan was genereted with this flag off
    #--extend-zooms-if-still-dropping \
    -n "Projects ${STATE_NAME}" \
    -l "projects_${STATE_CODE}" \
    -A 'Source: <a href="https://parivesh.nic.in/" target="_blank" rel="noopener noreferrer">Parivesh</a>' \
    "$geojsonl_file"
  pmtiles convert "$mbtiles_file" "$pmtiles_stage_file"
  rm -f "$mbtiles_file"
  mv "$pmtiles_stage_file" "$pmtiles_file"
fi

if [ -f "$parquet_file" ] && [ "$FORCE_REBUILD_RELEASE_ASSETS" != "1" ]; then
  echo "Reusing cached GeoParquet: $parquet_file"
else
  rm -f "$parquet_file" "$parquet_stage_file"
  uvx --from "geoparquet-io==${GPIO_VERSION}" gpio convert \
    --geoparquet-version 1.1 \
    --compression zstd \
    --compression-level 22 \
    "$geojsonl_file" \
    "$parquet_stage_file"
  mv "$parquet_stage_file" "$parquet_file"
fi

{
  echo "State Code: ${STATE_CODE}"
  echo "State Name: ${STATE_NAME}"
  echo "Workflow: ${RUN_CONTEXT}"
  echo "Run ID: ${RUN_ID}"
  echo "Run Attempt: ${RUN_ATTEMPT}"
  echo "Commit SHA: ${COMMIT_SHA}"
  if [ -n "${SOURCE_RELEASE_TAG:-}" ]; then
    echo "Source Release Tag: ${SOURCE_RELEASE_TAG}"
  fi
  if [ -n "${REPAIRED_FEATURES_ADDED:-}" ]; then
    echo "Repaired Features Added: ${REPAIRED_FEATURES_ADDED}"
  fi
  echo "Completed At (UTC): ${COMPLETED_AT}"
  echo "CSV Output: ${csv_file}"
  echo "GeoJSONL Output: ${geojsonl_file}"
  echo "PMTiles Output: ${pmtiles_file}"
  echo "GeoParquet Output: ${parquet_file}"
} >"$run_info_stage"
mv "$run_info_stage" "$run_info_file"

rm -f "$csv_archive" "$geojsonl_archive" "$csv_archive_stage" "$geojsonl_archive_stage"
create_flat_archive "$csv_archive_stage" "$csv_file"
create_flat_archive "$geojsonl_archive_stage" "$geojsonl_file"
mv "$csv_archive_stage" "$csv_archive"
mv "$geojsonl_archive_stage" "$geojsonl_archive"
