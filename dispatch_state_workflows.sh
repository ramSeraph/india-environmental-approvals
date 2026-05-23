#!/usr/bin/env bash

set -euo pipefail

# Local helper to drain the per-state GitHub Actions workflows one by one.
#
# Defaults:
#   - done states are inferred from the latest release assets
#   - the active state is inferred from the latest in-progress state workflow
#
# Optional override if you need to force the current active state:
#   ACTIVE_CODE=23 bash dispatch_state_workflows.sh

ACTIVE_CODE="${ACTIVE_CODE:-}"
MAX_RETRIES="${MAX_RETRIES:-5}"
POLL_SECONDS="${POLL_SECONDS:-120}"
WORKFLOW_DIR=".github/workflows"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
GH_REPO="${GH_REPO:-ramSeraph/india-environmental-approvals}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required but not found in PATH." >&2
  exit 1
fi

gh auth status >/dev/null

if [[ "${GH_REPO}" == "auto" ]]; then
  GH_REPO=""
fi

if [[ -z "${GH_REPO}" ]]; then
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "${remote_url}" ]]; then
    GH_REPO="$(printf '%s\n' "${remote_url}" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
  fi
fi

if [[ -z "${GH_REPO}" ]]; then
  echo "Could not determine GitHub repository. Set GH_REPO=owner/repo." >&2
  exit 1
fi

normalize_code() {
  printf "%02d" "$((10#$1))"
}

normalized_done_codes=""

append_done_code() {
  local code="$1"
  local normalized_code
  normalized_code="$(normalize_code "${code}")"

  case ",${normalized_done_codes:-}," in
    *,"${normalized_code}",*) ;;
    *)
      normalized_done_codes="${normalized_done_codes:+${normalized_done_codes},}${normalized_code}"
      ;;
  esac
}

load_done_codes_from_release() {
  local release_codes

  release_codes="$(
    gh release view \
      --repo "${GH_REPO}" \
      --json assets \
      --jq '.assets[].name' 2>/dev/null | \
    sed -nE 's/^Projects_([0-9]+)\..*/\1/p' | \
    sort -u
  )"

  if [[ -z "${release_codes}" ]]; then
    return 0
  fi

  while IFS= read -r code; do
    [[ -n "${code}" ]] || continue
    append_done_code "${code}"
  done <<< "${release_codes}"
}

load_done_codes_from_release
append_done_code "27"

if [[ -n "${ACTIVE_CODE}" ]]; then
  ACTIVE_CODE="$(normalize_code "${ACTIVE_CODE}")"
fi

declare -a STATE_ORDER=()
STATE_METADATA_FILE="$(mktemp)"

cleanup() {
  rm -f "${STATE_METADATA_FILE}"
}

trap cleanup EXIT

done_code_contains() {
  local needle="$1"
  case ",${normalized_done_codes:-}," in
    *,"${needle}",*) return 0 ;;
    *) return 1 ;;
  esac
}

state_field_for_code() {
  local code="$1"
  local field_index="$2"

  awk -F '\t' -v code="${code}" -v field_index="${field_index}" '
    $1 == code {
      print $field_index
      exit
    }
  ' "${STATE_METADATA_FILE}"
}

state_code_for_workflow_name() {
  local workflow_name="$1"

  awk -F '\t' -v workflow_name="${workflow_name}" '
    $4 == workflow_name {
      print $1
      exit
    }
  ' "${STATE_METADATA_FILE}"
}

while IFS=$'\t' read -r code name workflow_file workflow_name; do
  STATE_ORDER+=("${code}")
  printf '%s\t%s\t%s\t%s\n' "${code}" "${name}" "${workflow_file}" "${workflow_name}" >> "${STATE_METADATA_FILE}"
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
        workflow_name = f"Run {name} pipeline"
        print(f"{code}\t{name}\t{workflow}\t{workflow_name}")
PY
)

if [[ -z "${ACTIVE_CODE}" ]]; then
  active_workflow_name="$(
    gh run list \
      --repo "${GH_REPO}" \
      --limit 100 \
      --json workflowName,status,createdAt \
      --jq 'map(select(.status != "completed" and (.workflowName | startswith("Run ")) and .workflowName != "Run state pipeline")) | sort_by(.createdAt) | last | (.workflowName // "")' \
      2>/dev/null | tr -d '\r'
  )"

  if [[ -n "${active_workflow_name}" ]]; then
    ACTIVE_CODE="$(state_code_for_workflow_name "${active_workflow_name}")"
  fi
fi

latest_run_field() {
  local workflow_file="$1"
  local jq_expr="$2"

  gh run list \
    --repo "${GH_REPO}" \
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
        --repo "${GH_REPO}" \
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
        --repo "${GH_REPO}" \
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

  gh workflow run "${workflow_file}" --repo "${GH_REPO}" --ref "${DEFAULT_BRANCH}" >/dev/null

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
  local name
  local workflow_file
  name="$(state_field_for_code "${code}" 2)"
  workflow_file="$(state_field_for_code "${code}" 3)"
  local workflow_name="Run ${name} pipeline"

  if [[ ! -f "${WORKFLOW_DIR}/${workflow_file}" ]]; then
    echo "Missing workflow file: ${WORKFLOW_DIR}/${workflow_file}" >&2
    exit 1
  fi

  if done_code_contains "${code}"; then
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
    gh run rerun "${run_id}" --repo "${GH_REPO}" >/dev/null
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
echo "Repository: ${GH_REPO}"
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
