#!/usr/bin/env bash

set -euo pipefail

# Local helper to drain the per-state GitHub Actions workflows one by one.
#
# Defaults reflect the current situation discussed in the terminal:
#   - Andhra Pradesh (28) is already running
#   - Delhi (07), Goa (30), and Andaman And Nicobar Islands (35) are done
#
# Override as needed, for example:
#   DONE_CODES=07,28,30,35 ACTIVE_CODE= MAX_RETRIES=8 bash dispatch_state_workflows.sh

DONE_CODES="${DONE_CODES:-07,30,35}"
ACTIVE_CODE="${ACTIVE_CODE:-28}"
MAX_RETRIES="${MAX_RETRIES:-5}"
POLL_SECONDS="${POLL_SECONDS:-120}"
WORKFLOW_DIR=".github/workflows"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required but not found in PATH." >&2
  exit 1
fi

gh auth status >/dev/null

normalize_code() {
  printf "%02d" "$((10#$1))"
}

declare -A DONE_SET=()
if [[ -n "${DONE_CODES}" ]]; then
  IFS=',' read -r -a done_items <<< "${DONE_CODES}"
  for code in "${done_items[@]}"; do
    [[ -n "${code}" ]] || continue
    DONE_SET["$(normalize_code "${code}")"]=1
  done
fi

if [[ -n "${ACTIVE_CODE}" ]]; then
  ACTIVE_CODE="$(normalize_code "${ACTIVE_CODE}")"
fi

declare -a STATE_ORDER=()
declare -A STATE_NAMES=()
declare -A WORKFLOW_FILES=()

while IFS=$'\t' read -r code name workflow_file; do
  STATE_ORDER+=("${code}")
  STATE_NAMES["${code}"]="${name}"
  WORKFLOW_FILES["${code}"]="${workflow_file}"
done < <(
  python3 - <<'PY'
import csv
import re

with open("states.csv", newline="", encoding="utf-8") as handle:
    reader = csv.DictReader(handle)
    for row in reader:
        code = f"{int(float(row['State Code'])):02d}"
        name = row["State Name(In English)"].strip()
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        workflow = f"run-state-{code}-{slug}.yml"
        print(f"{code}\t{name}\t{workflow}")
PY
)

latest_run_field() {
  local workflow_file="$1"
  local jq_expr="$2"

  gh run list \
    --workflow "${workflow_file}" \
    --limit 20 \
    --json databaseId,status,conclusion,createdAt \
    --jq "${jq_expr}" 2>/dev/null | tr -d '\r'
}

latest_run_id() {
  latest_run_field "$1" 'sort_by(.createdAt) | last | (.databaseId // "")'
}

latest_run_status() {
  latest_run_field "$1" 'sort_by(.createdAt) | last | (.status // "")'
}

latest_run_conclusion() {
  latest_run_field "$1" 'sort_by(.createdAt) | last | (.conclusion // "")'
}

latest_active_run_id() {
  latest_run_field "$1" 'map(select(.status != "completed")) | sort_by(.createdAt) | last | (.databaseId // "")'
}

wait_for_completion() {
  local run_id="$1"
  local workflow_name="$2"
  local state_name="$3"

  while true; do
    local status conclusion url
    local info
    info="$(
      gh run view "${run_id}" \
        --json status,conclusion,url \
        --jq '[.status, (.conclusion // ""), .url] | @tsv'
    )"
    IFS=$'\t' read -r status conclusion url <<< "${info}"

    printf '[%s] %s (%s): status=%s conclusion=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" \
      "${workflow_name}" \
      "${state_name}" \
      "${status}" \
      "${conclusion:-n/a}"

    if [[ "${status}" == "completed" ]]; then
      if [[ "${conclusion}" == "success" ]]; then
        echo "Completed successfully: ${url}"
        return 0
      fi

      echo "Run finished without success: ${url}" >&2
      return 1
    fi

    sleep "${POLL_SECONDS}"
  done
}

