#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

ACTION_STATUS=0
ACTION_APPLY=0
DO_GENERATE=0
DO_ENROLL=0
DO_EXPORT=0

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME --status [--debug]
  $SCRIPT_NAME --apply --generate-key [--dry-run] [--debug]
  $SCRIPT_NAME --apply --enroll [--dry-run] [--debug]
  $SCRIPT_NAME --apply --export-public [--dry-run] [--debug]

Scope:
  - MVP uses shim/MOK only.
  - No db/KEK/PK firmware key operations.
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --status)
        ACTION_STATUS=1
        ;;
      --apply)
        ACTION_APPLY=1
        ;;
      --generate-key)
        DO_GENERATE=1
        ;;
      --enroll)
        DO_ENROLL=1
        ;;
      --export-public)
        DO_EXPORT=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --debug)
        DEBUG=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done

  if [ "$ACTION_STATUS" = "0" ] && [ "$ACTION_APPLY" = "0" ]; then
    usage
    exit 1
  fi

  if [ "$ACTION_STATUS" = "1" ] && [ "$ACTION_APPLY" = "1" ]; then
    die "Choose only one mode: --status or --apply"
  fi

  if [ "$ACTION_APPLY" = "1" ]; then
    local ops=$((DO_GENERATE + DO_ENROLL + DO_EXPORT))
    if [ "$ops" -ne 1 ]; then
      die "With --apply choose exactly one operation: --generate-key, --enroll, or --export-public"
    fi
  fi

  if [ "$ACTION_STATUS" = "1" ] && [ $((DO_GENERATE + DO_ENROLL + DO_EXPORT)) -ne 0 ]; then
    die "Do not combine --status with apply operations"
  fi
}

machine_id() {
  cat /etc/machine-id
}

sb_key_dir() {
  printf '%s/secureboot/%s\n' "$GP_BOOTSTRAP_ROOT" "$(machine_id)"
}

sb_key_path() {
  printf '%s/MOK.key\n' "$(sb_key_dir)"
}

sb_crt_path() {
  printf '%s/MOK.crt\n' "$(sb_key_dir)"
}

do_status() {
  require_cmd mokutil

  log_info "Secure Boot state (mokutil --sb-state):"
  mokutil --sb-state 2>&1 | while IFS= read -r line; do
    log_info "  $line"
  done || true

  log_info "Enrolled MOK keys (mokutil --list-enrolled):"
  mokutil --list-enrolled 2>&1 | while IFS= read -r line; do
    log_info "  $line"
  done || true

  log_info "MVP scope: shim/MOK only, no db/KEK/PK operations."
}

do_generate_key() {
  require_cmd openssl

  local dir key crt subj
  dir="$(sb_key_dir)"
  key="$(sb_key_path)"
  crt="$(sb_crt_path)"

  if [ -f "$key" ] && [ -f "$crt" ]; then
    log_info "MOK key material already exists: $dir"
    return 0
  fi

  subj="/CN=gp-bootstrap MOK $(hostname)-$(machine_id)"

  if [ "${DRY_RUN:-0}" = "0" ]; then
    mkdir -p "$dir"
    chmod 700 "$dir"
  fi

  run_cmd openssl req -new -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 -subj "$subj" -keyout "$key" -out "$crt"

  if [ "${DRY_RUN:-0}" = "0" ]; then
    chmod 600 "$key"
    chmod 644 "$crt"
  fi

  log_info "Generated MOK keypair:"
  log_info "  private: $key"
  log_info "  public : $crt"
}

do_enroll() {
  require_cmd mokutil

  local crt
  crt="$(sb_crt_path)"
  [ -f "$crt" ] || die "Public cert not found: $crt (run --apply --generate-key first)"

  run_cmd mokutil --import "$crt"

  log_info "Enrollment queued. Complete manually after reboot:"
  log_info "  1) Reboot system"
  log_info "  2) Open MOK Manager"
  log_info "  3) Enroll key from disk"
  log_info "  4) Confirm enrollment password"
}

do_export_public() {
  local crt dest
  crt="$(sb_crt_path)"
  [ -f "$crt" ] || die "Public cert not found: $crt"

  dest="$(pwd)/MOK-$(machine_id).crt"
  run_cmd cp -f "$crt" "$dest"

  log_info "Exported public cert to: $dest"
}

main() {
  parse_args "$@"
  require_root
  init_common

  if [ "$ACTION_STATUS" = "1" ]; then
    do_status
    return 0
  fi

  with_lock

  if [ "$DO_GENERATE" = "1" ]; then
    do_generate_key
  elif [ "$DO_ENROLL" = "1" ]; then
    do_enroll
  elif [ "$DO_EXPORT" = "1" ]; then
    do_export_public
  fi
}

main "$@"
