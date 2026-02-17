#!/usr/bin/env bash
set -euo pipefail

GP_BOOTSTRAP_ROOT="/var/lib/gp-bootstrap"
GP_BOOTSTRAP_STATE_FILE="$GP_BOOTSTRAP_ROOT/state.env"
GP_BOOTSTRAP_LOCK_FILE="$GP_BOOTSTRAP_ROOT/lock"
GP_BOOTSTRAP_BACKUP_BASE="/var/backups/gp-bootstrap"
GP_BOOTSTRAP_LOG_BASE="/var/log/gp-bootstrap"

SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
DEBUG="${DEBUG:-0}"
DRY_RUN="${DRY_RUN:-0}"
LOG_FILE=""

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

now_ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_line() {
  local level="$1"
  shift
  local msg="$*"
  local line
  line="$(now_ts) [$SCRIPT_NAME] [$level] $msg"
  printf '%s\n' "$line" >&2
  if [ -n "$LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

log_info() {
  log_line "INFO" "$*"
}

log_warn() {
  log_line "WARN" "$*"
}

log_error() {
  log_line "ERROR" "$*"
}

log_debug() {
  if [ "${DEBUG:-0}" = "1" ]; then
    log_line "DEBUG" "$*"
  fi
}

die() {
  log_error "$*"
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This script must be run as root."
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command_exists "$cmd"; then
    die "Missing required command: $cmd"
  fi
}

require_cmd_best_effort() {
  local cmd="$1"
  if ! command_exists "$cmd"; then
    log_warn "Optional command not available: $cmd"
    return 1
  fi
  return 0
}

init_logging() {
  mkdir -p "$GP_BOOTSTRAP_LOG_BASE"
  LOG_FILE="$GP_BOOTSTRAP_LOG_BASE/${SCRIPT_NAME%.sh}.log"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
}

init_runtime_dirs() {
  mkdir -p "$GP_BOOTSTRAP_ROOT" "$GP_BOOTSTRAP_BACKUP_BASE"
}

init_common() {
  init_runtime_dirs
  init_logging
}

with_lock() {
  require_cmd flock
  mkdir -p "$GP_BOOTSTRAP_ROOT"
  exec 9>"$GP_BOOTSTRAP_LOCK_FILE"
  if ! flock -n 9; then
    die "Another gp-bootstrap operation is in progress (lock: $GP_BOOTSTRAP_LOCK_FILE)."
  fi
}

quote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    out+="$(printf '%q' "$arg") "
  done
  printf '%s' "${out% }"
}

run_cmd() {
  if [ "$#" -eq 0 ]; then
    die "run_cmd: missing command"
  fi
  local q
  q="$(quote_cmd "$@")"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] $q"
    return 0
  fi
  log_debug "exec: $q"
  "$@"
}

run_cmd_best_effort() {
  if [ "$#" -eq 0 ]; then
    die "run_cmd_best_effort: missing command"
  fi
  local q
  q="$(quote_cmd "$@")"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] $q"
    return 0
  fi
  log_debug "exec(best-effort): $q"
  "$@" || return 1
}

capture_cmd() {
  local outfile="$1"
  shift
  {
    printf '$ '
    quote_cmd "$@"
    printf '\n'
    "$@"
  } >"$outfile" 2>&1 || true
}

capture_text() {
  local outfile="$1"
  local text="$2"
  printf '%s\n' "$text" >"$outfile"
}

create_backup_dir() {
  local label="${1:-snapshot}"
  local ts
  ts="$(date '+%Y%m%d-%H%M%S')"
  local dir="$GP_BOOTSTRAP_BACKUP_BASE/${ts}-${label}"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] would create backup dir: $dir"
    printf '%s\n' "$dir"
    return 0
  fi

  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