wait_for_rerun_to_start() {
  local run_id="$1"
  local poll

  for poll in $(seq 1 24); do
    local status
    status="$(
      gh run view "${run_id}" \
        --json status \
        --jq '.status'
    )"

    if [[ "${status}" != "completed" ]]; then
      return 0
    fi

    sleep 5
  done

  echo "Rerun for ${run_id} did not leave completed state in time." >&2
  return 1
}

dispatch_new_run() {
  local workflow_file="$1"
  local before_id="$2"

  gh workflow run "${workflow_file}" --ref "${DEFAULT_BRANCH}" >/dev/null

  local attempt run_id
  for attempt in $(seq 1 30); do
    run_id="$(latest_run_id "${workflow_file}")"
    if [[ -n "${run_id}" && "${run_id}" != "${before_id}" ]]; then
      printf '%s\n' "${run_id}"
      return 0
    fi
    sleep 5
  done

  echo "Could not find the newly dispatched run for ${workflow_file}." >&2
  return 1
}

process_state() {
  local code="$1"
  local reuse_current="$2"
  local name="${STATE_NAMES[${code}]}"
  local workflow_file="${WORKFLOW_FILES[${code}]}"
  local workflow_name="Run ${name} pipeline"

  if [[ ! -f "${WORKFLOW_DIR}/${workflow_file}" ]]; then
    echo "Missing workflow file: ${WORKFLOW_DIR}/${workflow_file}" >&2
    exit 1
  fi

  if [[ -n "${DONE_SET[${code}]:-}" ]]; then
    echo "Skipping ${name} (${code}); marked done."
    return 0
  fi

  local run_id="" status="" conclusion=""

  if [[ "${reuse_current}" == "1" ]]; then
    run_id="$(latest_active_run_id "${workflow_file}")"
    if [[ -n "${run_id}" ]]; then
      echo "Resuming active run ${run_id} for ${name} (${code})."
    else
      status="$(latest_run_status "${workflow_file}")"
      conclusion="$(latest_run_conclusion "${workflow_file}")"
      run_id="$(latest_run_id "${workflow_file}")"

      if [[ "${status}" == "completed" && "${conclusion}" == "success" ]]; then
        echo "Skipping ${name} (${code}); latest run already succeeded."
        return 0
      fi
    fi
  fi

  local attempt=1
  while (( attempt <= MAX_RETRIES )); do
    if [[ -z "${run_id}" ]]; then
      local before_id
      before_id="$(latest_run_id "${workflow_file}")"
      echo "Dispatching ${name} (${code}) [attempt ${attempt}/${MAX_RETRIES}]..."
      run_id="$(dispatch_new_run "${workflow_file}" "${before_id}")"
      echo "Watching run ${run_id} for ${name} (${code})."
    else
      echo "Watching existing run ${run_id} for ${name} (${code}) [attempt ${attempt}/${MAX_RETRIES}]..."
    fi

    if wait_for_completion "${run_id}" "${workflow_name}" "${name}"; then
      return 0
    fi

    if (( attempt == MAX_RETRIES )); then
      echo "Exceeded retry budget for ${name} (${code})." >&2
      return 1
    fi

    echo "Rerunning failed run ${run_id} for ${name} (${code})..."
    gh run rerun "${run_id}" >/dev/null
    attempt=$((attempt + 1))
    wait_for_rerun_to_start "${run_id}"
  done
}

echo "Dispatch order: ${#STATE_ORDER[@]} states from states.csv"
echo "Marked done: ${DONE_CODES:-<none>}"
echo "Currently active: ${ACTIVE_CODE:-<none>}"
echo "Max retries: ${MAX_RETRIES}"
echo "Poll interval: ${POLL_SECONDS}s"
echo "Branch: ${DEFAULT_BRANCH}"
echo

if [[ -n "${ACTIVE_CODE}" ]]; then
  process_state "${ACTIVE_CODE}" "1"
fi

for code in "${STATE_ORDER[@]}"; do
  if [[ "${code}" == "${ACTIVE_CODE}" ]]; then
    continue
  fi
  process_state "${code}" "0"
done

echo
echo "All requested state workflows have completed."
