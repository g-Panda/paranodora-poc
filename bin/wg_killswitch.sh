#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

ACTION_APPLY=0
ACTION_STATUS=0

NM_CONN_NAME="${NM_CONN_NAME:-}"
PHYS_IFACE="${PHYS_IFACE:-}"
VPN_IFACE="${VPN_IFACE:-}"
MODE="${MODE:-strict+lan}"
LAN_CIDRS="${LAN_CIDRS:-192.168.0.0/16}"
VPN_ENDPOINT_IP="${VPN_ENDPOINT_IP:-}"
VPN_ENDPOINT_PORT="${VPN_ENDPOINT_PORT:-}"
ENDPOINT_OVERRIDE=""

CREATED_ZONES="gp-wg,gp-phys-lock"
CREATED_POLICIES=""
PHYS_RICH_RULES=""
POLICY_RICH_RULES=""

usage() {
  cat <<USAGE
Usage:
  $SCRIPT_NAME --apply --nm-conn <NAME> [--mode strict|strict+lan] [--lan <cidr1,cidr2>] [--endpoint IP:PORT] [--phys-iface IFACE] [--dry-run] [--debug]
  $SCRIPT_NAME --status [--nm-conn <NAME>] [--debug]

Notes:
  - Root only.
  - NetworkManager only (nmcli), no wg-quick.
  - Stateful kill switch remains active until manual reset.
USAGE
}

validate_cidr_list() {
  local cidr
  while read -r cidr; do
    [ -z "$cidr" ] && continue
    if ! printf '%s' "$cidr" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/(3[0-2]|[12]?[0-9])$'; then
      die "Invalid LAN CIDR: $cidr"
    fi
    if ! is_valid_ipv4 "${cidr%/*}"; then
      die "Invalid LAN CIDR address: $cidr"
    fi
  done < <(csv_to_lines "$LAN_CIDRS")
}

ensure_zone_rich_rule() {
  local zone="$1"
  local rule="$2"
  if firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
    log_debug "Rich rule already present in $zone: $rule"
    return 0
  fi
  run_cmd firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule"
}

ensure_policy_rich_rule() {
  local policy="$1"
  local rule="$2"
  if firewall-cmd --permanent --policy="$policy" --query-rich-rule="$rule" >/dev/null 2>&1; then
    log_debug "Rich rule already present in policy $policy: $rule"
    return 0
  fi
  run_cmd firewall-cmd --permanent --policy="$policy" --add-rich-rule="$rule"
}

list_gp_objects() {
  if command_exists firewall-cmd; then
    log_info "GP zones (permanent):"
    firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep '^gp-' | while IFS= read -r z; do
      [ -z "$z" ] && continue
      log_info "  zone: $z"
    done || true

    if firewall_supports_policies; then
      log_info "GP policies:"
      firewall-cmd --get-policies 2>/dev/null | tr ' ' '\n' | grep '^gp-' | while IFS= read -r p; do
        [ -z "$p" ] && continue
        log_info "  policy: $p"
      done || true
    fi
  fi
}

print_status() {
  print_env_detection

  if load_state_file; then
    log_info "State file: $GP_BOOTSTRAP_STATE_FILE"
    log_info "  ACTIVE=${ACTIVE:-0}"
    log_info "  STRATEGY=${STRATEGY:-unknown}"
    log_info "  NM_CONN_NAME=${NM_CONN_NAME:-}"
    log_info "  PHYS_IFACE=${PHYS_IFACE:-}"
    log_info "  VPN_IFACE=${VPN_IFACE:-}"
    log_info "  MODE=${MODE:-}"
    log_info "  LAN_CIDRS=${LAN_CIDRS:-}"
    log_info "  VPN_ENDPOINT_IP=${VPN_ENDPOINT_IP:-}"
    log_info "  VPN_ENDPOINT_PORT=${VPN_ENDPOINT_PORT:-}"
    log_info "  APPLIED_AT=${APPLIED_AT:-}"
    log_info "  BACKUP_DIR=${BACKUP_DIR:-}"
  else
    log_warn "No state file found at $GP_BOOTSTRAP_STATE_FILE"
  fi

  if command_exists firewall-cmd; then
    log_info "firewall active zones:"
    firewall-cmd --get-active-zones 2>/dev/null | while IFS= read -r line; do
      log_info "  $line"
    done || true

    for zone in gp-wg gp-phys-lock; do
      if firewall_zone_exists "$zone"; then
        log_info "zone details: $zone"
        firewall-cmd --permanent --zone="$zone" --list-all 2>/dev/null | while IFS= read -r line; do
          log_info "  $line"
        done || true
      fi
    done

    if firewall_supports_policies; then
      for policy in gp-vpn-egress gp-vpn-handshake gp-lan-allow gp-phys-drop; do
        if firewall_policy_exists "$policy"; then
          log_info "policy details: $policy"
          firewall-cmd --permanent --policy="$policy" --list-all 2>/dev/null | while IFS= read -r line; do
            log_info "  $line"
          done || true
        fi
      done
    fi
  fi

  if command_exists ip; then
    log_info "ip route:"
    ip route 2>/dev/null | while IFS= read -r line; do
      log_info "  $line"
    done || true

    log_info "ip rule:"
    ip rule 2>/dev/null | while IFS= read -r line; do
      log_info "  $line"
    done || true
  fi

  local phys="${PHYS_IFACE:-}"
  local vpn="${VPN_IFACE:-}"
  if [ -z "$phys" ]; then
    phys="$(detect_physical_iface || true)"
  fi

  if [ -n "$phys" ]; then
    print_dns_warning "$phys" "$vpn"
  fi

  list_gp_objects
}