snapshot_system_state() {
  local backup_dir="$1"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] would snapshot system state into $backup_dir"
    return 0
  fi

  mkdir -p "$backup_dir"
  date >"$backup_dir/timestamp.txt"

  if command_exists firewall-cmd; then
    capture_cmd "$backup_dir/firewalld_list_all_zones.txt" firewall-cmd --permanent --list-all-zones
    if firewall_supports_policies; then
      capture_cmd "$backup_dir/firewalld_list_policies.txt" firewall-cmd --permanent --list-policies
      capture_cmd "$backup_dir/firewalld_get_policies.txt" firewall-cmd --get-policies
    else
      capture_text "$backup_dir/firewalld_list_policies.txt" "firewalld policies unsupported"
    fi
    capture_cmd "$backup_dir/firewalld_direct_rules.txt" firewall-cmd --permanent --direct --get-all-rules
    capture_cmd "$backup_dir/firewalld_get_zones.txt" firewall-cmd --permanent --get-zones
    capture_cmd "$backup_dir/firewalld_get_active_zones.txt" firewall-cmd --get-active-zones
  else
    capture_text "$backup_dir/firewalld_list_all_zones.txt" "firewall-cmd not found"
  fi

  if command_exists nmcli; then
    capture_cmd "$backup_dir/nmcli_con_show.txt" nmcli con show
    capture_cmd "$backup_dir/nmcli_active_connections.txt" nmcli -t -f NAME,TYPE,DEVICE con show --active
  else
    capture_text "$backup_dir/nmcli_con_show.txt" "nmcli not found"
  fi

  if command_exists ip; then
    capture_cmd "$backup_dir/ip_route.txt" ip route
    capture_cmd "$backup_dir/ip_rule.txt" ip rule
    capture_cmd "$backup_dir/ip_link.txt" ip link
  fi

  if [ -f "$GP_BOOTSTRAP_STATE_FILE" ]; then
    cp -a "$GP_BOOTSTRAP_STATE_FILE" "$backup_dir/state.env.before"
  fi
}

save_state_file() {
  if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
    die "save_state_file requires key/value pairs"
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "[dry-run] would write state file: $GP_BOOTSTRAP_STATE_FILE"
    return 0
  fi

  mkdir -p "$GP_BOOTSTRAP_ROOT"
  local tmp
  tmp="$(mktemp "$GP_BOOTSTRAP_ROOT/.state.env.XXXXXX")"

  while [ "$#" -gt 0 ]; do
    local key="$1"
    local val="$2"
    shift 2
    printf '%s=%q\n' "$key" "$val" >>"$tmp"
  done

  mv "$tmp" "$GP_BOOTSTRAP_STATE_FILE"
  chmod 600 "$GP_BOOTSTRAP_STATE_FILE"
}

load_state_file() {
  if [ ! -f "$GP_BOOTSTRAP_STATE_FILE" ]; then
    return 1
  fi

  # shellcheck disable=SC1090
  . "$GP_BOOTSTRAP_STATE_FILE"
  return 0
}

mark_state_inactive() {
  if ! load_state_file; then
    log_warn "State file missing, nothing to mark inactive."
    return 0
  fi

  save_state_file \
    STATE_VERSION "${STATE_VERSION:-1}" \
    ACTIVE "0" \
    APPLIED_AT "${APPLIED_AT:-}" \
    RESET_AT "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    STRATEGY "${STRATEGY:-}" \
    NM_CONN_NAME "${NM_CONN_NAME:-}" \
    PHYS_IFACE "${PHYS_IFACE:-}" \
    VPN_IFACE "${VPN_IFACE:-}" \
    MODE "${MODE:-}" \
    LAN_CIDRS "${LAN_CIDRS:-}" \
    VPN_ENDPOINT_IP "${VPN_ENDPOINT_IP:-}" \
    VPN_ENDPOINT_PORT "${VPN_ENDPOINT_PORT:-}" \
    PREV_PHYS_ZONE "${PREV_PHYS_ZONE:-}" \
    PREV_VPN_ZONE "${PREV_VPN_ZONE:-}" \
    BACKUP_DIR "${BACKUP_DIR:-}" \
    CREATED_ZONES "${CREATED_ZONES:-}" \
    CREATED_POLICIES "${CREATED_POLICIES:-}" \
    PHYS_RICH_RULES "${PHYS_RICH_RULES:-}" \
    POLICY_RICH_RULES "${POLICY_RICH_RULES:-}" \
    NOTES "${NOTES:-}"
}

