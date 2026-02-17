# Test folder

This folder contains scripts for:
- Preparing libvirt/virt-manager VMs
- Running local repository checks on host
- Running runtime/no-leak/Secure Boot checks inside VM

## Scripts
- `test/vmm_prepare_vm.sh`
  - Prepares a Fedora/Bazzite test VM in libvirt.
  - Supports Secure Boot flag and cloud-init SSH seed (optional).
- `test/run_host_tests.sh`
  - Runs local static checks.
  - Optionally copies repo to VM and triggers `run_vm_tests.sh` remotely.
- `test/run_vm_tests.sh`
  - Runs runtime tests on VM as root.
  - Includes connectivity, leak, LAN expectation, and MOK checks.

## Typical flow
1. Prepare VM:
```bash
./test/vmm_prepare_vm.sh --download-image --ssh-pubkey ~/.ssh/id_ed25519.pub --secure-boot --recreate
```
2. Run local + remote checks from host:
```bash
./test/run_host_tests.sh --vm-host 192.168.122.101 --vm-user tester --nm-conn proton-wg --allow-disconnect
```
3. Or run directly inside VM:
```bash
sudo ./test/run_vm_tests.sh --nm-conn proton-wg --allow-disconnect
```

## Notes
- Leak check is destructive (`nmcli con down`) and requires `--allow-disconnect`.
- Secure Boot enrollment (`mokutil --import`) is interactive and disabled by default.
