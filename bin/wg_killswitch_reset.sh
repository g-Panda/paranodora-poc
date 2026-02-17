#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

ACTION_APPLY=0
ACTION_STATUS=0

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME --apply [--dry-run] [--debug]
  $SCRIPT_NAME --status [--debug]
USAGE
}

remove_policy_if_exists() {
  local policy="$1"
  if firewall_policy_exists "$policy"; then
    run_cmd_best_effort firewall-cmd --permanent --delete-policy="$policy" || true
  fi
}

remove_zone_if_exists() {
  local zone="$1"
  if firewall_zone_exists "$zone"; then
    run_cmd_best_effort firewall-cmd --permanent --delete-zone="$zone" || true
  fi
}

remove_zone_rich_rule_best_effort() {
  local zone="$1"
  local rule="$2"
  [ -z "$rule" ] && return 0
  run_cmd_best_effort firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$rule" || true
}

remove_policy_rich_rule_best_effort() {
  local policy="$1"
  local rule="$2"
  [ -z "$rule" ] && return 0
  run_cmd_best_effort firewall-cmd --permanent --policy="$policy" --remove-rich-rule="$rule" || true
}

remove_gp_direct_rules_best_effort() {
  local rules
  rules="$(firewall-cmd --permanent --direct --get-all-rules 2>/dev/null | grep 'gp-bootstrap:' || true)"
  if [ -z "$rules" ]; then
    return 0
  fi

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2086
    run_cmd_best_effort firewall-cmd --permanent --direct --remove-rule $line || true
  done <<<"$rules"
}

restore_interface_zone() {
  local iface="$1"
  local previous_zone="$2"

  [ -z "$iface" ] && return 0

  remove_interface_from_zone_best_effort gp-phys-lock "$iface"
  remove_interface_from_zone_best_effort gp-wg "$iface"

  if [ -n "$previous_zone" ]; then
    if ! firewall_zone_exists "$previous_zone"; then
      log_warn "Previous zone $previous_zone for interface $iface does not exist anymore; leaving interface unassigned."
      return 0
    fi
    assign_interface_zone "$iface" "$previous_zone"
  fi
}

print_status() {
  print_env_detection

  if ! load_state_file; then
    log_info "No state file found ($GP_BOOTSTRAP_STATE_FILE)."
    log_info "Kill switch reset status: inactive"
    return 0
  fi

  log_info "State file: $GP_BOOTSTRAP_STATE_FILE"
  log_info "  ACTIVE=${ACTIVE:-0}"
  log_info "  STRATEGY=${STRATEGY:-unknown}"
  log_info "  NM_CONN_NAME=${NM_CONN_NAME:-}"
  log_info "  PHYS_IFACE=${PHYS_IFACE:-}"
  log_info "  VPN_IFACE=${VPN_IFACE:-}"
  log_info "  PREV_PHYS_ZONE=${PREV_PHYS_ZONE:-}"
  log_info "  PREV_VPN_ZONE=${PREV_VPN_ZONE:-}"
  log_info "  CREATED_ZONES=${CREATED_ZONES:-}"
  log_info "  CREATED_POLICIES=${CREATED_POLICIES:-}"
  log_info "  APPLIED_AT=${APPLIED_AT:-}"
  log_info "  RESET_AT=${RESET_AT:-}"

  if command_exists firewall-cmd; then
    log_info "Current gp-* zones:"
    firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep '^gp-' | while IFS= read -r z; do
      log_info "  $z"
    done || true

    if firewall_supports_policies; then
      log_info "Current gp-* policies:"
      firewall-cmd --get-policies 2>/dev/null | tr ' ' '\n' | grep '^gp-' | while IFS= read -r p; do
        log_info "  $p"
      done || true
    fi
  fi
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

main() {
  parse_args "$@"
  require_root
  init_common

  require_cmd firewall-cmd

  if [ "$ACTION_STATUS" = "1" ]; then
    print_status
    return 0
  fi

  with_lock

  if ! load_state_file; then
    log_info "No kill switch state found. Reset is a no-op."
    return 0
  fi

  if [ "${ACTIVE:-0}" != "1" ]; then
    log_info "Kill switch already inactive. Reset is a no-op."
    return 0
  fi

  local backup_dir
  backup_dir="$(create_backup_dir "killswitch-reset")"
  snapshot_system_state "$backup_dir"

  log_info "Resetting kill switch state and firewall objects."

  local rule
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    remove_zone_rich_rule_best_effort gp-phys-lock "$rule"
  done < <(printf '%s' "${PHYS_RICH_RULES:-}" | tr '|' '\n' | sed '/^$/d')

  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    remove_policy_rich_rule_best_effort gp-vpn-handshake "$rule"
    remove_policy_rich_rule_best_effort gp-lan-allow "$rule"
  done < <(printf '%s' "${POLICY_RICH_RULES:-}" | tr '|' '\n' | sed '/^$/d')

  remove_gp_direct_rules_best_effort

  local policy
  while read -r policy; do
    [ -z "$policy" ] && continue
    remove_policy_if_exists "$policy"
  done < <(printf '%s' "${CREATED_POLICIES:-gp-vpn-egress,gp-vpn-handshake,gp-lan-allow,gp-phys-drop}" | tr ',' '\n' | sed '/^$/d')

  restore_interface_zone "${PHYS_IFACE:-}" "${PREV_PHYS_ZONE:-}"
  restore_interface_zone "${VPN_IFACE:-}" "${PREV_VPN_ZONE:-}"

  local zone
  while read -r zone; do
    [ -z "$zone" ] && continue
    remove_zone_if_exists "$zone"
  done < <(printf '%s' "${CREATED_ZONES:-gp-wg,gp-phys-lock}" | tr ',' '\n' | sed '/^$/d')

  run_cmd firewall-cmd --reload
  mark_state_inactive

  log_info "Kill switch reset completed."
  print_status
}

main "$@"
