#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=./common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM_HOST=""
VM_USER="tester"
VM_REPO_DIR="/tmp/gp-bootstrap-vm"
SSH_KEY_PATH=""
REMOTE_SUDO_CMD="sudo"
RUN_REMOTE=0

NM_CONN_NAME=""
MODE="strict+lan"
LAN_CIDRS="192.168.0.0/16"
PHYS_IFACE=""
ENDPOINT=""
LAN_PROBE_IP=""
ALLOW_DISCONNECT=0
HARD_RELOAD=0
RUN_MOK_ENROLL=0
SKIP_SECURE_BOOT=0
KEEP_ACTIVE_STATE=0

usage() {
  cat <<USAGE
Usage:
  $TEST_SCRIPT_NAME [options]

Local checks (always):
  - file/executable presence
  - shell syntax checks
  - script help output checks

Remote VM checks (optional):
  - push repo to VM via scp
  - execute test/run_vm_tests.sh through SSH

Options:
  --repo-root <path>           Override repository root
  --vm-host <host-or-ip>       Enable remote VM checks on this host
  --vm-user <user>             VM SSH user (default: tester)
  --vm-repo-dir <path>         Remote repo path (default: /tmp/gp-bootstrap-vm)
  --ssh-key <path>             SSH private key path
  --remote-sudo-cmd <cmd>      Remote privilege command (default: sudo)

  --nm-conn <name>             NM profile for remote VM tests
  --mode <strict|strict+lan>   Forwarded to VM tests
  --lan <cidr1,cidr2>          Forwarded to VM tests
  --phys-iface <iface>         Forwarded to VM tests
  --endpoint <ip:port>         Forwarded to VM tests
  --lan-probe-ip <ip>          Forwarded to VM tests
  --allow-disconnect           Forwarded to VM tests
  --hard-reload                Forwarded to VM tests
  --run-mok-enroll             Forwarded to VM tests
  --skip-secure-boot           Forwarded to VM tests
  --keep-active-state          Forwarded to VM tests

  --dry-run                    Print commands without executing
  --debug                      Verbose logging
  -h, --help                   Show help
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo-root)
        shift
        [ "$#" -gt 0 ] || die "--repo-root requires value"
        REPO_ROOT="$1"
        ;;
      --vm-host)
        shift
        [ "$#" -gt 0 ] || die "--vm-host requires value"
        VM_HOST="$1"
        RUN_REMOTE=1
        ;;
      --vm-user)
        shift
        [ "$#" -gt 0 ] || die "--vm-user requires value"
        VM_USER="$1"
        ;;
      --vm-repo-dir)
        shift
        [ "$#" -gt 0 ] || die "--vm-repo-dir requires value"
        VM_REPO_DIR="$1"
        ;;
      --ssh-key)
        shift
        [ "$#" -gt 0 ] || die "--ssh-key requires value"
        SSH_KEY_PATH="$1"
        ;;
      --remote-sudo-cmd)
        shift
        [ "$#" -gt 0 ] || die "--remote-sudo-cmd requires value"
        REMOTE_SUDO_CMD="$1"
        ;;
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

run_local_checks() {
  log_info "Running local repository checks"

  local must_exist=(
    "$REPO_ROOT/README.md"
    "$REPO_ROOT/CHANGELOG.md"
    "$REPO_ROOT/agent.md"
    "$REPO_ROOT/etc/example.env"
    "$REPO_ROOT/lib/common.sh"
    "$REPO_ROOT/bin/wg_killswitch.sh"
    "$REPO_ROOT/bin/wg_killswitch_reset.sh"
    "$REPO_ROOT/bin/vpn_reload.sh"
    "$REPO_ROOT/bin/sb_mok_mvp.sh"
    "$REPO_ROOT/test/common.sh"
    "$REPO_ROOT/test/vmm_prepare_vm.sh"
    "$REPO_ROOT/test/run_host_tests.sh"
    "$REPO_ROOT/test/run_vm_tests.sh"
  )

  local path
  for path in "${must_exist[@]}"; do
    assert_file_exists "$path"
  done

  local must_exec=(
    "$REPO_ROOT/bin/wg_killswitch.sh"
    "$REPO_ROOT/bin/wg_killswitch_reset.sh"
    "$REPO_ROOT/bin/vpn_reload.sh"
    "$REPO_ROOT/bin/sb_mok_mvp.sh"
    "$REPO_ROOT/test/vmm_prepare_vm.sh"
    "$REPO_ROOT/test/run_host_tests.sh"
    "$REPO_ROOT/test/run_vm_tests.sh"
  )

  for path in "${must_exec[@]}"; do
    assert_executable "$path"
  done

  run_cmd bash -n \
    "$REPO_ROOT/lib/common.sh" \
    "$REPO_ROOT/bin/wg_killswitch.sh" \
    "$REPO_ROOT/bin/wg_killswitch_reset.sh" \
    "$REPO_ROOT/bin/vpn_reload.sh" \
    "$REPO_ROOT/bin/sb_mok_mvp.sh" \
    "$REPO_ROOT/test/common.sh" \
    "$REPO_ROOT/test/vmm_prepare_vm.sh" \
    "$REPO_ROOT/test/run_host_tests.sh" \
    "$REPO_ROOT/test/run_vm_tests.sh"

  run_cmd "$REPO_ROOT/bin/wg_killswitch.sh" --help
  run_cmd "$REPO_ROOT/bin/wg_killswitch_reset.sh" --help
  run_cmd "$REPO_ROOT/bin/vpn_reload.sh" --help
  run_cmd "$REPO_ROOT/bin/sb_mok_mvp.sh" --help
  run_cmd "$REPO_ROOT/test/vmm_prepare_vm.sh" --help
  run_cmd "$REPO_ROOT/test/run_vm_tests.sh" --help

  log_info "Local checks passed"
}

