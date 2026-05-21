#!/usr/bin/env bash

set -euo pipefail

context="${1:-this step}"
deadline_epoch="${PIPELINE_DEADLINE_EPOCH:-}"

if [[ -z "${deadline_epoch}" ]]; then
  exit 0
fi

now_epoch="$(date +%s)"
remaining_seconds="$((deadline_epoch - now_epoch))"

if (( remaining_seconds <= 0 )); then
  echo "Pipeline runtime budget exceeded before ${context}" >&2
  exit 1
fi

echo "Runtime budget before ${context}: ${remaining_seconds}s remaining"
