# gp-bootstrap MVP/POC

MVP/POC repo with post-install scripts for:
- Fedora Workstation
- Bazzite/uBlue (rpm-ostree)

Scope:
- WireGuard kill switch via **NetworkManager only** (`nmcli`), no `wg-quick`
- Stateful kill switch (stays enforced until manual reset)
- Secure Boot MVP using **shim/MOK only** (`mokutil`), no db/KEK/PK changes

## Repository layout
- `bin/wg_killswitch.sh` - apply/status kill switch
- `bin/wg_killswitch_reset.sh` - rollback/reset from stored state
- `bin/vpn_reload.sh` - one-command NM profile reload
- `bin/sb_mok_mvp.sh` - Secure Boot MOK status/generate/enroll/export
- `lib/common.sh` - shared logging, deps, detection, backups, state, lock
- `etc/example.env` - sample env vars
- `test/` - host and VM test automation scripts
- `CHANGELOG.md` - release history
- `agent.md` - guardrails for coding agents and contributors

## Hard assumptions
- Root-only scripts
- Bash strict mode (`set -euo pipefail`)
- Logs in `/var/log/gp-bootstrap/`
- Backups in `/var/backups/gp-bootstrap/<timestamp>-<label>/`
- State file in `/var/lib/gp-bootstrap/state.env`
- Kill switch state is global (single active profile per host)
- Re-running `wg_killswitch.sh --apply` when active = status-only, no changes

## Prerequisites
Required commands:
- `bash`, `ip`, `flock`
- `nmcli` (NetworkManager)
- `firewall-cmd` (firewalld)
- `mokutil` and `openssl` (for Secure Boot script)

Optional but useful:
- `resolvectl` (DNS diagnostics in status)

### Fedora Workstation
Usually preinstalled: NetworkManager + firewalld.

If missing:
```bash
sudo dnf install -y NetworkManager firewalld mokutil openssl
sudo systemctl enable --now NetworkManager firewalld
```

### Bazzite/uBlue (rpm-ostree)
Bazzite is ostree-based. Scripts detect ostree mode and otherwise work the same.

If dependencies are missing, layer packages and reboot:
```bash
sudo rpm-ostree install mokutil openssl
sudo systemctl enable --now firewalld NetworkManager
```

## Quick start
Optionally load env defaults:
```bash
set -a
source ./etc/example.env
set +a
```

Apply kill switch:
```bash
sudo ./bin/wg_killswitch.sh --apply --nm-conn "proton-wg" --mode strict+lan --lan "192.168.0.0/16"
```

Check status:
```bash
sudo ./bin/wg_killswitch.sh --status
```

Reload VPN profile (manual recovery path):
```bash
sudo ./bin/vpn_reload.sh --apply --nm-conn "proton-wg"
```

Hard reload (optional):
```bash
sudo ./bin/vpn_reload.sh --apply --nm-conn "proton-wg" --hard
```

Reset kill switch:
```bash
sudo ./bin/wg_killswitch_reset.sh --apply
```

## Automated tests (`test/`)
Prepare a libvirt/vmm VM quickly:
```bash
./test/vmm_prepare_vm.sh --download-image --ssh-pubkey ~/.ssh/id_ed25519.pub --secure-boot --recreate
```

Run local repository checks on host:
```bash
./test/run_host_tests.sh
```

Run local checks plus remote VM runtime suite:
```bash
./test/run_host_tests.sh --vm-host 192.168.122.101 --vm-user tester --nm-conn proton-wg --allow-disconnect
```

Run runtime suite directly on VM:
```bash
sudo ./test/run_vm_tests.sh --nm-conn proton-wg --allow-disconnect
```

See detailed test docs in `test/README.md`.

## Kill switch model
Priority:
1. Firewalld `policies` strategy (if supported)
2. Fallback `zones` strategy

Objects created with `gp-` prefix:
- Zones: `gp-wg`, `gp-phys-lock`
- Policies (when supported):
  - `gp-vpn-egress`
  - `gp-vpn-handshake`
  - `gp-lan-allow` (only in `strict+lan`)
  - `gp-phys-drop`

