#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=./common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$REPO_ROOT/bin"

NM_CONN_NAME=""
MODE="strict+lan"
LAN_CIDRS="192.168.0.0/16"
PHYS_IFACE=""
ENDPOINT=""
LAN_PROBE_IP=""
STATUS_URL="https://ifconfig.co"
ALLOW_DISCONNECT=0
HARD_RELOAD=0
RUN_MOK_ENROLL=0
SKIP_SECURE_BOOT=0
KEEP_ACTIVE_STATE=0

KILLSWITCH_APPLIED=0

usage() {
  cat <<USAGE
Usage:
  sudo $TEST_SCRIPT_NAME --nm-conn <name> [options]

Options:
  --nm-conn <name>            NetworkManager WireGuard profile name (required)
  --mode <strict|strict+lan>  Kill switch mode (default: strict+lan)
  --lan <cidr1,cidr2>         LAN CIDRs when mode strict+lan (default: 192.168.0.0/16)
  --phys-iface <iface>        Override detected physical interface
  --endpoint <ip:port>        Override endpoint extraction
  --lan-probe-ip <ip>         LAN probe target for ping checks (default: current gateway)
  --status-url <url>          Public check URL (default: https://ifconfig.co)
  --allow-disconnect          Allow destructive leak test (nmcli con down)
  --hard-reload               Use vpn_reload.sh --hard
  --run-mok-enroll            Also run interactive MOK enrollment step
  --skip-secure-boot          Skip MOK/Secure Boot checks
  --keep-active-state         Do not reset kill switch at script end
  --dry-run                   Print commands without executing
  --debug                     Verbose logging
  -h, --help                  Show help

Test coverage:
  - Apply/status/reset kill switch
  - VPN connectivity with active tunnel
  - Leak test after VPN down (when --allow-disconnect)
  - LAN reachability expectation by mode (if probe IP known)
  - Secure Boot MOK status + key generation/export (best effort)
USAGE
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This test must run as root."
  fi
}

cleanup() {
  if [ "$KEEP_ACTIVE_STATE" = "1" ]; then
    log_warn "Skipping cleanup due to --keep-active-state"
    return 0
  fi

  if [ "$KILLSWITCH_APPLIED" = "1" ]; then
    log_info "Cleanup: resetting kill switch"
    "$BIN_DIR/wg_killswitch_reset.sh" --apply || true
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nm-conn)
        shift
        [ "$#" -gt 0 ] || die "--nm-conn requires value"
        NM_CONN_NAME="$1"
        ;;
      --mode)
        shift
        [ "$#" -gt 0 ] || die "--mode requires value"
        MODE="$1"
        ;;
      --lan)
        shift
        [ "$#" -gt 0 ] || die "--lan requires value"
        LAN_CIDRS="$1"
        ;;
      --phys-iface)
        shift
        [ "$#" -gt 0 ] || die "--phys-iface requires value"
        PHYS_IFACE="$1"
        ;;
      --endpoint)
        shift
        [ "$#" -gt 0 ] || die "--endpoint requires value"
        ENDPOINT="$1"
        ;;
      --lan-probe-ip)
        shift
        [ "$#" -gt 0 ] || die "--lan-probe-ip requires value"
        LAN_PROBE_IP="$1"
        ;;
      --status-url)
        shift
        [ "$#" -gt 0 ] || die "--status-url requires value"
        STATUS_URL="$1"
        ;;
      --allow-disconnect)
        ALLOW_DISCONNECT=1
        ;;
      --hard-reload)
        HARD_RELOAD=1
        ;;
      --run-mok-enroll)
        RUN_MOK_ENROLL=1
        ;;
      --skip-secure-boot)
        SKIP_SECURE_BOOT=1
        ;;
      --keep-active-state)
        KEEP_ACTIVE_STATE=1
        ;;
      --dry-run)
        TEST_DRY_RUN=1
        ;;
      --debug)
        TEST_DEBUG=1
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
}

