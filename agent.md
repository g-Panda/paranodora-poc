# agent.md

This repository provides a Linux networking/security MVP for:
- Fedora Workstation
- Bazzite/uBlue (rpm-ostree)

## Non-negotiable constraints
- WireGuard must be handled via NetworkManager (`nmcli`) only.
- Do not use `wg-quick`.
- Kill switch must be stateful until manual reset.
- Secure Boot automation is limited to shim/MOK (`mokutil`).
- Do not modify firmware db/KEK/PK in this project.

## Code guardrails
- Shell scripts must use `set -euo pipefail`.
- Keep changes idempotent where practical.
- Use `gp-` prefix for firewalld objects created by this project.
- Keep rollback safe and explicit.
- Preserve support for both policy and zone firewalld paths.

## Test guardrails
- Prefer `test/run_host_tests.sh` for local static validation.
- Use `test/run_vm_tests.sh` for runtime checks on VM.
- Treat leak tests as destructive; require explicit opt-in.
- Secure Boot enrollment tests are interactive; do not enable by default.

## Paths
- Runtime state: `/var/lib/gp-bootstrap/state.env`
- Logs: `/var/log/gp-bootstrap/`
- Backups: `/var/backups/gp-bootstrap/`

## Suggested workflow
1. Run local checks:
```bash
./test/run_host_tests.sh
```
2. Prepare VM (optional):
```bash
./test/vmm_prepare_vm.sh --download-image --ssh-pubkey ~/.ssh/id_ed25519.pub --secure-boot
```
3. Run VM checks:
```bash
sudo ./test/run_vm_tests.sh --nm-conn proton-wg --allow-disconnect
```
