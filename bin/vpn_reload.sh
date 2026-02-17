#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

ACTION_APPLY=0
ACTION_STATUS=0
HARD_RESTART=0
NM_CONN_NAME="${NM_CONN_NAME:-}"

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME --apply [--nm-conn <NAME>] [--hard] [--dry-run] [--debug]
  $SCRIPT_NAME --status [--nm-conn <NAME>] [--debug]

Behavior:
  --apply performs:
    1) nmcli con down "<NAME>" (best effort)
    2) nmcli con up "<NAME>"
    3) optional systemctl restart NetworkManager when --hard is set
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply)
        ACTION_APPLY=1
        ;;
      --status)
        ACTION_STATUS=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --debug)
        DEBUG=1
        ;;
      --hard)
        HARD_RESTART=1
        ;;
      --nm-conn)
        shift
        [ "$#" -gt 0 ] || die "--nm-conn requires value"
        NM_CONN_NAME="$1"
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

  if [ "$ACTION_APPLY" = "0" ] && [ "$ACTION_STATUS" = "0" ]; then
    usage
    exit 1
  fi

  if [ "$ACTION_APPLY" = "1" ] && [ "$ACTION_STATUS" = "1" ]; then
    die "Choose only one action: --apply or --status"
  fi
}

resolve_nm_conn() {
  if [ -n "$NM_CONN_NAME" ]; then
    return 0
  fi

  if load_state_file && [ -n "${NM_CONN_NAME:-}" ]; then
    return 0
  fi

  die "Missing NM connection name. Pass --nm-conn or ensure state file has NM_CONN_NAME."
}

print_status() {
  if [ -n "$NM_CONN_NAME" ]; then
    log_info "VPN profile requested: $NM_CONN_NAME"
  else
    log_info "VPN profile not provided; listing active connections"
  fi

  log_info "nmcli active connections:"
  nmcli -t -f NAME,TYPE,DEVICE,STATE con show --active 2>/dev/null | while IFS= read -r line; do
    log_info "  $line"
  done || true

  if [ -n "$NM_CONN_NAME" ]; then
    log_info "nmcli connection details: $NM_CONN_NAME"
    nmcli con show "$NM_CONN_NAME" 2>/dev/null | head -n 80 | while IFS= read -r line; do
      log_info "  $line"
    done || die "Connection not found in NetworkManager: $NM_CONN_NAME"

    local device
    device="$(nm_conn_active_device "$NM_CONN_NAME" || true)"
    if [ -n "$device" ]; then
      log_info "Device status for $device:"
      nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS dev show "$device" 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
      done || true
    fi
  fi
}

main() {
  parse_args "$@"
  require_root
  init_common
  require_cmd nmcli

  if [ "$ACTION_STATUS" = "1" ]; then
    print_status
    return 0
  fi

  with_lock

  resolve_nm_conn

  if [ "$HARD_RESTART" = "1" ]; then
    require_cmd systemctl
    log_warn "Hard mode enabled: restarting NetworkManager before profile up"
    run_cmd systemctl restart NetworkManager
  fi

  log_info "Reloading NM profile: $NM_CONN_NAME"
  run_cmd_best_effort nmcli con down "$NM_CONN_NAME" || true
  run_cmd nmcli con up "$NM_CONN_NAME"

  log_info "VPN profile reload finished"
  print_status
}

main "$@"
