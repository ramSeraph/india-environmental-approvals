#!/usr/bin/env bash

set -euo pipefail

command_name="${1:?command is required}"
state_file="${2:?state file is required}"
stage_value="${3:-}"

current_stage() {
  if [[ -f "${state_file}" ]]; then
    cat "${state_file}"
  else
    echo 0
  fi
}

case "${command_name}" in
  init)
    mkdir -p "$(dirname "${state_file}")"
    if [[ ! -f "${state_file}" ]]; then
      printf '0\n' > "${state_file}"
    fi
    ;;
  get)
    current_stage
    ;;
  at-least)
    current="$(current_stage)"
    [[ "${current}" -ge "${stage_value}" ]]
    ;;
  set)
    mkdir -p "$(dirname "${state_file}")"
    tmp_file="${state_file}.tmp"
    printf '%s\n' "${stage_value}" > "${tmp_file}"
    mv "${tmp_file}" "${state_file}"
    ;;
  *)
    echo "Unknown command: ${command_name}" >&2
    exit 1
    ;;
esac
