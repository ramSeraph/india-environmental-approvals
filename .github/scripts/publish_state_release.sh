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

TMP_DIR=$(mktemp -d)

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

release_exists() {
  local tag="$1"
  gh release view "$tag" --repo "$REPO" --json tagName >/dev/null 2>&1
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
            "pmtiles": None,
            "parquet": None,
            "run_info": None,
        },
    )

    if name.endswith(".csv.7z"):
        state_entry["csv"] = name
    elif name.endswith(".geojsonl.7z"):
        state_entry["geojsonl"] = name
    elif name.endswith(".pmtiles"):
        state_entry["pmtiles"] = name
    elif name.endswith(".parquet"):
        state_entry["parquet"] = name
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
            lines.append(f"- PMTiles: [{state_entry['pmtiles']}]({asset_link(state_entry['pmtiles'])})")
        else:
            lines.append("- PMTiles: not uploaded")

        if state_entry["parquet"]:
            lines.append(f"- GeoParquet: [{state_entry['parquet']}]({asset_link(state_entry['parquet'])})")
        else:
            lines.append("- GeoParquet: not uploaded")

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

  if release_exists "$RELEASE_TAG"; then
    return
  fi

  gh release create "$RELEASE_TAG" \
    --repo "$REPO" \
    --title "$RELEASE_TITLE" \
    --notes-file "$notes_file" \
    --latest
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

gh release upload "$RELEASE_TAG" \
  "$CSV_ARCHIVE" \
  "$GEOJSONL_ARCHIVE" \
  "$PMTILES_FILE" \
  "$PARQUET_FILE" \
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