is_ostree_system() {
  [ -f /run/ostree-booted ]
}

firewall_supports_policies() {
  if ! command_exists firewall-cmd; then
    return 1
  fi
  firewall-cmd --get-policies >/dev/null 2>&1
}

firewalld_is_running() {
  if ! command_exists systemctl; then
    return 1
  fi
  systemctl is-active --quiet firewalld
}

get_default_iface() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

is_probably_vpn_iface() {
  local iface="$1"
  case "$iface" in
    wg*|tun*|tap*|ppp*|vpn*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_physical_iface() {
  local iface
  while read -r iface; do
    [ -z "$iface" ] && continue
    if ! is_probably_vpn_iface "$iface"; then
      printf '%s\n' "$iface"
      return 0
    fi
  done < <(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1)}}}')

  if command_exists nmcli; then
    iface="$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | awk -F: '$2 ~ /ethernet|wifi/ && $3 == "connected" {print $1; exit}')"
    if [ -n "$iface" ]; then
      printf '%s\n' "$iface"
      return 0
    fi
  fi

  return 1
}

nm_conn_uuid() {
  local conn="$1"
  nmcli -g connection.uuid con show "$conn" 2>/dev/null | head -n1
}

nm_conn_filename() {
  local conn="$1"
  nmcli -g connection.filename con show "$conn" 2>/dev/null | head -n1
}

nm_conn_interface_name() {
  local conn="$1"
  local iface
  iface="$(nmcli -g connection.interface-name con show "$conn" 2>/dev/null | head -n1)"
  if [ -n "$iface" ]; then
    printf '%s\n' "$iface"
    return 0
  fi
  iface="$(nmcli -g wireguard.interface-name con show "$conn" 2>/dev/null | head -n1)"
  if [ -n "$iface" ]; then
    printf '%s\n' "$iface"
    return 0
  fi
  return 1
}

nm_conn_active_device() {
  local conn="$1"
  nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v target="$conn" '$1 == target {print $2; exit}'
}

parse_endpoint_from_nmcli() {
  local conn="$1"
  nmcli --show-secrets con show "$conn" 2>/dev/null \
    | sed -n 's/^[[:space:]]*endpoint[[:space:]]*=[[:space:]]*//p' \
    | head -n1
}

parse_endpoint_from_keyfile() {
  local file="$1"
  [ -f "$file" ] || return 1
  sed -n 's/^[[:space:]]*endpoint[[:space:]]*=[[:space:]]*//p' "$file" | head -n1
}

nm_conn_endpoint() {
  local conn="$1"
  local endpoint

  endpoint="$(parse_endpoint_from_nmcli "$conn")"
  if [ -n "$endpoint" ]; then
    printf '%s\n' "$endpoint"
    return 0
  fi

  local file
  file="$(nm_conn_filename "$conn")"
  if [ -n "$file" ]; then
    endpoint="$(parse_endpoint_from_keyfile "$file")"
    if [ -n "$endpoint" ]; then
      printf '%s\n' "$endpoint"
      return 0
    fi
  fi

  return 1
}

split_endpoint() {
  local endpoint="$1"
  if ! printf '%s' "$endpoint" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]{1,5}$'; then
    return 1
  fi

  local ip port
  ip="${endpoint%:*}"
  port="${endpoint##*:}"
  printf '%s %s\n' "$ip" "$port"
}

validate_mode() {
  local mode="$1"
  case "$mode" in
    strict|strict+lan)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

normalize_csv() {
  printf '%s' "$1" | tr -d ' ' | sed 's/,,*/,/g; s/^,//; s/,$//'
}

csv_to_lines() {
  printf '%s' "$1" | tr ',' '\n' | sed '/^$/d'
}

