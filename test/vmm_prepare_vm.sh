#!/usr/bin/env bash
set -euo pipefail

TEST_SCRIPT_NAME="$(basename "$0")"
# shellcheck source=./common.sh
. "$(cd "$(dirname "$0")" && pwd)/common.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VM_NAME="gp-fedora-vm"
PROFILE="fedora"
WORKDIR="$REPO_ROOT/test/.artifacts"
BASE_IMAGE=""
DOWNLOAD_IMAGE=0
IMAGE_URL=""
MEMORY_MB=4096
VCPUS=4
DISK_SIZE_GB=30
NETWORK_NAME="default"
CONNECTION_URI="qemu:///system"
OS_VARIANT="fedora-unknown"
VM_USER="tester"
SSH_PUBKEY_PATH=""
SECURE_BOOT=0
START_VM=1
RECREATE=0

usage() {
  cat <<USAGE
Usage:
  $TEST_SCRIPT_NAME [options]

Options:
  --name <vm-name>                 VM/domain name (default: gp-fedora-vm)
  --profile <fedora|bazzite>       Image profile (default: fedora)
  --workdir <path>                 Artifact directory (default: test/.artifacts)
  --base-image <qcow2>             Existing base qcow2 image to import
  --download-image                 Download image automatically (Fedora default URL)
  --image-url <url>                Override image URL used with --download-image
  --memory <mb>                    VM memory in MB (default: 4096)
  --vcpus <count>                  vCPU count (default: 4)
  --disk-size <gb>                 Disk size in GB after resize (default: 30)
  --network <libvirt-network>      Libvirt network name (default: default)
  --connection <uri>               Libvirt connection URI (default: qemu:///system)
  --os-variant <variant>           virt-install os-variant (default: fedora-unknown)
  --vm-user <name>                 Cloud-init user (default: tester)
  --ssh-pubkey <path>              Public SSH key path for cloud-init
  --secure-boot                    Enable UEFI Secure Boot in VM definition
  --no-start                       Define VM without immediate start
  --recreate                       Destroy and recreate VM if it already exists
  --dry-run                        Print actions without executing
  --debug                          Verbose logging
  -h, --help                       Show this help

Notes:
  - Designed for libvirt/virt-manager workflows.
  - For Bazzite profile, provide --base-image or --image-url with --download-image.
USAGE
}

default_image_url() {
  case "$PROFILE" in
    fedora)
      printf '%s\n' "https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-41-1.4.qcow2"
      ;;
    bazzite)
      printf '%s\n' ""
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)
        shift
        [ "$#" -gt 0 ] || die "--name requires value"
        VM_NAME="$1"
        ;;
      --profile)
        shift
        [ "$#" -gt 0 ] || die "--profile requires value"
        PROFILE="$1"
        ;;
      --workdir)
        shift
        [ "$#" -gt 0 ] || die "--workdir requires value"
        WORKDIR="$1"
        ;;
      --base-image)
        shift
        [ "$#" -gt 0 ] || die "--base-image requires value"
        BASE_IMAGE="$1"
        ;;
      --download-image)
        DOWNLOAD_IMAGE=1
        ;;
      --image-url)
        shift
        [ "$#" -gt 0 ] || die "--image-url requires value"
        IMAGE_URL="$1"
        ;;
      --memory)
        shift
        [ "$#" -gt 0 ] || die "--memory requires value"
        MEMORY_MB="$1"
        ;;
      --vcpus)
        shift
        [ "$#" -gt 0 ] || die "--vcpus requires value"
        VCPUS="$1"
        ;;
      --disk-size)
        shift
        [ "$#" -gt 0 ] || die "--disk-size requires value"
        DISK_SIZE_GB="$1"
        ;;
      --network)
        shift
        [ "$#" -gt 0 ] || die "--network requires value"
        NETWORK_NAME="$1"
        ;;
      --connection)
        shift
        [ "$#" -gt 0 ] || die "--connection requires value"
        CONNECTION_URI="$1"
        ;;
      --os-variant)
        shift
        [ "$#" -gt 0 ] || die "--os-variant requires value"
        OS_VARIANT="$1"
        ;;
      --vm-user)
        shift
        [ "$#" -gt 0 ] || die "--vm-user requires value"
        VM_USER="$1"
        ;;
      --ssh-pubkey)
        shift
        [ "$#" -gt 0 ] || die "--ssh-pubkey requires value"
        SSH_PUBKEY_PATH="$1"
        ;;
      --secure-boot)
        SECURE_BOOT=1
        ;;
      --no-start)
        START_VM=0
        ;;
      --recreate)
        RECREATE=1
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

validate_args() {
  case "$PROFILE" in
    fedora|bazzite)
      ;;
    *)
      die "Unsupported profile: $PROFILE (use fedora or bazzite)"
      ;;
  esac

  printf '%s' "$MEMORY_MB" | grep -Eq '^[0-9]+$' || die "--memory must be numeric"
  printf '%s' "$VCPUS" | grep -Eq '^[0-9]+$' || die "--vcpus must be numeric"
  printf '%s' "$DISK_SIZE_GB" | grep -Eq '^[0-9]+$' || die "--disk-size must be numeric"

  if [ -n "$SSH_PUBKEY_PATH" ] && [ ! -f "$SSH_PUBKEY_PATH" ]; then
    die "SSH public key file not found: $SSH_PUBKEY_PATH"
  fi

  if [ "$DOWNLOAD_IMAGE" = "0" ] && [ -z "$BASE_IMAGE" ]; then
    die "Provide --base-image or enable --download-image"
  fi
}