build_ssh_base() {
  SSH_BASE=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
  SCP_BASE=(scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

  if [ -n "$SSH_KEY_PATH" ]; then
    [ -f "$SSH_KEY_PATH" ] || die "SSH key not found: $SSH_KEY_PATH"
    SSH_BASE+=(-i "$SSH_KEY_PATH")
    SCP_BASE+=(-i "$SSH_KEY_PATH")
  fi
}

build_vm_test_args() {
  VM_TEST_ARGS=(--nm-conn "$NM_CONN_NAME" --mode "$MODE" --lan "$LAN_CIDRS")

  if [ -n "$PHYS_IFACE" ]; then
    VM_TEST_ARGS+=(--phys-iface "$PHYS_IFACE")
  fi
  if [ -n "$ENDPOINT" ]; then
    VM_TEST_ARGS+=(--endpoint "$ENDPOINT")
  fi
  if [ -n "$LAN_PROBE_IP" ]; then
    VM_TEST_ARGS+=(--lan-probe-ip "$LAN_PROBE_IP")
  fi
  if [ "$ALLOW_DISCONNECT" = "1" ]; then
    VM_TEST_ARGS+=(--allow-disconnect)
  fi
  if [ "$HARD_RELOAD" = "1" ]; then
    VM_TEST_ARGS+=(--hard-reload)
  fi
  if [ "$RUN_MOK_ENROLL" = "1" ]; then
    VM_TEST_ARGS+=(--run-mok-enroll)
  fi
  if [ "$SKIP_SECURE_BOOT" = "1" ]; then
    VM_TEST_ARGS+=(--skip-secure-boot)
  fi
  if [ "$KEEP_ACTIVE_STATE" = "1" ]; then
    VM_TEST_ARGS+=(--keep-active-state)
  fi
  if [ "$TEST_DEBUG" = "1" ]; then
    VM_TEST_ARGS+=(--debug)
  fi
}

run_remote_vm_checks() {
  if [ "$RUN_REMOTE" != "1" ]; then
    log_info "Remote VM checks skipped (no --vm-host provided)."
    return 0
  fi

  [ -n "$VM_HOST" ] || die "Internal error: VM_HOST empty"
  [ -n "$NM_CONN_NAME" ] || die "--nm-conn is required when --vm-host is used"

  require_cmd ssh
  require_cmd scp

  build_ssh_base
  build_vm_test_args

  local target
  target="$VM_USER@$VM_HOST"

  log_info "Preparing remote directory: $target:$VM_REPO_DIR"
  run_cmd "${SSH_BASE[@]}" "$target" "rm -rf '$VM_REPO_DIR' && mkdir -p '$VM_REPO_DIR'"

  log_info "Copying repository to VM"
  run_cmd "${SCP_BASE[@]}" -r "$REPO_ROOT/." "$target:$VM_REPO_DIR/"

  local remote_cmd
  remote_cmd="$REMOTE_SUDO_CMD bash '$VM_REPO_DIR/test/run_vm_tests.sh'"

  local arg
  for arg in "${VM_TEST_ARGS[@]}"; do
    remote_cmd+=" $(printf '%q' "$arg")"
  done

  log_info "Running remote VM tests"
  run_cmd "${SSH_BASE[@]}" "$target" "$remote_cmd"

  log_info "Remote VM checks passed"
}

main() {
  parse_args "$@"
  run_local_checks
  run_remote_vm_checks
}

main "$@"