validate_inputs() {
  [ -n "$NM_CONN_NAME" ] || die "--nm-conn is required"

  case "$MODE" in
    strict|strict+lan)
      ;;
    *)
      die "Unsupported mode: $MODE"
      ;;
  esac

  for f in wg_killswitch.sh wg_killswitch_reset.sh vpn_reload.sh sb_mok_mvp.sh; do
    assert_file_exists "$BIN_DIR/$f"
    assert_executable "$BIN_DIR/$f"
  done
}

auto_detect_lan_probe() {
  if [ -n "$LAN_PROBE_IP" ]; then
    return 0
  fi

  LAN_PROBE_IP="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  if [ -n "$LAN_PROBE_IP" ]; then
    log_info "Auto-detected LAN probe IP: $LAN_PROBE_IP"
  else
    log_warn "Could not auto-detect LAN probe IP. LAN reachability assertion will be skipped."
  fi
}

run_killswitch_apply() {
  local cmd=("$BIN_DIR/wg_killswitch.sh" --apply --nm-conn "$NM_CONN_NAME" --mode "$MODE" --lan "$LAN_CIDRS")

  if [ -n "$PHYS_IFACE" ]; then
    cmd+=(--phys-iface "$PHYS_IFACE")
  fi

  if [ -n "$ENDPOINT" ]; then
    cmd+=(--endpoint "$ENDPOINT")
  fi

  if [ "$TEST_DEBUG" = "1" ]; then
    cmd+=(--debug)
  fi

  run_cmd "${cmd[@]}"
  KILLSWITCH_APPLIED=1
}

run_status_check() {
  local cmd=("$BIN_DIR/wg_killswitch.sh" --status)
  if [ "$TEST_DEBUG" = "1" ]; then
    cmd+=(--debug)
  fi
  run_cmd "${cmd[@]}"

  if [ -f /var/lib/gp-bootstrap/state.env ]; then
    # shellcheck disable=SC1091
    . /var/lib/gp-bootstrap/state.env
    [ "${ACTIVE:-0}" = "1" ] || die "State file exists but ACTIVE is not 1"
  else
    die "Missing /var/lib/gp-bootstrap/state.env after apply"
  fi
}

reload_vpn() {
  local cmd=("$BIN_DIR/vpn_reload.sh" --apply --nm-conn "$NM_CONN_NAME")

  if [ "$HARD_RELOAD" = "1" ]; then
    cmd+=(--hard)
  fi

  if [ "$TEST_DEBUG" = "1" ]; then
    cmd+=(--debug)
  fi

  run_cmd "${cmd[@]}"
}

assert_vpn_connectivity() {
  require_cmd curl
  require_cmd timeout

  log_info "Checking outbound connectivity with VPN up: $STATUS_URL"
  if ! timeout 15 curl -4 --max-time 10 --silent --show-error "$STATUS_URL" >/tmp/gp-bootstrap-vpn-check.txt; then
    die "Connectivity check failed while VPN should be active"
  fi

  local observed
  observed="$(head -n1 /tmp/gp-bootstrap-vpn-check.txt || true)"
  log_info "Connectivity check passed. Observed response: ${observed:-<empty>}"
}

assert_no_leak_after_disconnect() {
  if [ "$ALLOW_DISCONNECT" != "1" ]; then
    log_warn "Skipping leak test (use --allow-disconnect to enable destructive VPN down check)."
    return 0
  fi

  require_cmd nmcli
  require_cmd timeout

  log_warn "Running destructive leak test: nmcli con down $NM_CONN_NAME"
  run_cmd nmcli con down "$NM_CONN_NAME" || true
  run_cmd sleep 3

  if timeout 10 curl -4 --max-time 6 --silent --show-error http://1.1.1.1 >/tmp/gp-bootstrap-leak-check.txt 2>/tmp/gp-bootstrap-leak-check.err; then
    die "Leak test failed: internet reachable outside VPN"
  fi

  log_info "Leak test passed: no direct internet after VPN down"
}

