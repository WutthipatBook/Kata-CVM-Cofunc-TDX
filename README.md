# CoFunc TDX E2E Standalone Bundle

Generated: 2026-06-12

This bundle reproduces the CoFunc TDX split-container fork E2E setup without
requiring the importer to clone `perf_proto`. It contains:

- source patches for the original CoFunc artifact, host kernel, and QEMU repos
- standalone runner/check scripts
- host kernel config used on `bud01`
- an automation script that can clone, patch, and build under a large workspace
  root such as `/mnt/nvme_500g/asdf`

This is intentionally E2E-only. It excludes the CoFunc Table 4 microbenchmark,
iperf, `unlink`, and procmgr-tool WIP.

## Minimal Importer Commands

For a clean host/workspace, this is the short path. Replace
`/mnt/nvme_500g/asdf` with the importer's large working directory.

```bash
tar -xf cofunc-tdx-e2e-standalone-20260612.tar.gz
export BUNDLE=$PWD/cofunc-tdx-e2e-standalone-20260612
export ROOT=/mnt/nvme_500g/asdf

"$BUNDLE/setup_cofunc_tdx_e2e.sh" prepare-sources --root "$ROOT"
"$BUNDLE/setup_cofunc_tdx_e2e.sh" all --root "$ROOT"

sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-kernel --root "$ROOT"
sudo reboot
```

After reboot:

```bash
export BUNDLE=/path/to/cofunc-tdx-e2e-standalone-20260612
export ROOT=/mnt/nvme_500g/asdf

sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-isolation --root "$ROOT"
sudo reboot
```

After the second reboot:

```bash
export BUNDLE=/path/to/cofunc-tdx-e2e-standalone-20260612
export ROOT=/mnt/nvme_500g/asdf

"$BUNDLE/setup_cofunc_tdx_e2e.sh" check-host --root "$ROOT"
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-face-smoke --root "$ROOT"
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-fig11 --root "$ROOT"
```

See `QUICKSTART.md` for the same flow in a shorter standalone file.

## Directory Structure

```text
cofunc-tdx-e2e-standalone-20260612/
  QUICKSTART.md
  README.md
  SHA256SUMS
  setup_cofunc_tdx_e2e.sh
  configs/
    host-kernel-6.19.0-rc6-cofunc-tdx.config
  docs/
    cofunc_tdx_paper_targets.md
  patches/
    cofunc-artifact/
      0001-Enable-CoFunc-TDX-split-container-execution.patch
      0001-Fix-CoFunc-workload-build-dependencies.patch
    host-kernel/
      0001-Add-KVM-support-for-CoFunc-split-containers.patch
    qemu/
      0001-Wire-CoFunc-split-container-KVM-ioctls-into-QEMU.patch
  scripts/
    run_tdx_sc_fork_e2e.sh
    run_tdx_fig11_pdf_compare.sh
    cofunc_tdx_paper_check.py
    cofunc_tdx_breakdown_compare.py
    cofunc_tdx_sc_fork_summary.py
    cofunc_tdx_host_perf_mode.sh
    cofunc_install_rebuilt_kvm_modules.sh
    mount_nvme0_as_nvme_500g.sh
    cofunc_flight_recorder.sh
    cofunc_host_trace.sh
```

Do not upload benchmark `results/`, Docker build leftovers, QEMU
`pc-bios/*.bz2`, QEMU `python/wheels/`, or local build directories.

## Original Repos

CoFunc artifact:

```text
url:  https://github.com/shijc-sjtu/cofunc-artifact.git
base: 7c41d63a1e40c9bddc7d0ba70c5b11c09fc80b90
```

TDX host kernel:

```text
url:  https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute
base: 91baa15c711afa2e06f9c824297aea1319bd5842
```

QEMU:

```text
url:  https://git.launchpad.net/ubuntu/+source/qemu
base: 96cda2bbb2f530d08f6bda1f0dc186a0e0ce9674
```

## Automated Setup

Pick a large workspace root. The root does not need to be exactly
`/mnt/nvme_500g/cofunc_tdx_artifact`; any large directory is fine:

```bash
export ROOT=/mnt/nvme_500g/asdf
export BUNDLE=/path/to/cofunc-tdx-e2e-standalone-20260612
```

Clone original repos, checkout base commits, and apply patches:

```bash
"$BUNDLE/setup_cofunc_tdx_e2e.sh" prepare-sources --root "$ROOT"
```

Build everything that does not modify the booted host:

```bash
"$BUNDLE/setup_cofunc_tdx_e2e.sh" all --root "$ROOT"
```

`all` runs:

```text
prepare-sources -> build-kernel -> build-qemu -> build-artifact
```

It does not install the kernel, edit GRUB, or reboot.

## Explicit Host Changes

Install the built kernel:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-kernel --root "$ROOT"
sudo reboot
```

If the host is already booted into the matching kernel and only rebuilt KVM
modules need replacement:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-kvm-modules --root "$ROOT"
```

Install CPU isolation boot arguments, then reboot:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-isolation --root "$ROOT"
sudo reboot
```

The default isolation plan is for a 32-CPU host:

```text
isolated CPUs:    16-31
housekeeping CPUs: 0-15
```

Override it if the importer host has a different CPU topology:

```bash
ISOLATED_CPUS=8-15 HOUSEKEEPING_CPUS=0-7 \
  "$BUNDLE/setup_cofunc_tdx_e2e.sh" install-isolation --root "$ROOT"
```

## Host Checks

After reboot:

```bash
"$BUNDLE/setup_cofunc_tdx_e2e.sh" check-host --root "$ROOT"
```

Expected local reference values from `bud01`:

```text
kernel: 6.19.0-rc6-cofunc-tdx+
kvm_intel.tdx: Y
kvm srcversion: 0BD0A0612BCAACA2BE920F4
kvm_intel srcversion: 65E9BDBE5E3D73DEA355ECB
```

## Run E2E

Single-workload smoke:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-face-smoke --root "$ROOT"
```

Paper Fig. 11 TDX subset plus comparison reports:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-fig11 --root "$ROOT"
```

Direct runner invocation is also supported:

```bash
sudo -v
"$BUNDLE/scripts/run_tdx_sc_fork_e2e.sh" \
  --artifact "$ROOT/cofunc-artifact" \
  --prepare-performance \
  --core-isolated \
  --quiet-workload-output \
  --out "$ROOT/results/tdx_all_$(date -u +%Y%m%d_%H%M%S)"
```

## Current Local Result Caveat

The E2E execution path is functional on the local setup: the clean full TDX fork
run completed all selected workloads without validation/KVM error logs.

Performance is not yet a paper match. The measured Fig. 11 TDX CoFunc fork
latencies remain several times slower than the digitized paper bars. This
bundle is therefore for reproducing the current E2E setup and measurement flow,
not for claiming the paper result is fully reproduced.
