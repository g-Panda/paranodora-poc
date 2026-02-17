#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_NAME="${TEST_SCRIPT_NAME:-$(basename "$0")}"
TEST_DEBUG="${TEST_DEBUG:-0}"
TEST_DRY_RUN="${TEST_DRY_RUN:-0}"

log_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_line() {
  local level="$1"
  shift
  printf '%s [%s] [%s] %s\n' "$(log_ts)" "$TEST_SCRIPT_NAME" "$level" "$*"
}

log_info() {
  log_line INFO "$*"
}

log_warn() {
  log_line WARN "$*"
}

log_error() {
  log_line ERROR "$*" >&2
}

log_debug() {
  if [ "${TEST_DEBUG:-0}" = "1" ]; then
    log_line DEBUG "$*"
  fi
}

die() {
  log_error "$*"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
}

run_cmd() {
  if [ "$#" -eq 0 ]; then
    die "run_cmd: empty command"
  fi

  local q
  q="$(printf '%q ' "$@")"
  q="${q% }"

  if [ "${TEST_DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] $q"
    return 0
  fi

  log_debug "exec: $q"
  "$@"
}

assert_file_exists() {
  local path="$1"
  [ -f "$path" ] || die "Expected file not found: $path"
}

assert_executable() {
  local path="$1"
  [ -x "$path" ] || die "Expected executable file: $path"
}

parse_global_test_flags() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --debug)
        TEST_DEBUG=1
        ;;
      --dry-run)
        TEST_DRY_RUN=1
        ;;
      *)
        printf '%s\n' "$1"
        ;;
    esac
    shift
  done
}

join_by() {
  local sep="$1"
  shift || true
  local out=""
  local item
  for item in "$@"; do
    if [ -z "$out" ]; then
      out="$item"
    else
      out+="$sep$item"
    fi
  done
  printf '%s\n' "$out"
}
