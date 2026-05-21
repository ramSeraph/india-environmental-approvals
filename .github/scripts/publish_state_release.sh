#!/usr/bin/env bash

set -euo pipefail

STATE_CODE=${1:?state code is required}
STATE_NAME=${2:?state name is required}
CSV_ARCHIVE=${3:?csv archive path is required}
GEOJSONL_ARCHIVE=${4:?geojsonl archive path is required}
PARQUET_FILE=${5:?parquet file path is required}
RUN_INFO_FILE=${6:?run info file path is required}

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
  python3 - <<'PY' "$json_file" "$notes_file" "$REPO" "$RUN_AT" "$RUN_MONTH" "$STATE_CODE" "$STATE_NAME" "$RELEASE_TAG"
import json
import re
import sys
from urllib.parse import quote

json_file, notes_file, repo, run_at, run_month, state_code, state_name, release_tag = sys.argv[1:]

with open(json_file, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

assets = payload.get("assets") or []

def asset_sort_key(name: str):
    match = re.search(r"Projects_(\d+)", name)
    return (int(match.group(1)) if match else 10**9, name)

def asset_link(name: str) -> str:
    return f"https://github.com/{repo}/releases/download/{release_tag}/{quote(name)}"

csv_assets = sorted(
    [asset["name"] for asset in assets if asset["name"].endswith(".csv.7z")],
    key=asset_sort_key,
)
geojsonl_assets = sorted(
    [asset["name"] for asset in assets if asset["name"].endswith(".geojsonl.7z")],
    key=asset_sort_key,
)
parquet_assets = sorted(
    [asset["name"] for asset in assets if asset["name"].endswith(".parquet")],
    key=asset_sort_key,
)
run_info_assets = sorted(
    [asset["name"] for asset in assets if asset["name"].endswith("_run.txt")],
    key=asset_sort_key,
)

lines = [
    f"<!-- release-month:{run_month} -->",
    f"# Datasets {run_month}",
    "",
    f"- Last update: `{run_at}`",
    f"- Most recent workflow: `{state_name}` (`{state_code}`)",
    "- Data license: [CC0 1.0 with requested attribution to Datameet and the original government source](https://github.com/ramSeraph/indianopenmaps/blob/main/DATA_LICENSE.md)",
    "",
    "## CSV archives",
]

if csv_assets:
    lines.extend(f"- [{name}]({asset_link(name)})" for name in csv_assets)
else:
    lines.append("- No CSV archives uploaded yet.")

lines.extend([
    "",
    "## GeoJSONL archives",
])

if geojsonl_assets:
    lines.extend(f"- [{name}]({asset_link(name)})" for name in geojsonl_assets)
else:
    lines.append("- No GeoJSONL archives uploaded yet.")

lines.extend([
    "",
    "## GeoParquet files",
])

if parquet_assets:
    lines.extend(f"- [{name}]({asset_link(name)})" for name in parquet_assets)
else:
    lines.append("- No GeoParquet files uploaded yet.")

lines.extend([
    "",
    "## Run metadata",
])

if run_info_assets:
    lines.extend(f"- [{name}]({asset_link(name)})" for name in run_info_assets)
else:
    lines.append("- No run metadata files uploaded yet.")

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
# ${RELEASE_TITLE}

- Last update: \`${RUN_AT}\`
- Most recent workflow: \`${STATE_NAME}\` (\`${STATE_CODE}\`)
EOF

create_release_if_needed "$INITIAL_NOTES"

gh release upload "$RELEASE_TAG" \
  "$CSV_ARCHIVE" \
  "$GEOJSONL_ARCHIVE" \
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
