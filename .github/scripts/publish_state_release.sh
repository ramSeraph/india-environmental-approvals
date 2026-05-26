#!/usr/bin/env bash

set -euo pipefail

STATE_CODE=${1:?state code is required}
STATE_NAME=${2:?state name is required}
CSV_ARCHIVE=${3:?csv archive path is required}
GEOJSONL_ARCHIVE=${4:?geojsonl archive path is required}
PMTILES_FILE=${5:?pmtiles file path is required}
PARQUET_FILE=${6:?parquet file path is required}
RUN_INFO_FILE=${7:?run info file path is required}

REPO=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
RUN_AT=${RUN_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
RUN_MONTH=${RUN_AT:0:7}
RELEASE_TAG=${RELEASE_TAG:-datasets-${RUN_MONTH}}
RELEASE_TITLE=${RELEASE_TITLE:-Datasets ${RUN_MONTH}}
GPIO_VERSION=${GPIO_VERSION:-0.9.0}
MAX_RELEASE_ASSET_BYTES=${MAX_RELEASE_ASSET_BYTES:-2000000000}
PMTILES_PARTITION_TMPDIR=${PMTILES_PARTITION_TMPDIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pmtiles-mosaic}

TMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

release_exists() {
  local tag="$1"
  gh release view "$tag" --repo "$REPO" --json tagName >/dev/null 2>&1
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

require_command gh
require_command uvx
require_command python3

file_size_bytes() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.getsize(sys.argv[1]))
PY
}

calculate_partition_count() {
  python3 - "$1" "$2" <<'PY'
import math
import sys

file_size = int(sys.argv[1])
max_release_asset_bytes = int(sys.argv[2])
if file_size < max_release_asset_bytes:
    print(1)
else:
    min_partitions = math.ceil(file_size / max_release_asset_bytes)
    power = math.ceil(math.log2(min_partitions))
    print(2 ** power)
PY
}

check_release_asset_size() {
  local asset_path="$1"
  if [ "$(file_size_bytes "$asset_path")" -ge "$MAX_RELEASE_ASSET_BYTES" ]; then
    echo "Release asset still exceeds size limit: $asset_path" >&2
    exit 1
  fi
}

clear_pmtiles_partitioned_outputs() {
  local pmtiles_prefix="${PMTILES_FILE%.pmtiles}"
  shopt -s nullglob
  local existing_parts=("${pmtiles_prefix}"-part*.pmtiles)
  shopt -u nullglob
  rm -f "${existing_parts[@]}" "${pmtiles_prefix}.mosaic.json"
}

clear_parquet_partitioned_outputs() {
  local parquet_prefix="${PARQUET_FILE%.parquet}"
  shopt -s nullglob
  local existing_parts=("${parquet_prefix}".*.parquet)
  shopt -u nullglob
  rm -f "${existing_parts[@]}" "${parquet_prefix}.parquet.meta.json"
}