prepare_paths() {
  run_cmd mkdir -p "$WORKDIR"
  VM_DIR="$WORKDIR/$VM_NAME"
  run_cmd mkdir -p "$VM_DIR"
  DOWNLOAD_PATH="$VM_DIR/base.qcow2"
  VM_DISK="$VM_DIR/${VM_NAME}.qcow2"
  CLOUD_USER_DATA="$VM_DIR/user-data"
  CLOUD_META_DATA="$VM_DIR/meta-data"
  CLOUD_SEED_ISO="$VM_DIR/seed.iso"
}

fetch_image_if_needed() {
  if [ "$DOWNLOAD_IMAGE" = "0" ]; then
    return 0
  fi

  local url
  url="$IMAGE_URL"
  if [ -z "$url" ]; then
    url="$(default_image_url)"
  fi

  if [ -z "$url" ]; then
    die "No default URL for profile '$PROFILE'. Pass --image-url explicitly."
  fi

  require_cmd curl
  log_info "Downloading image: $url"
  run_cmd curl -L --fail --output "$DOWNLOAD_PATH" "$url"
  BASE_IMAGE="$DOWNLOAD_PATH"
}

prepare_disk() {
  [ -n "$BASE_IMAGE" ] || die "Internal error: BASE_IMAGE is empty"
  [ -f "$BASE_IMAGE" ] || die "Base image not found: $BASE_IMAGE"

  require_cmd qemu-img

  if [ -f "$VM_DISK" ]; then
    run_cmd rm -f "$VM_DISK"
  fi

  run_cmd cp --reflink=auto "$BASE_IMAGE" "$VM_DISK"
  run_cmd qemu-img resize "$VM_DISK" "${DISK_SIZE_GB}G"
}

render_cloud_init() {
  if [ -z "$SSH_PUBKEY_PATH" ]; then
    log_warn "No --ssh-pubkey provided, skipping cloud-init seed ISO generation."
    return 0
  fi

  require_cmd cloud-localds

  local pubkey
  pubkey="$(cat "$SSH_PUBKEY_PATH")"

  cat >"$CLOUD_USER_DATA" <<CLOUD
#cloud-config
users:
  - default
  - name: $VM_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_authorized_keys:
      - $pubkey
package_update: true
packages:
  - NetworkManager
  - firewalld
  - mokutil
  - openssl
  - curl
runcmd:
  - [ systemctl, enable, --now, NetworkManager ]
  - [ systemctl, enable, --now, firewalld ]
CLOUD

  cat >"$CLOUD_META_DATA" <<META
instance-id: $VM_NAME
local-hostname: $VM_NAME
META

  run_cmd cloud-localds "$CLOUD_SEED_ISO" "$CLOUD_USER_DATA" "$CLOUD_META_DATA"
}

vm_exists() {
  virsh --connect "$CONNECTION_URI" dominfo "$VM_NAME" >/dev/null 2>&1
}

destroy_existing_vm_if_requested() {
  if ! vm_exists; then
    return 0
  fi

  if [ "$RECREATE" != "1" ]; then
    die "VM '$VM_NAME' already exists. Use --recreate to replace it."
  fi

  log_warn "Recreating existing VM: $VM_NAME"
  run_cmd virsh --connect "$CONNECTION_URI" destroy "$VM_NAME" || true
  run_cmd virsh --connect "$CONNECTION_URI" undefine "$VM_NAME" --nvram || run_cmd virsh --connect "$CONNECTION_URI" undefine "$VM_NAME"
}

create_vm() {
  require_cmd virt-install
  require_cmd virsh

  local args=()
  args+=(--connect "$CONNECTION_URI")
  args+=(--name "$VM_NAME")
  args+=(--memory "$MEMORY_MB")
  args+=(--vcpus "$VCPUS")
  args+=(--import)
  args+=(--os-variant "$OS_VARIANT")
  args+=(--disk "path=$VM_DISK,format=qcow2,bus=virtio")
  args+=(--network "network=$NETWORK_NAME,model=virtio")
  args+=(--graphics spice)
  args+=(--video qxl)
  args+=(--rng /dev/urandom)
  args+=(--noautoconsole)

  if [ -f "$CLOUD_SEED_ISO" ]; then
    args+=(--disk "path=$CLOUD_SEED_ISO,device=cdrom")
  fi

  if [ "$SECURE_BOOT" = "1" ]; then
    args+=(--boot "uefi,loader_secure=yes")
  fi

  run_cmd virt-install "${args[@]}"

  if [ "$START_VM" = "1" ]; then
    run_cmd virsh --connect "$CONNECTION_URI" start "$VM_NAME" || true
  fi
}

print_next_steps() {
  log_info "VM prepared: $VM_NAME"
  log_info "Artifacts: $VM_DIR"
  log_info "Open in virt-manager: virt-manager --connect $CONNECTION_URI"
  log_info "Console: virsh --connect $CONNECTION_URI console $VM_NAME"
  log_info "When VM is ready, run: ./test/run_vm_tests.sh --help"
}

main() {
  parse_args "$@"
  validate_args

  require_cmd virsh
  require_cmd virt-install

  prepare_paths
  fetch_image_if_needed
  prepare_disk
  render_cloud_init
  destroy_existing_vm_if_requested
  create_vm
  print_next_steps
}

main "$@"