cleanup_partial_policies() {
  local p
  for p in gp-vpn-egress gp-vpn-handshake gp-lan-allow gp-phys-drop; do
    if firewall_policy_exists "$p"; then
      run_cmd_best_effort firewall-cmd --permanent --delete-policy="$p" || true
    fi
  done
}

setup_zones_and_rules() {
  local endpoint_rule="$1"

  if ! ensure_zone gp-wg; then
    return 1
  fi
  if ! ensure_zone gp-phys-lock; then
    return 1
  fi

  if ! set_zone_target gp-wg ACCEPT; then
    return 1
  fi
  if ! set_zone_target gp-phys-lock DROP; then
    return 1
  fi

  if ! assign_interface_zone "$PHYS_IFACE" gp-phys-lock; then
    return 1
  fi
  if ! assign_interface_zone "$VPN_IFACE" gp-wg; then
    return 1
  fi

  if ! ensure_zone_rich_rule gp-phys-lock "$endpoint_rule"; then
    return 1
  fi
  if [ -n "$PHYS_RICH_RULES" ]; then
    PHYS_RICH_RULES+="||"
  fi
  PHYS_RICH_RULES+="$endpoint_rule"

  if [ "$MODE" = "strict+lan" ]; then
    local cidr rule
    while read -r cidr; do
      [ -z "$cidr" ] && continue
      rule="rule family=\"ipv4\" destination address=\"$cidr\" accept"
      if ! ensure_zone_rich_rule gp-phys-lock "$rule"; then
        return 1
      fi
      PHYS_RICH_RULES+="||$rule"
    done < <(csv_to_lines "$LAN_CIDRS")
  fi

  return 0
}