Behavior:
- VPN iface goes to `gp-wg` (`ACCEPT`)
- Physical iface goes to `gp-phys-lock` (`DROP`)
- Allow only:
  - VPN endpoint UDP `IP:PORT` on physical iface
  - LAN CIDRs when mode is `strict+lan`
- Everything else on physical iface remains blocked

No-leak statefulness:
- Rules remain active even if VPN disconnects.
- Internet outside VPN should stay blocked until manual reset.

## CLI reference
### `wg_killswitch.sh`
```bash
sudo ./bin/wg_killswitch.sh --apply --nm-conn <NAME> [--mode strict|strict+lan] [--lan "CIDR1,CIDR2"] [--endpoint IP:PORT] [--phys-iface IFACE] [--dry-run] [--debug]
sudo ./bin/wg_killswitch.sh --status [--nm-conn <NAME>] [--debug]
```

### `wg_killswitch_reset.sh`
```bash
sudo ./bin/wg_killswitch_reset.sh --apply [--dry-run] [--debug]
sudo ./bin/wg_killswitch_reset.sh --status [--debug]
```

### `vpn_reload.sh`
```bash
sudo ./bin/vpn_reload.sh --apply [--nm-conn <NAME>] [--hard] [--dry-run] [--debug]
sudo ./bin/vpn_reload.sh --status [--nm-conn <NAME>] [--debug]
```

### `sb_mok_mvp.sh`
```bash
sudo ./bin/sb_mok_mvp.sh --status
sudo ./bin/sb_mok_mvp.sh --apply --generate-key
sudo ./bin/sb_mok_mvp.sh --apply --enroll
sudo ./bin/sb_mok_mvp.sh --apply --export-public
```

## Secure Boot MOK flow (MVP)
1. Generate keypair:
```bash
sudo ./bin/sb_mok_mvp.sh --apply --generate-key
```
Stored in:
`/var/lib/gp-bootstrap/secureboot/<machine-id>/{MOK.key,MOK.crt}`

2. Enroll public cert:
```bash
sudo ./bin/sb_mok_mvp.sh --apply --enroll
```
3. Reboot and finish in MOK Manager (manual enrollment).

Notes:
- No firmware db/KEK/PK modification.
- Second-system scenario (shared vs per-install MOK) is intentionally documentation-only in MVP.

## Test plan (no nmap)
1. Apply kill switch and bring VPN up:
```bash
sudo ./bin/wg_killswitch.sh --apply --nm-conn "proton-wg"
curl -4 ifconfig.co
```
Expected: works.

2. Disconnect VPN:
```bash
nmcli con down "proton-wg"
curl -4 1.1.1.1
```
Expected: fails (no-leak).

3. LAN check in `strict+lan`:
```bash
ping -c 2 192.168.0.1
```
Expected: works.

4. LAN check in `strict`:
```bash
sudo ./bin/wg_killswitch_reset.sh --apply
sudo ./bin/wg_killswitch.sh --apply --nm-conn "proton-wg" --mode strict
ping -c 2 192.168.0.1
```
Expected: blocked.

5. Reload path:
```bash
sudo ./bin/vpn_reload.sh --apply --nm-conn "proton-wg"
```
Expected: profile goes down/up with one command.

6. Reset:
```bash
sudo ./bin/wg_killswitch_reset.sh --apply
```
Expected: interfaces/zones restored from state, gp-* objects removed, idempotent on re-run.

## Warnings
- This is MVP/POC code: validate in controlled environment first.
- Test remote access implications before applying on remote hosts.
- DNS is not forced in MVP; status prints warning signals only.

## TODO (post-MVP)
- NetworkManager dispatcher integration for automated reactions
- DNS hardening (DNS only through VPN in NM profile)
- Optional IPv6 kill switch path
- Extended policy compatibility matrix across firewalld versions