is_valid_port() {
  local port="$1"
  if ! printf '%s' "$port" | grep -Eq '^[0-9]+$'; then
    return 1
  fi
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_valid_ipv4() {
  local ip="$1"
  if ! printf '%s' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
    return 1
  fi

  local IFS='.'
  local o
  for o in $ip; do
    if [ "$o" -lt 0 ] || [ "$o" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

firewall_zone_exists() {
  local zone="$1"
  firewall-cmd --permanent --get-zones 2>/dev/null | tr ' ' '\n' | grep -Fxq "$zone"
}

firewall_policy_exists() {
  local policy="$1"
  firewall-cmd --get-policies 2>/dev/null | tr ' ' '\n' | grep -Fxq "$policy"
}

firewall_zone_of_interface() {
  local iface="$1"
  local zone
  zone="$(firewall-cmd --permanent --get-zone-of-interface="$iface" 2>/dev/null || true)"
  if [ "$zone" = "no zone" ]; then
    zone=""
  fi
  printf '%s\n' "$zone"
}

ensure_zone() {
  local zone="$1"
  if firewall_zone_exists "$zone"; then
    return 0
  fi
  run_cmd firewall-cmd --permanent --new-zone="$zone"
}

ensure_policy() {
  local policy="$1"
  if firewall_policy_exists "$policy"; then
    return 0
  fi
  run_cmd firewall-cmd --permanent --new-policy="$policy"
}

set_zone_target() {
  local zone="$1"
  local target="$2"
  run_cmd firewall-cmd --permanent --zone="$zone" --set-target="$target"
}

remove_interface_from_zone_best_effort() {
  local zone="$1"
  local iface="$2"
  run_cmd_best_effort firewall-cmd --permanent --zone="$zone" --remove-interface="$iface" || true
}

assign_interface_zone() {
  local iface="$1"
  local zone="$2"
  local current
  current="$(firewall_zone_of_interface "$iface")"

  if [ "$current" = "$zone" ]; then
    return 0
  fi

  if [ -n "$current" ]; then
    remove_interface_from_zone_best_effort "$current" "$iface"
  fi

  run_cmd firewall-cmd --permanent --zone="$zone" --add-interface="$iface"
}

policy_set_priority_if_supported() {
  local policy="$1"
  local priority="$2"

  if firewall-cmd --help 2>/dev/null | grep -q -- '--set-priority'; then
    run_cmd firewall-cmd --permanent --policy="$policy" --set-priority="$priority"
  else
    log_warn "firewall-cmd does not expose --set-priority; leaving default priority for $policy"
  fi
}

dns_servers_for_iface() {
  local iface="$1"
  nmcli -g IP4.DNS dev show "$iface" 2>/dev/null | sed '/^$/d' | paste -sd ',' -
}

print_dns_warning() {
  local phys_iface="$1"
  local vpn_iface="$2"

  if ! command_exists nmcli; then
    return 0
  fi

  local phys_dns vpn_dns
  phys_dns="$(dns_servers_for_iface "$phys_iface")"
  vpn_dns=""
  if [ -n "$vpn_iface" ]; then
    vpn_dns="$(dns_servers_for_iface "$vpn_iface")"
  fi

  if [ -n "$phys_dns" ] && [ -z "$vpn_dns" ]; then
    log_warn "Potential DNS leak: physical interface $phys_iface has DNS ($phys_dns) and VPN interface has none."
  fi

  if command_exists resolvectl; then
    log_info "resolvectl status (first 30 lines):"
    resolvectl status 2>/dev/null | head -n 30 | while IFS= read -r line; do
      log_info "  $line"
    done
  fi
}

print_env_detection() {
  if is_ostree_system; then
    log_info "System type: ostree/rpm-ostree"
  else
    log_info "System type: classic (non-ostree)"
  fi

  if command_exists firewall-cmd; then
    if firewalld_is_running; then
      log_info "firewalld: installed and running"
    else
      log_warn "firewalld: installed but not active"
    fi

    if firewall_supports_policies; then
      log_info "firewalld policies: supported"
    else
      log_warn "firewalld policies: not supported (zones fallback needed)"
    fi
  else
    log_warn "firewalld: firewall-cmd not found"
  fi

  if command_exists nmcli; then
    log_info "NetworkManager: nmcli available"
  else
    log_warn "NetworkManager: nmcli not found"
  fi
}