apply_policies_strategy() {
  local endpoint_rule="$1"
  CREATED_POLICIES="gp-vpn-egress,gp-vpn-handshake,gp-phys-drop"

  if [ "$MODE" = "strict+lan" ]; then
    CREATED_POLICIES+=",gp-lan-allow"
  fi

  if ! setup_zones_and_rules "$endpoint_rule"; then
    return 1
  fi

  if ! ensure_policy gp-vpn-egress; then
    return 1
  fi
  if ! ensure_policy gp-vpn-handshake; then
    return 1
  fi
  if ! ensure_policy gp-phys-drop; then
    return 1
  fi

  if [ "$MODE" = "strict+lan" ]; then
    if ! ensure_policy gp-lan-allow; then
      return 1
    fi
  fi

  run_cmd_best_effort firewall-cmd --permanent --policy=gp-vpn-egress --remove-ingress-zone=HOST || true
  run_cmd_best_effort firewall-cmd --permanent --policy=gp-vpn-egress --remove-egress-zone=gp-wg || true
  run_cmd firewall-cmd --permanent --policy=gp-vpn-egress --set-target=ACCEPT
  run_cmd firewall-cmd --permanent --policy=gp-vpn-egress --add-ingress-zone=HOST
  run_cmd firewall-cmd --permanent --policy=gp-vpn-egress --add-egress-zone=gp-wg
  policy_set_priority_if_supported gp-vpn-egress -100

  run_cmd_best_effort firewall-cmd --permanent --policy=gp-vpn-handshake --remove-ingress-zone=HOST || true
  run_cmd_best_effort firewall-cmd --permanent --policy=gp-vpn-handshake --remove-egress-zone=gp-phys-lock || true
  run_cmd firewall-cmd --permanent --policy=gp-vpn-handshake --set-target=ACCEPT
  run_cmd firewall-cmd --permanent --policy=gp-vpn-handshake --add-ingress-zone=HOST
  run_cmd firewall-cmd --permanent --policy=gp-vpn-handshake --add-egress-zone=gp-phys-lock
  policy_set_priority_if_supported gp-vpn-handshake -90
  if ! ensure_policy_rich_rule gp-vpn-handshake "$endpoint_rule"; then
    return 1
  fi
  POLICY_RICH_RULES="$endpoint_rule"

  if [ "$MODE" = "strict+lan" ]; then
    run_cmd_best_effort firewall-cmd --permanent --policy=gp-lan-allow --remove-ingress-zone=HOST || true
    run_cmd_best_effort firewall-cmd --permanent --policy=gp-lan-allow --remove-egress-zone=gp-phys-lock || true
    run_cmd firewall-cmd --permanent --policy=gp-lan-allow --set-target=ACCEPT
    run_cmd firewall-cmd --permanent --policy=gp-lan-allow --add-ingress-zone=HOST
    run_cmd firewall-cmd --permanent --policy=gp-lan-allow --add-egress-zone=gp-phys-lock
    policy_set_priority_if_supported gp-lan-allow -80

    local cidr lan_rule
    while read -r cidr; do
      [ -z "$cidr" ] && continue
      lan_rule="rule family=\"ipv4\" destination address=\"$cidr\" accept"
      if ! ensure_policy_rich_rule gp-lan-allow "$lan_rule"; then
        return 1
      fi
      POLICY_RICH_RULES+="||$lan_rule"
    done < <(csv_to_lines "$LAN_CIDRS")
  fi

  run_cmd_best_effort firewall-cmd --permanent --policy=gp-phys-drop --remove-ingress-zone=HOST || true
  run_cmd_best_effort firewall-cmd --permanent --policy=gp-phys-drop --remove-egress-zone=gp-phys-lock || true
  run_cmd firewall-cmd --permanent --policy=gp-phys-drop --set-target=DROP
  run_cmd firewall-cmd --permanent --policy=gp-phys-drop --add-ingress-zone=HOST
  run_cmd firewall-cmd --permanent --policy=gp-phys-drop --add-egress-zone=gp-phys-lock
  policy_set_priority_if_supported gp-phys-drop 100

  return 0
}

apply_zones_strategy() {
  local endpoint_rule="$1"
  CREATED_POLICIES=""
  POLICY_RICH_RULES=""
  setup_zones_and_rules "$endpoint_rule"
}

