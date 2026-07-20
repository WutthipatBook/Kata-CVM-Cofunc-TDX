# Manifest

Bundle: `cofunc-tdx-e2e-standalone-20260612`

Generated: 2026-06-12

Purpose: CoFunc TDX split-container fork E2E reproduction only.

Excluded WIP:

- CoFunc Table 4 microbenchmark runner/checker
- iperf microbenchmark wrapper/client changes
- guest `unlink` libc changes
- procmgr ELF-tool workaround

## Source Repositories

| Component | URL | Base commit | Patch directory |
| --- | --- | --- | --- |
| CoFunc artifact | `https://github.com/shijc-sjtu/cofunc-artifact.git` | `7c41d63a1e40c9bddc7d0ba70c5b11c09fc80b90` | `patches/cofunc-artifact/` |
| Host kernel | `https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute` | `91baa15c711afa2e06f9c824297aea1319bd5842` | `patches/host-kernel/` |
| QEMU | `https://git.launchpad.net/ubuntu/+source/qemu` | `96cda2bbb2f530d08f6bda1f0dc186a0e0ce9674` | `patches/qemu/` |

## Main Entry Point

```bash
./setup_cofunc_tdx_e2e.sh prepare-sources --root /mnt/nvme_500g/asdf
```

The same script provides build, install, host-check, and run actions. See
`README.md` for the full workflow.
