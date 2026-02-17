# Changelog

All notable changes to this project are documented in this file.

## [0.2.0] - 2026-02-17
### Added
- Test toolkit in `test/`:
  - `test/common.sh`
  - `test/vmm_prepare_vm.sh` (libvirt/virt-manager VM preparation)
  - `test/run_host_tests.sh` (local checks + optional remote VM execution)
  - `test/run_vm_tests.sh` (runtime no-leak and Secure Boot checks)
  - `test/README.md`
- `CHANGELOG.md` (this file).
- `agent.md` with implementation and contribution guardrails.

### Changed
- `README.md` expanded with testing section and references to the new `test/` flow.

## [0.1.0] - 2026-02-17
### Added
- Initial MVP/POC scripts:
  - `bin/wg_killswitch.sh`
  - `bin/wg_killswitch_reset.sh`
  - `bin/vpn_reload.sh`
  - `bin/sb_mok_mvp.sh`
  - `lib/common.sh`
  - `etc/example.env`
  - `README.md`