resolve_runtime_values() {
  LAN_CIDRS="$(normalize_csv "$LAN_CIDRS")"

  if ! validate_mode "$MODE"; then
    die "Invalid mode: $MODE (allowed: strict, strict+lan)"
  fi

  if [ "$MODE" = "strict+lan" ]; then
    validate_cidr_list
  fi

  if [ -z "$NM_CONN_NAME" ]; then
    die "NM connection name is required (use --nm-conn or NM_CONN_NAME env)."
  fi

  if [ -z "$PHYS_IFACE" ]; then
    PHYS_IFACE="$(detect_physical_iface || true)"
  fi
  if [ -z "$PHYS_IFACE" ]; then
    die "Failed to detect physical interface. Pass --phys-iface explicitly."
  fi

  if [ -z "$VPN_IFACE" ]; then
    VPN_IFACE="$(nm_conn_active_device "$NM_CONN_NAME" || true)"
  fi
  if [ -z "$VPN_IFACE" ]; then
    VPN_IFACE="$(nm_conn_interface_name "$NM_CONN_NAME" || true)"
  fi
  if [ -z "$VPN_IFACE" ]; then
    die "Failed to detect VPN interface from NM profile. Set connection.interface-name or export VPN_IFACE."
  fi

  if [ "$PHYS_IFACE" = "$VPN_IFACE" ]; then
    die "Physical interface and VPN interface resolve to the same value ($PHYS_IFACE)."
  fi

  if [ -n "$ENDPOINT_OVERRIDE" ]; then
    read -r VPN_ENDPOINT_IP VPN_ENDPOINT_PORT < <(split_endpoint "$ENDPOINT_OVERRIDE" || true)
  fi

  if [ -z "$VPN_ENDPOINT_IP" ] || [ -z "$VPN_ENDPOINT_PORT" ]; then
    local detected_endpoint
    detected_endpoint="$(nm_conn_endpoint "$NM_CONN_NAME" || true)"
    if [ -n "$detected_endpoint" ]; then
      read -r VPN_ENDPOINT_IP VPN_ENDPOINT_PORT < <(split_endpoint "$detected_endpoint" || true)
    fi
  fi

  if [ -z "$VPN_ENDPOINT_IP" ] || [ -z "$VPN_ENDPOINT_PORT" ]; then
    die "VPN endpoint unresolved. Provide --endpoint IP:PORT or set VPN_ENDPOINT_IP/VPN_ENDPOINT_PORT."
  fi

  if ! is_valid_ipv4 "$VPN_ENDPOINT_IP"; then
    die "Invalid VPN endpoint IPv4: $VPN_ENDPOINT_IP"
  fi
  if ! is_valid_port "$VPN_ENDPOINT_PORT"; then
    die "Invalid VPN endpoint port: $VPN_ENDPOINT_PORT"
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
      --nm-conn)
        shift
        [ "$#" -gt 0 ] || die "--nm-conn requires a value"
        NM_CONN_NAME="$1"
        ;;
      --mode)
        shift
        [ "$#" -gt 0 ] || die "--mode requires a value"
        MODE="$1"
        ;;
      --lan)
        shift
        [ "$#" -gt 0 ] || die "--lan requires a value"
        LAN_CIDRS="$1"
        ;;
      --endpoint)
        shift
        [ "$#" -gt 0 ] || die "--endpoint requires a value"
        ENDPOINT_OVERRIDE="$1"
        ;;
      --phys-iface)
        shift
        [ "$#" -gt 0 ] || die "--phys-iface requires a value"
        PHYS_IFACE="$1"
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

  require_cmd ip

  if [ "$ACTION_STATUS" = "1" ]; then
    print_status
    return 0
  fi

  with_lock

  require_cmd nmcli
  require_cmd firewall-cmd

  if ! firewalld_is_running; then
    die "firewalld is not active. Start firewalld before applying kill switch."
  fi

  if load_state_file && [ "${ACTIVE:-0}" = "1" ]; then
    log_info "Kill switch already active. Showing status only (no changes)."
    print_status
    return 0
  fi

  resolve_runtime_values

  local backup_dir
  backup_dir="$(create_backup_dir "killswitch-apply")"
  snapshot_system_state "$backup_dir"

  local prev_phys_zone prev_vpn_zone
  prev_phys_zone="$(firewall_zone_of_interface "$PHYS_IFACE")"
  prev_vpn_zone="$(firewall_zone_of_interface "$VPN_IFACE")"

  log_info "Applying kill switch for NM profile: $NM_CONN_NAME"
  log_info "Physical iface: $PHYS_IFACE | VPN iface: $VPN_IFACE | mode: $MODE"
  log_info "VPN endpoint: ${VPN_ENDPOINT_IP}:${VPN_ENDPOINT_PORT}"

  local endpoint_rule
  endpoint_rule="rule family=\"ipv4\" destination address=\"$VPN_ENDPOINT_IP\" port port=\"$VPN_ENDPOINT_PORT\" protocol=\"udp\" accept"

  local strategy
  strategy="zones"

  if firewall_supports_policies; then
    log_info "firewalld policies supported, trying policy strategy first"
    if apply_policies_strategy "$endpoint_rule"; then
      strategy="policy"
    else
      log_warn "Policy strategy failed, cleaning partial policies and falling back to zones"
      cleanup_partial_policies
      PHYS_RICH_RULES=""
      POLICY_RICH_RULES=""
      apply_zones_strategy "$endpoint_rule"
      strategy="zones"
    fi
  else
    log_info "firewalld policies unsupported, using zones strategy"
    apply_zones_strategy "$endpoint_rule"
  fi

  run_cmd firewall-cmd --reload

  save_state_file \
    STATE_VERSION "1" \
    ACTIVE "1" \
    APPLIED_AT "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    RESET_AT "" \
    STRATEGY "$strategy" \
    NM_CONN_NAME "$NM_CONN_NAME" \
    PHYS_IFACE "$PHYS_IFACE" \
    VPN_IFACE "$VPN_IFACE" \
    MODE "$MODE" \
    LAN_CIDRS "$LAN_CIDRS" \
    VPN_ENDPOINT_IP "$VPN_ENDPOINT_IP" \
    VPN_ENDPOINT_PORT "$VPN_ENDPOINT_PORT" \
    PREV_PHYS_ZONE "$prev_phys_zone" \
    PREV_VPN_ZONE "$prev_vpn_zone" \
    BACKUP_DIR "$backup_dir" \
    CREATED_ZONES "$CREATED_ZONES" \
    CREATED_POLICIES "$CREATED_POLICIES" \
    PHYS_RICH_RULES "$PHYS_RICH_RULES" \
    POLICY_RICH_RULES "$POLICY_RICH_RULES" \
    NOTES "gp-bootstrap:mvp"

  log_info "Kill switch applied successfully using strategy: $strategy"
  print_status
}

main "$@"