assert_lan_expectation() {
  if [ -z "$LAN_PROBE_IP" ]; then
    log_warn "Skipping LAN assertion (no probe IP)."
    return 0
  fi

  require_cmd ping

  if [ "$MODE" = "strict+lan" ]; then
    if ping -c 2 -W 1 "$LAN_PROBE_IP" >/tmp/gp-bootstrap-lan-check.txt 2>&1; then
      log_info "LAN check passed in strict+lan mode (reachable: $LAN_PROBE_IP)"
    else
      die "LAN check failed in strict+lan mode (unreachable: $LAN_PROBE_IP)"
    fi
  else
    if ping -c 2 -W 1 "$LAN_PROBE_IP" >/tmp/gp-bootstrap-lan-check.txt 2>&1; then
      die "LAN check failed in strict mode (LAN should be blocked but ping succeeded)"
    fi
    log_info "LAN check passed in strict mode (blocked: $LAN_PROBE_IP)"
  fi
}

run_secure_boot_checks() {
  if [ "$SKIP_SECURE_BOOT" = "1" ]; then
    log_warn "Skipping secure boot checks by request (--skip-secure-boot)."
    return 0
  fi

  if ! command -v mokutil >/dev/null 2>&1; then
    log_warn "mokutil not found; skipping secure boot checks."
    return 0
  fi

  local status_cmd=("$BIN_DIR/sb_mok_mvp.sh" --status)
  local gen_cmd=("$BIN_DIR/sb_mok_mvp.sh" --apply --generate-key)
  local exp_cmd=("$BIN_DIR/sb_mok_mvp.sh" --apply --export-public)

  if [ "$TEST_DEBUG" = "1" ]; then
    status_cmd+=(--debug)
    gen_cmd+=(--debug)
    exp_cmd+=(--debug)
  fi

  run_cmd "${status_cmd[@]}"
  run_cmd "${gen_cmd[@]}"

  local mid key_path crt_path
  mid="$(cat /etc/machine-id)"
  key_path="/var/lib/gp-bootstrap/secureboot/$mid/MOK.key"
  crt_path="/var/lib/gp-bootstrap/secureboot/$mid/MOK.crt"

  [ -f "$key_path" ] || die "Missing generated key: $key_path"
  [ -f "$crt_path" ] || die "Missing generated cert: $crt_path"

  local key_perm cert_perm
  key_perm="$(stat -c '%a' "$key_path")"
  cert_perm="$(stat -c '%a' "$crt_path")"

  if [ "$key_perm" != "600" ]; then
    die "Unexpected key permissions: $key_perm (expected 600)"
  fi

  if [ "$cert_perm" != "644" ]; then
    die "Unexpected cert permissions: $cert_perm (expected 644)"
  fi

  run_cmd "${exp_cmd[@]}"

  local export_path
  export_path="$REPO_ROOT/MOK-$mid.crt"
  [ -f "$export_path" ] || die "Expected exported cert not found: $export_path"

  if [ "$RUN_MOK_ENROLL" = "1" ]; then
    local enr_cmd=("$BIN_DIR/sb_mok_mvp.sh" --apply --enroll)
    if [ "$TEST_DEBUG" = "1" ]; then
      enr_cmd+=(--debug)
    fi
    run_cmd "${enr_cmd[@]}"
  else
    log_warn "Skipping interactive MOK enrollment (use --run-mok-enroll to enable)."
  fi

  log_info "Secure Boot MVP checks completed"
}

main() {
  parse_args "$@"
  require_root

  require_cmd bash
  require_cmd ip
  require_cmd nmcli

  validate_inputs
  auto_detect_lan_probe

  trap cleanup EXIT

  log_info "Step 1/6: pre-reset (idempotent baseline)"
  run_cmd "$BIN_DIR/wg_killswitch_reset.sh" --apply

  log_info "Step 2/6: apply kill switch"
  run_killswitch_apply

  log_info "Step 3/6: status and VPN reload"
  run_status_check
  reload_vpn

  log_info "Step 4/6: connectivity checks"
  assert_vpn_connectivity
  assert_no_leak_after_disconnect
  assert_lan_expectation

  log_info "Step 5/6: restore VPN profile after leak check"
  reload_vpn

  log_info "Step 6/6: secure boot checks"
  run_secure_boot_checks

  if [ "$KEEP_ACTIVE_STATE" = "0" ]; then
    run_cmd "$BIN_DIR/wg_killswitch_reset.sh" --apply
    KILLSWITCH_APPLIED=0
  fi

  log_info "VM test run completed successfully"
}

main "$@"