prepare_pmtiles_assets() {
  pmtiles_assets=()
  if [ ! -f "$PMTILES_FILE" ]; then
    echo "Missing PMTiles file: $PMTILES_FILE" >&2
    exit 1
  fi

  if [ "$(file_size_bytes "$PMTILES_FILE")" -lt "$MAX_RELEASE_ASSET_BYTES" ]; then
    pmtiles_assets=("$PMTILES_FILE")
    return
  fi

  local split_dir="${TMP_DIR}/pmtiles"
  mkdir -p "$split_dir"
  mkdir -p "$PMTILES_PARTITION_TMPDIR"
  TMPDIR="$PMTILES_PARTITION_TMPDIR" uvx --from "pmtiles-mosaic" partition \
    --from-source "$PMTILES_FILE" \
    --size-limit "$MAX_RELEASE_ASSET_BYTES" \
    --no-cache \
    --to-pmtiles "${split_dir}/$(basename "$PMTILES_FILE")"

  shopt -s nullglob
  local split_parts=("${split_dir}"/*.pmtiles)
  local split_mosaics=("${split_dir}"/*.mosaic.json)
  shopt -u nullglob

  if [ ${#split_parts[@]} -eq 0 ] || [ ${#split_mosaics[@]} -eq 0 ]; then
    echo "PMTiles partitioning did not produce the expected outputs" >&2
    exit 1
  fi

  for split_part in "${split_parts[@]}"; do
    check_release_asset_size "$split_part"
  done

  clear_pmtiles_partitioned_outputs
  pmtiles_assets=()
  for split_file in "${split_parts[@]}" "${split_mosaics[@]}"; do
    local final_path
    final_path="$(dirname "$PMTILES_FILE")/$(basename "$split_file")"
    mv "$split_file" "$final_path"
    pmtiles_assets+=("$final_path")
  done
  rm -f "$PMTILES_FILE"
}

prepare_parquet_assets() {
  parquet_assets=()
  if [ ! -f "$PARQUET_FILE" ]; then
    echo "Missing GeoParquet file: $PARQUET_FILE" >&2
    exit 1
  fi

  if [ "$(file_size_bytes "$PARQUET_FILE")" -lt "$MAX_RELEASE_ASSET_BYTES" ]; then
    parquet_assets=("$PARQUET_FILE")
    return
  fi

  local base_name
  base_name=$(basename "${PARQUET_FILE%.parquet}")
  local split_dir="${TMP_DIR}/parquet"
  local partition_count
  partition_count=$(calculate_partition_count "$(file_size_bytes "$PARQUET_FILE")" "$MAX_RELEASE_ASSET_BYTES")

  while true; do
    rm -rf "$split_dir"
    mkdir -p "$split_dir"
    uvx --from "geoparquet-io==${GPIO_VERSION}" gpio partition kdtree \
      "$PARQUET_FILE" \
      "$split_dir" \
      --geoparquet-version 1.1 \
      --compression zstd \
      --compression-level 22 \
      --partitions "$partition_count" \
      -v

    shopt -s nullglob
    split_files=("${split_dir}"/*.parquet)
    shopt -u nullglob

    if [ ${#split_files[@]} -eq 0 ]; then
      echo "GeoParquet partitioning did not produce any output files" >&2
      exit 1
    fi

    oversized=0
    for split_file in "${split_files[@]}"; do
      if [ "$(file_size_bytes "$split_file")" -ge "$MAX_RELEASE_ASSET_BYTES" ]; then
        oversized=1
        break
      fi
    done

    if [ "$oversized" -eq 0 ]; then
      break
    fi

    partition_count=$((partition_count * 2))
  done

  local final_stage_dir="${TMP_DIR}/parquet-final"
  rm -rf "$final_stage_dir"
  mkdir -p "$final_stage_dir"
  renamed_files=()
  for split_file in "${split_files[@]}"; do
    local new_name="${final_stage_dir}/${base_name}.$(basename "$split_file")"
    mv "$split_file" "$new_name"
    renamed_files+=("$new_name")
  done

  local parquet_meta_file="${final_stage_dir}/${base_name}.parquet.meta.json"
  python3 .github/scripts/create_parquet_meta.py "$parquet_meta_file" "$GPIO_VERSION" "${renamed_files[@]}"
  clear_parquet_partitioned_outputs
  parquet_assets=()
  for staged_file in "${renamed_files[@]}" "$parquet_meta_file"; do
    local final_path
    final_path="$(dirname "$PARQUET_FILE")/$(basename "$staged_file")"
    mv "$staged_file" "$final_path"
    parquet_assets+=("$final_path")
  done
  rm -f "$PARQUET_FILE"
}

render_release_notes() {
  local json_file="$1"
  local notes_file="$2"
  local states_csv="states.csv"
  python3 - <<'PY' "$json_file" "$notes_file" "$REPO" "$RUN_AT" "$RUN_MONTH" "$STATE_CODE" "$STATE_NAME" "$RELEASE_TAG" "$states_csv"
import csv
import json
import re
import sys
from urllib.parse import quote

json_file, notes_file, repo, run_at, run_month, state_code, state_name, release_tag, states_csv = sys.argv[1:]

with open(json_file, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

assets = payload.get("assets") or []

def asset_link(name: str) -> str:
    return f"https://github.com/{repo}/releases/download/{release_tag}/{quote(name)}"

def route_slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

state_names = {}
with open(states_csv, "r", encoding="utf-8", newline="") as handle:
    for row in csv.DictReader(handle):
        code = row.get("State Code", "").strip()
        name = row.get("State Name(In English)", "").strip()
        if code and name:
            state_names[code] = name

grouped_assets = {}

for asset in assets:
    name = asset["name"]
    match = re.search(r"Projects_(\d+)", name)
    if not match:
        continue

    code = match.group(1)
    state_entry = grouped_assets.setdefault(
        code,
        {
            "csv": None,
            "geojsonl": None,
            "pmtiles": [],
            "pmtiles_mosaic": None,
            "parquet": [],
            "parquet_meta": None,
            "run_info": None,
        },
    )

    if name.endswith(".csv.7z"):
        state_entry["csv"] = name
    elif name.endswith(".geojsonl.7z"):
        state_entry["geojsonl"] = name
    elif name.endswith(".mosaic.json"):
        state_entry["pmtiles_mosaic"] = name
    elif name.endswith(".pmtiles"):
        state_entry["pmtiles"].append(name)
    elif name.endswith(".parquet.meta.json"):
        state_entry["parquet_meta"] = name
    elif name.endswith(".parquet"):
        state_entry["parquet"].append(name)
    elif name.endswith("_run.txt"):
        state_entry["run_info"] = name

lines = [
    f"<!-- release-month:{run_month} -->",
    f"- Last update: `{run_at}`",
    f"- Most recent workflow: `{state_name}` (`{state_code}`)",
    "- Data license: [CC0 1.0 with requested attribution to Datameet and the original government source](https://github.com/ramSeraph/indianopenmaps/blob/main/DATA_LICENSE.md)",
    "",
    "## States",
]

if grouped_assets:
    for code in sorted(grouped_assets, key=lambda value: (int(value), value)):
        state_label = state_names.get(code, f"State {code}")
        state_entry = grouped_assets[code]
        route_path = f"/not-so-open/environmental/approvals/{route_slug(state_label)}/parivesh/"
        lines.append(f"### {state_label} ({code})")
        lines.append(
            f"- Tiles - https://indianopenmaps.com{route_path}" + "{z}/{x}/{y}.pbf"
            f" - [view](https://indianopenmaps.com{route_path}view)"
        )
        if state_entry["csv"]:
            lines.append(f"- CSV archive: [{state_entry['csv']}]({asset_link(state_entry['csv'])})")
        else:
            lines.append("- CSV archive: not uploaded")

        if state_entry["geojsonl"]:
            lines.append(f"- GeoJSONL archive: [{state_entry['geojsonl']}]({asset_link(state_entry['geojsonl'])})")
        else:
            lines.append("- GeoJSONL archive: not uploaded")

        if state_entry["pmtiles"]:
            if len(state_entry["pmtiles"]) == 1 and not state_entry["pmtiles_mosaic"]:
                pmtiles_name = state_entry["pmtiles"][0]
                lines.append(f"- PMTiles: [{pmtiles_name}]({asset_link(pmtiles_name)})")
            else:
                pmtiles_parts = ", ".join(
                    f"[{name}]({asset_link(name)})" for name in sorted(state_entry["pmtiles"])
                )
                lines.append(f"- PMTiles parts: {pmtiles_parts}")
        else:
            lines.append("- PMTiles: not uploaded")

        if state_entry["pmtiles_mosaic"]:
            lines.append(f"- PMTiles mosaic: [{state_entry['pmtiles_mosaic']}]({asset_link(state_entry['pmtiles_mosaic'])})")

        if state_entry["parquet"]:
            if len(state_entry["parquet"]) == 1 and not state_entry["parquet_meta"]:
                parquet_name = state_entry["parquet"][0]
                lines.append(f"- GeoParquet: [{parquet_name}]({asset_link(parquet_name)})")
            else:
                parquet_parts = ", ".join(
                    f"[{name}]({asset_link(name)})" for name in sorted(state_entry["parquet"])
                )
                lines.append(f"- GeoParquet parts: {parquet_parts}")
        else:
            lines.append("- GeoParquet: not uploaded")

        if state_entry["parquet_meta"]:
            lines.append(f"- GeoParquet metadata: [{state_entry['parquet_meta']}]({asset_link(state_entry['parquet_meta'])})")

        if state_entry["run_info"]:
            lines.append(f"- Run metadata: [{state_entry['run_info']}]({asset_link(state_entry['run_info'])})")
        else:
            lines.append("- Run metadata: not uploaded")

        lines.append("")
else:
    lines.append("- No state assets uploaded yet.")

with open(notes_file, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
    handle.write("\n")
PY
}

create_release_if_needed() {
  local notes_file="$1"
  local create_error_file="$TMP_DIR/release-create.stderr"

  if release_exists "$RELEASE_TAG"; then
    return
  fi

  if gh release create "$RELEASE_TAG" \
    --repo "$REPO" \
    --title "$RELEASE_TITLE" \
    --notes-file "$notes_file" \
    --latest \
    2>"$create_error_file"; then
    return
  fi

  if release_exists "$RELEASE_TAG"; then
    return
  fi

  cat "$create_error_file" >&2
  return 1
}

INITIAL_NOTES="$TMP_DIR/initial-notes.md"
RELEASE_JSON="$TMP_DIR/release.json"
RELEASE_NOTES="$TMP_DIR/release-notes.md"

cat >"$INITIAL_NOTES" <<EOF
<!-- release-month:${RUN_MONTH} -->
- Last update: \`${RUN_AT}\`
- Most recent workflow: \`${STATE_NAME}\` (\`${STATE_CODE}\`)
EOF

create_release_if_needed "$INITIAL_NOTES"

prepare_pmtiles_assets
prepare_parquet_assets

if [ ${#pmtiles_assets[@]} -eq 0 ]; then
  echo "No PMTiles assets found for upload" >&2
  exit 1
fi

if [ ${#parquet_assets[@]} -eq 0 ]; then
  echo "No GeoParquet assets found for upload" >&2
  exit 1
fi

gh release upload "$RELEASE_TAG" \
  "$CSV_ARCHIVE" \
  "$GEOJSONL_ARCHIVE" \
  "${pmtiles_assets[@]}" \
  "${parquet_assets[@]}" \
  "$RUN_INFO_FILE" \
  --repo "$REPO" \
  --clobber

gh release view "$RELEASE_TAG" \
  --repo "$REPO" \
  --json assets,body,createdAt,publishedAt \
  >"$RELEASE_JSON"

render_release_notes "$RELEASE_JSON" "$RELEASE_NOTES"

gh release edit "$RELEASE_TAG" \
  --repo "$REPO" \
  --title "$RELEASE_TITLE" \
  --notes-file "$RELEASE_NOTES" \
  --latest
