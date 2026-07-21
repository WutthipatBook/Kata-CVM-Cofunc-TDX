# CoFunc TDX Reproduction Handoff

Date: 2026-06-23

## Goal

Reproduce and understand the CoFunc Intel TDX results from:

- Paper: `Serverless Functions Made Confidential and Efficient with Split Containers`
- Local PDF: `/home/booklyn/sec25cycle1-prepub-121-shi-jiacheng.pdf`

The broader motivation is to compare the original Intel TDX artifact against the
Arm CCA/shrinkwrap work, where results currently mismatch. Treat this TDX setup
as a reference run, but note that this local setup is a forward-port, not the
paper's exact software stack.

## Important Workspace Rules

- Do not use or modify `/mnt/nvme_500g`; the user explicitly said it is not
  their workspace.
- Use `/mnt/new_disk`.
- The mistaken `/mnt/new_disk/shrinkwrap_build/cofunc_tdx_artifact` directory
  was removed. Shrinkwrap is for Arm CCA, not this TDX work.
- Correct TDX workspace:
  `/mnt/new_disk/cofunc_tdx_artifact`
- TDX bundle:
  `/home/booklyn/cofunc-tdx`
- Installed artifact:
  `/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact`

## Setup State

Host readiness was checked and is good:

```text
kernel=6.19.0-rc6-cofunc-tdx+
kvm_intel.tdx=Y
kvm srcversion=0BD0A0612BCAACA2BE920F4
kvm_intel srcversion=65E9BDBE5E3D73DEA355ECB
isolated CPUs=16-31
performance governor=yes
```

Built/installed components under `/mnt/new_disk/cofunc_tdx_artifact`:

- Patched `cofunc-artifact`
- Patched QEMU 10.2.1:
  `/mnt/new_disk/cofunc_tdx_artifact/install/qemu-ubuntu-tdx/bin/qemu-system-x86_64`
- TDX OVMF:
  `/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd`
- ChCore CVM ISO:
  `/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/build/chcore.iso`
- Docker/helper/runtime images required by the artifact

The kernel source clone from Launchpad was unreliable, but the host is already
booted into the working CoFunc TDX kernel, so kernel build/install was skipped.

## Local Artifact Patch Applied After Setup

The installed artifact has a local modification in:

```text
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/cvm.sh
```

Changes:

- Default `COFUNC_CVM_USE_SUDO` to `1`, so QEMU can access KVM even when
  `booklyn` is not in the `kvm` group.
- Pass `COFUNC_GDB_PORT_FILE="$trace_dir/gdb-port"` to avoid stale
  `/tmp/chcore-gdb-port-0` permission failures.

Current diff:

```diff
-use_sudo=${COFUNC_CVM_USE_SUDO:-0}
+use_sudo=${COFUNC_CVM_USE_SUDO:-1}
...
         COFUNC_TRACE_DIR="$trace_dir" \
+        COFUNC_GDB_PORT_FILE="$trace_dir/gdb-port" \
         screen -L -Logfile "$trace_dir/screen.log" -dmS "$session" build/simulate.sh
```

This is only applied to the installed artifact. If `prepare-sources
--reset-existing` is run later, fold this into the bundle patch first or it will
be lost.

## Runtime Environment Exports

Use these for TDX runs:

```bash
export BUNDLE=/home/booklyn/cofunc-tdx
export ROOT=/mnt/new_disk/cofunc_tdx_artifact

export COFUNC_TDX_QEMU="$ROOT/install/qemu-ubuntu-tdx/bin/qemu-system-x86_64"
export COFUNC_TDX_OVMF="$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd"
export COFUNC_TDX_QEMU_BIOS_DIR="$ROOT/src/ubuntu-qemu-resolute/pc-bios"
```

`sudo` must be run from the user's terminal. The Codex sandbox cannot prompt for
the password.

## Completed Runs

### Smoke Test

Result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/tdx_face_20260622_053447
```

Status:

```text
fn_py_face_detection ok attempts=1 rc=0
```

Summary:

```text
fn_py_face_detection TDX_CoFunc_fork=1.168s Artifact_C=0.617s actual/expected=1.893
```

### Fig. 11 TDX Subset

Command shape:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-fig11 --root "$ROOT"
```

Result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741
```

All selected workloads completed with `ok`.

TDX CoFunc summary:

```text
fn_py_compression        1.374s
fn_py_face_detection     1.181s
fn_py_image_processing   7.464s
fn_py_sentiment          0.146s
fn_py_video_processing   52.678s
fn_py_dna_visualisation  19.196s
fn_js_thumbnailer        0.386s
fn_js_uploader           0.509s
chain_js_alexa           0.544s
Avg ratio vs artifact C  3.074
```

Useful reports:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/workload-status.tsv
/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/tdx_sc_fork_summary.txt
/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/paper-check.txt
/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/fig11-breakdown.txt
```

`validation.txt` and `dmesg-kvm-errors.log` were empty/good.

### Native/Lean Baseline

Result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/native_fig11_20260622_062302
```

This was run on the same host and CPU mask. Python Native results are close to
the digitized paper Native TDX bars, which is important: the workload bodies and
CPU are not the main reason for the CoFunc gap.

Comparison:

```text
app        native   paper native   CoFunc TDX   paper CoFunc
face       0.347s   0.324s         1.181s       0.346s
image      2.350s   2.230s         7.464s       2.390s
video      18.318s  18.800s        52.678s      18.800s
compress   0.384s   0.370s         1.374s       0.422s
dna        5.644s   5.300s         19.196s      5.670s
```

JS raw `lean_launch` E2E is not directly the paper Native baseline because the
artifact's plotting script emulates JS fork-mode Native using Native execution
time plus CoFunc boot/CoW terms. Be careful interpreting uploader,
thumbnailer, and Alexa.

The native CoW microbenchmark result currently looks wrong:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/native_fig11_20260622_062302/log/microbenchmarks/cow/result
1782109727.091315
```

That value looks like a timestamp, not a latency. Revisit before using
artifact-style JS Native emulation.

## Paper Targets And Software Caveat

The paper states the TDX testbed used:

```text
Intel Sapphire Rapids, 48 cores, 4 GHz, 503 GB DRAM
RHEL 8.7
Linux kernel 5.19.0
```

This local setup is not that exact stack:

```text
Ubuntu-based Linux 6.19.0-rc6-cofunc-tdx+
QEMU 10.2.1
CoFunc KVM/QEMU hooks forward-ported to the newer TDX/KVM APIs
```

An exact original kernel commit/version has not been found locally. The paper
only gives `Linux kernel 5.19.0`. The bundle currently targets Ubuntu resolute
kernel commit `91baa15c711afa2e06f9c824297aea1319bd5842`.

This difference may explain performance characteristics, especially in the KVM
and TDX memory conversion paths.

## Current Interpretation

Mechanical reproduction now works. Numeric reproduction does not yet match the
paper.

Important observation:

- Python Native is close to paper.
- CoFunc TDX is about `2.8x` to `3.6x` slower than the paper for the major
  Python Fig. 11 workloads.
- The gap is mostly in `t_exec`, not startup.
- Current logs show large `t_grant_exec` / memory accept time for many
  workloads, but they do not expose enough detail to know why.

Likely investigation target:

```text
CoFunc TDX memory grant / MapGPA / accept / KVM prefault path
```

Relevant files:

```text
Guest accept accounting:
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/kernel/split-container/split_container.c

TDX page accept implementation:
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c

Shadow container grant/map/prefault path:
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/shadow_container/main.c

Python workload stat template:
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/template.py
```

Existing counters:

- `sc_t_accept`
- `sc_n_accept`
- `sc_t_pgfault`
- `sc_n_cow`
- `n_hcalls_exec`
- `t_grant_exec` currently maps to `sc_t_accept`

But the normal workload logs only expose coarse `t_grant_exec` and `n_cow`.

## Recommended Next Steps

1. Fold the local `cvm.sh` fix into the bundle patch so future resets keep it.

2. Add lightweight guest-visible counters:
   - expose `STAT_N_ACCEPT`
   - expose `STAT_T_PGFAULT`
   - print `n_accept_exec`, `t_pgfault_exec`, and existing `n_cow`
   - simplest path is extending `get_stat()` in
     `cvm_os/kernel/split-container/split_container.c` and the Python/JS
     templates.

3. Add accept granularity counters in:

   ```text
   cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c
   ```

   Track:

   - `accept_4k_count`
   - `accept_2m_count`
   - `accept_1g_count`
   - reject/fallback counts

4. Add shadow-container timing in:

   ```text
   shadow_container/main.c
   ```

   Around:

   - `KVM_SET_MEMORY_ATTRIBUTES`
   - `madvise(MADV_DONTNEED)`
   - `fallocate(...PUNCH_HOLE...)`
   - `KVM_PRE_FAULT_MEMORY`

   This answers whether time is lost in guest-side TDX accept, host KVM memory
   attribute changes, or prefault.

5. Rebuild after instrumentation:

   ```bash
   export ROOT=/mnt/new_disk/cofunc_tdx_artifact
   export BUNDLE=/home/booklyn/cofunc-tdx
   sudo -v
   "$BUNDLE/setup_cofunc_tdx_e2e.sh" build-artifact --root "$ROOT"
   ```

   Then rerun a narrow smoke target first, e.g. face + compression, before the
   full Fig. 11 subset.

6. Keep original-kernel search separate:
   - The paper says RHEL 8.7 + Linux 5.19.0.
   - If an author artifact or branch with exact kernel patches exists, that may
     be a better comparison than the Ubuntu 6.19 forward-port.

## Original TDX Kernel Provenance Search

Status on 2026-06-22: provenance search should happen before heavier
instrumentation, because the current working stack is a forward-port to Ubuntu
6.19 while the paper testbed says RHEL 8.7 + Linux 5.19.0.

Figshare artifact metadata:

```text
DOI: 10.6084/m9.figshare.28234346.v4
Public page: https://figshare.com/articles/software/CoFunc_Artifacts/28234346/4
Downloaded file: /mnt/new_disk/cofunc_tdx_artifact/provenance/cofunc-artifact-figshare-v4.tar.gz
MD5: df059bc73e826853973e69adaeb00407
Extracted at: /mnt/new_disk/cofunc_tdx_artifact/provenance/figshare-v4/cofunc-artifact
```

The Figshare tarball is the same public CoFunc artifact family as the installed
repo. Its top-level README documents the SEV-SNP setup, but it also contains an
Intel TDX QEMU patch stack here:

```text
/mnt/new_disk/cofunc_tdx_artifact/provenance/figshare-v4/cofunc-artifact/cvm_os/kernel/arch/x86_64/boot/intel_tdx/qemu_patches
/mnt/new_disk/cofunc_tdx_artifact/provenance/figshare-v4/cofunc-artifact/cvm_os/kernel/arch/x86_64/boot/intel_tdx/qemu-split-container.patch
```

Important finding: the embedded TDX QEMU stack expects the old pre-upstream TDX
KVM ABI:

- `KVM_X86_TDX_VM`
- `KVM_TDX_CAPABILITIES`
- `KVM_TDX_INIT_VM`
- `KVM_TDX_INIT_VCPU`
- `KVM_TDX_INIT_MEM_REGION`
- `KVM_TDX_FINALIZE_VM`
- `KVM_EXIT_TDX_VMCALL`
- workaround constants such as `KVM_EXIT_TDX = 50` and `KVM_CAP_VM_TYPES = 1000`

Best current kernel candidate:

```text
repo: https://github.com/intel/tdx.git
tag:  kvm-upstream-2022.09.01-v5.19-snapshot
sha:  8298dd80cf482b58dec935832e1afc9d3a00587f
path: /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot
base kernel Makefile: VERSION=5 PATCHLEVEL=19 SUBLEVEL=0
```

Why this is the strongest candidate so far:

- The paper says Linux kernel 5.19.0.
- The tag is explicitly a v5.19 TDX KVM snapshot.
- Its `README.md` says `kvm-upstream-snapshot` is a 5.19 code base with bug
  fixes and can be used as host/guest kernel to launch a TDX VM.
- Its UAPI headers match the artifact's embedded QEMU/header expectations:
  `KVM_MEM_PRIVATE`, `KVM_EXIT_TDX_VMCALL`, `KVM_EXIT_TDX = 50`,
  `KVM_EXIT_MEMORY_FAULT = 100`, `KVM_CAP_ENCRYPT_MEMORY_DEBUG = 300`,
  `KVM_CAP_VM_TYPES = 1000`, and the `KVM_TDX_INIT_*` structs.

Neighbor candidate:

```text
repo: https://github.com/intel/tdx.git
tag:  kvm-upstream-2022.08.23-v5.19-snapshot
sha:  98782cfb5fbc2ff06a6da1324cb1e9f1070e3ef6
path: /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.08.23-v5.19-snapshot
```

The August 23 and September 1 candidates have identical checked UAPI headers.
September 1 adds README/provenance material and is therefore a better initial
target unless other artifact evidence points to August 23.

Likely matching QEMU candidate:

```text
repo: https://github.com/intel/qemu-tdx.git
tag:  tdx-upstream-snapshot-2022-09-01-v7.1
sha:  9c48d24da644a9a4841060c6bab201cbaf1255b8
```

The September kernel README says QEMU `tdx-upstream-snapshot` is aimed to
co-work with `kvm-upstream-snapshot`.

## 2026-06-23 Intel TDX 5.19 Kernel Build

Built the strongest kernel candidate with the CoFunc split-container host patch:

```text
source: /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot
branch: cofunc-tdx-5.19-port
patch:  /home/booklyn/cofunc-tdx/patches/host-kernel/0001-Add-CoFunc-split-container-hooks-for-intel-tdx-5.19.patch
build:  /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc
release: 5.19.0-cofunc-tdx-5.19+
```

Important build notes:

- `CONFIG_LOCALVERSION="-cofunc-tdx-5.19"` was set.
- `CONFIG_DEBUG_INFO_BTF` was disabled after the first final-link attempt failed
  in `BTFIDS vmlinux` with `FAILED: load BTF from vmlinux: Invalid argument`.
- `split_container_vcpu_idle` must be exported with `EXPORT_SYMBOL_GPL` because
  TDX code is linked into `kvm-intel.ko`, while the helper lives in `kvm.ko`.

Successful build outputs:

```text
/mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc/arch/x86/boot/bzImage
/mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc/arch/x86/kvm/kvm.ko
/mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc/arch/x86/kvm/kvm-intel.ko
```

Verification:

```text
kernelrelease: 5.19.0-cofunc-tdx-5.19+
kvm.ko vermagic: 5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
kvm-intel.ko vermagic: 5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
kvm-intel.ko depends: kvm
Module.symvers exports split_container_vcpu_idle from arch/x86/kvm/kvm
```

This kernel is now installed as an additional boot option and has been booted
once. The persistent GRUB default still points at the known-working 6.19 CoFunc
TDX kernel.

### 2026-06-24 rollback-safe install prep

The user gave explicit go-ahead to install `5.19.0-cofunc-tdx-5.19+`, with the
requirement that rollback to the current kernel remains easy.

Current boot state before install prep:

```text
running kernel: 6.19.0-rc6-cofunc-tdx+
current GRUB default:
gnulinux-advanced-c09b0899-4a52-4d88-92f9-03deb85598da>gnulinux-6.19.0-rc6-cofunc-tdx+-advanced-c09b0899-4a52-4d88-92f9-03deb85598da
```

Disk-space note:

- Raw unstripped 5.19 modules are about `5.2G`, too risky for `/`, which only
  has about `3.4G` free.
- A stripped module staging tree was created under `/mnt/new_disk`:

  ```text
  /mnt/new_disk/cofunc_tdx_artifact/install/kernel-5.19-modules-staging/lib/modules/5.19.0-cofunc-tdx-5.19+
  ```

- Staged stripped modules are about `117M`.

Rollback-safe installer:

```text
/home/booklyn/cofunc-tdx/scripts/install_kernel_5_19_safe.sh
```

Dry check passed:

```text
kernel release: 5.19.0-cofunc-tdx-5.19+
staged modules: 117M
root free: 3.4G
boot free: 973M
current kernel: 6.19.0-rc6-cofunc-tdx+
```

The installer does the following:

- backs up `/etc/default/grub`, `/boot/grub/grub.cfg`, `/boot/grub/grubenv`,
  current `grub-editenv`, `uname`, and disk state under
  `/mnt/new_disk/cofunc_tdx_artifact/boot-backups/`;
- copies the stripped staged modules to `/lib/modules/5.19.0-cofunc-tdx-5.19+`;
- installs `/boot/vmlinuz-*`, `/boot/System.map-*`, and `/boot/config-*`;
- runs `depmod`, `update-initramfs`, and `update-grub`;
- restores the previous saved GRUB default after `update-grub`;
- generates:
  - `/mnt/new_disk/cofunc_tdx_artifact/boot-5.19-once.sh`
  - `/mnt/new_disk/cofunc_tdx_artifact/rollback-5.19-kernel.sh`

Run from the user's terminal because Codex cannot provide the sudo password:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/install_kernel_5_19_safe.sh --install
```

Install completed successfully and was verified on 2026-06-24:

```text
/boot/vmlinuz-5.19.0-cofunc-tdx-5.19+
/boot/initrd.img-5.19.0-cofunc-tdx-5.19+
/boot/System.map-5.19.0-cofunc-tdx-5.19+
/boot/config-5.19.0-cofunc-tdx-5.19+
/lib/modules/5.19.0-cofunc-tdx-5.19+        117M
```

Verified KVM module:

```text
/lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm-intel.ko.zst
vermagic: 5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
```

Persistent saved GRUB default is still:

```text
gnulinux-advanced-c09b0899-4a52-4d88-92f9-03deb85598da>gnulinux-6.19.0-rc6-cofunc-tdx+-advanced-c09b0899-4a52-4d88-92f9-03deb85598da
```

The 5.19 GRUB entry exists:

```text
Ubuntu, with Linux 5.19.0-cofunc-tdx-5.19+
gnulinux-5.19.0-cofunc-tdx-5.19+-advanced-c09b0899-4a52-4d88-92f9-03deb85598da
```

Install backup directory:

```text
/mnt/new_disk/cofunc_tdx_artifact/boot-backups/5.19.0-cofunc-tdx-5.19+-20260624_025856
```

One-shot boot completed on 2026-06-24:

```text
current kernel: 5.19.0-cofunc-tdx-5.19+
boot time:      2026-06-24 03:14:35 UTC
cmdline:        nohibernate kvm_intel.tdx=1 split_lock_detect=off numa_balancing=disable isolcpus=domain,managed_irq,16-31 nohz_full=16-31 rcu_nocbs=16-31 irqaffinity=0-15
```

`grub-editenv list` after boot:

```text
saved_entry=gnulinux-advanced-c09b0899-4a52-4d88-92f9-03deb85598da>gnulinux-6.19.0-rc6-cofunc-tdx+-advanced-c09b0899-4a52-4d88-92f9-03deb85598da
next_entry=
```

Operational caution: this is a remote lab machine that may be shared. Future
reboots should be coordinated first. Before running long workloads, check
whether the machine is in active use (`who`, `w`, and lab/job conventions).

After install, boot 5.19 exactly once:

```bash
sudo /mnt/new_disk/cofunc_tdx_artifact/boot-5.19-once.sh
sudo reboot
```

Rollback if needed:

```bash
sudo /mnt/new_disk/cofunc_tdx_artifact/rollback-5.19-kernel.sh
```

What did not prove the kernel:

- Applying the public Figshare `patches/linux.patch` to the September 2022 TDX
  snapshot does not apply cleanly. This is not decisive because that patch is
  the artifact's SEV-SNP host patch, while the missing paper TDX host patch is a
  separate CoFunc-to-TDX integration.

## 2026-06-23 Intel TDX QEMU 7.1 Old-ABI Build

Built the likely matching Intel QEMU candidate for the 5.19 TDX KVM ABI:

```text
repo:    https://github.com/intel/qemu-tdx.git
tag:     tdx-upstream-snapshot-2022-09-01-v7.1
sha:     9c48d24da644a9a4841060c6bab201cbaf1255b8
source:  /mnt/new_disk/cofunc_tdx_artifact/provenance/qemu-candidates/qemu-tdx-2022-09-01-v7.1
branch:  cofunc-tdx-oldabi
patch:   /home/booklyn/cofunc-tdx/patches/qemu/0002-Wire-CoFunc-split-container-for-intel-tdx-7.1-oldabi.patch
build:   /mnt/new_disk/cofunc_tdx_artifact/build/qemu-tdx-2022-09-01-cofunc
install: /mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc
binary:  /mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64
```

Patch behavior:

- Adds `SLOT_ID`-based split-container VM type encoding:
  `(((SLOT_ID + 1) & 0xff) << 24)`.
- Handles old TDX VMCALL subfunctions `0x10010` and `0x10011`.
- Keeps the CoFunc debug `putchar` path, but sets
  `TDG_VP_VMCALL_SUCCESS` for handled requests so the guest does not receive
  the initialized invalid-operand status.

Configure/build notes:

```text
QEMU version: 7.0.90
target: x86_64-softmmu
KVM: enabled
TCG: disabled
FDT: system
slirp: system
submodules initialized: ui/keycodemapdb only
```

Why TCG was disabled: with TCG enabled, Meson tries to configure
`tests/fp/berkeley-softfloat-3` and `tests/fp/berkeley-testfloat-3`, requiring
extra submodules that are irrelevant for a KVM/TDX-only host run.

Verification:

```text
qemu-system-x86_64 --version => QEMU emulator version 7.0.90
qemu-system-x86_64 -object help includes tdx-guest
binary contains old ABI marker KVM_TDX_INIT_MEM_REGION
binary contains CoFunc marker unknown split-container request
```

This QEMU has not been used to boot a TD yet.

## 2026-06-23 Old-ABI Artifact Runtime Prep

Prepared an old-ABI working copy from the pristine Figshare extraction:

```text
source: /mnt/new_disk/cofunc_tdx_artifact/provenance/figshare-v4/cofunc-artifact
work:   /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi
```

Why this separate copy exists:

- The Figshare source uses the old TDX KVM ABI:
  `KVM_EXIT_TDX_VMCALL`, `run->tdx.u.vmcall.*`, and
  `struct kvm_userspace_memory_region`.
- The forward-ported current artifact uses the newer upstream ABI:
  `run->hypercall.*`, guest memfd, memory attributes, and prefault APIs.
- Reusing the current ChCore ISO would mix guest hypercall ABIs, so the old copy
  builds its own ChCore image.

Scaffolding copied into the old-ABI copy:

- `.config` set for `CHCORE_PLAT=intel_tdx`
- idempotent HTTPS `download_musl.sh`
- TDX launcher-generation CMake glue from the current artifact
- sudo/trace-aware `testcases/tools/cvm.sh`
- copied/reset `musl-libc` dependency

Recorded patch for old-ABI runtime defaults:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0003-Point-oldabi-tdx-runtime-at-new-disk.patch
```

This patch makes old-ABI launch defaults point at `/mnt/new_disk`:

```text
QEMU: /mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64
OVMF: /mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd
```

Core ABI-sensitive files in the old copy remain pristine relative to Figshare:

```text
shadow_container/main.c
cvm_os/kernel/split-container/split_container.c
cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c
```

ChCore old-ABI build state:

```text
kernel image: /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi/cvm_os/build/kernel/kernel.img
runtime ISO:  /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi/cvm_os/build/chcore.iso
launcher:     /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi/cvm_os/build/simulate.sh
```

ISO packaging note:

- `./chbuild build` succeeded through the ChCore kernel and user payloads.
- It failed only at `grub-mkrescue` because the builder container lacks
  `mformat`.
- Host `/usr/bin/grub-mkrescue`, `/usr/bin/mformat`, and `/usr/bin/xorriso`
  were present, so the ISO was packaged in:

  ```text
  /tmp/cofunc-oldabi-iso-20260623/chcore.iso
  ```

- The finished ISO was copied back into the container-owned
  `cvm_os/build/chcore.iso`.

Verification:

```text
chcore.iso: ISO 9660 CD-ROM filesystem data (DOS/MBR boot sector), bootable
chcore.iso size: 11M
kernel.img: ELF 64-bit LSB executable, x86-64, statically linked
simulate.sh mode: executable
```

Old-ABI shadow-container image:

```text
tag: split_container_builder:latest
id:  sha256:b50f7a780e787bb0e2cb1035541fed19087cc77a751ae37d168e41ec4c63709b
created: 2026-06-23T08:21:43Z
runtime: /runtime/runtime inside the image
```

Important: this overwrote the shared `split_container_builder:latest` tag. That
is intentional for the next old-ABI TDX experiments, but switch/rebuild it if
returning to the forward-ported artifact.

Current host state:

```text
running kernel: 6.19.0-rc6-cofunc-tdx+
5.19 build:     /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc
```

The 5.19 kernel has still not been installed or booted.

Firmware status:

- Local binary available:
  `/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd`
- No matching 2022 TDVF/OVMF binary was found locally.
- QEMU 7.1 has TDVF support code, but not a built firmware image.
- Therefore firmware is still a provenance gap. A first smoke can try the
  available 2025 OVMF, but exact-paper reproduction should eventually identify
  or build the matching 2022 TDVF.

Recommended provenance-first next step:

1. Decide whether to smoke the old QEMU + old-ABI artifact with the available
   2025 OVMF first, or pause to fetch/build matching 2022 TDVF.
2. With explicit user go-ahead, install/boot the built 5.19 host kernel:
   `5.19.0-cofunc-tdx-5.19+`.
3. After booting 5.19, run only a narrow old-ABI CVM smoke test first.
4. Only after the old stack boots, run CoFunc workload smoke tests and then add
   portable counters in guest/shadow-container code.

## Update: 2026-06-24 5.19 Boot And Old-ABI Runner

The host is now booted into the installed 5.19 kernel:

```text
uname -r: 5.19.0-cofunc-tdx-5.19+
```

The boot was done through a one-shot GRUB entry; the persistent GRUB default
still points back to the 6.19 kernel. This is intentional rollback safety.

Current caveats:

- `/mnt/new_disk` is mounted read-only after the reboot in this shell. The
  old-ABI runner remounts it read-write when run as root.
- Codex cannot run `sudo` interactively here, so workload launches still need
  to be started from the user's terminal.
- `/dev/kvm` exists on the host, but the user is not in the `kvm` group; use
  `sudo` for the workload runner.

Old-ABI Fig. 11 runner:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

Status:

- Script syntax check passed.
- Script is executable.
- No `oldabi_5_19_fig11_*` result directory has been observed yet under
  `/mnt/new_disk/cofunc_tdx_artifact/results`.

Run commands from the user's terminal:

```bash
sudo STOP_AFTER_SMOKE=1 /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

The first command does a one-workload smoke test. The second command runs the
selected Fig. 11 old-ABI TDX workload set and writes results to:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_fig11_<UTC timestamp>
```

First old-ABI 5.19 attempt:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_fig11_20260624_033331
```

This attempt stopped during the initial `fn_py_face_detection` smoke workload,
before creating `smoke-summary.txt` or `tdx_sc_fork_summary.txt`.

Failure:

```text
ModuleNotFoundError: No module named 'boto3'
```

Cause:

- `boto3` exists for the normal `booklyn` Python under
  `/home/booklyn/.local/lib/python3.10/site-packages`.
- The runner is executed with `sudo`, so root's Python path did not include that
  user site-packages directory when old artifact workload `prepare.py` ran.

Fix applied to the runner:

- Added `HOST_PYTHON_SITE`, defaulting to
  `/home/booklyn/.local/lib/python3.10/site-packages`.
- Validate that `HOST_PYTHON_SITE/boto3` exists before starting the run.
- Export `PYTHONPATH="$HOST_PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}"` around
  each artifact action invocation.
- Record `host_python_site` in `run-env.txt`.

Next run should start with smoke again:

```bash
sudo STOP_AFTER_SMOKE=1 /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

Second old-ABI 5.19 smoke attempt:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_fig11_20260624_033752
```

This fixed the Python dependency issue and reached CVM launch, but ChCore did
not reach the shell prompt before timeout:

```text
Timed out waiting for ChCore shell after 240s
```

The serial log reached firmware/GRUB and then stopped before ChCore output:

```text
BdsDxe: starting Boot0001 "UEFI Misc Device"
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

Important observation:

- This failed old-ABI launch used `tdx_smp=32`.
- The previously working forward-ported 6.19 launch used `tdx_smp=16`.

Runner adjustment applied after this failure:

- Default `COFUNC_TDX_SMP` to `16` in
  `/home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh`.
- Export that value into each old artifact action.
- Record `tdx_smp` in `run-env.txt`.

Next run should smoke with the new 16-vCPU default:

```bash
sudo STOP_AFTER_SMOKE=1 /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

Third old-ABI 5.19 smoke attempt:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_fig11_20260624_034426
```

This run used the intended 16-vCPU setting:

```text
tdx_smp=16
```

It failed before ChCore boot because QEMU could not create a KVM VM:

```text
ioctl(KVM_CREATE_VM) failed: 16 Device or resource busy
qemu-system-x86_64: -accel kvm: failed to initialize kvm: Device or resource busy
```

Host-level checks immediately afterward found no live `qemu-system-x86_64`,
`screen`, or `/dev/kvm` holder, so this was likely a transient leftover from
the previous timed-out TD teardown rather than an active process still running.

Runner adjustment applied after this failure:

- Add `cleanup_cvm_state` to clean snapshot, CVM, lean rootfs, and cgroup state.
- Call that cleanup from the wrapper `EXIT` trap.
- Clean CVM state before each workload attempt.
- Retry only the narrow `KVM_CREATE_VM ... Device or resource busy` failure,
  defaulting to:

  ```text
  COFUNC_KVM_BUSY_RETRIES=3
  COFUNC_KVM_BUSY_COOLDOWN_SEC=20
  ```

The wrapper still defaults to:

```text
COFUNC_TDX_SMP=16
```

Next run should smoke again with the retry-aware wrapper:

```bash
sudo STOP_AFTER_SMOKE=1 /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

Fourth old-ABI 5.19 smoke attempt:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_fig11_20260624_044510
```

This run no longer failed with `KVM_CREATE_VM` busy. It reached the same stable
boot failure as the earlier 32-vCPU attempt:

```text
Timed out waiting for ChCore shell after 240s
BdsDxe: starting Boot0001 "UEFI Misc Device"
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

Confirmed:

- `tdx_smp=16`
- `kvm_busy_retries=3`
- no `smoke-summary.txt` was produced
- GRUB config inside both old and forward-port ISOs is identical:

  ```text
  menuentry "IPADS ChCore x86-64" {
          multiboot2 /boot/kernel.img
  }
  ```

Important comparison:

- The working forward-port run also prints the same GRUB/video messages, then
  proceeds to `[ChCore] uart init finished`.
- The old-ABI run never prints the ChCore UART line.
- The old and forward ChCore build `.config` files match.
- `tdx.c`, `tdx.S`, `tdx.h`, and `arch/io.h` are effectively identical between
  old-ABI and forward-port copies, except for a logging-level change in
  `tdx_accept_page`.

New diagnostic script:

```text
/home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

Purpose:

- Boot only ChCore, no workload.
- Use the old QEMU 7.0.90 + 5.19 host + current 2025 OVMF.
- Try the forward-port `cofunc-artifact` ISO first by default.

This isolates whether the boot failure follows the old ChCore image or the
old-QEMU/new-OVMF/5.19 launch stack.

Run from the user's terminal:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

To test both forward and old ChCore ISOs in one run:

```bash
sudo TARGET=both /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

Diagnostic result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_045553
```

This default run used `TARGET=current`, so it booted the known-working
forward-port ChCore ISO with the old QEMU 7.0.90 + 5.19 host + current 2025
TDX OVMF stack. It still failed:

```text
current	FAIL rc=1	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_045553/current-cvm.log
Timed out waiting for ChCore shell after 120s
BdsDxe: starting Boot0001 "UEFI Misc Device"
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

That means the old-ABI boot failure is not specific to the old ChCore image.
The failure follows the old QEMU / 5.19 / 2025 OVMF launch stack.

The diagnostic script now has a second mode:

```bash
sudo LAUNCH_MODE=direct /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

`LAUNCH_MODE=direct` bypasses the artifact `cvm.sh` wrapper and runs an
Intel-README-style old-QEMU command directly with private memfd memory and
explicit CPU/machine options. This should be the next quick probe before
building a matching 2022-era TDVF/OVMF.

Direct-launch diagnostic result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_051235
```

This used:

```text
target=current
launch_mode=direct
tdx_smp=16
boot_timeout=120
qemu=QEMU emulator version 7.0.90
ovmf=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd
```

It failed with:

```text
current	FAIL rc=124	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_051235/current-cvm.log
```

The log contains only the QEMU command line and no OVMF/GRUB serial output.
That makes direct mode less informative than the artifact wrapper path; the
wrapper reaches OVMF/GRUB, then stalls before ChCore UART init.

Firmware provenance update:

- The 2022 QEMU tree records the exact edk2 submodule gitlink:

  ```text
  160000 commit b24306f15daa2ff8510b06702114724b33895d3c	roms/edk2
  ```

- The submodule URL is:

  ```text
  https://gitlab.com/qemu-project/edk2.git
  ```

- A local 2022 QEMU edk2 x86_64 blob exists and has TDVF-looking strings:

  ```text
  /mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/share/qemu/edk2-x86_64-code.fd
  ```

The diagnostic script now allows a firmware override via `COFUNC_TDX_OVMF`.
Next cheap probe:

```bash
sudo COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/share/qemu/edk2-x86_64-code.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

If this still fails, build a matching TDVF/OVMF from edk2 commit
`b24306f15daa2ff8510b06702114724b33895d3c`.

Result of trying the raw local 2022 x86_64 code blob:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_052516
current	FAIL rc=1	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_052516/current-cvm.log
qemu: could not load PC BIOS '/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/share/qemu/edk2-x86_64-code.fd'
```

Diagnosis:

- The raw `edk2-x86_64-code.fd` is `0x37c000` bytes, not a 64 KiB multiple,
  so old QEMU rejects it before parsing TDVF.
- TDVF metadata inside the blob expects a 4 MiB image:

  ```text
  section 0: data_off=0x84000 raw=0x37c000 end=0x400000
  section 1: data_off=0x0     raw=0x84000
  ```

- The old QEMU bundle also has `edk2-i386-vars.fd`, exactly `0x84000` bytes.
  QEMU's own edk2 makefile notes that the i386 varstore template is reused for
  x86_64.

Created a combined 2022 TDVF candidate:

```text
/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd
size=4194304
sha256=f52b6edb0f656d42e824227912e11d3cc3cd7811df1cf37f756ca266763ec220
```

Local metadata parse passed:

```text
size 0x400000, mod64k 0
OVMF footer present
TDX metadata GUID present
metadata sig 0x46564454, version 1, entries 6
all section data ranges are within the file
```

Next probe:

```bash
sudo COFUNC_TDX_OVMF=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

Combined 2022 TDVF probe result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_053246
current	FAIL rc=1	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_053246/current-cvm.log
```

This used:

```text
launch_mode=artifact
tdx_smp=16
boot_timeout=120
ovmf=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd
```

The earlier `qemu: could not load PC BIOS` error disappeared, so the combined
TDVF image is accepted as a BIOS image. However, QEMU exited before any
OVMF/GRUB/ChCore serial text appeared. The log only contains repeated
`CPUID.07H:EBX.intel-pt` warnings and then the screen session is gone.

Normal `dmesg` did not show TDX/KVM errors around the run, only Docker veth
messages from workload prep.

The diagnostic script now supports:

```text
LAUNCH_MODE=artifact-fg
COFUNC_QEMU_STRACE=1
```

`artifact-fg` runs the artifact QEMU command in the foreground instead of via
`screen`. With `COFUNC_QEMU_STRACE=1`, it also writes per-process strace logs
under the run's trace directory.

Next diagnostic:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 \
  COFUNC_TDX_OVMF=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

Foreground/strace diagnostic result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_053845
current	FAIL rc=124	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_053845/current-cvm.log
```

This timed out after 180s, but strace showed a diagnostic-harness problem:

```text
ioctl(0, TCSETS, ...) = ? ERESTARTSYS
--- SIGTTOU {si_signo=SIGTTOU, si_code=SI_KERNEL} ---
--- stopped by SIGTTOU ---
```

QEMU was stopped while trying to use `-serial mon:stdio` under the foreground
`timeout`/`strace` wrapper. This is not evidence about ChCore or TDVF yet.

Updated `boot_oldqemu_chcore_diag.sh` so `LAUNCH_MODE=artifact-fg` now uses:

```text
-monitor none
-serial file:$trace_root/${target}-serial.log
```

instead of `-serial mon:stdio`. It still supports `COFUNC_QEMU_STRACE=1`, but
the next run should avoid the `SIGTTOU` stop and record serial output in:

```text
<result>/current-trace/current-serial.log
```

Next diagnostic to rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 \
  COFUNC_TDX_OVMF=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

Foreground/strace diagnostic after switching serial to a file:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_060056
current	FAIL rc=1	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_060056/current-cvm.log
```

This used:

```text
target=current
launch_mode=artifact-fg
qemu_strace=1
tdx_smp=16
boot_timeout=120
qemu=QEMU emulator version 7.0.90
ovmf=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd
```

Result:

- The `SIGTTOU` foreground-wrapper problem is fixed.
- QEMU opened the serial log but wrote zero bytes to it.
- The main QEMU process and its traced threads exited cleanly with status `0`
  after about one second.
- The wrapper reported `FAIL rc=1` only because `artifact-fg` intentionally
  treats "QEMU exited successfully but ChCore shell was not seen" as failure.
- Strace shows the VM and vCPUs were created, TDX `KVM_MEMORY_ENCRYPT_OP`
  ioctls succeeded, and vCPUs reached `KVM_RUN` before teardown.
- Normal `dmesg` did not show TDX/KVM errors around the run.

Interpretation:

- With the assembled 2022 TDVF, old QEMU/5.19 no longer reaches OVMF/GRUB.
- It exits cleanly before firmware serial output. At this point, the cause was
  not verified; the next run removed `-no-reboot` to test whether QEMU was
  seeing a reset path.
- This is distinct from the 2025 OVMF behavior, where old QEMU/5.19 reaches
  OVMF/GRUB and then stalls before ChCore UART output.

The diagnostic script now has two extra `artifact-fg` toggles:

```text
COFUNC_QEMU_NO_REBOOT=0   omit -no-reboot
COFUNC_QEMU_DEBUG=1       add -d guest_errors,int,cpu_reset and write qemu-debug.log
```

Recommended next diagnostic:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_TDX_OVMF=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

That should answer whether the 2022 TDVF path is immediately resetting. Check:

```text
<result>/current-trace/current-qemu-debug.log
<result>/current-trace/current-serial.log
<result>/current-cvm.log
```

Result of the no-`-no-reboot` / QEMU-debug diagnostic:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_060905
current	FAIL rc=1	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_060905/current-cvm.log
```

Run configuration:

```text
target=current
launch_mode=artifact-fg
qemu_strace=1
qemu_no_reboot=0
qemu_debug=1
tdx_smp=16
boot_timeout=120
qemu=QEMU emulator version 7.0.90
ovmf=/home/booklyn/cofunc-tdx/firmware/tdvf-2022-qemu-edk2-x86_64.fd
```

Verified evidence:

- The command did not include `-no-reboot`.
- `current-serial.log` is exactly `0` bytes.
- `current-qemu-debug.log` is `43244` bytes.
- The QEMU debug log contains exactly `32` `CPU Reset` entries:
  - `16` entries at `EIP=00000000`
  - `16` entries at `EIP=0000fff0`
- `current-cvm.log` contains `16` occurrences of:

  ```text
  cpus are not resettable, terminating
  ```

- The strace logs also contain `16` writes of that same message.
- Strace evidence:
  - `KVM_CREATE_VCPU` occurred `16` times.
  - successful `KVM_RUN` return occurred `16` times.
  - `KVM_MEMORY_ENCRYPT_OP` occurred `28` times:
    - `25` successful returns
    - `3` `E2BIG` probe returns
    - `0` other `KVM_MEMORY_ENCRYPT_OP` errors
  - the main QEMU trace ended with `exit_group(0)`.
- `dmesg --ctime --since '2026-06-24 06:08:50'` had no matches for:

  ```text
  tdx|kvm|qemu|error|fail|trap|segfault|general protection|BUG|WARNING
  ```

Evidence-based conclusion:

- The assembled 2022 TDVF run does reach KVM TD/vCPU setup and KVM run.
- It still produces no firmware/GRUB/ChCore serial output.
- Without `-no-reboot`, QEMU reports that the TD CPUs are not resettable and
  terminates cleanly.
- This verifies a reset/termination path for the assembled 2022 TDVF case. It
  does not, by itself, identify why that firmware path requests reset or fails
  before serial output.

Next evidence-only comparison:

Run the same foreground/debug mode with the known 2025 OVMF to confirm whether
the diagnostic harness still observes the previously seen OVMF/GRUB output:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=90 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

2025 OVMF foreground/debug comparison result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_062229
current	FAIL rc=124	/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_062229/current-cvm.log
```

Run configuration:

```text
target=current
launch_mode=artifact-fg
qemu_strace=1
qemu_no_reboot=0
qemu_debug=1
tdx_smp=16
boot_timeout=90
qemu=QEMU emulator version 7.0.90
ovmf=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd
```

Verified evidence:

- `current-cvm.log` shows `timeout --kill-after=30s 150 ...`.
- `current-cvm.log` ends with:

  ```text
  qemu-system-x86_64: terminating on signal 15 from pid 1991509 (timeout)
  ```

- `current-serial.log` is `312` bytes and contains:

  ```text
  BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
  BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
  Unknown memory type 15, considering reserved
  Unknown memory type 15, considering reserved
  error: no suitable video mode found.
  ```

- `current-serial.log` contains `0` occurrences of `ChCore`.
- `current-qemu-debug.log` is `43244` bytes and contains exactly `32`
  `CPU Reset` entries:
  - `16` entries at `EIP=00000000`
  - `16` entries at `EIP=0000fff0`
- There are `0` occurrences of:

  ```text
  cpus are not resettable, terminating
  ```

  in both `current-cvm.log` and the strace logs.

- Strace evidence:
  - `KVM_CREATE_VCPU` occurred `16` times.
  - successful `KVM_RUN` returns occurred `13123` times.
  - `KVM_MEMORY_ENCRYPT_OP` occurred `28` times:
    - `25` successful returns
    - `3` `E2BIG` probe returns
    - `0` other `KVM_MEMORY_ENCRYPT_OP` errors
  - the timeout delivered SIGTERM; strace logs contain `6` `SIGTERM`
    mentions.
- `dmesg --ctime --since '2026-06-24 06:22:20'` had no matches for:

  ```text
  tdx|kvm|qemu|error|fail|trap|segfault|general protection|BUG|WARNING
  ```

Evidence-based comparison:

- The foreground/debug harness works: with 2025 OVMF, it captures the same
  OVMF/GRUB serial stage seen in earlier artifact-mode runs.
- The assembled 2022 TDVF and 2025 OVMF runs differ in observed behavior:
  - assembled 2022 TDVF: no serial output; QEMU reports non-resettable TD CPUs
    and exits cleanly.
  - 2025 OVMF: OVMF/GRUB serial output appears; no ChCore output; QEMU is
    killed by the timeout.
- Both runs show the same initial `CPU Reset` debug-count pattern and no
  non-`E2BIG` `KVM_MEMORY_ENCRYPT_OP` errors.

Next evidence-only path:

- Treat the assembled 2022 TDVF as not yet proven usable for this launch path.
- Either locate/build a matching 2022 TDVF image from the QEMU edk2 commit, or
  continue debugging the 2025 OVMF path where the observed stop point is after
  GRUB output and before `[ChCore] uart init finished`.

## 2026-06-24 Early ChCore Main Probe Prep

Prepared a narrow probe for the 2025 OVMF path. The purpose is to distinguish:

- GRUB/firmware never transfers to ChCore, versus
- ChCore reaches `main()` but hangs before the first normal UART log.

Patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0004-Early-TDX-main-entry-probe.patch
sha256=5d14cf6e1635e2f0012eef0d5fe6918536ab70f5173d7925ac6fdea42d2f5153
```

Helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=5e2af6a8ec15ff33fe34680e6e814297e36703500bd0674fcb536ec57b4e52a8
```

The patch adds a direct early TDX split-container debug hypercall in
`cvm_os/kernel/arch/x86_64/main.c`:

```text
[ChCore probe] main entry before uart_init
[ChCore probe] after uart_init
```

It deliberately does not call `split_container_request()` because that would
touch `current_cap_group` too early. It calls `tdx_do_hypercall()` directly with
`VMCALL_SC_REQUEST` / `SC_REQ_DEBUG_PUTC`, so the output should appear in the
QEMU CVM log, not necessarily the serial log.

Validation completed:

```text
patch --dry-run -d /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact -p1 -i /home/booklyn/cofunc-tdx/patches/cofunc-artifact/0004-Early-TDX-main-entry-probe.patch
```

Result:

```text
checking file cvm_os/kernel/arch/x86_64/main.c
```

The dry-run also printed a read-only warning because Codex is sandboxed from
writing `/mnt/new_disk`; the sudo helper will remount `/mnt/new_disk` read-write
if needed.

Extra local validation applied the same patch to a disposable `/tmp` copy of
`main.c` and verified the resulting file contains exactly the expected probe
sites:

```text
tdx_early_debug_puts("[ChCore probe] main entry before uart_init\n");
tdx_early_debug_puts("[ChCore probe] after uart_init\n");
```

Current ChCore config confirms the probe should compile in:

```text
CHCORE_PLAT:STRING=intel_tdx
CHCORE_SPLIT_CONTAINER:BOOL=ON
```

First attempted helper run on 2026-06-24 did patch `main.c`, but did not
produce a probed ISO:

```text
main.c before:  fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
main.c after:   c9644faa6417b51c286db3998eaa0bbee1e1857122d0681a6dd7380b51a214d8
chcore.iso:     ec62cddf066c46baf32e5d73adc9a6ff13df1e10612e20dc4a42a9124e18b069 unchanged
kernel.img mtime: 2026-06-20 08:02:27
chcore.iso mtime: 2026-06-20 08:02:28
```

The subsequent diagnostic was therefore only a repeat baseline, not evidence
about the early probe:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_080702
```

It again timed out after the OVMF/GRUB output and contained no probe text, but
`grep -a` found no probe strings in either `build/kernel/kernel.img` or
`build/chcore.iso`, so absence of probe output is not meaningful for that run.

Root cause found:

- Top-level `cmake --build build --target help` advertises `kernel`, but not
  `chcore.iso`.
- The real `chcore.iso` target is under `build/kernel`.

The helper was updated to:

- keep the existing source patch if already applied;
- remove only stale generated outputs:
  `main.c.obj`, `build/kernel/kernel.img`,
  `build/kernel/arch/x86_64/boot/intel_tdx/chcore.iso`, and
  `build/chcore.iso`;
- run `cmake --build build/kernel --target chcore.iso`;
- copy the kernel-subproject ISO back to `build/chcore.iso`, which is the path
  the diagnostic launcher uses;
- fail unless `kernel.img` and `chcore.iso` contain the probe strings.

Host-side tools needed by the corrected helper are present:

```text
/usr/bin/cmake
/usr/bin/grub-mkrescue
/usr/bin/mformat
/usr/bin/xorriso
/usr/bin/rg
```

Next command for the user to rerun:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Corrected helper rerun succeeded on 2026-06-24:

```text
build timestamp: 2026-06-24 08:16:44 UTC
main.c:          c9644faa6417b51c286db3998eaa0bbee1e1857122d0681a6dd7380b51a214d8
kernel.img:      2b2984d1259e402691366c80fe26d8ed0ffee39bda1d51cec32faa8a029ea24c
kernel ISO:      85124d7e056f710245aef328a4bb659b5ad984488d73926ffee9a4398ad60e66
launcher ISO:    85124d7e056f710245aef328a4bb659b5ad984488d73926ffee9a4398ad60e66
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260624_081642
```

Verified with `grep -a`:

```text
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/build/kernel/kernel.img
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/build/chcore.iso
```

Both contain:

```text
[ChCore probe] main entry before uart_init
[ChCore probe] after uart_init
```

No new `oldqemu_chcore_diag_*` result directory was observed after this rebuild
as of the handoff update. The next step is to rerun the 2025 OVMF foreground
diagnostic so the probed ISO is actually booted.

2026-06-24 diagnostic after the verified probed ISO:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_082106
```

Run state:

```text
kernel=5.19.0-cofunc-tdx-5.19+
launch_mode=artifact-fg
qemu_strace=1
qemu_no_reboot=0
qemu_debug=1
tdx_smp=16
boot_timeout=30
qemu=QEMU emulator version 7.0.90
ovmf=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd
```

Evidence from this run:

- `build/chcore.iso` did contain the two `[ChCore probe]` strings before the
  run.
- `current-cvm.log`, `current-serial.log`, and strace contain no
  `[ChCore probe]` and no `[ChCore]`.
- Serial still stops after:

  ```text
  BdsDxe: starting Boot0001 "UEFI Misc Device"
  Unknown memory type 15, considering reserved
  error: no suitable video mode found.
  ```

- QEMU was killed by timeout, not by a non-resettable CPU exit:

  ```text
  qemu-system-x86_64: terminating on signal 15 from pid 3278283 (timeout)
  ```

- QEMU debug log shape remained:

  ```text
  size=43244 bytes
  CPU Reset count=32
  EIP=00000000 count=16
  EIP=0000fff0 count=16
  ```

- Strace showed:

  ```text
  KVM_CREATE_VCPU count=16
  KVM_RUN returns about 11235 total
  KVM_MEMORY_ENCRYPT_OP count=28
  KVM_MEMORY_ENCRYPT_OP E2BIG probes=3
  no non-E2BIG KVM_MEMORY_ENCRYPT_OP errors
  no writes of the probe text
  ```

Important caveat found after this run:

- The initial early probe used the forward-ported guest hypercall register
  layout:

  ```text
  tdx_do_hypercall(VMCALL_SC_REQUEST, SC_REQ_DEBUG_PUTC, c, 0, 0)
  ```

- The paper-era / 5.19 TDX KVM ABI and old QEMU expect:

  ```text
  r10=TDX_HYPERCALL_STANDARD
  r11=VMCALL_SC_REQUEST
  r12=SC_REQ_DEBUG_PUTC
  r13=c
  ```

- This is also visible in the Figshare source:

  ```text
  static long hypercall(u32 nr, u64 p1, u64 p2, u64 p3)
  {
          return tdx_do_hypercall(TDX_HYPERCALL_STANDARD, nr, p1, p2, p3);
  }
  ```

Prepared old-ABI correction patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0005-Use-old-TDX-ABI-for-early-main-probe.patch
sha256=e29750a897ec1ca4c5bb5016a6156bee65eae9efb4359e94896fa07817730eb4
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=bd422d4b26b23bbeb2d3c94b116c3c0ad289587634fa6db0df95904726547060
```

The new patch dry-runs cleanly against the current artifact source:

```text
checking file cvm_os/kernel/arch/x86_64/main.c
Hunk #1 succeeded at 69 (offset 1 line).
```

A disposable `/tmp` application verified `main.c` then contains:

```text
TDX_HYPERCALL_STANDARD,
VMCALL_SC_REQUEST,
SC_REQ_DEBUG_PUTC,
```

Next step:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun the same 2025 OVMF foreground diagnostic. The next run is the one
that should decide whether ChCore reaches `main()` under old QEMU/5.19/2025
OVMF.

After a successful build, rerun the 2025 OVMF foreground diagnostic:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules:

- If `current-cvm.log` contains `main entry before uart_init` but not
  `after uart_init`, GRUB did transfer to ChCore and the observed stop is inside
  `uart_init()`.
- If both probe lines appear, the stop is after `uart_init()`.
- If neither probe line appears, there is no evidence yet that execution reached
  ChCore `main()`.

2026-06-24 update: old-ABI C probe was tested; assembly entry probe is now prepared
---------------------------------------------------------------------------------

The old-ABI C-level `main()` probe was rebuilt and boot-tested:

```text
build timestamp: 2026-06-24 08:29:11 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260624_082911
main.c:          3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
kernel.img:      5353c27abbab0866ad00cc864eed5f2a021a366ceb0976c197d8a0e8f46161d9
chcore.iso:      d85712b80f69fd61c91e3951793782b55341beb8a2e63491a8a40f4da7846715
```

The corresponding boot diagnostic is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_082923
```

Evidence from that run:

```text
result=FAIL rc=124
serial path=current-trace/current-serial.log
probe strings in serial=0
probe strings in cvm/trace files=0
KVM_CREATE_VCPU=16
KVM_RUN=13526
KVM_MEMORY_ENCRYPT_OP=28
KVM_MEMORY_ENCRYPT_OP E2BIG=3
non-E2BIG KVM_MEMORY_ENCRYPT_OP errors=0
CPU Reset count=32
EIP=00000000 count=16
EIP=0000fff0 count=16
qemu-debug bytes=43244
```

The serial log still stops at GRUB/early handoff output:

```text
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
Unknown memory type 15, considering reserved
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

Hard conclusion from this run:

- There is no evidence that execution reached ChCore `main()`.
- Because this was a C-level probe, it does not yet distinguish between
  "GRUB never entered ChCore `_start`" and "ChCore entered `_start` but stopped
  before `main()`."

Prepared next diagnostic:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0006-Add-early-TDX-assembly-entry-probe.patch
sha256=0d407938153452ccfaf97caf0d193db7636346e7f2837d722a3c5026b616fec9
```

This patch dry-runs cleanly against the current artifact source:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=fff94115b98b59b15771cbc1982cfadafda435803bcd0a914ee8c4ac8adfc9fe
```

Current source state before the next sudo rebuild:

- `main.c` already contains the old-ABI C probe.
- `header.S` does not yet contain `TDX_BOOT_PUTC`; the assembly entry probe is
  prepared in patch `0006` but has not yet been applied to the artifact tree.

Next required command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules for the assembly probe:

- No `[ASM0]`: no evidence that GRUB entered ChCore `_start`.
- `[ASM0]` but no `[ASM1]`: execution reached `_start` but stopped before the
  high-VA path reaches `call main`.
- `[ASM1]` but no `[ChCore probe] main entry before uart_init`: execution reached
  immediately before `call main`, but `main()`/the C probe did not complete.
- `[ASM1]` and C probe present: execution reached `main()`; use the before/after
  `uart_init()` markers to localize the next stop.

2026-06-24 update: assembly entry probe was tested; no ChCore entry was observed
--------------------------------------------------------------------------------

The assembly-entry probe was applied and rebuilt:

```text
build timestamp: 2026-06-24 08:55:24 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260624_085524
main.c:          3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:        18f7606f9d63fe7402885aaa6c4d89e07d798db05ca15fa05a588b2072f036e4
kernel.img:      776b637a746585ee04870ebc30213d585ae3a8bf5266631b90bead67d410bae8
chcore.iso:      d06b3abc38c02c083d97f5af3d682ef6114c249a9a6f70730d198047b18d59c3
```

The corresponding boot diagnostic is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260624_085528
```

Evidence from that run:

```text
result=FAIL rc=124
serial path=current-trace/current-serial.log
probe strings in serial/trace=0
KVM_CREATE_VCPU=16
KVM_RUN=13367
KVM_MEMORY_ENCRYPT_OP=28
KVM_MEMORY_ENCRYPT_OP E2BIG=3
non-E2BIG KVM_MEMORY_ENCRYPT_OP errors=0
CPU Reset count=32
EIP=00000000 count=16
EIP=0000fff0 count=16
qemu-debug bytes=43244
not-resettable/nonreset lines=0
timeout termination lines=1
```

The serial log remained:

```text
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
Unknown memory type 15, considering reserved
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

Verification of the instrumented image:

- `header.S.obj` disassembly contains fourteen `tdcall` sites for `[ASM0]` and
  `[ASM1]`, using `RAX=0`, `RCX=0xfc00`, `R10=0`, `R11=0x10011`, `R12=1`, and
  `R13=<char>`.
- `kernel.img` and `chcore.iso` still contain the C probe string
  `[ChCore probe] main entry before uart_init`.
- Local `tdx.S` confirms `__tdx_hypercall` uses the same TDVMCALL ABI.
- The QEMU source used for `qemu-system-x86_64` handles subfunction `0x10011`,
  checks `in_r12 == SC_REQ_DEBUG_PUTC`, prints `in_r13`, and flushes stdout.

Hard conclusion from this run:

- There is no observed ChCore `_start`/`main()` execution under old
  QEMU + 5.19 + 2025 OVMF.
- The next unknown is whether GRUB reaches and returns from the `multiboot2`
  command / `boot` handoff.

Prepared next diagnostic: GRUB handoff probe
--------------------------------------------

Prepared patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0007-Add-GRUB-handoff-probe.patch
sha256=b64751555542d33cd45f5ec25aec502ecb4dc7b54320aac6e54466a2da385fb9
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=c0c348a778b84e7d24939e1572a2cc81779d2ca4eb3173d3f2ef818af7317de0
```

The GRUB probe patch dry-runs cleanly against the current artifact source:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/iso/boot/grub/grub.cfg
```

The generated ISO boot config currently is only:

```text
set timeout=0
set default=0

menuentry "IPADS ChCore x86-64" {
        multiboot2 /boot/kernel.img
}
```

Next required command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules:

- No `[GRUB probe] before multiboot2`: the boot path is not executing this
  `grub.cfg`.
- `before multiboot2` but no `after multiboot2`: GRUB entered the command but
  did not return from `multiboot2 /boot/kernel.img`.
- `after multiboot2` and `before boot` but no ChCore `[ASM0]`: GRUB loaded the
  kernel image and invoked `boot`, but no ChCore entry was observed.
- `[GRUB probe] boot returned`: GRUB attempted the handoff and returned instead
  of transferring permanently to ChCore.

2026-06-26 update: GRUB reaches `boot`, but ChCore entry is still not observed
------------------------------------------------------------------------------

The GRUB handoff probe was applied and rebuilt:

```text
build timestamp: 2026-06-26 04:25:35 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260626_042534
grub.cfg:        cf38ecf8b189575e73f35784ef1a334e51d515c0babd10d98837d00da4d640a5
kernel.img:      776b637a746585ee04870ebc30213d585ae3a8bf5266631b90bead67d410bae8
chcore.iso:      b9f4790285c8e1f5b5dc82be2f3289ef9803783239286aacb65a01a5b6d353db
```

The corresponding boot diagnostic is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260626_042539
```

Evidence from that run:

```text
result=FAIL rc=124
[GRUB probe] before multiboot2=1
[GRUB probe] after multiboot2=1
[GRUB probe] before boot=1
[GRUB probe] boot returned=0
[ASM0]/[ASM1]/[ChCore probe]/[ChCore]=0
KVM_CREATE_VCPU=16
KVM_RUN=13492
KVM_MEMORY_ENCRYPT_OP=28
KVM_MEMORY_ENCRYPT_OP E2BIG=3
non-E2BIG KVM_MEMORY_ENCRYPT_OP errors=0
CPU Reset count=32
EIP=00000000 count=16
EIP=0000fff0 count=16
qemu-debug bytes=43244
not-resettable/nonreset lines=0
```

The serial ordering is:

```text
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
[GRUB probe] before multiboot2
[GRUB probe] after multiboot2
[GRUB probe] before boot
Unknown memory type 15, considering reserved
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

Hard conclusion from this run:

- GRUB does execute the intended `grub.cfg`.
- `multiboot2 /boot/kernel.img` returns.
- GRUB reaches the explicit `boot` command.
- `boot` does not return to the script, but no ChCore `_start` marker is
  observed.
- The video-mode error happens after `before boot`, so the next narrow test is
  to remove ChCore's Multiboot2 framebuffer request from `header.S`.

Prepared next diagnostic: remove Multiboot2 framebuffer request
---------------------------------------------------------------

Prepared patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0008-Drop-Multiboot2-framebuffer-request.patch
sha256=65c43441c023782d1ee65785ee0ba43d96fda09725d9846fa73f46120edcae01
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=1d635f390f3c369c07915c41ae4f1c7496e7d1576f23ac5f04daf6810ef3779d
```

The framebuffer-removal patch dry-runs cleanly against the current artifact
source:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S
```

Next required command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules:

- If the video-mode error disappears and `[ASM0]` appears, the framebuffer
  request was blocking the handoff.
- If the video-mode error disappears but `[ASM0]` is still absent, the next
  blocker is later in GRUB `boot` / EFI handoff.
- If the video-mode error remains, it is not caused solely by ChCore's
  framebuffer tag.

2026-06-26 update: framebuffer removal did not fix GRUB handoff
----------------------------------------------------------------

The framebuffer-removal diagnostic was rebuilt and run:

```text
build timestamp: 2026-06-26 12:35:41 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260626_123541
main.c:          3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:        8cdb668db4fabec5301030d6ccdfa7a8b64b11804f513c98981322d8ebe5738f
grub.cfg:        cf38ecf8b189575e73f35784ef1a334e51d515c0babd10d98837d00da4d640a5
kernel.img:      3f5e994d55c4c627e9cc1863def3188741817276e74e95d89971f2573539c9ad
chcore.iso:      549f02b380baf6d6d82c1f0625683f7b66dc0c7a54a67857e738f36e9c58e5f1
```

The corresponding boot diagnostic is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260626_123544
```

Evidence from that run:

```text
result=FAIL rc=124
[GRUB probe] before multiboot2=1
WARNING: no console will be available to OS=1
[GRUB probe] after multiboot2=1
[GRUB probe] before boot=1
[GRUB probe] boot returned=0
[ASM0]/[ASM1]/[ChCore probe]/[ChCore]=0
KVM_CREATE_VCPU=16
KVM_RUN=13135
KVM_MEMORY_ENCRYPT_OP=28
KVM_MEMORY_ENCRYPT_OP E2BIG=3
CPU Reset count=32
EIP=00000000 count=16
EIP=0000fff0 count=16
qemu-debug bytes=43244
```

The serial ordering is:

```text
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
[GRUB probe] before multiboot2
WARNING: no console will be available to OS
[GRUB probe] after multiboot2
[GRUB probe] before boot
Unknown memory type 15, considering reserved
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

Additional source-string evidence:

```text
Unknown memory type                         -> GRUB mmap.mod
WARNING: no console will be available to OS -> GRUB multiboot2.mod
no suitable video mode found                -> GRUB video.mod
```

Hard conclusion from this run:

- The framebuffer request is absent from the rebuilt source/object/ISO search
  path, but the GRUB video error remains.
- Therefore the video-mode error is not caused solely by ChCore's removed
  Multiboot2 framebuffer tag.
- GRUB still reaches `boot`; `boot` still does not return; no ChCore entry
  marker is observed.
- The next narrow diagnostic is to add a Multiboot2 console-flags header tag,
  because GRUB explicitly warns that no OS console will be available.

Prepared next diagnostic: add Multiboot2 console flags
------------------------------------------------------

Prepared patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0009-Add-Multiboot2-console-flags-tag.patch
sha256=9d55665b88f2b1432c0825a388a0420878e5e04a9d38a8165d9ab583178def95
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=3f27f29d18e017d9f06dd7246e89feab2331bfbff84bcb3ac6be353cc602e430
```

The console-flags patch dry-runs cleanly against the current artifact source:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S
```

Next required command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules:

- If the console warning disappears and `[ASM0]` appears, the missing
  Multiboot2 console tag was blocking the handoff.
- If the console warning disappears but the video error and missing `[ASM0]`
  remain, the console tag is not sufficient and the next test should target
  GRUB's video mode selection directly.
- If the console warning remains, GRUB is not accepting the EGA-text console
  declaration in this TDX/nographic boot path.

2026-06-26 update: console-flags tag did not change GRUB behavior
------------------------------------------------------------------

The Multiboot2 console-flags diagnostic was rebuilt and run:

```text
build timestamp: 2026-06-26 13:34:33 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260626_133433
main.c:          3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:        2c61b548bada6e6ced6297a8cb8954029daf47117939832128a1c2161e907b0e
grub.cfg:        cf38ecf8b189575e73f35784ef1a334e51d515c0babd10d98837d00da4d640a5
kernel.img:      dad3931d8ad60409343485afa9c088e94a29a62c895d397c8d21cde39913fa9a
chcore.iso:      250235b145a19898db99f487cd89ac6a0b623cfaedb479b5f9fd4fee09337c97
```

The corresponding boot diagnostic is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260626_133435
```

Evidence from that run:

```text
result=FAIL rc=124
[GRUB probe] before multiboot2=1
WARNING: no console will be available to OS=1
[GRUB probe] after multiboot2=1
[GRUB probe] before boot=1
[GRUB probe] boot returned=0
Unknown memory type=2
no suitable video mode found=1
[ASM0]/[ASM1]/[ChCore probe]/[ChCore]=0
KVM_CREATE_VCPU=16
KVM_RUN=13371
KVM_MEMORY_ENCRYPT_OP=28
KVM_MEMORY_ENCRYPT_OP E2BIG=3
CPU Reset count=32
EIP=00000000 count=16
EIP=0000fff0 count=16
qemu-debug bytes=43244
```

Patch/application evidence:

```text
header.S contains console_flags_tag_start / console_flags_tag_end
header.S.obj contains console_flags_tag_start / console_flags_tag_end
MULTIBOOT_HEADER_TAG_FRAMEBUFFER/framebuffer_tag_* search count=0
```

Hard conclusion from this run:

- The console-flags tag was present in source and object, so this was not a
  failed-apply case.
- GRUB still prints the no-console warning.
- GRUB still reaches `boot`; `boot` still does not return; no ChCore entry
  marker is observed.
- The next narrow diagnostic is to force `gfxpayload=text` in `grub.cfg`, which
  directly targets the GRUB `video.mod` error seen after `before boot`.

Prepared next diagnostic: force GRUB gfxpayload=text
----------------------------------------------------

Prepared patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0010-Set-GRUB-gfxpayload-text.patch
sha256=acc78683f1391a38c944a55e1bd6c8bc6b7c26f820c292f6b2764d49708e41a3
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=4e909f6e20439cdf359516082b45b06a888534c76858a71507374142833d2295
```

The `gfxpayload=text` patch dry-runs cleanly against the current artifact
source:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/iso/boot/grub/grub.cfg
```

Next required command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules:

- If `no suitable video mode found` disappears and `[ASM0]` appears, GRUB video
  payload mode selection was blocking the handoff.
- If `no suitable video mode found` disappears but `[ASM0]` remains absent, the
  next blocker is later in the GRUB `boot` / EFI handoff path.
- If `no suitable video mode found` remains, `gfxpayload=text` is not sufficient
  in this old-QEMU/TDX/nographic path.

2026-06-26 update: gfxpayload=text removes video error but not handoff stall
----------------------------------------------------------------------------

The GRUB `gfxpayload=text` diagnostic was rebuilt and run:

```text
build timestamp: 2026-06-26 13:54:53 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260626_135452
main.c:          3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:        2c61b548bada6e6ced6297a8cb8954029daf47117939832128a1c2161e907b0e
grub.cfg:        8c1751eef7d2320a38592dbc94b8b57757ff32504d43764d99f8bed81a42688c
kernel.img:      dad3931d8ad60409343485afa9c088e94a29a62c895d397c8d21cde39913fa9a
chcore.iso:      9a548115143cc69e0d9f7438da7eaca0d18d533ea8aebf7c341eb8e404e1f0dc
```

The corresponding boot diagnostic is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260626_135457
```

Evidence from that run:

```text
result=FAIL rc=124
[GRUB probe] before multiboot2=1
[GRUB probe] gfxpayload=text
WARNING: no console will be available to OS=1
[GRUB probe] after multiboot2=1
[GRUB probe] before boot=1
[GRUB probe] boot returned=0
Unknown memory type=2
no suitable video mode found=0
[ASM0]/[ASM1]/[ChCore probe]/[ChCore]=0
KVM_CREATE_VCPU=16
KVM_RUN=13147
KVM_MEMORY_ENCRYPT_OP=28
KVM_MEMORY_ENCRYPT_OP E2BIG=3
CPU Reset count=32
EIP=00000000 count=16
EIP=0000fff0 count=16
qemu-debug bytes=43244
```

Additional cleanup/process evidence:

```text
ps -C qemu-system-x86_64 -> no live QEMU process
ps -C strace             -> no live strace process
ps -C timeout            -> no live timeout process
qemu-debug exception/fault search found only the normal CPU Reset records
```

Hard conclusion from this run:

- `set gfxpayload=text` is accepted by GRUB and removes the GRUB
  `no suitable video mode found` error.
- The handoff still does not produce ChCore serial output.
- `boot` still does not return to GRUB.
- There is no QEMU `-d int` evidence of a guest exception/fault in this run.
- Because the ChCore entry probes currently rely on the TDX debug-putc
  hypercall path, the next narrow test should use an entry-side effect that
  does not rely on that path.

Prepared next diagnostic: opt-in early UD2 entry trap
-----------------------------------------------------

Prepared patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0011-Add-early-entry-ud2-trap.patch
sha256=6c071e0df674055b1de2b34b62b98ee375bcb620488c5104d839ebc15710d819
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=e9b476a7cfa84093a2c051bd0e682d65bc52e466156741c682a534a803c61ab9
```

The UD2 patch dry-runs cleanly against the current artifact source:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S
Hunk #1 succeeded at 94 (offset 8 lines).
```

The UD2 trap is intentionally opt-in:

```bash
sudo COFUNC_ENTRY_TRAP=1 /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

Then rerun:

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

Interpretation rules:

- If QEMU debug logs an invalid-op/fault path after GRUB `boot`, GRUB is
  reaching ChCore `_start`; the previous missing serial output is then likely
  due to the early TDX debug-putc path or the entry code immediately after it.
- If QEMU debug still shows only the normal reset records and no fault path, the
  current evidence still points to GRUB/EFI handoff not reaching ChCore `_start`.

Prepared cleanup path
---------------------

Prepared cleanup helper:

```text
/home/booklyn/cofunc-tdx/scripts/cleanup_current_tdx_diagnostics.sh
sha256=265ac12af2870f3b1018ef81a372d49d6f0969f5db2b8e5c9918b80e75a8a53e
```

Run this after diagnostics are finished, not before the next test:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/cleanup_current_tdx_diagnostics.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_cleanup.log
```

The cleanup helper restores pre-diagnostic `main.c`, `header.S`, and `grub.cfg`
from backups, rebuilds `chcore.iso`, and verifies that `[ChCore probe]`,
`[GRUB probe]`, `TDX_BOOT_PUTC`, the UD2 trap, and `gfxpayload=text` are absent.

2026-06-26 update: cleanup ran before UD2 boot diagnostic
---------------------------------------------------------

The opt-in UD2 build did run:

```text
build timestamp: 2026-06-26 14:30:03 UTC
backup:          /home/booklyn/cofunc-tdx/backups/current-early-probe-20260626_143003
main.c:          3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:        7223da9dda7929aeaf1bceb53f02f3d1570d9b6e7f901de04753e71fd5bd63ce
grub.cfg:        8c1751eef7d2320a38592dbc94b8b57757ff32504d43764d99f8bed81a42688c
kernel.img:      14c93facacf6dbcc590c31e786792a08060950e1839ad6b8866ec8bc751e5546
chcore.iso:      f174665de41a3d2a0478c4a21ee8c258fdcfcb74fb6a921f756b1aa8bf4a2a06
```

However, the cleanup helper ran immediately afterward:

```text
cleanup timestamp: 2026-06-26 14:30:08 UTC
cleanup backup:    /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260626_143007
main.c:            fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S:          62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg:          d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
kernel.img:        9abee804b865fcc6000c974cd3d537d2fb10369eeee5094fe7e889add3f09523
chcore.iso:        29cc02944b0440d6b10c38a6a3927b5c63d843629fe739d0e9ce7d0a856d916c
```

Hard conclusion:

- The UD2 boot diagnostic was not captured.
- `last_diag_terminal.log` still points to the earlier `gfxpayload=text` run:
  `/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_diag_20260626_135457`.
- There is no newer `oldqemu_chcore_diag_*` result directory after cleanup.
- No live `qemu-system-x86_64`, `strace`, or `timeout` process remains.
- The artifact is now in the clean pre-diagnostic state.

If the UD2 test is still needed, rerun the UD2 build and boot diagnostic before
running cleanup:

```bash
sudo COFUNC_ENTRY_TRAP=1 /home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_probe_build.log
```

```bash
sudo LAUNCH_MODE=artifact-fg COFUNC_QEMU_STRACE=1 COFUNC_QEMU_NO_REBOOT=0 COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=30 \
  COFUNC_TDX_OVMF=/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_diag_terminal.log
```

2026-06-27 update: one-shot UD2 runner prepared
------------------------------------------------

To avoid repeating the mistake where cleanup runs before the boot diagnostic is
captured, use the one-shot runner for the next UD2 test:

```text
/home/booklyn/cofunc-tdx/scripts/run_ud2_entry_trap_test.sh
sha256=f8e58dfc13e9bfca62f2404e9eb7669bcfe8ede27d8ba31ba394511e8aba1b92
```

The apply helper was also tightened so `COFUNC_ENTRY_TRAP=1` verifies that the
UD2 trap is present in both the rebuilt `header.S.obj` and `kernel.img`, not
only the source:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=6f50ff24e5c75efd130804a7201d91b6264db9fd5bc744aacafeb0fb7b966e96
```

Both scripts pass `bash -n`.

Run:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_ud2_entry_trap_test.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_ud2_entry_trap_test.log
```

The runner will:

- build the UD2 entry-trap diagnostic ISO;
- run the old-QEMU TDX boot diagnostic before cleanup;
- write per-run logs under `/home/booklyn/cofunc-tdx/logs/ud2-entry-trap-*`;
- write the VM boot output under `/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_ud2_entry_*`;
- then run `/home/booklyn/cofunc-tdx/scripts/cleanup_current_tdx_diagnostics.sh`.

Set `COFUNC_SKIP_FINAL_CLEANUP=1` only if the diagnostic artifact should be left
in place for manual inspection.

2026-06-27 update: first one-shot UD2 run aborted before boot
--------------------------------------------------------------

The one-shot UD2 runner was invoked:

```text
wrapper log: /home/booklyn/cofunc-tdx/last_ud2_entry_trap_test.log
run dir:     /home/booklyn/cofunc-tdx/logs/ud2-entry-trap-20260627_123100
```

It built a UD2 entry-trap diagnostic image, but aborted before running the boot
diagnostic:

```text
error: rebuilt kernel.img does not contain early entry UD2 trap
```

This was a verifier bug, not a missing UD2 in the image. The cleanup backup
contains the pre-cleanup diagnostic kernel image:

```text
/home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_123101/kernel.img.before-cleanup
```

Disassembly of that image proves the trap was present:

```text
ffffffffc0100058 <_start>:
ffffffffc010005c: bc 00 90 10 00  mov    $0x109000,%esp
ffffffffc0100061: 0f 0b           ud2
```

Root cause of the false failure:

- The verifier used `objdump -d "$KERNEL_IMG" | rg -q '\bud2\b'` under
  `set -o pipefail`.
- `rg -q` can exit as soon as it finds a match.
- `objdump` can then receive SIGPIPE, causing the whole pipeline to report
  failure even though the match existed.

The helper was fixed to write disassembly to files first, then search those
files:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=69deaa1980e5d58320deba35be01154e8ddd2f299a0ba2f4440b65743c8f8020
```

The one-shot runner itself is unchanged:

```text
/home/booklyn/cofunc-tdx/scripts/run_ud2_entry_trap_test.sh
sha256=f8e58dfc13e9bfca62f2404e9eb7669bcfe8ede27d8ba31ba394511e8aba1b92
```

Both scripts pass `bash -n`.

Cleanup did run after the aborted test:

```text
cleanup backup: /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_123101
```

Current artifact source state is clean:

```text
main.c:   fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S: 62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg: d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
```

There is still no captured UD2 boot result. Rerun:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_ud2_entry_trap_test.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_ud2_entry_trap_test.log
```

2026-06-27 update: UD2 proves GRUB reaches ChCore _start
---------------------------------------------------------

The corrected one-shot UD2 runner completed build, boot diagnostic, and cleanup:

```text
wrapper log: /home/booklyn/cofunc-tdx/last_ud2_entry_trap_test.log
run dir:     /home/booklyn/cofunc-tdx/logs/ud2-entry-trap-20260627_124924
boot out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_ud2_entry_20260627_124924
cleanup:     /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_125056
```

Diagnostic image hashes before cleanup:

```text
main.c:     3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:   7223da9dda7929aeaf1bceb53f02f3d1570d9b6e7f901de04753e71fd5bd63ce
grub.cfg:   8c1751eef7d2320a38592dbc94b8b57757ff32504d43764d99f8bed81a42688c
kernel.img: 14c93facacf6dbcc590c31e786792a08060950e1839ad6b8866ec8bc751e5546
chcore.iso: 01bdf2d80d89883941ccbd57dbe6e36aa4aaac47e4f21457ae1895c0dd382898
```

Serial evidence:

```text
[GRUB probe] before multiboot2=1
[GRUB probe] gfxpayload=text=1
WARNING: no console will be available to OS=1
[GRUB probe] after multiboot2=1
[GRUB probe] before boot=1
[GRUB probe] boot returned=0
Unknown memory type=2
no suitable video mode found=0
#UD - Invalid Opcode=1
RIP  - 0000000000100061=1
[ASM0]/[ASM1]/[ChCore probe]/[ChCore]=0
```

The saved pre-cleanup diagnostic kernel disassembly confirms the injected trap:

```text
/home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_125056/kernel.img.before-cleanup

ffffffffc0100058 <_start>:
ffffffffc010005c: bc 00 90 10 00  mov    $0x109000,%esp
ffffffffc0100061: 0f 0b           ud2
```

Hard conclusion:

- GRUB does transfer control to ChCore `_start`.
- The reported serial exception RIP, `0x100061`, matches the physical address
  of the injected `_start` UD2 (`PADDR(ffffffffc0100061)`).
- Therefore the earlier missing `[ASM0]`/`[ASM1]` output does not mean GRUB
  failed to jump to ChCore.
- The next blocker is inside ChCore's earliest entry path, or specifically in
  the early diagnostic output path that uses TDX debug-putc TDCALLs.

Cleanup evidence:

```text
main.c:     fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S:   62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg:   d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
kernel.img: 9abee804b865fcc6000c974cd3d537d2fb10369eeee5094fe7e889add3f09523
chcore.iso: cf3f324f82bf5250c102b6e8a68c34cbb9465d0705f23c820e8104285f304da4
```

No live `qemu-system-x86_64`, `strace`, or `timeout` process remained after the
test.

Suggested next diagnostic:

- Add a second opt-in trap after the `[ASM0]` TDX debug-putc sequence.
- If the after-putc trap fires, the debug-putc sequence returns but produces no
  output; focus on the TDX debug-putc ABI/QEMU handler path.
- If the after-putc trap does not fire, the early TDX debug-putc sequence itself
  hangs or faults before returning.

2026-06-27 update: after-ASM0 trap runner prepared
--------------------------------------------------

Prepared patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0012-Add-after-ASM0-ud2-trap.patch
sha256=acefdef379142466961344da06d9971a08150010a50bef853efa61c8c0f9471d
```

Prepared one-shot runner:

```text
/home/booklyn/cofunc-tdx/scripts/run_after_asm0_trap_test.sh
sha256=8d32aa524472775e586f3daa674b2283da4667288b89315010e73571771c83ca
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/apply_current_early_probe_build.sh
sha256=e69db92d5a8ee1d78f426eabf3e4f99591d0102873594f01cf1d12d2f8419840
```

Updated cleanup helper:

```text
/home/booklyn/cofunc-tdx/scripts/cleanup_current_tdx_diagnostics.sh
sha256=60c011f67fbb11342bb82a946f7c04f381887b177ddd49c3b057433321ba8652
```

All three scripts pass `bash -n`.

The after-ASM0 patch applies cleanly after the assembly entry probe:

```text
checking file cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S
Hunk #1 succeeded at 107 (offset 2 lines).
```

Run:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_after_asm0_trap_test.sh \
  2>&1 | tee /home/booklyn/cofunc-tdx/last_after_asm0_trap_test.log
```

The runner will build with `COFUNC_AFTER_ASM0_TRAP=1`, boot before cleanup,
then restore the clean artifact state.

2026-06-27 update: after-ASM0 trap proves debug-putc returns without output
----------------------------------------------------------------------------

The after-ASM0 trap runner completed build, boot diagnostic, and cleanup:

```text
wrapper log: /home/booklyn/cofunc-tdx/last_after_asm0_trap_test.log
run dir:     /home/booklyn/cofunc-tdx/logs/after-asm0-trap-20260627_130952
boot out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_after_asm0_trap_20260627_130952
cleanup:     /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_131123
```

Diagnostic image hashes before cleanup:

```text
main.c:     3663a59c496c0bb473face19a57977a7d23ce3d5be49aeb4f85aca398103ffdb
header.S:   278aa2cd296ece51116abbd40f9c60770c6345bd90f8d989161a50affd02448c
grub.cfg:   8c1751eef7d2320a38592dbc94b8b57757ff32504d43764d99f8bed81a42688c
kernel.img: be17b24acec31c0ae9c0c00fc32d2108bae0b93132899aa8b160a8a711618ce7
chcore.iso: b507ba97d8375823260e1634edb4d27dc2f78b61cc00cb06ed05a0571e6a4959
```

Serial evidence:

```text
[GRUB probe] before multiboot2=1
[GRUB probe] gfxpayload=text=1
WARNING: no console will be available to OS=1
[GRUB probe] after multiboot2=1
[GRUB probe] before boot=1
[GRUB probe] boot returned=0
Unknown memory type=2
no suitable video mode found=0
#UD - Invalid Opcode=1
RIP  - 0000000000100184=1
[ASM0]/[ASM1]/[ChCore probe]/[ChCore]=0
```

The saved pre-cleanup diagnostic kernel disassembly confirms the trap location:

```text
/home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_131123/kernel.img.before-cleanup

ffffffffc0100058 <_start>:
...
ffffffffc010017e: 66 0f 01 cc  tdcall        # final "\n" debug-putc
ffffffffc0100182: 5e           pop    %rsi
ffffffffc0100183: 5f           pop    %rdi

ffffffffc0100184 <cofunc_after_asm0_ud2>:
ffffffffc0100184: 0f 0b        ud2
```

Hard conclusion:

- GRUB reaches ChCore `_start`.
- ChCore executes the full `[ASM0]\n` TDX debug-putc sequence and reaches the
  after-ASM0 trap.
- The debug-putc sequence returns control to ChCore, but no `[ASM0]` output is
  emitted to serial, QEMU stdout/stderr logs, or the wrapper logs.
- Therefore the current blocker is not GRUB handoff and not a hang inside the
  first debug-putc sequence. The next focus is the TDX debug-putc ABI/QEMU
  handler path, or the next ChCore entry step after `[ASM0]`.

Notable register state at the trap:

```text
RIP=0000000000100184
RAX=0000000000000000
RCX=000000000000FC00
R10=8000000000000000
R11=0000000000010011
R12=0000000000000001
R13=000000000000000A
```

Cleanup evidence:

```text
main.c:   fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S: 62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg: d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
```

### QEMU/TDVMCALL ABI evidence after after-ASM0

Source evidence:

```text
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.S
  TDVMCALL_EXPOSE_REGS_MASK = TDX_R10 | TDX_R11 | TDX_R12 | TDX_R13 | TDX_R14 | TDX_R15
  The wrapper loads r10-r15 from struct tdx_hypercall_args and sets ecx to this mask.

/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/kernel/split-container/split_container.c
  split_container_request(op, a, b) -> hypercall(VMCALL_SC_REQUEST, op, a, b)
  TDX hypercall path -> tdx_do_hypercall(nr, p1, p2, p3, 0)

/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c
  tdx_do_hypercall sets r10=nr, r11=p1, r12=p2, r13=p3, r14=p4.

/mnt/new_disk/cofunc_tdx_artifact/provenance/qemu-candidates/qemu-tdx-2022-09-01-v7.1/target/i386/kvm/tdx.c
  tdx_handle_vmcall initializes status_code to TDG_VP_VMCALL_INVALID_OPERAND.
  It sets SUCCESS only when vmcall type is 0, subfunction is KVM_HC_TDX_SC_REQUEST (0x10011),
  and in_r12 is SC_REQ_DEBUG_PUTC (1), then putchar(in_r13).

/mnt/new_disk/cofunc_tdx_artifact/provenance/qemu-candidates/qemu-tdx-2022-09-01-v7.1/include/split-container.h
  KVM_HC_TDX_SC_REQUEST = 0x10011
  SC_REQ_DEBUG_PUTC = 1
```

Runtime/binary evidence:

```text
/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64
  strings include:
    unknown tdg.vp.vmcall type 0x%llx subfunction 0x%llx
    unknown split-container request 0x%llx

/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_after_asm0_trap_20260627_130952/current-cvm.log
  No unknown tdg.vp.vmcall / unknown split-container request warnings were present.
```

Current interpretation, bounded by evidence:

- The assembly probe uses the same register exposure mask and the same r10-r13 layout as ChCore's own TDX hypercall wrapper.
- At the after-ASM0 trap, r10 was `0x8000000000000000`, which the 2022 QEMU source defines as `TDG_VP_VMCALL_INVALID_OPERAND`.
- QEMU did not log either unknown-handler warning in the after-ASM0 run. The next diagnostic should capture the state after exactly one debug-putc call, because the seven-call `[ASM0]\n` sequence only shows the final call's register state.

### Prepared next diagnostic: single debug-putc trap

Added on 2026-06-27:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact/0013-Add-single-putc-ud2-trap.patch
/home/booklyn/cofunc-tdx/scripts/run_single_putc_trap_test.sh
```

Helper hashes:

```text
apply_current_early_probe_build.sh    177fa3b611f6d9e155643e07796abb497917d094a5a05ed167f2a1b6f1e0203c
cleanup_current_tdx_diagnostics.sh    9ae3ddb0f3d34c52f6cac547d3e26db4706261528246c779d532a5026be82d02
run_single_putc_trap_test.sh          41ffff35937d745e716ea6709079b98fc1381b44adee938a2424cf3c05b3bfd8
0013-Add-single-putc-ud2-trap.patch   a6d6bf1d6cf4ae52654cf5894f8175eff1c94c9dfd9cf4c75e9f239de0f6d2d5
```

Run command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_single_putc_trap_test.sh
```

### 2026-06-27 single debug-putc trap result

The single-putc trap runner completed build, boot diagnostic, and cleanup:

```text
run dir:  /home/booklyn/cofunc-tdx/logs/single-putc-trap-20260627_135204
boot out: /mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_single_putc_trap_20260627_135204
cleanup:  /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_135336
```

Serial evidence:

```text
[GRUB probe] before boot
Unknown memory type 15, considering reserved
Unknown memory type 15, considering reserved
!!!! X64 Exception Type - 06(#UD - Invalid Opcode)  CPU Apic ID - 00000000 !!!!
RIP  - 000000000010008C
RAX  - 0000000000000000, RCX - 000000000000FC00
R10  - 8000000000000000
R11  - 0000000000010011, R12 - 0000000000000001, R13 - 000000000000005B
```

Disassembly of the saved pre-cleanup kernel confirms the trap was immediately
after the first debug-putc TDCALL:

```text
/home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260627_135336/kernel.img.before-cleanup

ffffffffc0100063: xor    %eax,%eax
ffffffffc0100065: mov    $0xfc00,%ecx
ffffffffc010006a: xor    %r10d,%r10d
ffffffffc010006d: mov    $0x10011,%r11
ffffffffc0100074: mov    $0x1,%r12
ffffffffc010007b: mov    $0x5b,%r13
ffffffffc0100088: tdcall

ffffffffc010008c <cofunc_single_putc_ud2>:
ffffffffc010008c: ud2
```

QEMU/strace evidence:

```text
current-cvm.log: no "unknown tdg.vp.vmcall" warning
current-cvm.log: no "unknown split-container request" warning
strace: no write(1, "[", 1)
strace write(1, ...): only QEMU --version output before launch
```

Hard conclusion:

- The first debug-putc TDVMCALL itself returns `R10=0x8000000000000000`.
- That value matches `TDG_VP_VMCALL_INVALID_OPERAND` in both the QEMU and host
  kernel TDX source.
- The missing output is not caused by a later call in the `[ASM0]\n` sequence.

### 2026-06-27 host-kernel routing finding

The live 5.19 module is tied to this source/build:

```text
running kernel: 5.19.0-cofunc-tdx-5.19+
kvm_intel: /lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm-intel.ko.zst
/lib/modules/5.19.0-cofunc-tdx-5.19+/build  -> /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc
/lib/modules/5.19.0-cofunc-tdx-5.19+/source -> /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot
```

Build metadata for `tdx.o` points at:

```text
/mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot/arch/x86/kvm/vmx/tdx.c
```

Relevant source evidence:

```text
arch/x86/kvm/vmx/tdx.c
  handle_tdvmcall() default:
    tdvmcall_set_return_code(vcpu, TDG_VP_VMCALL_INVALID_OPERAND)

  handle_tdvmcall() currently routes these standard TDVMCALL leaves:
    CPUID, HLT, IO, EPT violation, MSR read/write,
    GET_TD_VM_CALL_INFO, REPORT_FATAL_ERROR, MAP_GPA,
    SETUP_EVENT_NOTIFY_INTERRUPT, GET_QUOTE

  It does not route KVM_HC_TDX_SC_VCPU_IDLE (0x10010) or
  KVM_HC_TDX_SC_REQUEST (0x10011) to userspace/QEMU.
```

This explains the combination of evidence:

- guest issued standard TDVMCALL `r10=0`, `r11=0x10011`;
- KVM returned `TDG_VP_VMCALL_INVALID_OPERAND`;
- QEMU did not print the debug byte;
- QEMU also did not log an unknown VMCALL, because the request never reached
  QEMU's TDX VMCALL handler.

Prepared host-kernel follow-up patch:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0002-Route-CoFunc-TDX-VMCALL-leaves-to-userspace-for-5.19.patch
sha256: d6f3d104139bc4e8387c30a1c72f76e804a88d5e464ce7be7624f46af9ef94c6
```

Dry-run result:

```text
patch --dry-run -d /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot -p1 -i /home/booklyn/cofunc-tdx/patches/host-kernel/0002-Route-CoFunc-TDX-VMCALL-leaves-to-userspace-for-5.19.patch
Hunk #1 succeeded at 1829 with fuzz 2.
```

Former next engineering step, completed in the update below:

1. Apply the new host-kernel patch to the 5.19 source.
2. Rebuild/reinstall `kvm.ko` and `kvm-intel.ko` or rebuild/install the kernel.
3. Coordinate module reload or reboot carefully because this is a shared remote
   host.
4. Re-run `sudo /home/booklyn/cofunc-tdx/scripts/run_single_putc_trap_test.sh`.
   Expected proof of fix: QEMU writes `[` to stdout and the trap shows
   `R10=0`.

### 2026-06-27 patched host KVM module build

Applied patch:

```text
patch -d /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot -p1 -i /home/booklyn/cofunc-tdx/patches/host-kernel/0002-Route-CoFunc-TDX-VMCALL-leaves-to-userspace-for-5.19.patch
patching file arch/x86/kvm/vmx/tdx.c
Hunk #1 succeeded at 1829 with fuzz 2.
```

Source verification after patch:

```text
arch/x86/kvm/vmx/tdx.c
1835: case KVM_HC_TDX_SC_VCPU_IDLE:
1836: case KVM_HC_TDX_SC_REQUEST:
1838:  * CoFunc TDX split-container requests are handled by QEMU.
```

The first single-module rebuild target failed at final modpost because it tried
to post-process `kvm-intel.ko` without KVM core symbols in the same modpost set.
The KVM subdirectory build succeeded:

```text
make -C /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc M=arch/x86/kvm -j16 modules
...
LD [M]  arch/x86/kvm/kvm-intel.ko
LD [M]  arch/x86/kvm/kvm.ko
```

Built artifact hashes:

```text
3e5b31cb80bc3c9a5b1e6f952121f36ccc066786d6d75caf5d430c3a29b3edae  arch/x86/kvm/vmx/tdx.o
f60acfa2c7ddc104a8c180aee64f76017a9518e4fb55f57914e2cc2c01757dfd  arch/x86/kvm/kvm-intel.o
2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2  arch/x86/kvm/kvm-intel.ko
733ba70491b9e81077103c60e2bf904d29100cd7719b3bcb47b156b07fbb2e16  arch/x86/kvm/kvm.ko
```

Installed live modules are still old at this point:

```text
/lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm.ko.zst payload:
3e82b0cac38b8e6ceda9b8a60b8034214ba37e72e6a7e920154d3bbd5e726409

/lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm-intel.ko.zst payload:
67c7cc6259ac44ad7bbf4bd82bf6b9d8083250616477cd70748a27256df7dca8
```

Binary-level proof in the rebuilt `kvm-intel.ko`:

```text
tdx_handle_exit:
  lea    -0x10010(%rsi),%rax
  cmp    $0x1,%rax
  jbe    ... <tdx_vp_vmcall_to_user path>
```

This routes both `0x10010` and `0x10011` to userspace/QEMU.

Added install/reload helper:

```text
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh
sha256: 281e5088120842b05e033b8af2d3db9a915b881853b4a0974d252659972ae03c
```

Check mode output:

```text
running kernel: 5.19.0-cofunc-tdx-5.19+
build dir: /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc
module root: /lib/modules/5.19.0-cofunc-tdx-5.19+
built kvm.ko sha256: 733ba70491b9e81077103c60e2bf904d29100cd7719b3bcb47b156b07fbb2e16
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed kvm.ko.zst payload sha256: 3e82b0cac38b8e6ceda9b8a60b8034214ba37e72e6a7e920154d3bbd5e726409
installed kvm-intel.ko.zst payload sha256: 67c7cc6259ac44ad7bbf4bd82bf6b9d8083250616477cd70748a27256df7dca8
/dev/kvm users: none detected
```

Next step:

```text
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
```

The reload step should only be run after coordinating with other lab users. It
refuses to run if `/dev/kvm` is busy.

### 2026-06-28 patched KVM modules installed and reloaded

The user ran the install/reload commands for the patched 5.19 KVM modules.

Verification:

```text
running kernel: 5.19.0-cofunc-tdx-5.19+
build dir: /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc
module root: /lib/modules/5.19.0-cofunc-tdx-5.19+
built kvm.ko sha256: 733ba70491b9e81077103c60e2bf904d29100cd7719b3bcb47b156b07fbb2e16
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed kvm.ko.zst payload sha256: 733ba70491b9e81077103c60e2bf904d29100cd7719b3bcb47b156b07fbb2e16
installed kvm-intel.ko.zst payload sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
/dev/kvm users: none detected
```

Loaded module state:

```text
/sys/module/kvm/srcversion:       BB8F56728BEBC00FC43E70C
/sys/module/kvm_intel/srcversion: 8471047B8F88FAB864A6A8F
/sys/module/kvm_intel/parameters/tdx: Y
modinfo -n kvm_intel:
/lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm-intel.ko.zst
```

Next test:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_single_putc_trap_test.sh
```

Codex could not run this directly because non-interactive sudo is unavailable
from the current session.

### 2026-06-28 single-putc retest after patched KVM reload

The user reran:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_single_putc_trap_test.sh
```

Artifacts:

```text
run dir:        /home/booklyn/cofunc-tdx/logs/single-putc-trap-20260628_015820
boot out:       /mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_single_putc_trap_20260628_015820
cleanup backup: /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260628_015952
```

Serial evidence:

```text
!!!! X64 Exception Type - 06(#UD - Invalid Opcode)  CPU Apic ID - 00000000 !!!!
RIP  - 000000000010008C
RAX  - 0000000000000000, RCX - 000000000000FC00
R10  - 0000000000000000
R11  - 0000000000000000, R12 - 0000000000000000, R13 - 0000000000000000
```

QEMU/strace evidence:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_single_putc_trap_20260628_015820/current-trace/current-qemu.strace.3449710:
01:58:23.780156 write(1, "[", 1) = 1
```

No `unknown tdg.vp.vmcall`, `unknown split-container`, `INVALID`, or `invalid`
messages were found in `current-cvm.log` or the QEMU strace files.

Hard conclusion:

- The patched 5.19 host KVM module fixed the immediate TDVMCALL routing bug.
- The first debug-putc TDVMCALL now reaches QEMU.
- QEMU handles `KVM_HC_TDX_SC_REQUEST / SC_REQ_DEBUG_PUTC`, writes `[`, and
  returns success (`R10=0`).
- This closes the previous `TDG_VP_VMCALL_INVALID_OPERAND` finding.

Cleanup evidence:

```text
cleanup time: 2026-06-28T01:59:52Z
main.c:     fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S:   62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg:   d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
kernel.img: 9abee804b865fcc6000c974cd3d537d2fb10369eeee5094fe7e889add3f09523
chcore.iso: 215fb3f96e99db214685e216a1f4520a55db7f7dbe15610992d13e0a7459a780
```

No diagnostic markers remain in `main.c`, `header.S`, or `grub.cfg`, and no
live `qemu-system`, `strace`, or diagnostic runner process remained after the
test.

Next test:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_after_asm0_trap_test.sh
```

Expected evidence if the fix generalizes to the full early putc sequence:
QEMU writes the full `[ASM0]\n` sequence and the after-ASM0 trap shows `R10=0`.

### 2026-06-28 after-ASM0 retest after patched KVM reload

The user reran:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_after_asm0_trap_test.sh
```

Latest successful evidence:

```text
run dir:        /home/booklyn/cofunc-tdx/logs/after-asm0-trap-20260628_023400
boot out:       /mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_after_asm0_trap_20260628_023400
cleanup backup: /home/booklyn/cofunc-tdx/backups/current-diagnostic-cleanup-20260628_023532
```

Serial evidence:

```text
!!!! X64 Exception Type - 06(#UD - Invalid Opcode)  CPU Apic ID - 00000000 !!!!
RIP  - 0000000000100184
RAX  - 0000000000000000, RCX - 000000000000FC00
R10  - 0000000000000000
R11  - 0000000000000000, R12 - 0000000000000000, R13 - 0000000000000000
```

QEMU log evidence:

```text
current-cvm.log:
[ASM0]
```

QEMU strace evidence:

```text
02:34:03.885304 write(1, "[", 1)  = 1
02:34:03.885348 write(1, "A", 1)  = 1
02:34:03.885390 write(1, "S", 1)  = 1
02:34:03.885431 write(1, "M", 1)  = 1
02:34:03.885474 write(1, "0", 1)  = 1
02:34:03.885515 write(1, "]", 1)  = 1
02:34:03.885556 write(1, "\n", 1) = 1
```

No `unknown tdg.vp.vmcall`, `unknown split-container`, `INVALID`, or `invalid`
messages were found in `current-cvm.log` or the QEMU strace files.

Hard conclusion:

- The patched host KVM routing fix generalizes from the first debug-putc call to
  the full early `[ASM0]\n` sequence.
- The after-ASM0 trap now sees `R10=0`, so the last TDCALL in the sequence
  returned success.
- The earlier missing `[ASM0]` output was fully explained by the missing
  `KVM_HC_TDX_SC_REQUEST` route in host KVM.

Cleanup evidence:

```text
cleanup time: 2026-06-28T02:35:32Z
main.c:     fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S:   62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg:   d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
kernel.img: 9abee804b865fcc6000c974cd3d537d2fb10369eeee5094fe7e889add3f09523
chcore.iso: 52eb0000994c0c7882d7d6c09d99a6db8c95ae65aa9ba90ab50e75ff9bdda561
```

No diagnostic markers remain in `main.c`, `header.S`, or `grub.cfg`, and no
live QEMU/strace diagnostic process remained after the test.

Next test:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

or rerun the narrow workload smoke test. The next question is whether clean
ChCore now proceeds past early boot under the original old-QEMU/5.19 ABI path,
not merely whether the diagnostic putc calls work.

### 2026-06-28 clean old-QEMU boot diagnostic after KVM routing fix

The user ran a clean, no-trap boot diagnostic:

```bash
sudo env OUT=/mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_clean_boot_20260628_034329 \
  LAUNCH_MODE=artifact-fg \
  COFUNC_QEMU_STRACE=1 \
  COFUNC_QEMU_NO_REBOOT=0 \
  COFUNC_QEMU_DEBUG=1 \
  COFUNC_CVM_BOOT_TIMEOUT=60 \
  /home/booklyn/cofunc-tdx/scripts/boot_oldqemu_chcore_diag.sh
```

Result:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldqemu_chcore_clean_boot_20260628_034329
status: current FAIL rc=124
```

Serial evidence:

```text
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
Unknown memory type 15, considering reserved
Unknown memory type 15, considering reserved
error: no suitable video mode found.
```

QEMU evidence:

```text
current-cvm.log: timeout killed QEMU after 120 seconds
current-qemu-debug.log: only CPU reset dumps; no guest exception/fault found
strace: no guest debug-putc writes; only QEMU --version output
no unknown tdg.vp.vmcall / unknown split-container / invalid VMCALL messages
```

Artifact state after the run:

```text
main.c:     fd5ba3d41fab54da32dac483688ebe05efc67e7245ae3e9ada3778a201f459ef
header.S:   62ba4b20b400ce33d26116cb173d163d4865731ddeee1ecec2f00a32dd2b5365
grub.cfg:   d77f5c38a42d582095f01f68707648781b86d14dab3956ee25f6aafa5cf0efe2
kernel.img: 9abee804b865fcc6000c974cd3d537d2fb10369eeee5094fe7e889add3f09523
chcore.iso: 52eb0000994c0c7882d7d6c09d99a6db8c95ae65aa9ba90ab50e75ff9bdda561
```

No diagnostic source markers remain.

Interpretation bounded by evidence:

- The KVM routing bug remains fixed, but this clean boot diagnostic does not
  prove a successful ChCore boot.
- The clean ISO is too silent: without the GRUB/early-putc probes, the only
  visible output is GRUB's video-mode warning and then timeout.
- There is no hard evidence of a new TDVMCALL failure or guest exception in this
  run.

Next useful test:

- Run a narrow workload smoke test through the artifact path, because that is
  the real success criterion for CoFunc reproduction.
- If it fails or times out, add a minimal no-trap progress probe after `[ASM0]`
  and before/after `main()` to locate the next stall without changing the host
  KVM path again.

### 2026-06-28 old-ABI workload smoke after KVM routing fix

The user ran:

```bash
sudo env STOP_AFTER_SMOKE=1 \
  OUT=/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_smoke_20260628_062601 \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

Result:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_smoke_20260628_062601
status: no smoke-summary.txt; run failed before summary
```

The action log says:

```text
Timed out waiting for ChCore shell after 240s
```

The same log and CVM trace show ChCore reached normal kernel initialization
before the timeout. Important hard evidence:

```text
[ChCore] uart init finished
parse multiboot2 info finished
interrupt init finished
SYSCALL init finished
mm init finished
[ChCore] configure: cr0 is 0x80010031, cr4 is 0x3706e8
Intel Turbo Boost is ENABLED.
BUG: tdx_do_wrmsr:116 on (expr) __tdx_hypercall(&args, 0)
[INFO] General Protection Fault
Trap from 0xffffffffc01235b4 EC 0 Trap No. 13
rcx: 0xfc00
```

Source mapping:

- `cvm_os/kernel/arch/x86_64/machine/cpu.c:181-197` implements
  `set_turbo_boost()`: it reads MSR `0x1a0`, prints whether Turbo Boost is
  enabled, then writes MSR `0x1a0`.
- `cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c:97-116` implements
  `tdx_do_wrmsr()`: non-direct MSRs are sent through the TDX WRMSR VMCALL, and
  any nonzero return triggers `BUG_ON`.
- The log line order strongly identifies the failing guest operation as the
  Turbo Boost write to `MSR_IA32_MISC_ENABLE` (`0x1a0`). This is evidence from
  the source and log ordering, not a measured register printout yet.

Bounded conclusion:

- The previous host KVM routing bug is not the current blocker.
- The workload path reaches ChCore proper.
- The current blocker is a guest kernel BUG during a TDX WRMSR hypercall, most
  likely the Turbo Boost `wrmsr(0x1a0, val)`.

Next diagnostic:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_msr_skip_smoke.sh
```

That helper applies a temporary old-ABI patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0001-Skip-TDX-MISC-ENABLE-wrmsr-diagnostic.patch
```

The patch skips only TDX WRMSR to MSR `0x1a0` and logs the skipped value. It
also logs `msr/value/ret` if any later TDX WRMSR still fails. The helper backs
up `tdx.c`, `kernel.img`, the runtime ISO, and the kernel-subproject ISO if
present; rebuilds the diagnostic old-ABI ISO; runs only the smoke workload; and
restores the backed-up source/images on exit.

### 2026-06-28 old-ABI Turbo WRMSR skip result

The user ran:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_msr_skip_smoke.sh
```

Result:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_msr_skip_smoke_20260628_131915
status: no smoke-summary.txt; run failed before summary
backup: /home/booklyn/cofunc-tdx/backups/oldabi-turbo-msr-skip-20260628_131915
```

Cleanup evidence:

```text
No `CoFunc diag`, `skip TDX WRMSR`, or `TDX WRMSR failed` marker remains in
old-ABI tdx.c, kernel.img, or chcore.iso after the helper restored backups.
```

Before/after restore hashes matched:

```text
tdx.c before/restored:      c291ce63f0d939568ed5ab37d59e6c892c4f3334824a980a81f3f85ed6349976
kernel.img before/restored: 08a26f5eb06ea6c2f66397a3f7b2bcd931e5ccc7c7306f3562c3372ebe1d9450
chcore.iso before/restored: 7aa54725f1f88a1683a89e9500f26beb79feb0d19194aa42c428671e1e1f68de
```

Hard evidence from the diagnostic run:

```text
[INFO] Intel Turbo Boost is ENABLED.
[CoFunc diag] skip TDX WRMSR 0x1a0 value=0x0
[INFO] [ChCore] lock init finished
[INFO] [ChCore] sched init finished
[INFO] [SMP] CPU 1 is running
...
[INFO] [SMP] CPU 15 is running
BUG: get_cpu_apic_id:136 on (expr) cpu_id < 0 || cpu_id >= madt_info.processor_count
[INFO] General Protection Fault
```

Bounded conclusion:

- Skipping `WRMSR 0x1a0` moves boot past the previous `tdx_do_wrmsr:116` BUG.
- The skipped value printed by the diagnostic was `0x0`.
- The next blocker is old-ABI SMP startup: QEMU exposes 16 vCPUs
  (`COFUNC_TDX_SMP=16`), MADT reports APIC IDs 0-15, but old-ABI ChCore loops
  up to compiled `PLAT_CPU_NUM=128` and calls `get_cpu_apic_id(16)`.

Relevant current-vs-old ABI source diff:

```text
current artifact:
  madt.c adds get_cpu_count() => madt_info.processor_count
  acpi.h declares get_cpu_count()
  smp.c uses cpu_num = MIN((int)PLAT_CPU_NUM, (int)get_cpu_count())
  enable_smp_cores() loops cpuid = 1; cpuid < cpu_num

old-ABI artifact:
  enable_smp_cores() still loops cpuid = 1; cpuid < PLAT_CPU_NUM
```

This exactly matches successful current-artifact logs, which also show only
MADT APIC IDs 0-15 and SMP CPUs 1-15 before `Welcome to ChCore shell`.

Next diagnostic:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh
```

That helper applies two temporary patches, rebuilds old-ABI ChCore, runs only
the smoke workload, and restores the source/images on exit:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0001-Skip-TDX-MISC-ENABLE-wrmsr-diagnostic.patch
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0002-Bound-old-ABI-SMP-startup-to-MADT-cpu-count.patch
```

### 2026-06-28 old-ABI Turbo WRMSR skip + SMP bound result

The user ran the next diagnostic. The newest run inspected was:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_smoke_20260628_151113
backup: /home/booklyn/cofunc-tdx/backups/oldabi-turbo-smp-bound-20260628_151113
status: no smoke-summary.txt; run failed before summary
```

Important progress:

```text
[INFO] [SMP] CPU 15 is running
[INFO] [ChCore] boot smp
[INFO] [ChCore] create initial thread done
Welcome to ChCore shell!
```

Bounded conclusion:

- The SMP CPU-count bound moved boot past the previous
  `get_cpu_apic_id(16)` BUG.
- The old-ABI ChCore kernel now reaches the shell under old QEMU + 5.19 with
  the temporary Turbo WRMSR skip and SMP-bound patches.
- The smoke still fails before writing `smoke-summary.txt`.

New hard blocker:

```text
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi/testcases/testcases/fn_py_face_detection/exec_log

mode runc-sc-snapshot
t_begin 1782659489.7399968
t_runc_init 1782659490.0161239
[SC-D] assert failed: 0 at /runtime/main.c:1417
```

The action log stops before `lean_container/start.sh` can create
`smoke-log/fn_py_face_detection/sc_fork.log`, so the failure is in the
snapshot stage:

```text
action.sh sequence:
  cvm.sh
  sc-snapshot.sh
  lean_container/start.sh sc-fork ...

sc-snapshot.sh waits for "snapshot done", but the shadow runtime asserts first.
```

Source mapping:

- Current-artifact `shadow_container/main.c:1417` is the default assert in the
  `switch (get_vmcall_op(run))` loop after `KVM_RUN`.
- Current-artifact shadow runtime reads TDX requests from `run->hypercall.*`
  and also handles newer `KVM_HC_MAP_GPA_RANGE`.
- Old-ABI shadow runtime source reads TDX requests from
  `run->tdx.u.vmcall.*`.
- Old-ABI `shadow_container/config.h` currently says:

  ```text
  #define CONFIG_PLAT_AMD_SEV
  ```

Interpretation:

- This looks like the snapshot container is running a shadow runtime built for
  the newer/current ABI, or otherwise not built as the old-ABI Intel TDX shadow
  runtime.
- Rebuilding only `split_container_builder:latest` is not sufficient because
  workload images copy `/runtime/runtime` into `/bin/sc-runtime` at image build
  time through `testcases/tools/Dockerfile`.

Prepared next diagnostic:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0003-Use-TDX-shadow-runtime-config-diagnostic.patch
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

Validation:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
patch --dry-run -d /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi -p1 \
  -i /home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0003-Use-TDX-shadow-runtime-config-diagnostic.patch
```

Both passed. The dry-run printed only the expected read-only warning from the
sandboxed check.

Run:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

What the helper does:

- Temporarily changes old-ABI `shadow_container/config.h` from AMD SEV to Intel
  TDX.
- Tags the current Docker images so their `latest` tags can be restored:
  `split_container_builder`, `fn_py_face_detection`, and
  `fn_py_face_detection_base` if present.
- Rebuilds `split_container_builder:latest` from the old-ABI TDX shadow runtime.
- Rebuilds the `fn_py_face_detection` image so `/bin/sc-runtime` comes from the
  old-ABI TDX builder.
- Runs the existing Turbo-WRMSR-skip + SMP-bound smoke helper.
- Restores the old-ABI shadow-runtime source and Docker image tags on exit.

### 2026-06-28 old-ABI TDX shadow runtime smoke result

The user ran:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

Result inspected:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_smoke_20260628_160715
backup: /home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260628_160715
status: no smoke-summary.txt; run failed before summary
```

Progress:

- The previous snapshot-stage shadow runtime assert is gone.
- The run reached `lean-sc-fork`, so the temporary old-ABI TDX shadow runtime
  rebuild and workload image rebuild moved execution past `sc-snapshot.sh`.

Hard evidence from the attempt log:

```text
child pid: -1, expected: 344385
t_launch_begin 1782662896.329906
open mem file: No such file or directory
/dev/hugepages/split_container/fn_py_face_detection_1
Traceback ...
KeyError: 't_shadow_begin'
```

Fresh testcase `exec_log`:

```text
mode lean-sc-fork
child pid: -1, expected: 344385
t_launch_begin 1782662896.329906
/dev/hugepages/split_container/fn_py_face_detection_1
Killed
```

Interpretation:

- The next blocker is missing hugepage/memfile setup for `lean-sc-fork`.
- The old-ABI `testcases/tools/tasks/run_sc_fork/action.sh` still had
  `hugepage.sh` commented out, while the forward-ported artifact enables
  `hugepage.sh` and cleans it via an EXIT trap.
- Because `/bin/sc-runtime -m /dev/hugepages/split_container/<fn>_1 ...`
  expects that file, the old-ABI smoke fails before `t_shadow_begin`.

Prepared follow-up patch:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0004-Enable-hugepage-setup-for-old-ABI-run-sc-fork.patch
```

Updated helper:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

The helper now also temporarily applies the old-ABI `run_sc_fork` hugepage
setup patch and restores `action.sh` on exit. Validation passed:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
patch --dry-run -d /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi -p1 \
  -i /home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0004-Enable-hugepage-setup-for-old-ABI-run-sc-fork.patch
```

Next run:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

### 2026-06-28 old-ABI TDX shadow runtime + hugepage smoke success

The user reran the updated helper:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

Result:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_smoke_20260628_162554
backup: /home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260628_162554
status: smoke-summary.txt produced
```

Important hard evidence:

```text
smoke-log/fn_py_face_detection/sc_fork.log:
{"timestamp": 1782663976.3339605, "t_boot_lean": 0.010483980178833008,
 "t_boot_sc": 0.046607017517089844, "t_boot_func": 0.012601613998413086,
 "t_exec": 2.1042304039001465, "t_e2e": 2.1739230155944824,
 "n_hcalls_exec": 1541, "n_cow": 3397,
 "t_encrypt_exec": 0.00719724, "t_grant_exec": 0.605986202,
 "t_delegate_exec": 0.0, "t_attest_import": 1.248e-05,
 "t_grant_import": 0.02562484, "t_delegate_import": -1e-09}
```

Summary:

```text
Function                 TDX_CoFunc_fork(s)  Artifact_C(s)  actual/expected
fn_py_face_detection                  2.174          0.617            3.523
Avg ratio                                            3.523
```

Bounded conclusion:

- The old-ABI path can now execute the face-detection CoFunc fork smoke under
  old QEMU + 5.19 using temporary diagnostics:
  - skip TDX WRMSR to `MSR_IA32_MISC_ENABLE` (`0x1a0`);
  - bound SMP startup to MADT CPU count;
  - build the shadow runtime as old-ABI Intel TDX;
  - enable hugepage setup in old-ABI `run_sc_fork`.
- This confirms the previous missing-hugepage blocker is fixed for the smoke.
- The result is still much slower than the paper/artifact target
  (`2.174s` actual vs `0.617s` artifact C target for face detection), consistent
  with the earlier forward-port performance gap.

Cleanup evidence:

```text
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260628_162554/sha256.before
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260628_162554/sha256.restored
```

The before/restored hashes match for:

```text
shadow_container/config.h
testcases/tools/tasks/run_sc_fork/action.sh
```

Post-run source search shows old-ABI `run_sc_fork/action.sh` is restored to the
commented hugepage lines:

```text
# $tools/hugepage.sh
# $tools/hugepage.sh clean
```

Next useful step:

- Run a full old-ABI Fig. 11 subset helper that applies the same temporary
  fixes, rebuilds all selected workload images with the old-ABI TDX shadow
  runtime, and runs without `STOP_AFTER_SMOKE=1`.

Prepared after the successful smoke:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

Also updated:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh
```

Validation passed:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh
```

Full run command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

The full wrapper defaults to:

```text
STOP_AFTER_SMOKE=0
OUT=/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_<timestamp>
```

It rebuilds all selected Fig. 11 workload images so `/bin/sc-runtime` comes
from the temporary old-ABI Intel TDX shadow runtime. To run a smaller subset,
set `COFUNC_OLDABI_RUNTIME_WORKLOADS` to a whitespace-separated list accepted by
`run_oldabi_5_19_fig11.sh`, for example:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="fn_py_compression fn_py_face_detection" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

2026-06-28 follow-up: the first attempted full wrapper run did not create a
`oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_*` result directory. Codex found
and fixed a helper bug: the full-run refactor left an obsolete `$WORKLOAD`
reference under `set -u`, so the script could exit before creating the runtime
backup/result directory. The stale reference has been removed.

Revalidated after the fix:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
rg -n '\$WORKLOAD|WORKLOAD=' ...  # only DEFAULT_WORKLOAD remains
```

Rerun the same full command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

### 2026-06-29 full old-ABI TDX runtime wrapper attempt

The user reran:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

Result inspected:

```text
status: no oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_* result directory
backup: /home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260629_014002
```

Evidence from the backup:

```text
diagnostic images written:
  split_container_builder
  fn_py_compression
  fn_py_face_detection
  fn_py_image_processing

docker image tags backed up through:
  fn_py_sentiment
  fn_py_sentiment_base
```

Bounded conclusion:

- The wrapper exited before invoking the nested old-ABI ChCore/QEMU runner.
- The stop point was during the `fn_py_sentiment` image rebuild or immediately
  after it, before `fn_py_sentiment.diagnostic` could be written.
- There was no persistent per-workload build log from this attempt.
- `fn_py_sentiment/tools` was left behind with timestamp `2026-06-29 01:41:44`,
  which means the artifact `build.sh` copied its temporary tools directory and
  then failed before its final `rm -r tools`.

Follow-up wrapper hardening:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

Changes:

- Remove a leftover generated workload `tools/` directory before rebuilding
  that workload image.
- Remove generated workload `tools/` directories during wrapper cleanup.
- Tee build output into the timestamped backup directory:
  - `split_container_builder.build.log`
  - `<image>.build.log`

Validation:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

Rerun the same full command. If it fails again before creating a Fig. 11 result
directory, inspect the newest backup's `*.build.log` file, especially
`fn_py_sentiment.build.log`.

The user pasted the terminal output from the failing attempt. The actual
failure was:

```text
fn_py_sentiment Dockerfile:
  RUN pip install textblob

pip repeatedly timed out connecting to the hardcoded proxy:
  202.120.40.82:11235
```

This failure happens in the workload base-image rebuild, not in the final layer
that injects `/bin/sc-runtime` from `split_container_builder`.

Follow-up fix in the wrapper:

- If `<image>_base:latest` already exists, reuse it and rebuild only the final
  workload image layer with:

  ```text
  docker build -t <image> -f tools/Dockerfile --build-arg BASE_NAME=<image>_base .
  ```

- Fall back to the original full workload rebuild only if the base image is
  missing.

This should avoid the hardcoded `textblob` proxy path for `fn_py_sentiment` and
similar dependency-download rebuilds. Revalidated:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

### 2026-06-29 full old-ABI TDX runtime wrapper success

The user reran:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

Result:

```text
out:    /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_020731
backup: /home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260629_020731
kernel: 5.19.0-cofunc-tdx-5.19+
qemu:   QEMU emulator version 7.0.90
status: tdx_sc_fork_summary.txt produced
```

The wrapper successfully reused existing workload base images and rebuilt only
the final workload layers. Each build log starts with `using existing
<image>_base:latest; rebuilding final <image> layer only`, including
`fn_py_sentiment`, so the hardcoded `textblob` proxy path was avoided.

Summary:

```text
Function                 TDX_CoFunc_fork(s)  Artifact_C(s)  actual/expected
fn_py_compression                  3.039          0.685            4.436
fn_py_face_detection               2.150          0.617            3.485
fn_py_image_processing            12.617          4.537            2.781
fn_py_sentiment                    0.258          0.014           18.448
fn_py_video_processing            62.642         28.930            2.165
fn_py_dna_visualisation           26.439          9.395            2.814
fn_js_thumbnailer                  0.730          0.193            3.782
fn_js_uploader                     1.222          0.221            5.531
chain_js_alexa                     1.171          0.156            7.505
Avg ratio                                                          5.661
```

Run parameters:

```text
fn_py_compression 20
fn_py_face_detection 20
fn_py_image_processing 20
fn_py_sentiment 20
fn_py_video_processing 5
fn_py_dna_visualisation 10
fn_js_thumbnailer 20
fn_js_uploader 20
chain_js_alexa/fn_js_alexa_frontend 20
chain_js_alexa/fn_js_alexa_interact 20
chain_js_alexa/fn_js_alexa_smarthome 20
chain_js_alexa/fn_js_alexa_tv 20
```

Cleanup evidence:

- Old-ABI shadow runtime source hashes before/restored matched for
  `shadow_container/config.h` and `testcases/tools/tasks/run_sc_fork/action.sh`.
- Nested Turbo/SMP diagnostic source and image hashes before/restored matched
  for `tdx.c`, `smp.c`, `madt.c`, `acpi.h`, `kernel.img`, and `chcore.iso`.
- No generated workload `tools/` directories remained under
  `cofunc-artifact-oldabi/testcases/testcases`.
- No leftover `qemu-system`, `sc-runtime`, `run_oldabi`, or CVM `screen`
  processes were found after the run, aside from Codex's own inspection command.

Important warning:

- The workload run completed and wrote summaries, but `dmesg-final.log` captured
  48 host kernel reports of:

  ```text
  BUG: Bad page state ... page dumped because: PAGE_FLAGS_CHECK_AT_PREP flag(s) set
  ```

- These occurred around `2026-06-29 02:22:24` to `02:22:27 UTC` in
  `qemu-system-x86` and `sc-runtime`, with call traces through KVM/TDX page
  fault paths such as `hva_to_pfn`, `kvm_faultin_pfn`,
  `kvm_mmu_page_fault`, and `tdx_handle_exit`.
- The normal GRUB serial warning `error: no suitable video mode found` appeared
  once per CVM trace and is not new.

Bounded conclusion:

- Full old-ABI 5.19 + old-QEMU workload execution now works end to end with the
  temporary diagnostics:
  - skip TDX WRMSR to `MSR_IA32_MISC_ENABLE`;
  - bound old-ABI SMP startup to MADT CPU count;
  - build the old-ABI shadow runtime as Intel TDX;
  - enable old-ABI `run_sc_fork` hugepage setup;
  - reuse existing workload base images while refreshing `/bin/sc-runtime`.
- Numeric reproduction still does not match the paper/artifact targets. The
  average ratio is `5.661x`, worse than the earlier forward-port Fig. 11 ratio.
- The host `Bad page state` reports are a new important investigation target
  before treating this 5.19 old-ABI run as clean enough for final comparison.

### 2026-06-29 Bad page state / THP investigation setup

Initial investigation of the `Bad page state` reports:

- The reports occur during the Alexa chain, between:

  ```text
  chain_js_alexa/fn_js_alexa_frontend/sc_fork.log  2026-06-29T02:22:14Z
  dmesg Bad page state burst                         2026-06-29T02:22:24-27Z
  chain_js_alexa/fn_js_alexa_interact/sc_fork.log   2026-06-29T02:22:31Z
  ```

- The stack repeatedly goes through:

  ```text
  do_huge_pmd_anonymous_page
  __get_user_pages
  hva_to_pfn
  kvm_faultin_pfn
  kvm_mmu_page_fault
  tdx_handle_exit
  ```

- The dumped page flags are:

  ```text
  referenced|node=0|zone=2|lastcpupid=0x1fffff
  page dumped because: PAGE_FLAGS_CHECK_AT_PREP flag(s) set
  ```

- The CoFunc kernel patch mostly changes VM/VCPU ownership and idle VCPU reuse;
  it does not directly manipulate page flags. The current suspect is the older
  TDX/KVM private/shared memory path interacting with anonymous transparent huge
  pages, not the split-container idle-list patch itself.

Prepared diagnostic helper:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

What it does:

- saves the active `/sys/kernel/mm/transparent_hugepage/enabled` mode;
- sets it to `never` for one diagnostic run;
- calls the existing old-ABI TDX runtime Fig. 11 wrapper;
- restores the previous THP mode on exit.

Also updated:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

It now honors `COFUNC_OLDABI_RUNTIME_WORKLOADS` so short A/B subsets can run,
instead of always running the full Fig. 11 workload list. It also records THP
state and the selected workload list in `run-env.txt`.

Validation:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

Suggested first A/B run:

```bash
sudo env COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

Compare this result against the prior full run's Alexa frontend/interact metrics
and check the new `dmesg-final.log` for `BUG: Bad page state`. If the warning
disappears and timing changes materially, THP is likely connected to both the
host warning and the performance gap. If the warning remains, focus next on TDX
private-page unpin/drop paths.

### 2026-06-29 First THP-never attempt result

User ran the suggested Alexa-only THP diagnostic:

```bash
sudo env COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

Result directory:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_thp_never_20260629_024556
```

This run is not a valid Alexa A/B point:

- `run-env.txt` confirms THP was set to `never` during the run and restored to
  the previous host mode afterward.
- The main workload params contained only the two Alexa functions, but the
  lower-level runner always starts with `fn_py_face_detection x1` as a smoke
  action.
- The temporary runtime wrapper rebuilt only the selected Alexa images, so the
  mandatory face smoke did not get the temporary old-ABI TDX `/bin/sc-runtime`.
- The run stopped at the smoke action after the 1200 second timeout:

  ```text
  run-fn_py_face_detection-1.log ... Terminated
  ```

Fresh host warning signal from this run:

- New `Bad page state` reports appeared at `2026-06-29 02:46:13 UTC`, not just
  the previous `02:22:27` lines left in the kernel ring buffer.
- In this attempt, the fresh reports were in process `tee` while allocating the
  hugetlb pool:

  ```text
  alloc_buddy_huge_page
  alloc_fresh_huge_page
  alloc_pool_huge_page
  __nr_hugepages_store_common
  hugetlb_sysctl_handler_common
  proc_sys_write
  ```

- The ChCore/QEMU trace also showed many `2M reject reason` lines during boot
  with THP forced to `never`.

Follow-up fix applied:

- Updated
  `/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh`
  so the temporary image rebuild set always includes `fn_py_face_detection`,
  because that smoke action always runs before the main selected workload list.
- Validation:

  ```text
  bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
  ```

Next retry: rerun the same Alexa-only THP-never command above. The retry should
rebuild `fn_py_face_detection` plus the two selected Alexa images, allowing the
smoke to use the temporary old-ABI TDX runtime and letting the diagnostic reach
the intended Alexa workload pair.

### 2026-06-29 THP-never retry results

Two valid Alexa-only THP-never retries were produced after the smoke-image fix:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_thp_never_20260629_031956
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_thp_never_20260629_032721
```

Both reached the mandatory smoke and both selected Alexa functions:

```text
fn_py_face_detection x1
chain_js_alexa/fn_js_alexa_frontend x20
chain_js_alexa/fn_js_alexa_interact x20
```

The summary helper prints an empty main table for this subset because it expects
Fig. 11 aggregate names, but the raw `sc_fork.log` JSON is complete. Raw average
`t_e2e` comparison:

```text
run                 frontend avg   interact avg   frontend+interact
full-020731         0.146165s      0.289629s      0.435794s
thp-never-031956    0.145091s      0.279465s      0.424557s
thp-never-032721    0.146876s      0.284702s      0.431578s
```

Interpretation:

- Disabling THP did not materially change the Alexa frontend/interact timings.
- Disabling THP did not eliminate `Bad page state`.
- `dmesg-final.log` bad-page report counts:

  ```text
  full-020731       48
  thp-never-031956  53
  thp-never-032721  65
  ```

- The first retry reported fresh bad pages at `2026-06-29 03:21:47 UTC`, mostly
  in `sc-runtime`, then in `sqlx-sqlite-wor`.
- The second retry reported fresh bad pages at `2026-06-29 03:27:36 UTC` in
  `tar`, then a large suppressed burst at `03:28:37 UTC`:

  ```text
  BUG: Bad page state: 82471 messages suppressed
  ```

  with visible reports in unrelated host processes such as `node`, `git`, and
  `sudo`.

Bounded conclusion:

- Anonymous THP is not the main cause of the host bad-page corruption or the
  performance gap. The problem still appears with THP set to `never`.
- The stronger suspect is now old Intel TDX private/shared page lifecycle or
  KVM page release/unpin/accounting around CoFunc/sc-runtime memory setup,
  possibly affecting later host allocations.

Operational note:

- After the retries, the host THP mode was observed as:

  ```text
  always madvise [never]
  ```

  This likely happened because one retry started while THP was already `never`,
  so the wrapper restored to its observed starting mode. Restore the normal host
  mode with:

  ```bash
  echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
  ```

Follow-up safety fix:

- Updated
  `/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh`
  to write `thp-wrapper-state.txt` in the result directory and support an
  explicit restore override via `COFUNC_THP_RESTORE_MODE=madvise`.
- Validation:

  ```text
  bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
  ```

### 2026-06-29 private memfile invalidation hypothesis

After THP was ruled out as the main cause, inspected the active 5.19 source:

```text
/mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot
```

Relevant findings:

- `tdx_sept_set_private_spte()` pins private guest pages with `get_page()`.
- `tdx_sept_drop_private_spte()` removes the private page from the TDX module,
  does `TDH.PHYMEM.PAGE.WBINVD`, then calls `tdx_unpin()`.
- The host CoFunc patch does not directly manipulate page flags.
- The private memory backing is the early 2022 `MFD_INACCESSIBLE` /
  `memfile_notifier` implementation, not the later upstream private-fd code.

Potential bug found in `virt/kvm/kvm_main.c`:

```c
if (end < slot->base_gfn + base_pgoff ||
    start > slot->base_gfn + base_pgoff + slot->npages)
        return;
```

`start` and `end` are shmem file offsets, but this check mixes in
`slot->base_gfn`. If a private memslot has a nonzero guest GPA base, the
invalidation can be missed or clipped incorrectly, leaving stale private SPTEs
after page-cache removal. That is consistent with later allocator-side
`BUG: Bad page state` reports.

Prepared diagnostic host-kernel patch:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0003-Fix-private-memfile-invalidate-offset-translation.patch
sha256: 5220ea9c8afd3d53a4a27214d177113552e02767ae22afdda04a876c835c6e7a
```

Dry-run result:

```text
patch --dry-run -d /mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot -p1 -i /home/booklyn/cofunc-tdx/patches/host-kernel/0003-Fix-private-memfile-invalidate-offset-translation.patch
File virt/kvm/kvm_main.c is read-only; trying to patch anyway
checking file virt/kvm/kvm_main.c
```

Added build helper:

```text
/home/booklyn/cofunc-tdx/scripts/build_5_19_private_mem_invalidate_fix.sh
```

Validation:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/build_5_19_private_mem_invalidate_fix.sh
/home/booklyn/cofunc-tdx/scripts/build_5_19_private_mem_invalidate_fix.sh --check

state: not-applied
mount: ro,nosuid,nodev,relatime
```

Suggested next commands:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_private_mem_invalidate_fix.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
```

Then run the small Alexa subset:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

Expected diagnostic readout:

- If `Bad page state` disappears or drops sharply, the stale private memfile
  invalidation path is likely a real contributor.
- If bad pages remain similar, keep this patch in mind but move to the next A/B:
  disabling CoFunc idle-vCPU reuse while preserving VMCALL routing.

### 2026-06-29 private memfile invalidation retest

The user applied, rebuilt, installed, and reloaded the private memfile
invalidation patch.

Verification:

```text
/home/booklyn/cofunc-tdx/scripts/build_5_19_private_mem_invalidate_fix.sh --check
state: applied
mount: ro,nosuid,nodev,relatime

/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check
built kvm.ko sha256: 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
installed kvm.ko.zst payload sha256: 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
```

Live module state:

```text
/sys/module/kvm/srcversion: ED3E0B888F2851473A9EEFB
/sys/module/kvm_intel/srcversion: 8471047B8F88FAB864A6A8F
/sys/module/kvm_intel/parameters/tdx: Y
```

Two Alexa subset runs appeared:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_045434
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_045547
```

Bad-page counts:

```text
run                 bad pages   suppressed   process breakdown
045434              64          1            47 cmake, 12 sh, 3 rs:main, 1 git
045547              48          0            48 qemu-system-x86
pre-patch full      48          0            44 sc-runtime, 4 qemu-system-x86
thp-never 031956    53          0            20 sc-runtime, 33 sqlx-sqlite-wor
thp-never 032721    66          1            35 sudo, 13 node, 12 git, 5 tar
```

The cleanest post-patch stack is the second run, where all 48 reports are in
`qemu-system-x86` at `2026-06-29 04:56:08 UTC`:

```text
do_huge_pmd_anonymous_page
__handle_mm_fault
handle_mm_fault
__get_user_pages
get_user_pages_unlocked
hva_to_pfn [kvm]
kvm_faultin_pfn [kvm]
direct_page_fault [kvm]
kvm_mmu_page_fault [kvm]
tdx_handle_exit [kvm_intel]
kvm_arch_vcpu_ioctl_run [kvm]
```

Representative page flags:

```text
flags: 0x17ffffc0000002(referenced|node=0|zone=2|lastcpupid=0x1fffff)
page dumped because: PAGE_FLAGS_CHECK_AT_PREP flag(s) set
```

Alexa timings did not materially improve:

```text
run                 frontend avg   interact avg
pre-patch full      0.146165s      0.289629s
thp-never 031956    0.145091s      0.279465s
thp-never 032721    0.146876s      0.284702s
post-patch 045434   0.144054s      0.295339s
post-patch 045547   0.144394s      0.284286s
```

Conclusion:

- The private memfile invalidation bug is real-looking source hygiene, but it
  did not remove the observed bad-page behavior or close the performance gap.
- The stack and flags now point more directly at KVM's normal PFN release /
  accessed-bit path for pages faulted by `hva_to_pfn()`.

Prepared next diagnostic patch:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0004-Diagnostic-skip-KVM-accessed-mark-on-pfn-release.patch
sha256: 7e7c3817a751c03a5622aba6d04d636733bf5e01b84cdde7197200d912336379
```

It changes `kvm_set_page_accessed()` into a diagnostic no-op, so KVM no longer
calls `mark_page_accessed()` when releasing a clean PFN.

Added helper:

```text
/home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_accessed_mark.sh
```

Validation:

```text
bash -n /home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_accessed_mark.sh
/home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_accessed_mark.sh --check
state: not-applied
patch --dry-run ... 0004-Diagnostic-skip-KVM-accessed-mark-on-pfn-release.patch
Hunk #1 succeeded at 3098 (offset 1 line).
```

Suggested next commands:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_accessed_mark.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

## 2026-06-29 Update: 0004 Did Not Remove Bad Pages

The skip-`kvm_set_page_accessed()` diagnostic was applied, built, installed,
and reloaded on top of 0003. The live module state after reload was:

```text
live kvm srcversion 8313D7C608129AEC0BF4BDE
live kvm_intel srcversion 8471047B8F88FAB864A6A8F
tdx Y
```

Result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_050935
```

Bad-page summary:

```text
bad_page=50
processes=36 tar; 14 node
flags=referenced|node=0|zone=2|lastcpupid=0x1fffff
```

The reports now surface mostly during ordinary file/page-cache allocations
(`tar`, `node`) at the first CVM launch, but still show
`PAGE_FLAGS_CHECK_AT_PREP` with `referenced` set. Alexa timings were essentially
unchanged:

```text
pre-patch full       frontend 0.146165s   interact 0.289629s
post-0003 045547     frontend 0.144394s   interact 0.284286s
post-0004 050935     frontend 0.145065s   interact 0.282436s
```

Conclusion: 0004 did not fix either bad-page reports or the performance gap.

## 2026-06-29 Update: 2M TDX Accept Rejections

The old-ABI ChCore path has `CHCORE_SPLIT_CONTAINER_HPAGE=ON` and therefore
uses `ACCEPT_PAGE_SIZE=HPAGE_SIZE` in:

```text
/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact-oldabi/cvm_os/kernel/split-container/split_container.c
```

That calls `tdx_enc_status_changed_phys()` over 2MB ranges. In
`plat/intel_tdx/tdx.c`, each range tries 1G, then 2M, then falls back to 4K.
The observed log lines:

```text
2M reject reason: 0xc0000b0b00000001, <gpa>, 1
```

mean the 2MB `TDX_ACCEPT_PAGE` attempt failed and the guest fell back to 4KB
accepts. In the 050935 Alexa subset, the run logs include repeated rejected 2MB
accepts:

```text
fn_py_face_detection smoke: 28
alexa frontend x20:       80
alexa interact x20:       140
```

Prepared an opt-in diagnostic to bypass the rejected 2MB attempts and accept in
4KB chunks from the start:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0005-Diagnostic-force-4K-split-container-accept.patch
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_4k_accept.sh
```

The wrapper sets `COFUNC_OLDABI_FORCE_4K_ACCEPT=1`; the existing old-ABI helper
temporarily applies the patch, rebuilds the ChCore ISO, runs the same runtime
rebuild path, then restores source/images.

Suggested next subset run. Reverse 0004 first so this test is not compounded
with the no-op `kvm_set_page_accessed()` diagnostic; this leaves 0003 applied.

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_accessed_mark.sh --reverse-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_4k_accept.sh
```

## 2026-06-29 Update: 4K Accept Diagnostic Regressed Performance

The suggested run completed:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_4k_accept_20260629_051952
```

Host-side state before the run was clean for this comparison:

```text
0004 skip-kvm-accessed state: not-applied
built/installed kvm.ko payload sha256: 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
```

The helper did use the 4K diagnostic:

```text
/home/booklyn/cofunc-tdx/backups/oldabi-turbo-smp-bound-20260629_051956/options
cofunc_oldabi_force_4k_accept=1
```

The wrapper restored guest source/images afterward. Current
`split_container.c` is back to the normal conditional:

```text
#ifdef CHCORE_SPLIT_CONTAINER_HPAGE
#define ACCEPT_PAGE_SIZE HPAGE_SIZE
#else
#define ACCEPT_PAGE_SIZE PAGE_SIZE
#endif
```

Raw JSON timing comparison:

```text
run                  workload     avg e2e     avg exec    avg grant_exec  2M rejects
pre-full-020731      frontend     0.146165    0.091800    0.025873        80
post-0003-045547     frontend     0.144394    0.090800    0.025811        80
post-0004-050935     frontend     0.145065    0.091350    0.025888        80
4k-accept-051952     frontend     0.194862    0.138850    0.069580        20

pre-full-020731      interact     0.289629    0.237150    0.102961        140
post-0003-045547     interact     0.284286    0.231000    0.103194        140
post-0004-050935     interact     0.282436    0.229550    0.102819        140
4k-accept-051952     interact     0.362853    0.310250    0.172546        20

pre-full-020731      face-smoke   2.183405    2.106611    0.608479        28
post-0003-045547     face-smoke   2.151474    2.088373    0.606914        28
post-0004-050935     face-smoke   2.170182    2.093669    0.600560        28
4k-accept-051952     face-smoke   2.721648    2.650730    1.047162        3
```

Conclusion:

- Forcing 4KB split-container accepts reduced rejected 2MB accept attempts, but
  made execution/grant time much worse.
- It also did not remove host bad-page reports:

```text
4k-accept-051952 bad_page=56
processes=51 systemd-journal; 5 dockerd
flags=dirty|node=0|zone=2|lastcpupid=0x1fffff
```

Do not pursue the 4K-accept diagnostic as a performance fix. The bad pages still
look like pages returned to the buddy allocator with stale flags, and the
culprit is likely elsewhere in the old 5.19 TDX/private-page lifecycle rather
than in the failed 2MB accept fallback itself.

Runner hygiene update:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh
```

Now records `run-start.txt` and, at cleanup, writes
`kernel-journal-since-start.log` using `journalctl -k --since @<epoch>` when
available. This is non-destructive and avoids `dmesg -C`, while making future
bad-page attribution cleaner than `dmesg-final.log` alone.

## 2026-06-29 Update: Normal Subset With Per-Run Kernel Journal

A clean normal Alexa subset was run after reversing 0004 and after the 4K-accept
diagnostic had restored source/images:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_054917
```

Run start:

```text
run_start_utc=2026-06-29T05:49:22Z
selected_workloads=chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact
```

Timing was back to the stable post-0003 baseline:

```text
run                  workload     avg e2e     avg exec    avg grant_exec  2M rejects
post-0003-045547     frontend     0.144394    0.090800    0.025811        80
post-0004-050935     frontend     0.145065    0.091350    0.025888        80
normal-054917        frontend     0.145086    0.091300    0.025814        80

post-0003-045547     interact     0.284286    0.231000    0.103194        140
post-0004-050935     interact     0.282436    0.229550    0.102819        140
normal-054917        interact     0.282849    0.229500    0.103175        140

post-0003-045547     face-smoke   2.151474    2.088373    0.606914        28
post-0004-050935     face-smoke   2.170182    2.093669    0.600560        28
normal-054917        face-smoke   2.186045    2.117790    0.610967        28
```

The new per-run journal confirmed the bad-page reports occur during this run:

```text
kernel-journal-since-start.log explicit bad_page=61
first explicit: Jun 29 05:49:33, process tee
main burst:     Jun 29 05:49:36, process qemu-system-x86
processes:      qemu-system-x86=59, tee=1
dominant flags: referenced
```

Important new clue: the very first in-window bad page is not in QEMU. It is in
`tee` while `hugepage.sh` writes `/proc/sys/vm/nr_hugepages`, with stack:

```text
alloc_buddy_huge_page.isra.0
alloc_fresh_huge_page
alloc_pool_huge_page
__nr_hugepages_store_common
hugetlb_sysctl_handler_common
proc_sys_write
vfs_write
```

Then QEMU surfaces the same pattern while allocating THP-backed memory for KVM:

```text
do_huge_pmd_anonymous_page
__get_user_pages
hva_to_pfn [kvm]
kvm_faultin_pfn [kvm]
kvm_mmu_page_fault [kvm]
tdx_handle_exit [kvm_intel]
```

The journal also begins with:

```text
BUG: Bad page state: 282 messages suppressed
```

This strengthens the interpretation that large-page allocation is exposing pages
already returned to the buddy allocator with stale flags. The current trace does
not yet prove where the pages were contaminated.

Added a no-CVM/no-Docker probe:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_hugepage_only_probe.sh
```

It runs only `testcases/tools/hugepage.sh` for a workload, captures
`kernel-journal-since-start.log`, records meminfo/nr_hugepages before/after,
and cleans up hugepages.

Suggested next command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_hugepage_only_probe.sh fn_py_face_detection
```

If the hugepage-only probe also reports bad pages, then a CVM launch is not
needed to expose the contaminated free pages. A stronger follow-up would be a
fresh reboot followed by this hugepage-only probe before any TDX/CVM run.

## 2026-06-29 Update: Hugepage-Only Probe Results

Two hugepage-only probes were run:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_hugepage_only_probe_fn_py_face_detection_20260629_060453
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_hugepage_only_probe_fn_py_face_detection_20260629_060504
```

Both allocated and then cleaned 256 2MB hugetlb pages for `fn_py_face_detection`
(`memory_mb=512`):

```text
before:      HugePages_Total=0
after alloc: HugePages_Total=256, HugePages_Free=0
after clean: HugePages_Total=0
```

Use `kernel-journal-since-start.log` for these probes. `dmesg-final.log` still
contains stale QEMU reports from the previous normal subset.

Probe 060453 did surface bad pages without launching a CVM or Docker workload:

```text
kernel-journal-since-start.log
explicit_bad=2
suppressed=202
process=tee
flags:
  referenced|node=0|zone=2|lastcpupid=0x1fffff
  referenced|dirty|node=0|zone=2|lastcpupid=0x1fffff
```

Stack:

```text
alloc_buddy_huge_page.isra.0
alloc_fresh_huge_page
alloc_pool_huge_page
__nr_hugepages_store_common
hugetlb_sysctl_handler_common
proc_sys_write
vfs_write
```

The immediate second probe, 060504, was clean:

```text
kernel-journal-since-start.log: -- No entries --
explicit_bad=0
suppressed=0
```

Interpretation:

- A CVM launch is not required to expose the contaminated free pages; allocating
  hugetlb pages alone can do it.
- The clean second probe suggests the first hugepage-only allocation consumed
  and/or scrubbed the currently available contaminated pages.
- This still does not identify the original contaminator. The next useful check
  is to run the normal Alexa subset immediately after this clean hugepage-only
  probe. If bad pages reappear, the normal CoFunc/TDX path is likely
  recontaminating pages. If it stays clean, the previous bad pages may have been
  residue from earlier diagnostics.

Suggested next command:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

## 2026-06-29 Update: Normal Subset After Clean Hugepage Probe

The normal Alexa subset was run immediately after the clean 060504 hugepage-only
probe:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_061050
```

State stayed clean:

```text
0004 skip-kvm-accessed state: not-applied
kvm.ko payload sha256: 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
```

Timing stayed at the stable baseline:

```text
run                  workload     avg e2e     avg exec    avg grant_exec  2M rejects
normal-054917        frontend     0.145086    0.091300    0.025814        80
normal-after-clean   frontend     0.142474    0.091000    0.025806        80

normal-054917        interact     0.282849    0.229500    0.103175        140
normal-after-clean   interact     0.281524    0.230300    0.103329        140

normal-054917        face-smoke   2.186045    2.117790    0.610967        28
normal-after-clean   face-smoke   2.168470    2.098075    0.606149        28
```

Bad pages reappeared in the first CVM launch:

```text
run_start_utc=2026-06-29T06:10:54Z
first CVM launch-env mtime=2026-06-29T06:11:06Z
bad-page window=Jun 29 06:11:08 - Jun 29 06:11:09
explicit_bad=118
suppressed=0
process=qemu-system-x86
dominant flags=referenced
```

Representative stack:

```text
do_huge_pmd_anonymous_page
__get_user_pages
hva_to_pfn [kvm]
kvm_faultin_pfn [kvm]
kvm_mmu_page_fault [kvm]
tdx_handle_exit [kvm_intel]
```

Interpretation:

- The clean hugepage-only probe did not make the subsequent normal run clean.
- This still does not prove QEMU/KVM is the original contaminator, because the
  report is still from allocation time (`check_new_pages`) while QEMU/KVM is
  faulting THP-backed userspace memory.
- However, the absence of a `tee`/hugetlb bad-page report in 061050 means the
  bad pages were exposed by QEMU's anonymous THP/GUP path this time, not by the
  explicit hugetlb pool allocation.

Added a no-QEMU anonymous THP probe:

```text
/home/booklyn/cofunc-tdx/scripts/run_anon_thp_probe.sh
```

It `mmap`s anonymous memory, calls `madvise(MADV_HUGEPAGE)`, touches one byte
per 2MB chunk, captures `kernel-journal-since-start.log`, then releases the
mapping.

Suggested next sequence:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_hugepage_only_probe.sh fn_py_face_detection
sudo /home/booklyn/cofunc-tdx/scripts/run_anon_thp_probe.sh 512
```

If anonymous THP alone reports the same bad-page pattern after the hugepage
probe, then QEMU/KVM is not required to expose it. If anonymous THP is clean but
the normal subset still reports bad pages, the KVM GUP/TDX path becomes more
suspicious.

## 2026-06-29 Update: First Anonymous THP Probe Was Not Isolated

The suggested hugepage-only plus anonymous-THP sequence was run:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_hugepage_only_probe_fn_py_face_detection_20260629_062155
/mnt/new_disk/cofunc_tdx_artifact/results/anon_thp_probe_512mb_20260629_062155
```

Both recorded the same `run_start_epoch`:

```text
run_start_epoch=1782714115
run_start_utc=2026-06-29T06:21:55Z
```

The two `kernel-journal-since-start.log` files are byte-identical:

```text
sha256=b87c920064d3073a8889356715b15e5d60186d1d9ef62e3a428af9d138421d07
```

The shared journal contains only the hugepage-only bad-page report:

```text
explicit_bad=1
suppressed=154
process=tee
stack=alloc_buddy_huge_page -> __nr_hugepages_store_common -> proc_sys_write
```

So this run does **not** answer whether anonymous THP alone is clean or bad; the
anon-THP probe's journal inherited the previous command's same-second kernel
messages.

The anon-THP payload itself completed:

```text
size_mb=512
madvise_ret=0
touched_2m_chunks=256
closed=1
```

But the first version only captured meminfo after closing the mapping, so it
did not prove that THPs were resident while mapped.

Fixed:

```text
/home/booklyn/cofunc-tdx/scripts/run_anon_thp_probe.sh
```

The script now:

- waits `COFUNC_THP_PROBE_START_DELAY_SEC` seconds before taking
  `run_start_epoch` (default: 2);
- touches every 4KB page in the mapping;
- prints `/proc/meminfo` and `/proc/self/smaps_rollup` while the mapping is
  still alive.

Suggested rerun:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_oldabi_hugepage_only_probe.sh fn_py_face_detection
sudo /home/booklyn/cofunc-tdx/scripts/run_anon_thp_probe.sh 512
```

## 2026-06-29 Update: Fixed Anonymous THP Probe Was Clean

The fixed sequence was rerun:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_hugepage_only_probe_fn_py_face_detection_20260629_074325
/mnt/new_disk/cofunc_tdx_artifact/results/anon_thp_probe_512mb_20260629_074326
```

The probes now have separated start times:

```text
hugepage-only run_start_utc=2026-06-29T07:43:25Z
anon-THP      run_start_utc=2026-06-29T07:43:28Z
```

Both per-run journals were clean:

```text
kernel-journal-since-start.log: -- No entries --
explicit_bad=0
suppressed=0
```

The hugepage-only probe did allocate and clean 256 hugetlb pages:

```text
before:      HugePages_Total=0
after alloc: HugePages_Total=256, HugePages_Free=0
after clean: HugePages_Total=0
```

The anon-THP probe did fault in anonymous THPs while the mapping was alive:

```text
size_mb=512
madvise_ret=0
touched_4k_pages=131072
meminfo while mapped:      AnonHugePages=522240 kB
smaps_rollup while mapped: AnonHugePages=522240 kB
```

Do not use `dmesg-final.log` for this specific comparison; both probe
directories contain stale QEMU/tee reports there. The isolated evidence is the
per-run `kernel-journal-since-start.log`, and it is clean.

Interpretation:

- Generic hugetlb allocation can expose contaminated free pages sometimes, but
  the latest hugepage-only probe was clean.
- Generic anonymous THP allocation is clean in this run, even with ~510MB of
  THPs resident.
- That makes the normal QEMU/KVM GUP path more suspicious than generic THP
  allocation alone.

Suggested next command: rerun the narrowed normal subset with THP forced to
`never`, now that the runner has per-run journal capture. Earlier THP-never
results were harder to interpret because `dmesg-final.log` was not isolated.

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

## 2026-06-29 Update: THP-Never With Isolated Journal Still Shows Bad Pages

The narrowed normal subset was rerun with THP forced to `never`:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_thp_never_20260629_075008
```

Run evidence:

```text
kernel=5.19.0-cofunc-tdx-5.19+
qemu=QEMU emulator version 7.0.90
selected_workloads=chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact
thp_enabled=always madvise [never]
thp_defrag=always defer defer+madvise [madvise] never
```

The helper still runs the mandatory face smoke before the selected workload
subset. Timing stayed close to the normal 061050 subset:

```text
run                 workload       n   e2e(s)    exec(s)   boot(s)   grant_exec(s)   n_cow
normal-061050       frontend      20   0.142474  0.091000  0.051474  0.025806        816.85
thp-never-075008    frontend      20   0.146509  0.091300  0.055209  0.025765        808.70
normal-061050       interact      20   0.281524  0.230300  0.051224  0.103329        1965.40
thp-never-075008    interact      20   0.283656  0.229950  0.053706  0.103008        2009.30
normal-061050       face-smoke     1   2.168470  2.098075  0.070395  0.606149        3397.00
thp-never-075008    face-smoke     1   2.175999  2.099882  0.076117  0.610419        3397.00
```

Bad-page evidence from the isolated `kernel-journal-since-start.log`:

```text
explicit bad-page reports: 174
suppressed reports:        39082
first report:              Jun 29 07:50:27
last explicit report:      Jun 29 07:51:37

processes:
  qemu-system-x86: 157
  C2 CompilerThre: 17

flags:
  referenced:       128
  referenced|dirty: 46
```

The important stack changed. With THP forced to `never`, the QEMU reports no
longer go through `do_huge_pmd_anonymous_page`; they go through normal folio
allocation under KVM's GUP path:

```text
vma_alloc_folio
__get_user_pages
hva_to_pfn [kvm]
kvm_faultin_pfn [kvm]
kvm_mmu_page_fault [kvm]
tdx_handle_exit [kvm_intel]
```

Interpretation:

- Disabling THP removes the huge-PMD allocation path but does not remove the
  bad-page reports.
- Disabling THP does not materially improve the timing or `t_grant_exec`.
- Generic anonymous THP was clean in the fixed no-QEMU probe, while the KVM/GUP
  path still exposes bad pages even with THP disabled. That keeps the suspect
  area around KVM PFN/GUP release/accounting or an earlier contamination source
  that KVM later exposes.
- The prior 0004 diagnostic, which skipped `kvm_set_page_accessed()`, did not
  fix the problem. A useful next diagnostic may need to include dirty marking
  (`kvm_set_page_dirty()` / `kvm_release_page_dirty()`) or explicitly clear
  `PageReferenced`/`PageDirty` before pages are returned from the KVM path, but
  treat that as a diagnostic mask rather than a real fix until proven.

Operational note: this THP-never run left host THP active as `never`, and
`thp-wrapper-state.txt` contains only:

```text
before=always [madvise] never
during=always madvise [never]
```

Restore manually before normal/non-diagnostic runs:

```bash
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

The THP wrapper was hardened after this run:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

It now records `restore_mode`, records `restore_write_rc`, and traps
`INT`/`TERM`/`HUP` as well as `EXIT`. Syntax check passed:

```bash
bash -n /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_thp_never.sh
```

## 2026-06-29 Update: Prepared Combined KVM Dirty/Accessed Diagnostic

After the THP-never result, the host THP mode was manually restored and
verified:

```text
/sys/kernel/mm/transparent_hugepage/enabled = always [madvise] never
/sys/kernel/mm/transparent_hugepage/defrag  = always defer defer+madvise [madvise] never
```

Prepared a stronger host-KVM diagnostic than 0004:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0005-Diagnostic-skip-KVM-dirty-accessed-page-flags.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_ad_marks.sh
```

Purpose:

- 0004 only skipped `kvm_set_page_accessed()` and did not remove bad-page
  reports.
- 0005 skips both `kvm_set_page_dirty()` and `kvm_set_page_accessed()` by
  returning before `SetPageDirty(page)` and `mark_page_accessed(page)`.
- This is a diagnostic mask, not a proposed fix. If `referenced`/`dirty` bad
  pages still appear, KVM A/D flag updates are probably not the primary source
  of contamination.

Verification:

```text
patch dry-run: clean
bash -n build_5_19_skip_kvm_ad_marks.sh: clean
patch sha256: 7db11163a0bb84b379eb564cadbed81d47b5f1c66560e13d39dd4395dbada57a
script sha256: 164acfd562bf6e1fdcc88b6b868819e99df16d5eb5caff8dd8b8a1e0eb80b14f
0005 state: not-applied
legacy 0004 skip-accessed state: not-applied
/mnt/new_disk mount: ro,nosuid,nodev,relatime
```

Current installed KVM module baseline before 0005:

```text
running kernel: 5.19.0-cofunc-tdx-5.19+
built kvm.ko sha256:                 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
built kvm-intel.ko sha256:           2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed kvm.ko.zst payload sha256: 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
installed kvm-intel payload sha256:  2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
/dev/kvm users: none detected
```

Next command sequence for the user:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_ad_marks.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload

/home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_ad_marks.sh --check
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check

sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
```

After the run is inspected, reverse 0005 and reinstall/reload unless another
diagnostic needs to build on it:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_skip_kvm_ad_marks.sh --reverse-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
```

## 2026-06-29 Update: 0005 Did Not Improve Performance

The combined KVM dirty/accessed diagnostic was run:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_081817
```

Diagnostic state during inspection:

```text
0005 skip KVM dirty/accessed state: applied
legacy 0004 skip-accessed state:    not-applied
built/installed kvm.ko payload:     bf5a376ac6095782ba54deaf5554a46ef11f6e02201c3200d84e0af26a9551c4
built/installed kvm-intel payload:  2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
THP enabled:                        always [madvise] never
```

Timing compared with the normal 061050 subset and the THP-never 075008 subset:

```text
run                 workload       n   e2e(s)    exec(s)   boot(s)   grant_exec(s)   n_cow
normal-061050       frontend      20   0.142474  0.091000  0.051474  0.025806        816.85
thp-never-075008    frontend      20   0.146509  0.091300  0.055209  0.025765        808.70
0005-081817         frontend      20   0.143552  0.090800  0.052752  0.025771        804.85

normal-061050       interact      20   0.281524  0.230300  0.051224  0.103329        1965.40
thp-never-075008    interact      20   0.283656  0.229950  0.053706  0.103008        2009.30
0005-081817         interact      20   0.282285  0.229100  0.053185  0.102693        1964.75

normal-061050       face-smoke     1   2.168470  2.098075  0.070395  0.606149        3397.00
thp-never-075008    face-smoke     1   2.175999  2.099882  0.076117  0.610419        3397.00
0005-081817         face-smoke     1   2.135647  2.071701  0.063946  0.603795        3397.00
```

2MB accept rejects were unchanged:

```text
frontend:   80
interact:   140
face-smoke: 28
```

Bad-page reports were still present in the isolated journal, but the exposure
pattern changed:

```text
explicit bad-page reports: 36
suppressed reports:        0 observed
first report:              Jun 29 08:18:23
last report:               Jun 29 08:18:23

processes:
  java:             18
  C2 CompilerThre:  14
  node:              4

flags:
  referenced:       30
  referenced|dirty: 6
```

Important timing detail:

```text
run_start_utc:       2026-06-29T08:18:21Z
bad-page burst:      Jun 29 08:18:23
face t_launch_begin: 1782721118.767064  # 2026-06-29T08:18:38Z
frontend launches:   start around 2026-06-29T08:18:50Z
interact launches:   start around 2026-06-29T08:19:05Z
```

Under 0005, no bad-page stack in the isolated journal involved
`qemu-system-x86`, `__get_user_pages`, `hva_to_pfn`, or `tdx_handle_exit`.
The visible stacks were normal `vma_alloc_folio` allocator paths in Java/Node
setup before the actual CVM launches.

Interpretation:

- 0005 does not improve the CoFunc timing or `t_grant_exec`.
- 0005 does not eliminate the underlying bad-page state; it only changes where
  stale `referenced`/`dirty` flags are exposed.
- This makes the KVM dirty/accessed marking path unlikely to be the main
  performance bottleneck.
- Since bad pages appear before CVM launch under 0005 and timings are unchanged,
  this line of investigation looks less relevant to the paper-performance gap.
  The better next performance path is to return to split-container grant /
  accept / KVM prefault instrumentation, especially why 2MB accepts are rejected
  and why `t_grant_exec` stays high.

## 2026-06-29 Update: 0005 Reversed; Grant/Accept Instrumentation Ready

The combined KVM dirty/accessed diagnostic was reversed and the installed KVM
modules are back at the 0003-only baseline:

```text
0005 skip KVM dirty/accessed state: not-applied
legacy 0004 skip-accessed state:    not-applied
running kernel:                      5.19.0-cofunc-tdx-5.19+
built/installed kvm.ko payload:      7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
built/installed kvm-intel payload:   2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
/dev/kvm users:                      none detected
THP enabled:                         always [madvise] never
```

Two temporary old-ABI diagnostic patches are prepared:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
```

Validation status:

```text
0006 patch --dry-run: pass
0007 patch --dry-run: pass
run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh bash -n: pass
```

The new wrapper is:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

It exports:

```text
COFUNC_OLDABI_CVM_EXTRA_PATCH=0006-Diagnostic-expose-guest-accept-pgfault-stats.patch
COFUNC_OLDABI_RUNTIME_EXTRA_PATCH=0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
```

Expected extra metrics in `lean-sc-*` result JSON:

```text
n_accept_exec
n_accept_import
t_pgfault_exec
t_pgfault_import
sc_host_grant_calls
sc_host_mem_size
sc_host_grant_total_ns / sc_host_grant_total_s
sc_host_mmap_anon_ns / sc_host_mmap_anon_s
sc_host_madvise_ns / sc_host_madvise_s
sc_host_mmap_file_ns / sc_host_mmap_file_s
sc_host_set_user_memory_region_ns / sc_host_set_user_memory_region_s
```

Next operational step: run the instrumented old-ABI subset. This still includes
the mandatory face smoke through the existing wrapper path:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-06-30 Update: 06:35 Run Got Host Metrics, Missed Guest Template Metrics

The rerun after the `sc_host_grant_total_ns` guard fix created:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_063558
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260630_063558
/home/booklyn/cofunc-tdx/backups/oldabi-turbo-smp-bound-20260630_063817
```

The shadow-runtime backup confirms:

```text
cofunc_oldabi_runtime_extra_patch=/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
docker_build_cache_args=--no-cache
```

New diagnostic image IDs were created:

```text
split_container_builder: sha256:5ca8ea8f6a3f877bf7f4c566268b87ee393f2c53585da384cf9fb8a3670d7f53 2026-06-30T06:36:10Z
fn_js_alexa_frontend:  sha256:c3b19e9ba0d1fd6c3888229eeb6b452e516ab8aa31b1cd4d05976f6adcd6dc22 2026-06-30T06:37:43Z
fn_js_alexa_interact:  sha256:b53cfec59a50e67fc0cb176a64f6a6f9afb90bcf1bee22e8fecef6385d68ca9d 2026-06-30T06:38:15Z
```

Host-side `sc_host_*` metrics are now present in the workload logs. The main
usable metrics from this run:

```text
fn_py_face_detection, n=1:
  t_e2e                 2.227880 s
  paper Artifact_C      0.617000 s
  actual/expected       3.611x
  t_exec                2.151513 s
  t_grant_exec          0.638707 s
  sc_host_grant_total   0.000394 s
  n_cow                 3397
  2M rejects            28

chain_js_alexa/fn_js_alexa_frontend, n=20:
  t_e2e                 0.142923 s
  t_exec                0.090950 s
  t_grant_exec          0.025735 s
  t_grant_import        0.025944 s
  sc_host_grant_total   0.000162 s
  n_cow                 818.75
  2M rejects            80
```

Interpretation so far: the user-space host `grant_mem()` wrapper is not the
large cost. It is sub-millisecond, while the existing `t_grant_exec` metric is
about 25.7 ms for Alexa frontend and about 638.7 ms for face detection. The
remaining performance gap is therefore below the host wrapper layer, likely in
guest accept/page-fault behavior, KVM/TDX grant work, or the existing
copy-on-write/2MB-reject path.

The run is not a complete Alexa comparison. `fn_js_alexa_interact` timed out
before writing `sc_fork.log`:

```text
Timed out waiting for ChCore shell after 240s
handle_perm_fault failed: fault_addr=400000 desired_perm=1
handle_trans_fault: no vmr found for va 0x10
trace: cofunc-trace/cvm-0-20260630_063856/exec_log_0.timeout
```

The previous 06:13 run still has the last complete interact timing:

```text
chain_js_alexa/fn_js_alexa_interact, n=20:
  t_e2e          0.285193 s
  t_exec         0.230750 s
  t_grant_exec   0.103509 s
  n_cow          1963.70
  2M rejects     140
```

Guest-side metrics did not appear anywhere in the 06:35 result:

```text
rg "sc_guest_|n_accept_|t_pgfault" oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_063558
# no matches
```

Root cause: the diagnostic wrapper rebuilt the final workload images so
`/bin/sc-runtime` came from the patched builder, but existing workload
`*_base:latest` images still contained the old `/func/main.py` or
`/func/index.js`. The function Dockerfiles copy `tools/template.py` or
`tools/template.js` into the base image, while `testcases/tools/Dockerfile`
only updates runtime/tooling in the final image. So the host runtime probe was
valid, but the guest template print statements never entered the function
images.

Fix applied after this run:

- when `COFUNC_OLDABI_RUNTIME_EXTRA_PATCH` is set,
  `run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh` now rebuilds each selected
  workload's `*_base:latest` image with the patched `tools/template.py/js`;
- it still rebuilds the final workload image with `docker build --no-cache` so
  `/bin/sc-runtime` comes from the diagnostic `split_container_builder`;
- backup `options` now records
  `rebuild_workload_base_for_templates=1`;
- each rebuilt workload image must now pass both guards:
  `/bin/sc-runtime` contains `sc_host_grant_total_ns`, and `/func` contains
  `sc_guest_n_accept_before`.

Validation after this wrapper fix:

```text
run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh bash -n: pass
```

Host kernel warnings still appeared during the run. `run_start_utc` was
`2026-06-30T06:38:18Z`; `kernel-journal-since-start.log` includes a bad-page
burst at `06:38:27` with 430 suppressed messages and explicit `tar`/rsyslog
reports, followed by 7007 suppressed messages at `06:39:39` and additional
`node`/`ip6tables` bad-page reports through `06:41:42`. The flags remained
`referenced|node=0|zone=2|lastcpupid=0x1fffff`.

Next operational step is one more rerun. This one should rebuild the workload
base images enough to carry the guest template instrumentation, then verify it
inside `/func` before running:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-06-30 Update: 06:13 Run Completed But Reused Cached Images

The rerun produced:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_061311
```

It completed the mandatory face smoke plus 20 frontend and 20 interact runs.
However, the new `sc_host_*`, `sc_guest_*`, `n_accept_*`, and `t_pgfault_*`
fields were still absent from all result and verbose logs.

Timing remains in the same post-0003 baseline band:

```text
run                 workload       n   e2e(s)    exec(s)   boot_lean(s) boot_sc(s) boot_func(s) grant_exec(s) n_cow
061311 cached-inst  frontend      20   0.143805  0.091250  0.011982     0.028316   0.012257     0.025996      801.80
061311 cached-inst  interact      20   0.285193  0.230750  0.013174     0.029083   0.012186     0.103509      1963.70
061311 cached-inst  face-smoke     1   2.173005  2.103731  0.009679     0.046762   0.012833     0.610671      3397.00
```

2MB reject counts were unchanged:

```text
frontend:   80
interact:   140
face-smoke: 28
```

The isolated journal again showed bad-page state before the actual workload
launches:

```text
run_start_utc:        2026-06-30T06:13:15Z
bad-page burst:       Jun 30 06:13:24
first face launch:    around 2026-06-30T06:13:34Z
explicit bad pages:   60
suppressed line:      4990 messages suppressed
processes:            tar 42, systemd-journal 18
flags:                referenced|dirty
```

The missing instrumentation was due to Docker cache reuse, not a workload
failure:

```text
06:02 split_container_builder image: sha256:5be0c43bbae77ae2ec090d8de2678f43e9e0f08ffe4b28bd6c0df2db8ff926c5
06:13 split_container_builder image: sha256:5be0c43bbae77ae2ec090d8de2678f43e9e0f08ffe4b28bd6c0df2db8ff926c5
06:13 builder log: COPY main.c /runtime/main.c CACHED
06:13 builder log: RUN gcc -Werror -o /runtime/runtime /runtime/main.c CACHED
06:13 workload logs: COPY --from=builder /runtime/runtime /bin/sc-runtime CACHED
```

Guardrails added to:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh
```

When `COFUNC_OLDABI_RUNTIME_EXTRA_PATCH` is set, the wrapper now:

- builds `split_container_builder` with `docker build --no-cache`;
- builds selected workload images with `docker build --no-cache`;
- verifies patched source contains `sc_host_grant_total_ns` and
  `sc_guest_n_accept_before`;
- verifies `split_container_builder:latest` contains
  `sc_host_grant_total_ns` in `/runtime/runtime`;
- verifies every rebuilt workload image contains `sc_host_grant_total_ns`
  in `/bin/sc-runtime`;
- records `docker_build_cache_args=--no-cache` in backup `options`.

Validation after this script fix:

```text
0006 patch --dry-run: pass
0007 patch --dry-run: pass
run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh bash -n: pass
live old-ABI source restore check: no instrumentation markers present
0005 host KVM diagnostic state: not-applied
```

Next operational step is to rerun the same command. This rerun should take
longer because the diagnostic Docker builds are intentionally uncached:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-06-30 Update: First Instrumented Run Hit Analyzer Guard Bug

The first instrumented attempt produced:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_060230
```

It did not reach the Alexa subset. The mandatory face smoke completed far enough
to show baseline-like timing:

```text
t_launch_begin: 1782799414.498180
t_import_done:  1782799414.572311
t_func_done:    1782799416.6528165
t_e2e:          2.154637 s
t_exec:         2.080506 s
t_grant_exec:   0.607055 s
n_cow:          3397
2MB rejects:    28
```

Then `analyze.py` raised:

```text
KeyError: 't_pgfault_exec'
```

Reason: the first `0007` patch treated `t_pgfault_exec` and
`t_pgfault_import` as mandatory once the analyzer patch was active. The guest
template did not emit those fields, likely because the new stat IDs returned
`-1` or were otherwise unavailable in that image.

Follow-up fixes applied to:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
```

Changes:

- `analyze.py` now treats `t_pgfault_exec` and `t_pgfault_import` as optional,
  matching the already-optional `n_accept_*` handling.
- Python/JS templates now emit raw `sc_guest_n_accept_*` and
  `sc_guest_t_pgfault_*` values, so the next run will show whether the new
  `SYS_SC_GET_STAT` IDs are available or returning `-1`.
- `shadow_container/main.c` now prints `sc_host_*` grant counters immediately
  after `grant_mem()` and flushes stdout. The earlier final-exit print path was
  removed after the hunk proved unreliable across the old-ABI source tree.

Validation after the fix:

```text
0006 patch --dry-run: pass
0007 patch --dry-run: pass
run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh bash -n: pass
live old-ABI source restore check: no instrumentation markers present
0005 host KVM diagnostic state: not-applied
```

That rerun was completed as `20260630_061311`; see the cache-reuse section
above. Current next step after the script cache-bypass fix is to rerun the same
instrumented subset. This time the diagnostic Docker builds should be uncached
and verified:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-06-30 Update: 06:21 Rerun Stopped Before Docker Build

The 06:21 rerun did not create a new result directory. The latest result is
still:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_061311
```

It created only this shadow-runtime backup:

```text
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260630_062121
```

The backup reached the wrapper option capture:

```text
cofunc_oldabi_runtime_extra_patch=/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
docker_build_cache_args=--no-cache
```

The selected workloads were:

```text
fn_py_face_detection
chain_js_alexa/fn_js_alexa_frontend
chain_js_alexa/fn_js_alexa_interact
```

There was no lower-level `oldabi-turbo-smp-bound-*` backup and no Docker build
logs in the 06:21 backup, so the wrapper stopped before the first Docker build.

Root cause: the new guardrail required `sc_host_final_grant_total_ns`, but the
current `0007` patch only lands the immediate post-`grant_mem()` marker
`sc_host_grant_total_ns`. The immediate marker is the useful one because it is
printed and flushed as soon as `grant_mem()` completes.

Fix applied after the 06:21 stop:

- removed the stale final-exit hunk from `0007`;
- changed runtime source, builder-image, and workload-image guardrails to
  require `sc_host_grant_total_ns`;
- kept `docker build --no-cache` whenever
  `COFUNC_OLDABI_RUNTIME_EXTRA_PATCH` is set.

Validation after this fix:

```text
0006 patch --dry-run: pass
0007 patch --dry-run: pass
temp patch probe: sc_host_grant_total_ns present
temp patch probe: sc_guest_n_accept_before present
run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh bash -n: pass
```

Next operational step is still the same rerun. This should now pass the source
guardrail and then perform uncached diagnostic Docker builds:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-06-30 Current Tail Note

Newest result currently present:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_063558
```

The 07:02 rerun did not create a new result directory. It created only:

```text
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260630_070205
```

That backup reached the expected options:

```text
cofunc_oldabi_runtime_extra_patch=/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
docker_build_cache_args=--no-cache
rebuild_workload_base_for_templates=1
```

It rebuilt `split_container_builder`, rebuilt and verified
`fn_py_face_detection`, then rebuilt `fn_js_alexa_frontend_base` and
`fn_js_alexa_frontend`. It stopped before writing
`fn_js_alexa_frontend.diagnostic` and before starting
`fn_js_alexa_interact`, so the stop was a post-build guard.

Docker digest inspection of the frontend images from that failed build showed
that `/func/index.js` contained the new stat IDs:

```text
const STAT_N_ACCEPT = 0x7;
const STAT_T_PGFAULT = 0x8;
n_accept_before_exec = sc.stat_get_stat(STAT_N_ACCEPT);
t_pgfault_before_exec = sc.stat_get_stat(STAT_T_PGFAULT);
```

but it did not contain the raw print lines such as
`sc_guest_n_accept_before`. Root cause: the JS part of `0007` used one fuzzy
hunk with an incorrect old-line count, so `patch` landed only the first JS
portion and silently skipped the later JS `sc_guest_*` logging additions. The
source guard also checked Python and JS together, so Python's marker was enough
to pass.

Fix applied after the 07:02 stop:

- replaced the JS part of `0007` with correctly counted independent hunks;
- tightened the source guard to require `sc_guest_n_accept_before` separately
  in both `template.py` and `template.js`;
- kept the final image guard that checks `sc_guest_n_accept_before` under
  `/func`.

Validation after this fix:

```text
0007 patch --dry-run: pass
temp apply probe: JS sc_guest_n_accept_before present
temp apply probe: Python sc_guest_n_accept_before present
temp apply probe: host sc_host_grant_total_ns present
run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh bash -n: pass
run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh bash -n: pass
```

Current interpretation from the last completed result is unchanged: the
measured host `grant_mem()` wrapper is too small to explain the paper gap
(`0.000394 s` for face, `0.000162 s` avg for Alexa frontend), while
`t_grant_exec` remains much larger (`0.638707 s` for face, `0.025735 s` avg for
Alexa frontend). The next useful run is another instrumented rerun with both
the workload-base-template rebuild and corrected JS guest-print patch active:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-06-30 Update: 07:22 Instrumented Run Completed

The corrected diagnostic patch and workload-base rebuild path completed:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_072238
```

Associated backups:

```text
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260630_072238
/home/booklyn/cofunc-tdx/backups/oldabi-turbo-smp-bound-20260630_072457
```

Captured run environment:

```text
kernel=5.19.0-cofunc-tdx-5.19+
qemu=QEMU emulator version 7.0.90
tdx_smp=16
thp_enabled=always [madvise] never
thp_defrag=always defer defer+madvise [madvise] never
selected_workloads=chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact
```

The wrapper options show the diagnostic path that matters:

```text
cofunc_oldabi_runtime_extra_patch=/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
docker_build_cache_args=--no-cache
rebuild_workload_base_for_templates=1
```

The compact smoke summary is:

```text
Function                 TDX_CoFunc_fork(s) Artifact_C(s) actual/expected
fn_py_face_detection     2.163              0.617         3.505
Avg ratio                                               3.505
```

The subset produced one face sample, twenty Alexa frontend samples, and twenty
Alexa interact samples. `tdx_sc_fork_summary.txt` still only contains the
header, so use the per-workload `sc_fork.log` JSON and `run-*.log` files for
analysis.

Key averages:

```text
workload            n   e2e(s)   exec(s)  grant_exec(s)  pgfault_exec(s)  accept_exec  host_grant(s)  n_cow
face                1   2.1628   2.0879   0.6107         0.6572           23           0.000244       3399
alexa_frontend     20   0.1424   0.0904   0.0258         0.0314           1            0.000176       823.85
alexa_interact     20   0.3227   0.2675   0.1032         0.1154           4            0.000187       2025.9
```

Per-workload 2 MB accept rejection counts from the `run-*.log` files:

```text
fn_py_face_detection                 28
chain_js_alexa/fn_js_alexa_frontend  80
chain_js_alexa/fn_js_alexa_interact  140
```

Important diagnosis from this run:

- The diagnostic markers finally landed in both Python and JS workloads:
  `sc_host_*`, `sc_guest_*`, `n_accept_*`, and `t_pgfault_*` are present.
- The measured host `grant_mem()` wrapper is tiny: about `0.17` to `0.24 ms`.
  That is too small to explain the paper gap.
- `t_pgfault_exec` is the same scale as, or slightly larger than,
  `t_grant_exec`. This strongly suggests the time charged as grant/accept is
  being spent in the guest page-fault/accept path, not in the host wrapper
  around `grant_mem()`.
- The face result is still not paper-like: `2.163 s` vs the artifact expected
  `0.617 s`, or `3.505x`.

Kernel evidence captured with the run:

```text
kernel-journal-since-start.log: 113 explicit "BUG: Bad page state" records
dmesg-final.log:                 47 explicit "BUG: Bad page state" records
```

The journal burst starts at `Jun 30 07:25:11` in `qemu-system-x86` and shows
`PAGE_FLAGS_CHECK_AT_PREP` with flags such as:

```text
0x17ffffc0000002(referenced|node=0|zone=2|lastcpupid=0x1fffff)
```

Representative stack frames:

```text
do_huge_pmd_anonymous_page
get_user_pages_unlocked
hva_to_pfn [kvm]
kvm_faultin_pfn / direct_page_fault
tdx_handle_exit [kvm_intel]
```

Current interpretation after the successful diagnostic run:

- We should stop treating the host `grant_mem()` wrapper as the likely
  bottleneck.
- The useful next target is the KVM/TDX guest-memory fault path, especially the
  interaction between THP/2 MB accepts, KVM `hva_to_pfn`, and the recurring bad
  page state warnings.
- A targeted next experiment would be an instrumented rerun with THP disabled
  or forced 4 KB accept behavior, then compare `t_pgfault_exec`,
  `t_grant_exec`, 2 MB rejection counts, and bad-page counts against this
  07:22 baseline.

## 2026-06-30 Next Experiment Prepared: THP-Never With Instrumentation

Use THP-never first, rather than repeating the 4 KB accept diagnostic, because
the old 4 KB run already made performance worse while the latest bad-page stack
points directly at `do_huge_pmd_anonymous_page`.

Prepared wrapper:

```text
/home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented_thp_never.sh
```

It now toggles THP itself and composes the normal instrumented runner with:

```text
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch
/home/booklyn/cofunc-tdx/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch
```

Validation before run:

```text
/sys/kernel/mm/transparent_hugepage/enabled = always [madvise] never
/sys/kernel/mm/transparent_hugepage/defrag  = always defer defer+madvise [madvise] never
0006 patch --dry-run: pass
0007 patch --dry-run: pass
instrumented_thp_never wrapper bash -n: pass
```

Run command:

```bash
sudo COFUNC_THP_RESTORE_MODE=madvise \
  COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented_thp_never.sh
```

After completion, compare the new result against:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260630_072238
```

Primary fields to compare:

```text
t_pgfault_exec
t_grant_exec
n_accept_exec
n_cow
2M reject reason count
BUG: Bad page state count and stack/process attribution
```

## 2026-06-30 Update: THP-Never Instrumented Run Completed

Result:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_thp_never_20260630_080130
```

Associated backups:

```text
/home/booklyn/cofunc-tdx/backups/oldabi-tdx-shadow-runtime-20260630_080130
/home/booklyn/cofunc-tdx/backups/oldabi-turbo-smp-bound-20260630_080521
```

The run did execute with THP disabled:

```text
run_start_utc=2026-06-30T08:05:22Z
thp_enabled=always madvise [never]
thp_defrag=always defer defer+madvise [madvise] never
```

Important cleanup caveat: after the run, the host was still in THP `never`.
The state file only contained:

```text
before=always [madvise] never
restore_mode=madvise
during=always madvise [never]
```

Codex tried `sudo -n` restore, but sudo required a password. Restore manually
before further normal runs:

```bash
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
```

The combined wrapper was patched after this run so future
`instrumented_thp_never` runs own the THP toggle directly and record
`restore_write_rc` plus `after`.

Timing comparison against the 07:22 instrumented baseline:

```text
workload          mode       n   e2e(s)   exec(s)  grant_exec(s)  pgfault_exec(s)  accept_exec  host_grant(s)  n_cow
face              normal     1   2.1628   2.0879   0.6107         0.6572           23           0.000244       3399
face              thp-never  1   2.2034   2.1105   0.6077         0.6575           23           0.000379       3399
alexa_frontend    normal    20   0.1424   0.0904   0.0258         0.0314           1            0.000176       823.85
alexa_frontend    thp-never 20   0.1450   0.0923   0.0258         0.0321           1            0.000165       841
alexa_interact    normal    20   0.3227   0.2675   0.1032         0.1154           4            0.000187       2025.9
alexa_interact    thp-never 20   0.2701   0.2183   0.0987         0.1090           4            0.000123       2010.4
```

Alexa interact improved relative to the noisy 07:22 instrumented run, but face
and frontend got slightly worse. The grant/page-fault counters changed only
modestly:

```text
face pgfault_exec:      0.6572 -> 0.6575
frontend pgfault_exec:  0.0314 -> 0.0321
interact pgfault_exec:  0.1154 -> 0.1090
```

2 MB reject counts:

```text
workload          normal  thp-never
face              28      28
alexa_frontend    80      98
alexa_interact    140     140
```

Bad-page comparison:

```text
normal kernel-journal explicit BUGs:     113
normal suppressed reports:               0 observed
normal processes:                        113 qemu-system-x86

thp-never kernel-journal explicit BUGs:  171
thp-never suppressed reports:            35126
thp-never processes:                     81 qemu-system-x86, 60 node, 28 in:imklog, 1 systemd-journal
```

Stack-frame comparison:

```text
normal do_huge_pmd_anonymous_page: 113
thp-never do_huge_pmd_anonymous_page: 0
normal vma_alloc_folio: 113
thp-never vma_alloc_folio: 171
normal get_user_pages_unlocked: 113
thp-never get_user_pages_unlocked: 82
normal hva_to_pfn/tdx_handle_exit lines: 226
thp-never hva_to_pfn/tdx_handle_exit lines: 165
```

Interpretation:

- THP-never removes the `do_huge_pmd_anonymous_page` stack frame, as expected.
- It does not remove bad pages; the warnings persist through 4 KB allocation
  paths and become noisier in this run.
- It does not materially reduce `t_pgfault_exec` or `t_grant_exec` for face or
  frontend, so THP is not the performance root cause.
- The remaining target is still the stale page-flag / private-page lifecycle
  around KVM/TDX `hva_to_pfn` and guest-memory faulting, not the host
  `grant_mem()` wrapper and not THP alone.

Manual host-state restore was confirmed afterward:

```text
2026-06-30T08:37:28Z
/sys/kernel/mm/transparent_hugepage/enabled = always [madvise] never
/sys/kernel/mm/transparent_hugepage/defrag  = always defer defer+madvise [madvise] never
```

## 2026-07-01 Next Diagnostic: Clear Private-Memfile Page Flags

Prepared a targeted host-KVM diagnostic:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0006-Diagnostic-clear-private-memfile-page-flags.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_clear_private_mem_flags.sh
```

Rationale:

- The old-ABI TDX bad-page reports are dominated by `PG_referenced`, with a
  few `PG_dirty` cases.
- The generic KVM dirty/accessed diagnostic (`0005`) did not fix timings or
  eliminate bad-page state.
- The private backing path calls `shmem_getpage(..., SGP_WRITE)` from
  `shmem_get_pfn()`. In this 5.19 source, `SGP_WRITE` marks newly allocated
  folios referenced before KVM installs them into the TD.
- Therefore the next narrower probe clears `PG_referenced` and `PG_dirty` only
  on KVM private-memfile pages as their private PFN references are released:
  `kvm_private_mem_put_pfn()` and the final TDX `tdx_unpin()` path.

Validation done before handoff:

```text
bash -n build_5_19_clear_private_mem_flags.sh: ok
patch --dry-run against current 5.19 source: ok
0006 state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
/mnt/new_disk mount: ro,nosuid,nodev,relatime
```

The dry-run reported the expected read-only-source warning because
`/mnt/new_disk` was mounted read-only; the wrapper remounts it read-write when
run with sudo.

Next command sequence for the user:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_clear_private_mem_flags.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload

/home/booklyn/cofunc-tdx/scripts/build_5_19_clear_private_mem_flags.sh --check
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check

sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="chain_js_alexa/fn_js_alexa_frontend chain_js_alexa/fn_js_alexa_interact" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

If the Alexa-only run is clean or strongly improved, follow with face:

```bash
sudo COFUNC_OLDABI_RUNTIME_WORKLOADS="fn_py_face_detection" \
  /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

After collecting evidence, restore the 0003-only KVM baseline:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_clear_private_mem_flags.sh --reverse-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
```

2026-07-01 loaded-state check after user applied/installed/reloaded:

```text
0006 state: applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
built kvm.ko sha256: 896ed1bbc31903f0b73ab0511dd47eaf0d52756a74b2bc10cdd17f8f671cd961
built kvm-intel.ko sha256: 1dc24db92849aa0f1783a45dd5506eb5991c75c28a6e5236fec20e496425dbd8
installed payload hashes match built hashes
loaded kvm srcversion: ED3E0B888F2851473A9EEFB
loaded kvm_intel srcversion: E903288B25B77B0E8A9B9F3
kvm_intel tdx parameter: Y
/dev/kvm users: none detected during check
```

2026-07-01 result with 0006 applied:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260701_055119
```

The run selected Alexa frontend/interact, and the wrapper also ran the usual
face smoke. Timings versus the 2026-06-30 07:22 0003-only baseline:

```text
workload          mode       n   e2e(s)   exec(s)  grant_exec(s)  pgfault_exec(s)  accept_exec  host_grant(s)  n_cow
face              baseline   1   2.1628   2.0879   0.6107         0.6572           23           0.000244       3399
face              0006       1   2.1830   2.1109   0.6157         0.6617           23           0.000353       3399
alexa_frontend    baseline  20   0.1424   0.0904   0.0258         0.0314           1            0.000176       823.85
alexa_frontend    0006      20   0.1458   0.0926   0.0260         0.0318           1            0.000161       830.75
alexa_interact    baseline  20   0.3227   0.2675   0.1032         0.1154           4            0.000187       2025.9
alexa_interact    0006      20   0.3000   0.2476   0.1032         0.1155           4            0.000175       2025.35
```

The apparent Alexa-interact E2E improvement is not tied to the instrumented
guest fault/grant counters; `t_grant_exec` and `t_pgfault_exec` are unchanged.
Face and frontend are slightly worse. This diagnostic does not move the
performance bottleneck.

Bad-page behavior:

```text
baseline explicit BUGs: 113, no suppression line observed
0006 explicit BUGs:      61, but first log line says 36830 messages suppressed
```

Visible attribution changed:

```text
baseline processes: 113 qemu-system-x86
baseline flags:     111 referenced, 2 referenced|dirty

0006 processes:     49 tar, 11 node
0006 flags:         60 referenced|dirty
0006 visible stacks: 49 __filemap_get_folio, 11 vma_alloc_folio
0006 visible KVM/TDX frames: no hva_to_pfn/tdx_handle_exit/get_user_pages_unlocked
```

Interpretation: clearing page flags at KVM private PFN put/unpin did not fix
the performance issue, and it did not cleanly eliminate the stale page-flag
problem. The visible symptom moved from QEMU's KVM fault path to later host
allocations, while printk reported many suppressed bad-page messages. Restore
the 0003-only host KVM baseline before the next performance diagnostic.

2026-07-01 restore after 0006:

```text
0006 state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
built kvm.ko sha256: 7e36232a58451235ace7d237f7b28c81d910d6a154f57e9607c8a0a221cbe2fe
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed payload hashes match built hashes
loaded kvm srcversion: ED3E0B888F2851473A9EEFB
loaded kvm_intel srcversion: 8471047B8F88FAB864A6A8F
kvm_intel tdx parameter: Y
/dev/kvm users: none detected during check
```

The host is back on the 0003-only KVM module baseline.

2026-07-01 next diagnostic prepared:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0007-Diagnostic-log-private-fault-levels.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_private_fault_levels.sh
```

This diagnostic targets the current performance lead: the guest tries 2MB
split-container accepts, but the logs show 2MB accept rejections. The patch
adds bounded host KVM/TDX printk evidence for private memfile PFN order,
KVM hugepage-adjust levels, final direct-map walk level, and finalized TDX
private SEPT add level. If these lines show `order=0`, `host_level=1`,
`goal=1`, or `level=1`, the host is backing/installing private TD runtime
grant pages as 4KB leaves, which explains the guest fallback to many 4KB
accepts.

Validation before applying:

```text
patch sha256: 305c16c633f192a0e7691630f2ba72bad89719632cad223598cb5d85cff77ce5
patch --dry-run against the 5.19 source: clean
0007 state: not-applied
0006 flag-cleanup state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
mount: ro,nosuid,nodev,relatime
```

2026-07-01 result with 0007 applied:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260701_062500
```

The run did not reach workload metrics. QEMU aborted before the ChCore shell:

```text
CVM screen session exited before ChCore shell
KVM_GET_CLOCK failed: Input/output error
```

Host state/evidence:

```text
0007 state: applied
0006 state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
built kvm.ko sha256: b8cee4ac1ebf3a3d821171ad7b7e3344088669f8128df8a8c2b0de352ed5bb95
built kvm-intel.ko sha256: 0df814d1c8d630e3ce1477712f1c4806329ea1403eb272c57d23e18a160a09f3
installed payload hashes match built hashes
loaded kvm srcversion: 3DF9AACFE85D480026D9684
loaded kvm_intel srcversion: A534AB9336054B8B13D2EEB
kvm_intel tdx parameter: Y
/dev/kvm users: none detected after the failed run
```

The 0007 logs were useful but aimed too early/narrowly:

```text
kernel-journal-since-start.log:
  96 set_private_spte diagnostic lines
  0 private_pfn/hugepage_adjust/direct_map diagnostic lines
  1 BUG: Bad page state
```

The first four finalized SEPT additions were 2MB (`level=2`, `pages=512`) at
low GFNs, then the budget was consumed by 4KB additions around `gfn=0x806` and
up. The actual run uses the TDP MMU path (`kvm_tdp_mmu_map`), so the direct-map
probe in 0007 did not fire. The run also printed many normal TDX teardown lines
and a warning from `__handle_changed_spte` after QEMU aborted.

Prepared replacement diagnostic:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0008-Diagnostic-log-high-gfn-private-tdp-levels.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_high_gfn_private_tdp_levels.sh
0008 patch sha256: 295e4ffa84b1bcd012df714b3a2ee05a7c50c3011f4187984eb4d7bada292895
```

0008 removes the TDX `set_private_spte` hook and instead logs high-GFN
(`>= 0x100000`) private mappings in the common private PFN path and in
`kvm_tdp_mmu_map()`. This targets rejected accept GPAs such as `0x683000000`
without spending the log budget on early TD boot mappings. Validation:

```text
0007 reverse dry-run against current source: clean
0008 apply dry-run against clean baseline: clean
0008 check while 0007 is applied: state not-applied, conflict 0007 applied
```

2026-07-01 source state after user reversed 0007 and applied 0008:

```text
0007 state: not-applied
0008 state: applied
0006 state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
built kvm.ko sha256: fd5b462c4ad3be9378d031c85de28a20a482b7117216039fdad2dd5d6b0e29b6
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed kvm.ko.zst payload sha256: b8cee4ac1ebf3a3d821171ad7b7e3344088669f8128df8a8c2b0de352ed5bb95
installed kvm-intel.ko.zst payload sha256: 0df814d1c8d630e3ce1477712f1c4806329ea1403eb272c57d23e18a160a09f3
/dev/kvm users: none detected
```

The 0008 source is built, but the installed modules still contain the prior
0007 payload. Next step is install/reload, verify the installed payload hash
matches built `kvm.ko`, then run face.

2026-07-01 result with 0008 applied, installed, and loaded:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260701_064456
```

Final verified host/module state:

```text
0008 state: applied
0007 state: not-applied
0006 state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
running kernel: 5.19.0-cofunc-tdx-5.19+
built kvm.ko sha256: fd5b462c4ad3be9378d031c85de28a20a482b7117216039fdad2dd5d6b0e29b6
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed kvm.ko.zst payload sha256: fd5b462c4ad3be9378d031c85de28a20a482b7117216039fdad2dd5d6b0e29b6
installed kvm-intel.ko.zst payload sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
/dev/kvm users: none detected
```

Face workload metrics:

```text
n=1  e2e=2.170005083 exec=2.099133015 grant_exec=0.609147852 pgfault_exec=0.655522776 accept=23.000 host_grant=0.000415907 cow=3399.000
n=20 e2e=2.162358356 exec=2.087643683 grant_exec=0.599874388 pgfault_exec=0.647463398 accept=23.000 host_grant=0.000303611 cow=3399.000
```

This is essentially the same performance as the 0003-only baseline, as expected:
0008 is a diagnostic-only patch.

Guest 2MB accept failures persisted:

```text
run-fn_py_face_detection-1.log:  28 "2M reject reason" lines
run-fn_py_face_detection-20.log: 560 "2M reject reason" lines
first rejected GPAs include 0x583000000, 0x583200000, 0x583400000, 0x59fc00000
failure code: 0xc0000b0b00000001, page_size=1
```

Host diagnostic counts from `kernel-journal-since-start.log`:

```text
private TDP level diagnostic lines: 512
KVM_GET_CLOCK failed: 0
BUG: Bad page state lines: 116

tdp_adjust:
  host=0: 256
  host_pages=0: 256
  req=2/goal=2: 20
  req=1/goal=1: 236
  gfn_2m_aligned=1: 21
  gfn_2m_aligned=0: 235
  pfn_2m_aligned=1: 21
  pfn_2m_aligned=0: 235

tdp_target:
  host=0: 256
  iter_level=2 iter_pages=512: 20
  iter_level=1 iter_pages=1: 236
  old_present=0: 256
  fault_gfn_2m_aligned=1: 21
  fault_gfn_2m_aligned=0: 235
  iter_gfn_2m_aligned=1: 21
  iter_gfn_2m_aligned=0: 235
  pfn_2m_aligned=1: 21
  pfn_2m_aligned=0: 235
```

Interpretation: 0008 confirms that the host TDP path can and does install
high-GFN private mappings as 4KB leaves. In the captured budget, only 20
private mappings were installed as 2MB leaves (`iter_level=2`, `iter_pages=512`);
236 were installed as 4KB leaves (`iter_level=1`, `iter_pages=1`). The 4KB
cases line up with `goal=1` and mostly unaligned fault GFNs/PFNs. That supports
the current performance hypothesis: the guest asks to accept split-container
runtime grant memory in 2MB chunks, but the host has already created/split
private SEPT/TDP mappings at 4KB granularity, so the guest falls back to many
4KB TDCALL accepts.

Caveat: the 0008 log budget was consumed around high GFNs starting at
`gfn=0x100000..0x1028eb`. The face rejection GPAs correspond to GFNs around
`0x583000` and `0x59c000`. So 0008 proves the mechanism on the same high-GFN
private TDP path, but it does not yet capture the exact face rejected GPAs.
If exact one-to-one evidence is needed, create a follow-up diagnostic with a
later/range filter such as `gfn >= 0x500000` and a small budget.

Recommended next steps:

1. If we want exact proof before changing behavior, add a 0009 diagnostic that
   only logs private TDP mappings for the face grant GPA range (`gfn >=
   0x500000`) and rerun face once.
2. If the evidence is already sufficient, move to the fix path: inspect the
   private memfd/grant allocation path in QEMU/shadow runtime and make runtime
   grant backing arrive as 2MB-aligned/order-9 private memory before the guest
   2MB accept path runs.
3. After keeping enough evidence, restore the host from 0008 back to the
   0003-only baseline before doing unrelated benchmark comparisons.

2026-07-01 follow-up diagnostic prepared:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0009-Diagnostic-narrow-private-tdp-logging-to-face-gfns.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_private_tdp_levels.sh
```

0009 is an overlay on top of 0008. It changes the diagnostic range from
`gfn >= 0x100000` to `0x500000 <= gfn < 0x700000`, raises the per-site budget
to 1024, and changes the printk marker to `CoFunc old-ABI face-GFN private TDP
level diagnostic`. This range covers the observed face rejected GPAs around
`0x583000000..0x59fc00000` and the previously noted `0x683...` layout while
skipping the early `0x100...` mappings that consumed 0008's budget.

Validation:

```text
0009 patch sha256: 626b826a1e9aee6dcbba22f793fb0e01d2004b2b0c0094f822fa88255266dd3e
0009 script sha256: 1ef5fafd12620e8594e3a4fe07b6010595196bb220ab1fd60519820cd3dd316b
0009 face-GFN overlay state: not-applied
0008 high-GFN base state: applied
0007 private-fault-level state: not-applied
0006 flag-cleanup state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
patch --dry-run against current 0008 source: clean
mount: ro,nosuid,nodev,relatime
```

Next command sequence for exact face-GPA evidence:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_private_tdp_levels.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_private_tdp_levels.sh --check
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check
sudo env STOP_AFTER_SMOKE=1 COFUNC_OLDABI_RUNTIME_WORKLOAD=fn_py_face_detection /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

2026-07-02 0011 apply/build completed:

```text
0011 face-GFN hugepage-decision state: applied
0010 all-face-GFN TDP base state: applied
0009 face-GFN private MMU base state: applied
0007 private-fault-level state: not-applied
0006 flag-cleanup state: not-applied
legacy 0005 skip-dirty/accessed state: not-applied
legacy 0004 skip-accessed state: not-applied
/mnt/new_disk mount after build: ro,nosuid,nodev,relatime
running kernel at verification time: 6.19.0-rc6-cofunc-tdx+
```

Build evidence:

```text
backup/evidence dir: /home/booklyn/cofunc-tdx/backups/host-kernel-log-face-gfn-hugepage-decision-20260702_061013
0011 patch sha256: ff848430eb1c95266e191a12660cae304d8eb86129137219881b0f739bfc7a5a
mmu.c before sha256: 050fedc24b1733402350733f0ccd9ff94daf441cad3fb4b19d8c3721bf5aed25
mmu.c after sha256: 1e5bf63224fbbf79fe51ec5e799155f7a6c502d56d345b530ccf0a6c7a35bac0
built kvm.ko sha256: 4584617401e06e8ebd97daac0a4088680e955b10261b871d0e045756204b1600
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
built kvm.ko vermagic: 5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
built kvm-intel.ko vermagic: 5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
```

Do not run `install_5_19_patched_kvm_modules.sh --install/--reload` while the
host is still on 6.19; the script correctly refuses in that state. Reboot/select
`5.19.0-cofunc-tdx-5.19+` first, then install/reload/run the face smoke.

2026-07-02 next diagnostic prepared after 0010 results:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0011-Diagnostic-log-face-gfn-hugepage-decision.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_hugepage_decision.sh
```

0010 proved the exact face grant faults are private TDP faults but still map as
4KB leaves (`max=2 req=1 goal=1 iter_level=1`). 0011 keeps 0010 in place and
adds diagnostic-only logging inside `kvm_mmu_hugepage_adjust()` and
`__kvm_mmu_max_mapping_level()` for the same face GFN range
(`0x500000 <= gfn < 0x700000`).

The key question for 0011 is why `req_level` becomes `PG_LEVEL_4K`: lpage
disallowance, dirty tracking, private-slot handling, or the host HVA page-table
mapping level. The most useful fields are `hp_max_mapping result`,
`host_used`, `slot_private`, `slot_flags`, `l2_disallow`, and
`hp_adjust_result req`.

Validation:

```text
0011 patch sha256: ff848430eb1c95266e191a12660cae304d8eb86129137219881b0f739bfc7a5a
0011 script sha256: d1e9ce03277d39840d58e5677ba56201927687388d777e0a237e50715ebeadf8
patch --dry-run against reconstructed 0009/0010-shaped mmu.c: clean
patch -R --dry-run after temp apply: clean
script bash -n: clean
```

Next command sequence:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_hugepage_decision.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_hugepage_decision.sh --check
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check
sudo env STOP_AFTER_SMOKE=1 COFUNC_OLDABI_RUNTIME_WORKLOAD=fn_py_face_detection /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

Note: this Codex session could not see the live `/mnt/new_disk/cofunc_tdx_artifact`
tree, so the script was validated against a reconstructed 0009/0010-shaped
source snapshot. Do not switch this work to `/mnt/nvme_500g`; remount or restore
`/mnt/new_disk` before running the sequence above.

2026-07-02 result with 0009 applied, installed, and loaded:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260702_015604
```

Final verified host/module state:

```text
0009 face-GFN overlay state: applied
0008 high-GFN base state: not-applied
0007 private-fault-level state: not-applied
0006 flag-cleanup state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
running kernel: 5.19.0-cofunc-tdx-5.19+
built kvm.ko sha256: a011731fda9adad9aaf33124a808d0cd421f81d73c471632fdb67ae951a0007b
built kvm-intel.ko sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
installed kvm.ko.zst payload sha256: a011731fda9adad9aaf33124a808d0cd421f81d73c471632fdb67ae951a0007b
installed kvm-intel.ko.zst payload sha256: 2f25788c111ce280a4e90d11b1ab39a85659a6da99ac1c66a002ffb8de254df2
/dev/kvm users: none detected
```

Face smoke metrics:

```text
n=1 e2e=2.184123993 exec=2.107099771 grant_exec=0.609473450 pgfault_exec=0.655734288 accept=23.000 host_grant=0.000314718 cow=3399.000
paper check ratio for face: actual/expected = 3.540
```

Guest 2MB accept failures persisted in the runtime grant range:

```text
sc_host_gpa: 0x680000000
sc_host_mem_size: 0x20000000
2M reject reason lines: 28
first rejected GPAs/GFNs:
  0x683000000 -> gfn 0x683000
  0x683200000 -> gfn 0x683200
  0x683400000 -> gfn 0x683400
  0x69fc00000 -> gfn 0x69fc00
failure code: 0xc0000b0b00000001, page_size=1
```

Host diagnostic result:

```text
face-GFN private TDP level diagnostic lines: 0
face-GFN private MMU level diagnostic lines: 0
dmesg private TDP/MMU diagnostic lines: 0
kernel journal BUG: Bad page state lines: 58
dmesg BUG: Bad page state lines: 45
KVM_GET_CLOCK failed: 0
```

The absence of 0009 face-GFN private TDP/MMU lines is significant because the
source and loaded module both contain the 0009 markers. The bad-page stack for
the same run shows the runtime grant fault path going through the ordinary
userspace-HVA/GUP path:

```text
do_huge_pmd_anonymous_page
__get_user_pages
hva_to_pfn [kvm]
__gfn_to_pfn_memslot [kvm]
kvm_faultin_pfn [kvm]
direct_page_fault [kvm]
kvm_tdp_page_fault [kvm]
tdx_handle_exit [kvm_intel]
```

Updated interpretation: 0008 proved that some high-GFN private mappings can be
installed as 4KB leaves, but 0009 shows that the exact face runtime grant
GFNs do not enter the private-only KVM diagnostic path. For the runtime grant
pages that produce the 2MB accept rejections, the host evidence points instead
to the normal userspace-HVA/GUP + TDP path, likely with `fault->is_private == 0`
at the TDP map site. The next useful probe is not another private-only filter;
it should log all TDP mappings in the face grant range and include
`is_private`, slot flags, `req/goal/iter_level`, PFN/GFN alignment, and
`hva`.

Recommended next step:

```text
Prepare 0010 as an overlay on 0009 that logs all TDP mappings in
0x500000 <= gfn < 0x700000, without gating on is_private, and include
is_private in the printk. Rerun the same face smoke command once.
```

2026-07-02 next diagnostic prepared:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0010-Diagnostic-log-all-face-gfn-tdp-mappings.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_all_face_gfn_tdp_levels.sh
```

0010 is an overlay on top of 0009. It keeps the same face grant GFN filter
(`0x500000 <= gfn < 0x700000`) but removes the `is_private` gate from the TDP
logger and changes the printk marker to `CoFunc old-ABI face-GFN all TDP level
diagnostic`. It logs `private`, `slot_flags`, `hva`, `req/goal/host`,
`iter_level`, `iter_pages`, and GFN/PFN alignment.

Validation:

```text
0010 patch sha256: d6a8cbfc948105ec595307e7ec4bda6838c35fd25e7dac0c3e64b653030a3710
0010 script sha256: 80ce0c37c3c41309895dd164dc55673f144f497b3c6e3aad2b436b18da87bc12
0010 all-face-GFN TDP overlay state: not-applied
0009 face-GFN private base state: applied
0007 private-fault-level state: not-applied
0006 flag-cleanup state: not-applied
legacy 0005 state: not-applied
legacy 0004 state: not-applied
patch --dry-run against current 0009 source: clean
mount: ro,nosuid,nodev,relatime
```

Next command sequence:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_log_all_face_gfn_tdp_levels.sh --apply-build
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_all_face_gfn_tdp_levels.sh --check
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check
sudo env STOP_AFTER_SMOKE=1 COFUNC_OLDABI_RUNTIME_WORKLOAD=fn_py_face_detection /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

2026-07-02 continuation checkpoint after graphing detour:

Current local state:

```text
running kernel: 6.19.0-rc6-cofunc-tdx+
/mnt/new_disk mount: ro,nosuid,nodev,relatime
0011 face-GFN hugepage-decision state: not-applied
0010 all-face-GFN TDP base state: applied
0009 face-GFN private MMU base state: applied
0007 private-fault-level state: not-applied
0006 flag-cleanup state: not-applied
legacy 0005 skip-dirty/accessed state: not-applied
legacy 0004 skip-accessed state: not-applied
```

The latest 0010 run to analyze is:

```text
/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_20260702_020502
```

Smoke result:

```text
fn_py_face_detection TDX_CoFunc_fork=2.172s Artifact_C=0.617s actual/expected=3.521
```

0010 all-TDP diagnostic summary from `kernel-journal-since-start.log`:

```text
1022 mappings: private=1 max=1 req=1 goal=1 host=0 gfn_2m_aligned=0 pfn_2m_aligned=0
   2 mappings: private=1 max=2 req=1 goal=1 host=0 gfn_2m_aligned=1 pfn_2m_aligned=1
```

The two aligned mappings are the exact leading rejected runtime grant GFNs:

```text
gfn=0x683000 pfn=0x1e7ac00 max=2 req=1 goal=1 host=0 hva=0x78c41ca00000
gfn=0x683200 pfn=0x1e7b200 max=2 req=1 goal=1 host=0 hva=0x78c41cc00000
```

Interpretation: 0010 gives stronger evidence than 0009. The rejected face
runtime grant faults are marked private (`fault->is_private=1`) and can be
2MB-aligned in both GFN and PFN, but `kvm_mmu_hugepage_adjust()` still leaves
`req_level=PG_LEVEL_4K` and `goal_level=PG_LEVEL_4K`. The `slot_flags=0x0` and
`host=0` fields are suspicious because `kvm_faultin_pfn_private()` would set
`fault->host_level` from the private backing order only for `KVM_MEM_PRIVATE`
slots. This suggests a split-brain path: private GPA state with a non-private
classic userspace memslot, falling back to the normal HVA/GUP mapping path.

Next diagnostic remains 0011:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0011-Diagnostic-log-face-gfn-hugepage-decision.patch
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_hugepage_decision.sh
```

0011 should answer whether `req_level` is lowered by `slot_private=0` plus
`host_pfn_mapping_level()` returning 4KB, or by lpage disallow/dirty tracking.
Because the current host is booted into 6.19, do not run the 5.19 module
install/reload sequence until rebooted into `5.19.0-cofunc-tdx-5.19+`.

Next command sequence from a password-capable terminal:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_hugepage_decision.sh --apply-build
```

Then reboot/select the 5.19 kernel if still on 6.19, and run:

```bash
uname -r
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
/home/booklyn/cofunc-tdx/scripts/build_5_19_log_face_gfn_hugepage_decision.sh --check
/home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --check
sudo env STOP_AFTER_SMOKE=1 COFUNC_OLDABI_RUNTIME_WORKLOAD=fn_py_face_detection /home/booklyn/cofunc-tdx/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
```

## 2026-07-13 Vanilla Kata-TDX Bring-Up Checkpoint

### Scope Correction

The immediate goal is deliberately narrower than the prior CoFunc
investigation:

```text
Run an unmodified modern Kata guest and agent as a TDX CVM, then run a
minimal OCI container (busybox true).
```

Do not use FunctionBench, CoFunc runtime changes, huge-page experiments, or
the old Kata 2.4 agent as bring-up criteria.  The public CoFunc artifact and
its Fig. 11 plotting path label the Kata baseline as `Kata-CVM (SEV)`, so this
is a TDX adaptation, not an exact reproduction of that baseline.

### Known-Good Pieces

The host is the old Intel TDX 5.19 ABI and therefore requires the matching
old-ABI QEMU rather than a current upstream QEMU:

```text
host kernel: 5.19.0-cofunc-tdx-5.19+
QEMU:        /mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64
QEMU source: /mnt/new_disk/cofunc_tdx_artifact/provenance/qemu-candidates/qemu-tdx-2022-09-01-v7.1
wrapper:     /home/booklyn/cofunc-tdx/scripts/qemu_tdx_oldabi_normalmem_wrapper.sh
```

The wrapper translates the modern Kata QEMU command line into the pre-upstream
TDX ABI.  It is compatibility glue for the host ABI, not a Kata runtime or
agent modification.

Modern Kata is installed and boots successfully through that QEMU plus the
wrapper:

```text
Kata runtime/agent: 3.32.0 (commit 337b6002681479fb6a605ca8a7a1138e81b6098c)
kernel:             /opt/kata/share/kata-containers/vmlinuz.container (6.18.35-197)
image:              /opt/kata/share/kata-containers/kata-containers-confidential.img
firmware:           /opt/kata/share/ovmf/OVMF.inteltdx.fd
```

Guest serial output reaches `ttRPC server started`, proving that the TDX VM
boots and the Kata agent vsock service is reachable.  For example:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_smoke_oldabi_qemu7_kata_ovmf_normalmem_ktrace_20260710_111325/log/_helpers/qemu-wrapper-logs/kata-qemu-tdx-oldabi-serial.sandbox-kata-tdx-fn_py_face_detection-1-4087731.log
```

### Eliminated Guest Rootfs Transports

`virtio-9p` is not a viable workaround.  Kata agent 3.32 has no 9p storage
handler and fails task creation with:

```text
Failed to find the storage handler 9p
```

The earlier experimental configuration that set `shared_fs = "virtio-9p"`
must not be reused:

```text
/home/booklyn/cofunc-tdx/configs/configuration-qemu-tdx-artifact-qemu7-debug-kata-ovmf-normalmem.toml
```

Standard `virtio-fs` also cannot work with this old TDX/QEMU combination as
currently supplied.  TDX requires `VIRTIO_F_ACCESS_PLATFORM` for the
virtio-fs device.  When Kata requests it, the old QEMU vhost-user device
rejects it:

```text
iommu_platform=true is not supported by the device
```

When it is absent, the guest rejects the device:

```text
virtiofs ... device must provide VIRTIO_F_ACCESS_PLATFORM
```

This is a backend feature-negotiation problem, not a config spelling issue.
QEMU 7 only accepts the feature if virtiofsd advertises it.  The installed
Kata virtiofsd (v1.13.2 lineage) does not advertise Access Platform.  Do not
make QEMU falsely advertise it: that would bypass the DMA/IOTLB contract and
is not a correct TDX fix.

The attempted Kata 2.4 agent path is also closed.  It is not the requested
modern vanilla baseline and fails its vsock listener with `EOPNOTSUPP`.

### Current Decision

Use a block-rootfs transport.  This keeps the Kata 3.32 runtime, agent,
kernel, and confidential image unmodified; it avoids both the unsupported 9p
agent path and the old-QEMU virtio-fs DMA feature mismatch.

The required configuration shape is:

```toml
shared_fs = "none"
disable_block_device_use = false
block_device_driver = "virtio-scsi"
```

`disable_block_device_use = false` is valid only when containerd supplies the
container rootfs through a block-capable snapshotter.  The normal overlayfs
snapshotter is insufficient.  `/etc/containerd/config.toml` has empty
`blockfile` and `devmapper` plugin stanzas; do not assume either is configured
or usable yet.  Prefer an isolated `blockfile` trial before a `devmapper`
thin-pool setup.

### Next Steps and Acceptance Test

1. Inspect containerd plugin availability and blockfile configuration without
   changing the active runtime:

   ```bash
   sudo ctr plugins ls
   sudo containerd config dump
   ```

2. Create a dedicated Kata config that uses the normalmem old-ABI wrapper,
   `shared_fs = "none"`, and block-rootfs.  It must not inherit the 9p,
   Kata-2.4, CPU-mask, or agent-CID experiments.

3. Back up `/etc/containerd/config.toml`, configure only the selected block
   snapshotter, and restart containerd.  This can interrupt existing
   containers but does not require a host reboot; coordinate it because this
   is a shared machine.

4. Run a standalone smoke test with the block snapshotter and the dedicated
   Kata runtime:

   ```bash
   sudo ctr --snapshotter <block-snapshotter> run --rm \\
     --runtime io.containerd.kata-qemu-tdx.v2 \\
     docker.io/library/busybox:latest kata-tdx-block-smoke true
   ```

5. Accept the Kata-TDX path only if the command exits `0` and the guest serial
   log shows agent startup without a QEMU/virtio transport error.  Only after
   this passes should FunctionBench and graph generation resume.

The CoFunc 2 MiB-promotion/A-D page-state investigation is independent of this
bring-up and remains frozen until the minimal Kata smoke succeeds.

### 2026-07-13 Vanilla Kata-TDX Acceptance Test Passed

The minimal OCI acceptance test completed successfully:

```text
run:     /home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_blockroot_smoke_20260713_050548
image:   docker.io/library/busybox:1.36.1
command: true
result:  Kata-TDX block-rootfs smoke passed
```

This proves that a modern, unmodified Kata 3.32 runtime and agent can execute
an OCI workload as a TDX CVM on this old 5.19 TDX ABI host when using:

```text
old-ABI QEMU 7 compatibility wrapper
containerd blockfile snapshotter for the OCI rootfs
shared_fs = "none"
QEMU 7 block_device_aio = "threads"
```

The wrapper is host-ABI compatibility glue.  No Kata runtime, agent, guest
kernel, or confidential guest image source was modified for this path.

The immediate bring-up goal is complete.  The next functional expansion, if
needed, is a narrow real workload smoke, followed by the existing FunctionBench
runner only after preserving this block-rootfs configuration.

### Prepared FunctionBench Blockfile Smoke

The generic workload runner now accepts two opt-in variables:

```text
CONTAINERD_SNAPSHOTTER=blockfile
CONTAINERD_PLATFORM=linux/amd64
```

When set, it verifies the snapshotter status, imports the Docker archive with
`ctr images import --local --platform linux/amd64 --snapshotter blockfile`, and
passes `--snapshotter blockfile` to `ctr run`.  When unset, the original
overlayfs behavior is unchanged.

The first narrow real-workload entry point is:

```text
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_face_smoke.sh
```

It runs exactly one `fn_py_face_detection` FunctionBench invocation with the
accepted Kata block-rootfs config and a 300-second timeout.  It is intentionally
separate from the full Fig. 11 runner.  Before use, cache sudo credentials in a
password-capable terminal:

```bash
sudo -v
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_face_smoke.sh
```

### 2026-07-13 Face Image Capacity Finding

The first real FunctionBench face-detection smoke reached containerd blockfile
image import, but did not launch Kata. The only consequential failure was:

```text
write .../usr/bin/lto-dump: no space left on device
```

The 512 MiB blockfile scratch filesystem is too small for the face-detection
image. The BuildKit messages about the temporary Dockerfile `ARG` default and
missing Git commit information are non-fatal metadata warnings; the image build
itself completed.

The later inspection corrected an important assumption: containerd 2.2.1's
blockfile snapshotter uses its own canonical `$root_path/scratch` file as the
template for every snapshot. The configured `scratch_file` is copied there only
when the canonical file is missing or `recreate_scratch=true`. Because the
configuration kept `recreate_scratch=false`, the existing 512 MiB
`kata-blockfile/scratch` remained active throughout both retries. The named
`scratch-2g.ext4` and `scratch-8g.ext4` files were not the files being cloned.

The image metadata proves that capacity beyond 2 GiB is unnecessary: the final
loopback-rewritten face image is 757,817,405 bytes across 23 layers. The helper
now defaults back to `scratch-2g.ext4` and sets `recreate_scratch=true` during
the containerd restart, deliberately regenerating the canonical scratch file.
This keeps per-layer blockfile consumption far lower than the 8 GiB trial. The
helper's `--check` output reports both the configured source and canonical
scratch sizes. `/Serverless` has approximately 711 GiB free, sufficient for
this trial. The next required sequence is:

```bash
sudo -v
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_blockfile_snapshotter.sh --apply
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_blockfile_snapshotter.sh --inspect
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_face_smoke.sh
```

The setup step restarts containerd, so coordinate it as for the initial
blockfile setup. It keeps a timestamped containerd configuration backup for
rollback.

If an import fails again, do not resize or retry immediately. First collect the
read-only blockfile state:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_blockfile_snapshotter.sh --inspect
```

This reports the configured source and canonical scratch capacities, logical
and allocated sizes of all retained blockfile files, and `ctr` snapshot
metadata. It is intended to detect stale blockfile state after an import
failure.

### 2026-07-13 Face Rootfs And Network Finding

With the canonical scratch fixed, the existing imported
`kata-tdx-fn_py_face_detection:latest` image was run successfully through the
blockfile snapshotter and Kata with the command `true`. This proves that the
758 MB, 23-layer image, its block rootfs, modern Kata agent, old-ABI QEMU
wrapper, and TDX guest boot path are all working together.

The FunctionBench runner had additionally passed `ctr run --net-host`. Its
Kata agent failed before process launch with `ENOENT` and then terminated QEMU
during cleanup. The host has no CNI configuration in `/etc/cni/net.d`, so the
runner now takes `CONTAINERD_NETWORK_MODE` (`none`, `cni`, or `host`) and the
narrow face smoke explicitly uses `none`. This isolates workload execution
from the unsupported host-network path. A later failure to reach the MinIO or
parameter helpers would be a separate guest-network provisioning task, not a
Kata/TDX boot or rootfs failure.

The no-network face run reached `/func/main.py` and failed only with
`URLError: [Errno 101] Network unreachable` when contacting the parameter
service at `172.16.0.1:8888`. The host has the required `/opt/cni/bin/bridge`
and `host-local` plugins. The opt-in helper installs a dedicated CNI
configuration for a `cofunc0` bridge at `172.16.0.1/16`; it does not restart
containerd or alter the physical, Docker, or libvirt interfaces:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_cni_network.sh --apply
CONTAINERD_NETWORK_MODE=cni /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_face_smoke.sh
```

The host CNI directory also contains `10-calico.conflist` and
`10-flannel.conflist`. `ctr --cni` selects the lexically first configuration;
the initial `10-cofunc-tdx.conflist` therefore invoked Calico instead. The
helper now installs `00-cofunc-tdx.conflist`, and on its next `--apply` backs
up and removes only its previous `10-cofunc-tdx.conflist` file. It does not
modify the Calico or Flannel configuration files.

The corrected CNI run on 2026-07-13 used `00-cofunc-tdx.conflist` and did not
invoke Calico. Host journal evidence confirms that it created `cofunc0` and a
veth pair, and Kata received an interface request for
`eth0=172.16.1.1/16`. The first run exited before the asynchronous network
rescan completed, so a timing race was initially plausible.

`run_kata_tdx_workload.sh` now accepts `KATA_PRE_COMMAND_DELAY`, defaulting to
zero. A 12-second confirmation run kept the VM alive, but the guest-agent
request then failed with:

```text
interface not available: Timeout after 3s waiting for uevent NetPciMatcher
{ devpath: "/devices/pci0000:00/0000:00:02.0/0000:01:01.0" }
```

The CNI network is therefore working, but the old TDX QEMU path is not
presenting Kata's dynamically hot-plugged virtio NIC to the guest. The next
investigation is QEMU PCI device hot-plug or a cold-plugged Kata-compatible
network device; it is not the FunctionBench image, blockfile rootfs, CNI
selection, or host routing. The runner records `t_network_wait_begin` and
`t_network_wait_done` around this diagnostic delay:

```bash
CONTAINERD_NETWORK_MODE=cni KATA_PRE_COMMAND_DELAY=12 \
  /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_face_smoke.sh
```

### 2026-07-13 CRI Cold-Plug Route

`ctr run --cni` starts the Kata VM before the CNI network is created. It
therefore requires a late virtio NIC hot-plug. On the old TDX QEMU path, the
shim receives a successful-looking endpoint but the guest agent times out
waiting for the PCI uevent at `00:02.0/01:01.0`. A 12-second pre-command wait
proved that this is not merely an ordering race.

The host already has the CRI runtime handler `kata-qemu-tdx` and `crictl`.
CRI provides the standard pod-sandbox lifecycle, including CNI provisioning
before Kata starts the workload container, so it is the narrow cold-plug
alternative to test before adding any network behavior to the old-ABI QEMU
wrapper.

The following helper has passed `--plan` against the active configuration:

```text
/home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_cri_blockroot.sh
```

Its `--apply` mode backs up `/etc/containerd/config.toml`, installs a dedicated
Kata config at `/etc/kata-containers/configuration-qemu-tdx-blockroot.toml`,
and changes only the `kata-qemu-tdx` CRI handler to use that config and the
`blockfile` snapshotter. It then restarts containerd. The restart can briefly
interrupt containerd-managed workloads, so it must be performed only when the
shared host is clear:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_cri_blockroot.sh --apply
```

The first post-change test is a CRI network probe using the already built face
image. It sends the same parameter-service POST to `172.16.0.1:8888` from a
Kata pod and cleans up only its own pod and container. It does not pull images
or start helper services; it reports a missing local pause image or parameter
helper explicitly:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_network_smoke.sh
```

This probe passed at `2026-07-13T09:01:32Z`: the CRI pod sandbox and workload
container were both created, the guest received `parameter_status=200`, and
the container exited with status `0`. The initial `RunPodSandbox` timeout was
not a TDX or QEMU rejection: `crictl` defaults to a two-second client timeout,
which is too short for a cold old-ABI TDX Kata boot. The probe now passes
`--timeout 120s` and `runp --cancel-timeout 120s`.

### 2026-07-13 Full Vanilla Kata TDX Face Workload Passed

The focused CRI workload runner is:

```text
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_face_workload.sh
```

It preserves the accepted modern Kata 3.32 runtime and agent, old-ABI TDX QEMU
wrapper, blockfile rootfs, and CRI cold-plugged CNI path. It verifies the host
MinIO and parameter helpers, runs the artifact's normal `prepare.py`, then
executes the unchanged function command, `/usr/bin/python /func/main.py`, in a
Kata TDX pod:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_face_workload.sh
```

Successful evidence:

```text
run:          /home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_face_workload_20260713_090436
pod_id:       1040ac52fd41c9f3eaeb198f8901f230a688378f1c7d2d9ad4fd8a19baa0f3b6
container_id: 5b37f42be591322143abcfa546011ea644093a54c1bc4b424a6c2058f4463408
t_import_begin 1783933483.8307686
t_func_load_begin 1783933485.4202626
t_import_done     1783933485.4209828
t_func_done       1783933485.9052403
container_state=CONTAINER_EXITED
container_exit_code=0
Kata-TDX CRI face-detection workload passed
```

This establishes the bring-up goal: an unmodified Kata guest can run the
FunctionBench face workload in a TDX CVM on this host. It does not yet make the
existing Fig. 11 `ctr --cni` runner valid, because that runner still relies on
the unsupported late virtio-NIC hot-plug path. Any benchmark extension must
use the CRI pod lifecycle (or provide an equivalent cold-plugged NIC), not
re-enable `ctr --cni`.

### 2026-07-13 Implementation Handoff: Generalize CRI to Fig. 11

#### Objective and Fixed Boundary

The next objective is to run all Fig. 11 workloads through the proven CRI
cold-plug path and generate analyzer-compatible Kata timing logs and graphs.
There are 12 executable function entries, which the plotting code aggregates
into 9 paper workloads because the 4 Alexa members form one `alexa` bar.

Do not change the host kernel, KVM modules, QEMU, OVMF, Kata runtime, Kata
agent, or guest image while implementing this step. The face success shows
that those layers are sufficient. The remaining work is user-space runner,
helper-service, logging, and plotting integration.

Known-good foundation:

```text
Kata config:
/etc/kata-containers/configuration-qemu-tdx-blockroot.toml

source Kata config:
/home/booklyn/cofunc-tdx/configs/configuration-qemu-tdx-artifact-qemu7-blockroot-normalmem.toml

CRI runtime handler:
kata-qemu-tdx

containerd snapshotter:
blockfile

CNI config selected first:
/etc/cni/net.d/00-cofunc-tdx.conflist

working face runner:
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_face_workload.sh

working face run:
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_face_workload_20260713_090436
```

The active CRI/containerd configuration is already applied. Do not restart
containerd or rerun an `--apply` helper merely to begin implementation. This
is a shared host; only change system configuration when a read-only preflight
proves that it has drifted and the user confirms that a restart is acceptable.

#### Deliverables

1. Add a generic runner:

   ```text
   /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_workload.sh
   ```

   Intended interface:

   ```bash
   sudo /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_workload.sh \
     <workload-path> <repetitions>
   ```

2. Keep `run_kata_tdx_cri_face_workload.sh` as a thin compatibility/smoke
   wrapper around the generic runner. The known face command must continue to
   pass after generalization.

3. Extend `testcases/tools/analyze.py` with an explicit input-log option while
   retaining `exec_log` as its backward-compatible default. The generic CRI
   runner must never depend on a shared mutable `exec_log` in a workload source
   directory.

4. Add a CRI-specific Fig. 11 orchestrator:

   ```text
   /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_fig11.sh
   ```

   Use `run_kata_tdx_fig11.sh` only as a source for workload counts, output
   layout, pre/postflight behavior, and graph invocation. Do not call its
   existing `ctr --cni` workload runner.

#### Generic Runner Contract

For a workload path such as `chain_js_alexa/fn_js_alexa_frontend`, preserve the
full path for logs and parameter-service names, but derive the Docker image
name from the final path component, matching the artifact's existing build
tools.

The generic runner should perform this flow:

1. Validate the workload path and read its existing `command` file. Commands
   differ by image and must not be hard-coded:

   ```text
   Python: /usr/bin/python or /usr/local/bin/python /func/main.py
   Node:   /usr/local/bin/node /func/main.js or /func/index.js
   ```

2. Verify the required helper services before changing or launching anything.
   Run optional `prepare.py` outside the timed region and as the invoking user,
   following the established `SUDO_USER`/`runuser` behavior.

3. Build the artifact source image only when missing. Build a separate
   `kata-tdx-<basename>:latest` image that rewrites workload/template loopback
   endpoints from `127.0.0.1` to the CNI gateway `172.16.0.1`. Do not mutate the
   original artifact image. Apply the rewrite to both Python and JavaScript
   files under `/func`, as the existing Kata workload runner does.

4. Import the derived image into containerd namespace `k8s.io` with
   `--local --platform linux/amd64 --snapshotter blockfile`. Skip import when
   the same image/digest is already present. Check names with:

   ```text
   ctr -n k8s.io images ls -q
   ```

   Do not use `crictl images -q` for a name-presence test; it prints image IDs,
   which previously caused every invocation to re-import both images.

5. Create a fresh CRI pod sandbox for every measured sample. This is required
   for a real Kata cold start and for the NIC to be present at VM boot. Reusing
   one pod for several function containers would measure warm containers and
   would not be comparable to the paper's Kata baseline.

6. Use duration-valued CRI timeouts, for example `300s`. Bare integers such as
   `120` are invalid for the installed `crictl`. Pass both the global
   `--timeout` and `runp --cancel-timeout`; the default two-second client
   timeout is shorter than this host's old-ABI TDX boot.

7. Record `t_launch_begin` immediately before `crictl runp`. Start the workload
   container with a guest shell command that prints `t_import_begin` and then
   `exec`s the workload's unmodified command. Capture these markers from the
   container log:

   ```text
   mode kata-launch
   t_launch_begin
   t_import_begin
   t_func_load_begin
   t_import_done
   t_func_done
   ```

8. Save pod/container JSON, container output, image digest, run environment,
   and runner log before cleanup. On success or failure, remove only the pod
   and container IDs created by that invocation. A failed sample must stop the
   batch and must not be silently discarded or replaced during a measured run.

9. Run `analyze.py` on each isolated sample log and append one JSON record to:

   ```text
   <log-root>/<workload-path>/kata_launch.log
   ```

   `analyze.py` already maps `mode kata-launch` to `t_boot_cntr`,
   `t_boot_func`, `t_exec`, and `t_e2e`. Preserve that schema because
   `cofunc_e2e_stage_breakdown.py` consumes it directly.

#### Fig. 11 Workload and Helper Matrix

Every workload uses the parameter service on host port `8888` through the
CNI gateway. Additional requirements are:

| Workload entries | Additional services and setup |
| --- | --- |
| `fn_py_sentiment` | None |
| Alexa `frontend`, `interact`, `smarthome` | None |
| `fn_py_face_detection`, `fn_py_image_processing`, `fn_py_compression`, `fn_py_dna_visualisation`, `fn_py_video_processing`, `fn_js_thumbnailer` | MinIO on `9000`; run each available `prepare.py` |
| `fn_js_uploader` | MinIO on `9000`, file server on `8080`, and `prepare.py` |
| Alexa `fn_js_alexa_tv` | Device service on `9090` |

CouchDB is not required by the Fig. 11 workload set. Do not add it to the
critical path unless a workload produces direct evidence that it is needed.

#### Validation Gates

Do not start the full matrix immediately. Use these gates:

1. Re-run face once through the generic runner. It must reproduce all five
   timing markers and exit `0`.
2. Run `fn_py_sentiment` once to validate a Python image without MinIO.
3. Run Alexa frontend once to validate the Node image/template path.
4. Run image processing, compression, thumbnailer, and DNA once each.
5. Run uploader and Alexa TV once each to validate ports `8080` and `9090`.
6. Run video once, last, because it is the largest and slowest workload.
7. Run the remaining Alexa members once and confirm that all 12 executable
   entries pass.

After each group, inspect host kernel messages for `BUG: Bad page state`, TDX
EPT failures, KVM faults, or page-state warnings. Also verify that no test pod,
container, shim, or QEMU process remains. Preserve diagnostics before cleanup
when a failure occurs.

Before importing all workload images, verify host free space and blockfile
snapshot capacity. The current sparse 2 GiB scratch image passed face, but
larger images, especially video, must be checked rather than assumed to fit.
If a larger scratch image is required, make that a separate reviewed system
configuration change before performance collection.

#### Measurement Matrix

After all one-shot gates pass, prebuild and import every image and prepare all
input data before starting timed samples. Run one unrecorded warm-up per
workload, then preserve the current experiment counts:

```text
fn_py_dna_visualisation                         10
fn_py_compression                              20
fn_py_face_detection                           20
fn_py_image_processing                         20
fn_py_sentiment                                20
fn_py_video_processing                          5
fn_js_thumbnailer                              20
fn_js_uploader                                 20
chain_js_alexa/fn_js_alexa_frontend            20
chain_js_alexa/fn_js_alexa_interact            20
chain_js_alexa/fn_js_alexa_smarthome           20
chain_js_alexa/fn_js_alexa_tv                  20
```

Record kernel release and cmdline, KVM module hashes/srcversions, QEMU and Kata
versions, Kata/containerd/CNI config hashes, image digests, THP state, CPU
governor, and host-load preflight in the run directory. This is a shared host:
do not collect performance data while another user's VM/container benchmark is
active, and do not restart services during the measurement matrix.

#### Graph Outputs and Acceptance

Feed the completed log root into:

```text
/home/booklyn/cofunc-tdx/scripts/cofunc_e2e_stage_breakdown.py
/home/booklyn/cofunc-tdx/scripts/cofunc_e2e_stage_bar_charts.py
```

Produce JSON, CSV, Markdown, PNG, and PDF artifacts under the timestamped run
directory and `~/BookArchive/Images`. The current chart code maps all four
`chain_js_alexa/...` workload paths to `chain_js_alexa` and sums their stage
means into the single Alexa bar; preserve that behavior for paper comparison.

The full task is complete only when:

- all 12 one-shot smokes exit `0`;
- every measured workload has the requested sample count with no hidden
  omissions;
- every sample has all timing markers and an analyzer record;
- stage sums match E2E within the analyzer's 1 ms tolerance;
- no kernel/KVM/TDX page-state regression appears;
- cleanup leaves no experiment pod, shim, QEMU, or container behind; and
- the cold/Kata graph contains all 9 Fig. 11 workload bars.

#### Paths That Must Not Be Reintroduced

- Do not use `ctr run --cni`; it requires unsupported late virtio-NIC hotplug.
- Do not use `--net-host`; it failed before workload process launch.
- Do not return to virtio-fs or 9p; the accepted transport is blockfile rootfs
  with `shared_fs = "none"` and `block_device_aio = "threads"`.
- Do not use the old two-second `crictl` timeout.
- Do not treat `crictl images -q` output as image names.
- Do not modify kernel/QEMU/firmware to solve a runner-level workload failure
  until the CRI, helper-service, image, and command logs have excluded those
  layers.

### Prepared Local Inputs

The following user-owned files are ready and deliberately do not modify the
active Kata configuration or containerd until explicitly run with `sudo`:

```text
Kata block-rootfs config:
/home/booklyn/cofunc-tdx/configs/configuration-qemu-tdx-artifact-qemu7-blockroot-normalmem.toml

containerd blockfile setup/rollback helper:
/home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_blockfile_snapshotter.sh

minimal OCI smoke runner:
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_smoke.sh
```

### 2026-07-13 Blockfile Device AIO Correction

The corrected blockfile pull and unpack succeeded in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_blockroot_smoke_20260713_045555
```

The first actual Kata task creation then reached QMP block-device hotplug and
failed before guest execution:

```text
QMP command failed: Parameter 'aio' does not accept value 'io_uring'
```

The old TDX QEMU 7 build does not accept `io_uring` for this device path.  The
dedicated block-rootfs config now sets:

```toml
block_device_aio = "threads"
```

This is the portable QEMU 7 AIO mode.  It changes only the block-rootfs
experiment; the regular Kata and CoFunc configurations remain untouched.  No
containerd change or restart is needed.  Rerun only the block-rootfs smoke
runner.

The new config is a three-line delta from the last modern Kata normalmem config:

```diff
-disable_block_device_use = true
+disable_block_device_use = false
-shared_fs = "virtio-9p"
+shared_fs = "none"
-block_device_aio = "io_uring"
+block_device_aio = "threads"
```

The setup helper creates a sparse 2 GiB ext4 scratch image under
`/Serverless/containerd/data/kata-blockfile`, backs up
`/etc/containerd/config.toml` to `~/BookArchive/KataTdxBackups`, applies the
blockfile stanza, restarts containerd, and verifies the plugin.  If containerd
cannot restart or the plugin does not reach `ok`, it automatically restores the
saved configuration and restarts containerd again.

Run the following in a password-capable terminal, after checking that a
containerd restart is acceptable to other users of the shared host:

```bash
sudo -v
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_blockfile_snapshotter.sh --check
sudo /home/booklyn/cofunc-tdx/scripts/prepare_kata_tdx_blockfile_snapshotter.sh --apply
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_smoke.sh
```

The smoke runner uses `ctr --runtime-config-path` with the dedicated config, so
it does not overwrite `/etc/kata-containers/configuration-qemu-tdx.toml`.  It
records the QEMU command, QEMU stderr, and guest serial output in a timestamped
directory below `~/BookArchive/StageBreakdownRuns`.

### 2026-07-13 Blockfile Pull Correction

The first blockfile smoke attempt stopped before QEMU/Kata launch with:

```text
ctr: unable to initialize unpacker: no unpack platforms defined: invalid argument
```

Cause: containerd 2.2's transfer service has an explicit unpack configuration
for `overlayfs` only.  A normal `ctr images pull --snapshotter blockfile`
therefore requests a blockfile unpack target that the transfer service filters
out, leaving no target platform for its unpacker.  This is neither a blockfile
plugin failure nor a Kata/TDX failure.

`run_kata_tdx_blockroot_smoke.sh` now uses the direct client path:

```bash
ctr images pull --local --platform linux/amd64 --snapshotter blockfile ...
```

`--local` bypasses the transfer-service target filter and asks the client to
unpack directly into the configured blockfile snapshotter.  The installed
containerd 2.2.1 `ctr images pull --help` confirms both flags.  Do not rerun
the containerd setup helper for this correction; rerun only:

```bash
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_blockroot_smoke.sh
```
## 2026-07-14 Kata-TDX Fig. 11 image-GC race

The first generic CRI Fig. 11 smoke matrix stopped at
`chain_js_alexa/fn_js_alexa_interact` in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_fig11_20260714_045033
```

This was not a Kata boot, TDX, CNI, Node.js, or Alexa workload failure.  The
pod sandbox booted, but CRI could no longer resolve the workload image when it
created the workload container.  The runner had observed the containerd tag at
05:03:58, then kubelet image GC removed that exact image at 05:04:05, one second
before `CreateContainer` failed:

```text
05:04:05 kubelet image_gc_manager: usage=89 highThreshold=85
05:04:05 kubelet: Removing image sha256:2838aac5... (Alexa interact)
05:04:05 containerd: ImageDelete kata-tdx-fn_js_alexa_interact:latest
05:04:06 containerd: CreateContainer ... image ... not found
```

The same GC pass subsequently removed smarthome, face detection, frontend,
sentiment, thumbnailer, compression, and image-processing images.  This also
explains why a successful earlier workload image was absent from both `ctr`
and `crictl` after the run.  Kubelet is connected to the same containerd CRI
socket and has `imageMinimumGCAge: 0s`, so an unused direct import is eligible
for immediate reclamation under image-filesystem pressure.

The generic runner now marks imported runtime references with
`io.cri-containerd.image=managed`, temporarily adds
`io.cri-containerd.pinned=pinned` for the lifetime of that workload runner,
and validates the reference through `crictl inspecti`.  Cleanup removes only a
pin created by the runner and preserves a pre-existing pin.  The pause image is
not temporarily pinned by this code.  This intentionally avoids disabling or
reconfiguring kubelet image GC on the shared host.

### 2026-07-14 Kata-TDX Fig. 11 image-GC pin validation

The first targeted Alexa Interact validation stopped before pinning because
`sudo docker save` created a root-owned archive in sticky `/tmp`, while the
runner tried to remove it as the invoking user.  The import had completed, but
the cleanup failure correctly stopped the run before a pod was created:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_interact_pinned_20260714_052851
```

`import_image` and its EXIT cleanup now remove that archive with the same
`SUDO` context as `docker save`.  This is runner-local cleanup only; the
retained failed-run archive remains preserved as evidence.

The corrected pinned-image validation passed in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_interact_pinned_20260714_053359
```

The runner logged the temporary pin at `05:34:09Z`, created a fresh Kata CRI
sandbox, and logged its release at `05:34:20Z`.  The container exited `0` and
emitted all required markers.  The analyzer record is valid:

```json
{"t_boot_cntr": 7.646980047225952, "t_boot_func": 0.4384448528289795,
 "t_exec": 0.029000043869018555, "t_e2e": 8.11442494392395}
```

Next, validate `chain_js_alexa/fn_js_alexa_smarthome` once using the same
generic runner.  If it passes, rerun the staged Fig. 11 CRI orchestrator.

The Smarthome pin validation also passed in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_smarthome_pinned_20260714_054134
```

It was temporarily pinned at `05:42:34Z`, its fresh CRI container exited `0`,
and the runner released the temporary pin at `05:42:50Z`.  The required
markers and analyzer record were preserved:

```json
{"t_boot_cntr": 10.438823938369751, "t_boot_func": 0.5189528465270996,
 "t_exec": 0.04200005531311035, "t_e2e": 10.999776840209961}
```

Both Alexa images that were directly affected by the previous kubelet image-GC
pass are now proven through the pin/launch/release lifecycle.  The next action
is the staged Fig. 11 orchestrator.  It reruns the twelve isolated smoke
gates, prebuilds inputs, performs one unrecorded warm-up for each workload,
and then collects the requested 215 cold-start samples.

### 2026-07-14 Fig. 11 staged run: QEMU/KVM failure and pin-cleanup correction

The staged collector ran in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_fig11_20260714_054919
```

All twelve smoke gates and all twelve warm-ups passed.  The measured
`fn_py_dna_visualisation` batch produced nine valid, preserved cold-start
records.  Sample 10 did not start its sandbox.  This is not an image-GC,
container-image, CNI, or FunctionBench failure.

The failure evidence is preserved under:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_fig11_20260714_054919/failure-evidence
```

Containerd started the sample-10 sandbox at `06:10:54Z`; QEMU then aborted at
`06:10:58Z` (exit 134).  The wrapper's QEMU stderr log records:

```text
error: kvm run failed Input/output error
KVM_GET_CLOCK failed: Input/output error
```

The later CRI vsock timeout was a downstream symptom of that QEMU abort.  At
`06:12:02Z`, cleanup also triggered a host kernel warning in
`__handle_changed_spte` (`arch/x86/kvm/mmu/tdp_mmu.c:627`), in the KVM TDP-MMU
path while handling TDX page reclamation.  There were no CRI pods or
containers bearing the Fig. 11 run token after the failure.

Do not resume performance collection or retry sample 10 until the shared-host
owner has reviewed this QEMU/KVM/TDX failure.  Do not reboot or restart
containerd, kubelet, Kata, QEMU, or KVM as part of this reproduction task.

The run also exposed a runner-local cleanup defect: passing
`io.cri-containerd.pinned-` to `ctr images label` added that literal label
instead of removing `io.cri-containerd.pinned`.  Thus the runner incorrectly
left its twelve benchmark image pins in place.  The generic runner now clears
both keys with empty values and verifies their absence before logging pin
release.  The Fig. 11 orchestrator now uses the supported `dmesg --time-format
iso` and captures post-failure CRI/process/kernel diagnostics through its EXIT
trap.  These user-space corrections are syntax-validated but have not been
runtime-validated; they do not modify any host runtime configuration.

Before any future benchmark attempt, remove the stale runner-created pins from
only the twelve `docker.io/library/kata-tdx-fn_*:latest` references that carry
the erroneous `io.cri-containerd.pinned-=true` label.  Do not touch the
pause-image pin or any image lacking that erroneous runner marker.

The stale-pin cleanup completed successfully.  The explicit twelve-image
target list is preserved at:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_fig11_20260714_054919/failure-evidence/runner-created-pins-to-release-v2.txt
```

The post-cleanup `ctr -n k8s.io images ls` capture is preserved alongside it
as `containerd-images-after-pin-cleanup.txt`.  It confirms that none of the
twelve `kata-tdx-fn_*:latest` references retains either CRI pin label.  The
separately managed `registry.k8s.io/pause:3.8` pins are still present and were
not altered.

### 2026-07-14 host-safety stop and SEPT failure analysis

The failure was more severe than the first summary above implied.  The first
kernel warning occurred at `06:11:02Z`, during sample 10 itself, at
`tdx_sept_zap_private_spte()`.  KVM attempted `TDH_MEM_RANGE_BLOCK` for private
4K GFN `0x7c27d`, but the TDX module reported that the child SEPTE was already
`SEPT_BLOCKED`.  KVM then attempted `TDH_MEM_PAGE_REMOVE` and received the same
`TDX_EPT_WALK_FAILED`.  The automatic teardown at `06:12:01Z` expanded the
damage into ten `TDH_PHYMEM_PAGE_RECLAIM -> TDX_PAGE_METADATA_INCORRECT`
warnings.  There was no host panic and no `BUG: Bad page state` in this run.

The post-failure audit also found a stale Kata-TDX VM from the July 13 direct
`ctr` experiment: shim PID `158884`, wrapper PID `158906`, QEMU PID `158965`,
and container ID `kata-tdx-fn_py_face_detection-1-155661`.  QEMU still owned
`/dev/kvm`, and the task metadata was stuck in `CREATED`.  Evidence is under:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_fig11_20260714_054919/host-safety-audit
```

The host owner coordinated a reboot.  The clean boot is kernel
`5.19.0-cofunc-tdx-5.19+`, boot ID
`c56678bd-a057-4df2-b363-027b20e17de9`, started at `2026-07-14 07:12:03Z`.
After remounting `/mnt/new_disk`, there were no Kata/QEMU processes, no
containerd tasks, no `/dev/kvm` owners, and `kvm_intel` had use count zero.

The runners now fail closed through:

```text
/home/booklyn/cofunc-tdx/scripts/kata_tdx_host_safety_gate.sh
```

The gate checks the current-boot kernel log, expected kernel, TDX module state,
KVM module use count, `/dev/kvm` owners, Kata/QEMU processes, and Kata records
in the `default` and `k8s.io` namespaces.  The generic CRI runner verifies that
container and pod records actually disappear before clearing their IDs.  If a
KVM/TDX stop marker appears, it refuses to initiate further CRI teardown and
preserves the IDs for coordinated recovery.  The Fig. 11 orchestrator invokes
the gate at each preflight.  These scripts pass `bash -n`; no TDX VM has been
launched with them yet.

#### Root-cause evidence for the 4K `SEPT_BLOCKED` child

The official Intel TDX module 1.5 source was inspected at:

```text
/tmp/confidential-computing.tdx.tdx-module-tdx_1.5
```

`TDH_MEM_PAGE_DEMOTE` explicitly calls `sept_unblock()` on a blocked large
leaf before cloning it into 512 child entries.  Therefore, demoted child
entries are already unblocked.  This explains the archived patch-0020 result
`0xc0000b0d00000001`: it is `TDX_EPT_ENTRY_STATE_INCORRECT`, operand RCX,
because patch 0020 tried to unblock already mapped children.  Do not reapply
patch 0020.

The old September 2022 KVM TDX code has a different problematic path in
`tdx_handle_private_zapped_spte()`: when a blocked 2M software SPTE is split,
KVM demotes it and then re-blocks all 512 4K SEPT children while installing
present KVM child SPTEs.  A subsequent partial `MAP_GPA` zap sees the target
KVM child as present and calls `TDH_MEM_RANGE_BLOCK` again.  The module sees
the child as already `SEPT_BLOCKED`, exactly matching the July 14 GFN, level,
call stack, and module output.  This path was dormant before the custom
old-ABI 2M promotion made normal-slot private 2M leaves common.

This is a strong causal explanation, but no corrective kernel patch has been
accepted or run.  Changing the split path requires careful handling of the
window between demote and the target-child block; simply unblocking every
child is wrong.

#### Conservative next A/B

For the Vanilla Kata baseline, first disable only the custom old-ABI private
2M promotion and retain the current normal-slot private TDP SPTE A/D
suppression and page-release cleanup.  This returns Vanilla Kata to the normal
4K private mapping behavior and avoids the suspect large-private split path.
The existing helper has been updated to recognize the current A/D and cleanup
markers and now requires the A/D suppression to remain applied:

```text
/home/booklyn/cofunc-tdx/scripts/build_5_19_disable_oldabi_private_2m.sh
```

Its read-only check currently reports: 0017 not applied; private TDP A/D
suppression applied; fault-release cleanup applied; TDX unpin cleanup applied;
and 0013 private 2M promotion applied.  The patch dry-run succeeds.  Applying
and building it writes the mounted kernel tree and must be done only with host
owner coordination.  It does not install modules or reload KVM.

After building, install the exact rebuilt modules with the existing guarded
module installer, reboot once, run the host-safety gate, and perform only one
isolated Vanilla Kata face smoke.  Stop immediately on any gate failure or
kernel marker.  Do not resume the full 215-sample collector until the isolated
smoke and a short multi-launch churn both complete with a clean post-run gate.

The stale July 13 default-namespace container metadata was inspected and then
deleted by exact ID.  It had no task, QEMU process, or `/dev/kvm` owner.  The
post-cleanup gate reported `host_safety=ready` for every check.

The no-2M A/B was built at `2026-07-14T16:12:29Z`.  Evidence and the pre-patch
source backup are in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-disable-oldabi-private-2m-20260714_161229
```

Built module hashes:

```text
kvm.ko       90e38c3a4f52afe1c2b2913ab4d7cea2796ff6ee5d076801a4ecf923117c4704
kvm-intel.ko d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
```

The modules were installed on disk without reloading KVM.  The rollback backup
is:

```text
/mnt/new_disk/cofunc_tdx_artifact/module-backups/kvm-5.19/5.19.0-cofunc-tdx-5.19+-20260714_164827
```

The installed payload hashes match the built files exactly.  At this handoff
point, the previous modules are still loaded; no VM has used the no-2M build.

The no-2M modules were subsequently reloaded without reboot.  Both the
pre-reload and post-reload host gates reported `host_safety=ready`.  Loaded
source versions are:

```text
kvm       22B2A410CCC77E86F9E3BC7
kvm_intel 5E9FE6DC9A74E201D9D3C2E
```

The first attempted face smoke stopped before creating a VM because the host
parameter helper was down.  Its entry and exit gates were clean.  Only the
required `scenv_param` and `scenv_minio` helper containers were then started;
the existing shared OpenWhisk containers were not modified.

One isolated no-2M Vanilla Kata face smoke passed in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_face_smoke_20260714_184027
```

The CRI container exited 0, all timing markers were present, `t_e2e` was
`12.385864496231079`, cleanup removed the pod/container records, the temporary
image pin was released, and both post-sample and runner-exit gates were clean.

This smoke did not exercise an eligible private 2M mapping.  Current-boot
counts after the run were zero for both the disabled-promotion diagnostic and
the old-ABI normal-slot A/D-suppression diagnostic; stop-marker count was also
zero.  THP was `[madvise]`, but post-run `AnonHugePages` and the explicit
hugetlb pool were both zero.  The built/loaded `kvm.ko` contains the disabled
promotion diagnostic, so its absence is runtime ineligibility, not a missing
patch.  Treat this as a successful functional smoke, not yet as a causal A/B
validation of the large-private split failure.

A bounded 10-launch no-2M face churn subsequently passed in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_face_churn10_20260715_035310
```

All ten cold CRI containers exited 0 and produced analyzer records.  The
runner emitted 22 `host_safety=ready` results: workload entry, before and after
each of ten samples, and runner exit.  Every sample cleanup removed its CRI
pod/container records, and the runner released its temporary image pin.
Timing summary:

```text
samples=10
mean_t_e2e=10.474375772476197
min_t_e2e=9.87185001373291
max_t_e2e=11.748493194580078
mean_t_boot_cntr=8.099851751327515
```

This establishes short-run functional stability for no-2M Vanilla Kata face
detection.  It still does not prove the huge-page causal A/B because the prior
post-smoke kernel counts showed no eligible disabled-promotion event.  The
next owner should move back to workload orchestration: run the twelve-workload
no-2M smoke matrix, then collect measurements in resumable per-workload or
small-batch units.  Keep the host safety gate around every sample and do not
resume a failed batch automatically.

### 2026-07-15 resumable Fig. 11 collector implementation

The CRI generic runner now accepts `START_ITERATION` (default `1`) and refuses
to overwrite an existing `sample-NNN` directory.  It records the start and end
iteration in `run-env.txt`.  This makes a deliberate append use new sample
numbers rather than replacing cold-start evidence.

`run_kata_tdx_cri_fig11.sh` now defaults to `FIG11_MODE=smokes`, which performs
only the selected one-sample validation matrix.  Its explicit modes are:

- `smokes` — one cold smoke per selected workload (all twelve when
  `FIG11_WORKLOADS` is unset);
- `batch` — requires an explicit, bounded whitespace-separated
  `FIG11_WORKLOADS` list and collects only those workloads into `RUN_DIR/log`;
- `render` — validates all twelve complete sample sets and renders graphs
  without launching a VM; and
- `full` — retained only as an explicit legacy monolithic mode.

`FIG11_RESUME=1` is manual, never automatic.  Before appending, the
orchestrator validates every existing analyzer JSON record and its matching
sample directory, clean exit status, and timing markers.  A completed workload
is skipped; a valid partial workload appends from its next sample number.  A
failed/inconsistent workload remains a hard stop.  Smoke and warm-up artifacts
also use unique attempt directories, and every generic invocation has its own
runner directory and host-safety gates.

All three Kata-TDX scripts pass `bash -n`.  The new read-only `render` mode was
also exercised against the interrupted July 14 run and correctly refused it:
DNA has nine analyzer records but ten sample directories, preserving its
failed sample-10 boundary rather than treating it as resumable.  No VM was
launched while implementing these controls.

### 2026-07-15 complete no-2M Fig. 11 smoke matrix

All twelve Fig. 11 workloads now have one successful Vanilla Kata-TDX no-2M
cold smoke.  The artifacts are intentionally split by their clean execution
boundaries:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_smokes_20260715_041408
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_smokes_remaining_20260715_042836
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_smoke_tv_20260715_044440
```

The first run passed DNA visualisation, compression, face detection, image
processing, sentiment, video processing, and thumbnailer.  It stopped before
creating an uploader VM because the host file-server helper was absent from
port 8080.  The second run passed uploader plus Alexa Frontend, Interact, and
Smarthome after the documented `scenv_file_server` helper was started.  It
stopped before creating an Alexa TV VM because the documented `scenv_device`
helper was absent from port 9090.  Alexa TV then passed in the third run after
that helper was started.

Every completed generic invocation logged clean pre/post/exit host-safety
gates, released its temporary image pin, exited its CRI container with status
zero, and emitted an analyzer record.  The final TV sample recorded
`t_e2e=8.287787914276123`.  No KVM/TDX stop marker appeared in the final run.
The two helper-readiness exits are pre-launch environment boundaries, not
benchmark or host-safety failures; their evidence remains preserved in the
first two run directories.

### 2026-07-15 patch-0017 measurement failure: blocked 2M SEPT ancestor

The first bounded measurement batch was deliberately DNA-only and stopped at
its first timed cold sandbox; the warm-up had passed cleanly.  Its preserved
directory is:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717
```

No measured analyzer record was written.  `log/fn_py_dna_visualisation/sample-001`
contains only the failed sandbox input/log evidence, so this batch is invalid,
must not be resumed, and must not contribute to a graph.

At `04:49:41Z`, the host emitted the same class of stop marker that the
no-2M A/B was intended to avoid:

```text
tdx_sept_zap_private_spte
TDH_MEM_RANGE_BLOCK: TDX_EPT_WALK_FAILED, SEPT_BLOCKED
TDH_MEM_PAGE_REMOVE: TDX_EPT_WALK_FAILED, SEPT_BLOCKED
```

KVM was operating on a normal `slot_private=0`, `tdx_level=0` 4K software leaf
(`gfn=0x7d276`, `blocked=1`), but `out_rdx=0x101` says the secure SEPT walk
stopped at a blocked 2M ancestor.  QEMU then reported
`kvm run failed Input/output error` and exited `134`; CRI's later vsock-agent
timeout was downstream.  Teardown subsequently produced warnings in
`tdx_reclaim_page` and KVM `__handle_changed_spte` / TDP-MMU handling.
The runner's exit gate correctly reported `host_safety=not-ready` and did not
retry or force additional cleanup.

The current `/tmp` QEMU logs were copied before any other launch to:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/failure-evidence/kata-qemu-tdx-oldabi-wrapper.0.log
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/failure-evidence/kata-qemu-tdx-oldabi-qemu.0.log
```

Their SHA-256 values are respectively
`82a32edcec8c779cde0bf82db80e47ab47daabaf7d9aeac083fccdec41ab0b52` and
`52607dd4c9af37d47228c01f5942b9335c143b4ef3a3e786d10624f88cd13615`.

Do not launch another Kata-TDX VM, resume the batch, collect further samples,
or generate Fig. 11 graphs on this boot.  The patch-0017 configuration hit a
host fault, so further progress is now kernel-development investigation, but
only after the shared-host owner coordinates recovery and the host-safety gate
is clean.

A concise standalone successor report is available at:

```text
/home/booklyn/cofunc-tdx/docs/tdx_fig11_no2m_handoff_20260715.md
```

### 2026-07-15 correction: patch 0017 was not a true 4K-only A/B

Later source and preserved-log review invalidated the statement above that the
failure proves a normal 4K-only path is unsafe independently of 2M mappings.
Patch 0017 disables only the custom
`cofunc_tdx_oldabi_private_2m_capable()` promotion.  It does not cap the 2M
result that `__kvm_mmu_max_mapping_level()` can obtain from the normal host
HVA/THP walk.

The same boot contains direct proof of a private 2M mapping under patch 0017:

```text
where=changed-live-split gfn=0x1200 level=2 old_present=1 old_last=1
```

Both the July 14 and July 15 failures requested a 4K child operation, but
`out_rdx=0x101` says the TDX walk stopped at a blocked level-1 (2M) SEPT
ancestor.  The software KVM tree had 4K leaves while the secure SEPT still had
a blocked 2M ancestor.  Thus these are the same structural-state divergence,
and the patch-0017 result does not falsify a 2M split-path cause.

The corrected standalone report includes the full PFN/SEPT evidence and
upstream design comparison.  An unapplied, dry-run-validated containment patch
now exists at:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0023-Diagnostic-force-oldabi-private-normal-slot-4K.patch
```

Patch 0023 genuinely caps old-ABI private normal-slot mappings at 4K.  It is
for a Vanilla Kata containment A/B only, is not a root fix, and must not be
used for CoFunc measurements because it disables CoFunc's private 2M mapping
optimization too.  The current boot remains unsafe; do not apply/build/reload
or launch a VM until the shared-host owner coordinates recovery.

### 2026-07-15 source-level split commit finding

The September 2022 TDP private-hugepage split is non-transactional across the
software TDP tree and the TDX secure SEPT.  `tdp_mmu_link_sp()` installs or
freezes the software SPTE and invokes `__handle_changed_spte()`.  The TDX
callback then performs `RANGE_BLOCK -> TRACK -> PAGE_DEMOTE`, but the callback
is `void`.  Although `tdx_sept_split_private_spte()` returns `-EIO` when
`PAGE_DEMOTE` fails, its caller discards that result.  The TDP caller therefore
returns success and publishes the 4K child table without a rollback path.

This mechanism directly explains the preserved failure state: KVM has 4K
software leaves while the secure walk still encounters the blocked 2M parent.
The shared-lock fault split is the leading trigger candidate; a partial
write-lock `MAP_GPA` split and the already-blocked split path remain possible.
The A/D suppression patches do not explain this earlier structural mismatch.

A behavior-preserving diagnostic patch is prepared at:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0024-Diagnostic-trace-private-2m-split-commit-order.patch
```

It logs only private hugepage split commit boundaries, live versus blocked
split paths, `PAGE_DEMOTE` outputs, and unbudgeted SEAMCALL failures.  It passes
`patch --dry-run`, `git apply --check`, and strict kernel checkpatch with zero
errors, warnings, or checks.  It has not been applied, built, installed, or
loaded.  The proof signature is a nonzero `phase=demote-end ... err=` followed
by `phase=tdp-end ... ret=0 linked=1` for the same transition.

Keep the mission and root-cause tracks separate.  After owner-coordinated host
recovery, patch 0023 is the containment path for collecting the Vanilla Kata
baseline with private normal-slot mappings truly capped to 4K.  Patch 0024
should be used with 2M enabled only in a separate owner-approved diagnostic
boot and one isolated smoke at a time.  Reproducing the host fault is not a
prerequisite for completing Fig. 11.

### 2026-07-15 patch-0023 smoke and low-noise follow-up

Patch 0023 was applied, built, installed, and owner-approved for reload.  The
loaded `kvm` srcversion is `604B04FCEE16BFBF96BA96D`, matching the build hash
`64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752`.
The isolated face smoke is preserved at:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_face_smoke_20260715_070308
```

The guest workload succeeded with exit code 0 and
`t_e2e=18.80324149131775`.  CRI cleanup was clean and all captured safety
gates remained ready.  The outer runner's failure was a false regression
classification: `TDX.*EPT` matched the benign phrase `TDX SEPT` in lifecycle
telemetry.  The runner now uses the canonical explicit gate expression and
reports kernel-log loss separately.

The run remains inconclusive as a dynamic mapping proof.  A burst of 876
per-4K SEPT teardown lines caused 22 `/dev/kmsg buffer overrun` notices.  Also,
the original patch-0023 marker logs only when the incoming request is above
4K; a zero count does not mean the unconditional old-ABI normal-slot branch
was bypassed when the incoming request was already 4K.

The independent review is:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/smoke_failure_review.md
```

An unapplied logging-only follow-up is ready at:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0025-Diagnostic-make-4k-containment-telemetry-conclusive.patch
```

Patch 0025 logs every sampled containment-branch entry with `normal_req` and
`would_cap`, retains a bounded TDP target-level sample, suppresses noisy older
per-page diagnostics, and limits SEPT lifecycle logging to huge mappings.  It
passes forward dry-run, `git apply --check`, and strict kernel checkpatch with
zero errors, warnings, or checks.  It has not been applied, built, installed,
or loaded.  After an owner-approved build/load cycle, run one isolated smoke
and require branch evidence, only level-1 private TDP targets, no private
level-2 SEPT lifecycle event, no canonical stop marker, and no log loss before
starting churn.

### 2026-07-15 patch-0023 applied and KVM modules built (not installed)

Patch 0023 has now been applied exactly once to the 5.19 source and built with
the existing KVM-only workflow.  It has not been installed, loaded, or used to
launch a VM.  This is a Vanilla Kata containment build only: do not collect
CoFunc measurements with it and do not apply patch 0024 on this boot.

Preserved evidence:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z
```

Source/build state:

```text
source base commit: 8298dd80cf482b58dec935832e1afc9d3a00587f
source file:        arch/x86/kvm/mmu/mmu.c
mmu.c before sha256: 8aa4e22909611bba12dff2b988ffcc5bcdba319d8a8d0c35172e3b42a22f3583
mmu.c after sha256:  b26d3f6096db117ac33b5017b3dc932496fc7f693ef52d191226f0b4ca6f7dbb
patch sha256:        a685b419e63a06828837a38269ec8efc12ba0a78df9e1e99302e6be1233160ce
build command:       make -C /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc M=arch/x86/kvm -j16 modules
build result:        exit 0
```

`backup/mmu.c.before-0023`, `backup/mmu.c.after-0023`, the exact patch input,
and copies of both built modules are preserved in the evidence directory.  The
required source-root forward/reverse `patch --dry-run`, `git apply --check`,
and strict `scripts/checkpatch.pl --strict --no-tree` were clean; the pre-apply
reverse dry run specifically reported `Unreversed patch detected!`, proving
0023 was not already applied.  The post-apply source passes `git diff --check`.

Built outputs:

```text
kvm.ko       sha256=64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752 srcversion=604B04FCEE16BFBF96BA96D
kvm-intel.ko sha256=d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794 srcversion=5E9FE6DC9A74E201D9D3C2E
both vermagic=5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
```

The new raw `kvm.ko` contains the exact forced-4K log marker.  Current
installed compressed payloads are still pre-0023 (`kvm`:
`90e38c3a4f52afe1c2b2913ab4d7cea2796ff6ee5d076801a4ecf923117c4704`,
`kvm-intel`:
`d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794`).
Current loaded versions are also pre-0023: `kvm=22B2A410CCC77E86F9E3BC7`,
`kvm_intel=5E9FE6DC9A74E201D9D3C2E`, and `kvm_intel.tdx=Y`.

No validation smoke occurred, so forced-4K, private level-2 split, private
promotion, and KVM/TDX stop-marker counts are all not-applicable—not zero
evidence.  Before installation, the owner must run the gate, check `/dev/kvm`,
and list CRI records exactly as documented in the standalone Fig. 11 handoff.
If all are clean, use only:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
```

### 2026-07-15 patch-0025 isolated smoke: successful 4K containment evidence

One owner-approved Vanilla Kata-TDX `fn_py_face_detection` smoke was run at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_smoke_20260715_083921`.
It completed without retry; no churn, measurement, full matrix, or additional
VM followed. The container state is `CONTAINER_EXITED`, exit code 0, and all six
captured safety gates are `host_safety=ready`. Cleanup left zero matching CRI
container or pod records.

The 83-line kernel delta records 64 executions of the private normal-slot
containment branch. Every record says `normal_req=2 capped_req=1 would_cap=1`.
Private `changed-live-split level=2`, all private level-2 SEPT lifecycle,
custom private-2M promotion, canonical stop-marker, and new kernel-log-loss
counts are each zero. Historical log-loss notices timestamped 07:06 predate the
08:39 run and are absent from its delta.

The separate TDP target sampler has zero records because its GFN filter
(`0x500000..0x7fffff`) does not overlap the exercised containment GFNs
(`0x0..0x8000`). This is an instrumentation limitation, not evidence of a
non-TDP path: the loaded host reports `tdp_mmu=Y`. Source flow shows the fault's
goal starts at level 1, the observed branch changes the computed normal request
from level 2 to level 1 and returns before goal promotion, and the TDP mapper
installs only at that goal. Combined with zero level-2 SEPT changes, true 4K
containment is proven for this isolated workload, though literal
`tdp_target ... iter_level=1` samples were not captured.

See
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/smoke_validation_20260715_083921.md`
for exact counts, checksums, and the conservative qualification. No additional
run is authorized.

### 2026-07-15 patch-0025 installation: no reload authorization implied

The owner ran the `pre-0025-install` full gate; it returned
`host_safety=ready` with no `/dev/kvm` owner, Kata/QEMU process, stale Kata CRI
record, or known current-boot stop marker. The installer saved the prior
patch-0023 module files under
`/mnt/new_disk/cofunc_tdx_artifact/module-backups/kvm-5.19/5.19.0-cofunc-tdx-5.19+-20260715_075826`.

The prior installed compressed-payload hashes were
`kvm=64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752` and
`kvm-intel=d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794`.
The new compressed payloads verify as
`kvm=ea3d14e28114ab79445ce67d642ca2d9bfe2b6a4b8022028c2af63ee75741233` and
`kvm-intel=153e6ee934bb32ab34e269cef08d647829489b04a38a53b0e213d7b8b5630cdf`,
matching the patch-0025 build. The installer reported KVM was not reloaded;
therefore the running pair remains the old loaded pair until separately approved
reload or reboot. Do not reload, reboot, restart services, or launch a VM absent
that approval. Installation evidence is at
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/install_evidence.md`.

### 2026-07-15 patch-0025 reload: exact loaded-version match

The owner ran the full `pre-0025-reload` gate, which returned
`host_safety=ready` with no `/dev/kvm` users, Kata/QEMU process, stale Kata CRI
record, or current-boot stop marker. The safe reload helper then reported
`kvm=C01F58A5F36A5E9E75E4B99` and
`kvm_intel=93A968602404A13EEF604A9`; both equal the patch-0025 build
srcversions. The loaded Intel module is
`/lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm-intel.ko.zst`,
and `kvm_intel.tdx=Y`.

This proves that patch-0025 is loaded, not merely installed. It does not grant
authority for VM launch: a fresh gate plus separate owner approval are required
before an isolated smoke. The preserved proof is
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/reload_evidence.md`.

The owner then ran the required `post-0025-reload` full gate; it again returned
`host_safety=ready` with no stop marker, `/dev/kvm` user, Kata/QEMU process, or
stale Kata CRI record. No VM launch follows from this gate; separate owner
authorization remains mandatory for the isolated smoke.

That guarded operation makes a rollback backup and replaces on-disk compressed
modules only.  Do not reload/reboot/restart or launch a VM without fresh owner
approval.  After an approved reload/reboot, prove the loaded srcversions and
installed compressed-payload hashes match the built pair before a single face
smoke.

### 2026-07-15 patch-0023 installed safely; reload still pending approval

The owner completed the on-disk installation command:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
```

No KVM reload, reboot, service restart, or VM launch followed.  The installer
made this rollback backup:

```text
/mnt/new_disk/cofunc_tdx_artifact/module-backups/kvm-5.19/5.19.0-cofunc-tdx-5.19+-20260715_063552
```

The backup's `module-hashes.txt` is copied into
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/module-install-backup-hashes.txt`.
Verification after the install establishes:

```text
backup kvm.ko.zst payload       90e38c3a4f52afe1c2b2913ab4d7cea2796ff6ee5d076801a4ecf923117c4704
backup kvm-intel.ko.zst payload d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
installed kvm.ko.zst payload    64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752
installed kvm-intel.ko.zst payload d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
```

The latter pair exactly matches the 0023 build.  The compressed-file SHA-256
values, preserved separately in `module_install_evidence.md`, are:
`f522277b3d32beab4756b1204b179c26f6a696607c110d36ba3a9fe1c8f81185`
(backup kvm), `6b5a364a7e438472b929b08f544d65be8ba4ab055ee373b85fb456cbaf405597`
(backup and installed kvm-intel), and
`7431a0edaff4205fe6b80cad5dcfb680a7bc72855363656f4106b4f9e090f3b9`
(installed kvm).

`/dev/kvm` had no owner at installer/preflight and immediate post-install
checks.  The loaded modules remain pre-0023:

```text
kvm       22B2A410CCC77E86F9E3BC7
kvm_intel 5E9FE6DC9A74E201D9D3C2E
kvm_intel.tdx=Y
```

No smoke/marker counts are available yet. Before any separately approved
reload, run the gate plus explicit `/dev/kvm` and CRI listings in the Fig. 11
handoff. If and only if those are clean and the owner explicitly approves,
reload with `sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload`.

### 2026-07-15 clean pre-reload host gate

The owner-provided transcript is preserved at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/owner-pre-reload-gate-and-cri.txt`
with SHA-256 `7bce296fca24a235ef5bc58c39d1252698c58da203d6f9876534447fed97ab68`.
It reports `host_safety=ready`, no known current-boot KVM/TDX stop marker,
zero `kvm_intel` users, no `/dev/kvm` owner, no Kata/QEMU process, and no Kata
container record in `default` or `k8s.io`.

The separately listed old CRI records are all non-Kata `(default)`-runtime
records in `openfaas`, `openfaas-fn`, and `kube-system`.  They are unrelated
shared-host history and must not be cleaned up. The reload gate is clean; only
explicit owner approval remains outstanding.

### 2026-07-15 patch-0023 reload verified

The owner approved and ran the safe KVM reload. Direct host verification proves
the loaded modules match the patched build and installed payloads:

```text
kernel=5.19.0-cofunc-tdx-5.19+
loaded/built kvm srcversion=604B04FCEE16BFBF96BA96D
loaded/built kvm_intel srcversion=5E9FE6DC9A74E201D9D3C2E
kvm_intel.tdx=Y
installed kvm payload=64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752
installed kvm-intel payload=d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
/dev/kvm users=none
```

The exact verification is preserved at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/post_reload_loaded_module_verification.md`.
No VM has launched since reload; a fresh ready gate remains mandatory before
the single isolated Vanilla Kata face smoke.

### 2026-07-15 patch-0023 face smoke pre-launch helper stop

The isolated face-smoke runner was started in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_face_smoke_20260715_064738`,
but correctly refused to create a VM because the required host parameter helper
at `127.0.0.1:8888/get_param` was unavailable. Port 8888 has no listener.

This was not a KVM/TDX failure: the Fig. 11 preflight, generic workload entry,
and runner-exit gates all reported `host_safety=ready`; the dmesg failure delta
is empty; and zero pods/containers with the test run token remain. The runner
exited 1 only because its design does not auto-start shared helpers. No VM,
forced-4K event, private level-2 split, private promotion, or stop marker can
be counted. Preserve this as a pre-launch readiness boundary and restore only
`scenv_param` before a later one-smoke retry.

Read-only host inspection showed that `scenv_param` and `scenv_minio` are both
absent (no containers/listeners on ports 8888 or 9000), but their exact images
are already local. Face also needs MinIO, so restore only these two helpers:

```bash
sudo docker run -d --rm --name scenv_param --net=host \
  -v /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases:/testcases \
  scenv_param:latest
sudo docker run -d --rm --name scenv_minio --net=host \
  -e MINIO_ROOT_USER=root -e MINIO_ROOT_PASSWORD=password \
  minio/minio:latest server /data
```

Require both documented parameter/MinIO curls to exit zero before creating a
fresh one-smoke run directory. Do not remove/restart unrelated shared
containers or resume the failed pre-launch attempt.

The owner subsequently had both required helpers running without altering
unrelated containers: `scenv_param` (`6abd49ffca7c`) and `scenv_minio`
(`0ee90474e910`) were `Up` from `2026-07-15T07:00:09Z`. Parameter lookup now
returns the face configuration and MinIO health exits zero. A new isolated
runner directory—not the preserved pre-launch failure—is required for the sole
remaining permitted face-smoke attempt.

### 2026-07-15 patch-0023 isolated face smoke: stop after incomplete kernel evidence

The sole post-reload face run completed its CRI container successfully
(`CONTAINER_EXITED`, code `0`, `t_e2e=18.80324149131775`) and left zero
test-token CRI records. Its preflight, workload-entry, post-sample,
runner-exit, and outer postflight gates all reported `host_safety=ready`.

The runner then exited 1 because `TDX.*EPT` also matches the loaded CoFunc
`TDX SEPT` lifecycle diagnostic. The 910-line delta contains 876 level-1
lifecycle events (438 zap and 438 drop) and 23 `/dev/kmsg buffer overrun`
notices. Gate-defined stop markers are zero, but the overrun means the log is
incomplete. Stop immediately: no retry, churn, measurement, reload, or further
VM launch on this boot.

Runtime counts are forced-4K=0, private live level-2 split=0, custom
private-2M promotion=0, and gate stop markers=0. Forced-4K=0 means the capping
branch was not observed; true 4K containment is not proven and bounded churn is
not authorized. Copied evidence and targeted no-VM verification are at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/smoke_failure_summary.md`.

### 2026-07-15 patch-0025 logging-only follow-up: build complete, deployment held

After the owner-reported `pre-0025` `host_safety=ready` gate, reconfirmation
found no `/dev/kvm` owners and no Kata/QEMU process. Patch 0025 was verified
unapplied by forward/reverse dry runs, `git apply --check`, and strict
`checkpatch`; backups and pre-change SHA-256 records were made for
`mmu.c`, `tdp_mmu.c`, and `tdx.c`. It was applied exactly once to the patch-0023
tree. The post-apply forward dry-run recognized it as applied, reverse dry-run
passed, `git diff --check` was clean, and strict checkpatch reported 0 errors,
0 warnings, and 0 checks (69 lines checked). The exact forward/reverse,
`git apply`, and checkpatch commands are preserved in `pre_apply_evidence.md`.

The complete evidence directory is
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042`.
The successful build command was:

```
make -C /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc M=arch/x86/kvm -j16 modules
```

Relative to that directory, the preserved pre-change backups are
`backup/arch/x86/kvm/mmu/mmu.c.before-0025`,
`backup/arch/x86/kvm/mmu/tdp_mmu.c.before-0025`, and
`backup/arch/x86/kvm/vmx/tdx.c.before-0025`.

Built output: `kvm.ko` SHA-256
`ea3d14e28114ab79445ce67d642ca2d9bfe2b6a4b8022028c2af63ee75741233`,
`srcversion=C01F58A5F36A5E9E75E4B99`; `kvm-intel.ko` SHA-256
`153e6ee934bb32ab34e269cef08d647829489b04a38a53b0e213d7b8b5630cdf`,
`srcversion=93A968602404A13EEF604A9`. Both use vermagic
`5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions`.

The new modules are not installed or loaded. The active patch-0023 pair remains
`kvm=604B04FCEE16BFBF96BA96D`,
`kvm_intel=5E9FE6DC9A74E201D9D3C2E`, and `kvm_intel.tdx=Y`.
No reload, reboot, service action, or VM launch occurred. With separate owner
approval only, use this guarded installation sequence, and continue only if the
first command says `host_safety=ready`:

```
sudo /home/booklyn/cofunc-tdx/scripts/kata_tdx_host_safety_gate.sh pre-0025-install
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
```

## CURRENT FINAL STATUS — 2026-07-15 patch-0025 face smoke complete

The older build-only state immediately above is superseded. Patch 0025 was
installed and loaded with matching srcversions
`kvm=C01F58A5F36A5E9E75E4B99` and
`kvm_intel=93A968602404A13EEF604A9`; `kvm_intel.tdx=Y`. The owner-approved
single face smoke completed at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_smoke_20260715_083921`.
There was no retry or subsequent VM.

The container exited 0, six captured gates remained `host_safety=ready`, and
cleanup left zero matching CRI records. The 83-line delta contains 64
containment records, all `normal_req=2 capped_req=1 would_cap=1`; private
level-2 split/SEPT, private 2M promotion, canonical stop-marker, and new
kernel-log-loss counts are all zero. This proves 4K containment for the
exercised old-ABI private normal-slot workload.

Qualification: the separate TDP target logger produced zero records because
its stale `0x500000..0x7fffff` GFN window misses this run's `0x0..0x8000`
samples. Static source flow proves the containment return leaves
`goal_level=PG_LEVEL_4K`, which is the TDP install target, but no literal
`tdp_target ... iter_level=1` record was captured. Exact evidence and checksums
are in
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/smoke_validation_20260715_083921.md`.

No churn, measurement, full matrix, patch, reload, or additional VM is
authorized by this handoff.

## CURRENT FINAL STATUS — 2026-07-15 bounded patch-0025 churn complete

The owner approved one five-launch `fn_py_face_detection` churn. It ran once at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_churn5_20260715_140851`
using the loaded patch-0023/0025 modules
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`.

The generic runner exited 0 after exactly five cold launches. All five
containers exited 0, all analyzer/timing records exist, its 12 safety gates and
the wrapper pre/post gates were ready, and cleanup left zero matching CRI
records or Kata/QEMU processes. Kernel-delta counts are private level-2
SEPT/lifecycle=0, private 2M promotion=0, canonical stop-marker=0, and new
kernel-log-loss=0.

Strict qualification: the churn produced zero new containment records. The
unchanged before/after snapshots each retain the isolated smoke's 64 records,
which exhausted patch 0025's module-lifetime `ATOMIC_INIT(64)` budget. No module
reload reset it. This is not evidence of a 2M mapping or instability, but it
fails the explicit requirement for churn-local containment telemetry. Do not
borrow the earlier 64 records to make that count nonzero.

The report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_churn5_20260715_140851/churn_validation_report.md`
(SHA-256
`3a90498d403582b832b97300a074cb39258bc3e48b1a970441d22b4eef92bbe3`).
The five-launch stability phase passed, but the overall validation is not an
unconditional pass. The if-and-only-if condition for recommending a small
multi-workload smoke batch is therefore not met. No retry, patch, reload,
measurement, full matrix, or additional VM is authorized.

## CURRENT MANAGER DISPOSITION — bounded churn accepted with exhausted telemetry

The churn-local containment count is zero only because patch 0025's static
module-lifetime 64-record budget was exhausted by the immediately preceding
isolated smoke. That smoke proved 64 normal 2M requests were actively capped
to 4K under the same loaded module identities. The subsequent churn passed five
cold launches with clean gates and zero private level-2 event, promotion, stop
marker, log loss, or cleanup residue.

Do not reload or patch KVM solely to replenish diagnostic messages. The prior
containment proof plus this five-launch stability result satisfies the current
decision boundary. With a fresh ready gate and separate owner approval, proceed
only to one small smoke-only batch of diverse workloads, one launch each, with
per-launch gates and no retry. A measured batch and full Fig. 11 matrix remain
unauthorized.

## CURRENT FINAL STATUS — patch-0025 diverse smokes passed 3/3

The approved diverse smoke harness ran once at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_diverse_smokes_20260715_144250`.
DNA visualization, video processing, and Alexa interaction each completed one
cold launch with exit code 0 and one complete analyzer record. All 20 combined
child/wrapper gates were ready; cleanup left zero run-token CRI objects and no
Kata/QEMU process. Per-workload and aggregate counts are private level-2
SEPT/TDP=0, private 2M promotion=0, canonical stop-marker=0, and new
kernel-log-loss=0.

The report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_diverse_smokes_20260715_144250/diverse_smokes_validation_report.md`
(SHA-256
`52827092f310be1b1ce47343afee7b1d76495a1666838888411ff9c9512fc902`).

True-4K smoke coverage is now four of twelve workloads: face, DNA, video, and
Alexa interaction. With a fresh ready gate and separate owner approval, test
the five remaining non-chain workloads, then the three remaining Alexa chain
workloads, one smoke each with fail-fast per-workload kernel checks and no
retry. Do not begin measurements or graph generation before all twelve smokes
are clean.

## CURRENT FINAL STATUS — patch-0025 non-chain smokes passed 5/5

Following a fresh ready full gate and successful parameter-helper, MinIO, and
port-8080 file-helper checks, the owner launched once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_nonchain_smokes.sh
```

The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_nonchain_smokes_20260715_181858`.
The harness returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`
without retry. Compression, image processing, sentiment, thumbnailer, and
uploader each had one cold CRI container exit 0 and one valid timing record.

Module identities remained `kvm=C01F58A5F36A5E9E75E4B99` and
`kvm_intel=93A968602404A13EEF604A9` on kernel
`5.19.0-cofunc-tdx-5.19+`, with `tdx=Y` and `tdp_mmu=Y`. All 32 wrapper/child
gates were ready, and final CRI/process checks show no run-token object,
Kata/QEMU process, or `/dev/kvm` user. Aggregate and child-delta counts are
private level-2 SEPT/TDP=0, private 2M promotion=0, canonical KVM/TDX stop
marker=0, and new kernel-log-loss=0.

New forced-4K telemetry is zero by design: the prior conclusive face smoke
already exhausted patch 0025's 64-record module-lifetime counter under the
same loaded modules. Do not reload KVM to reset it. The full timing table,
exact command, loaded identities, gate/cleanup proof, and dmesg hashes are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_nonchain_smokes_20260715_181858/nonchain_smokes_validation_report.md`
(SHA-256 `f950c6708590c83151bd93a79e41b2aea7e1b53f58e6a562caadf0851f7b3b20`).

True-4K smoke coverage is now 9/12. The next separately approved step may be
exactly one fail-fast cold smoke each for Alexa frontend, smarthome, and TV;
do not proceed to measurements, graphs, or the full Fig. 11 matrix.

## CURRENT FINAL STATUS — patch-0025 remaining Alexa smokes passed 3/3

The initial Alexa preflight stopped before VM creation when the TV device
helper was unavailable on port 9090. After the targeted `scenv_device` helper
with `DEVICE_NAME=tv` was confirmed listening and returning HTTP 200, a fresh
full gate, all three parameter checks, and the device check passed. The owner
then launched exactly once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_alexa_smokes.sh
```

The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_alexa_smokes_20260715_191148`.
The harness returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`
without retry. Alexa frontend, smarthome, and TV each had one cold CRI
container exit 0 and one valid timing record.

Module identities remained `kvm=C01F58A5F36A5E9E75E4B99` and
`kvm_intel=93A968602404A13EEF604A9` on kernel
`5.19.0-cofunc-tdx-5.19+`, with `tdx=Y` and `tdp_mmu=Y`. All 20 wrapper/child
gates were ready, and final CRI/process checks show no run-token object,
Kata/QEMU process, or `/dev/kvm` user. Aggregate and child-delta counts are
private level-2 SEPT/TDP=0, private 2M promotion=0, canonical KVM/TDX stop
marker=0, and new kernel-log-loss=0.

New forced-4K telemetry is zero by design because the conclusive face smoke
had already exhausted patch 0025's 64-record module-lifetime counter under
the same loaded modules. Do not reload KVM to reset it. The complete timing
table, helper/gate evidence, cleanup proof, and dmesg hashes are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_alexa_smokes_20260715_191148/alexa_smokes_validation_report.md`
(SHA-256 `83ae5d3bbd8ed2ed1e45527841a7d9206c0a2b7f6c90ad343de41dcc3f7b520f`).

True-4K cold-smoke coverage is now **12/12**. This completes smoke coverage,
not the measured Fig. 11 matrix. Do not perform measurements, graph
generation, KVM changes, or any new VM action without a separate owner
decision after report and host-capacity review.

## CURRENT FINAL STATUS — patch-0025 video measurement pilot passed 5/5

After a fresh ready gate plus video parameter-helper and MinIO checks, the
owner ran once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_video_measurement_pilot.sh
```

The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_video_measurement_pilot_20260716_041102`.
It retained one untimed warm-up separately and exactly five measured cold video
samples in `log/fn_py_video_processing/` for later Fig. 11 aggregation. The
harness returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0` with
no retry, graph rendering, or second workload.

Module identities remained `kvm=C01F58A5F36A5E9E75E4B99` and
`kvm_intel=93A968602404A13EEF604A9` on kernel
`5.19.0-cofunc-tdx-5.19+`, with `tdx=Y` and `tdp_mmu=Y`. Each measured container
exited 0 with a valid analyzer record; mean measured `t_e2e` was
`46.070450925827025` seconds. All 28 gates were ready. The warm-up, every
measured-launch delta, and the aggregate delta have private level-2
SEPT/TDP=0, private 2M promotion=0, canonical stop marker=0, and new kernel-log
loss=0. Cleanup left no run-token CRI object, Kata/QEMU process, or `/dev/kvm`
user.

New forced-4K telemetry is zero because the earlier face smoke consumed patch
0025's 64-record module-lifetime budget under the same modules. Do not reload
to reset it. Detailed timing, module/capacity evidence, per-launch dmesg hashes,
and the exact command are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_video_measurement_pilot_20260716_041102/video_measurement_pilot_validation_report.md`
(SHA-256 `d4748d8a044464251b35059a3c4c576224cd99e2e651907339ff8cdf976cd21b`).

Video's five required measured cold samples are complete. Do not render graphs
or begin another workload without a separate owner decision. The next measured
workload should be DNA visualization, with one untimed warm-up and ten measured
cold samples.

## CURRENT FINAL STATUS — patch-0025 DNA final measurement passed 10/10

The owner ran exactly once after a fresh full ready gate, DNA parameter-helper,
and MinIO preflight:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_dna_measurement.sh
```

Run root:
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_dna_measurement_20260716_044856`.
The harness SHA-256 is
`c6c8d57e8063795de454385cd1d487d643ecf17d9b8c8e029e53e92bca8287d0`.
It completed one excluded cold warm-up and exactly ten measured cold
`fn_py_dna_visualisation` launches in `log/fn_py_dna_visualisation/`, with
samples `001`--`010`, and returned `run_rc=0`, `postflight_gate_rc=0`, and
`evidence_rc=0`. No retry, resume, graph, or second workload occurred.

The modules were unchanged: kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, `tdp_mmu=Y`. Each measured
container exited 0 with valid analyzer and timing records. Measured means were
`t_boot_cntr=14.953594517707824`, `t_boot_func=0.7740473985671997`,
`t_exec=9.021167850494384`, and `t_e2e=24.74880976676941` seconds.

All 48 expected gates were ready. All eleven per-launch deltas and the
aggregate have zero private level-2 SEPT/TDP event, private 2M promotion,
canonical KVM/TDX stop marker, and new kernel-log-loss record. Final token
scoped CRI, Kata/QEMU process, and `/dev/kvm` owner checks were empty.
Forced-4K messages remain zero by design: the 64-entry patch-0025
module-lifetime counter was consumed by the earlier conclusive face smoke under
the same loaded modules; do not reload merely to replenish it.

The report, including the full timing table and dmesg hashes, is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_dna_measurement_20260716_044856/dna_measurement_validation_report.md`
(SHA-256 `d7e2bc5ef0832fcaead7df815fe2e677fc970f4c3763556179a72b2332e9df49`).

Final measured data is complete for **2/12 workloads: video and DNA**. No
further launch is authorized by this result. If separately approved, the next
bounded collection should be exactly one remaining 20-sample workload only;
`fn_py_compression` is the recommended next canonical Fig. 11 candidate.

## CURRENT FINAL STATUS — patch-0025 compression final measurement passed 20/20

The owner ran exactly once after a fresh full ready gate, compression
parameter-helper, and MinIO preflight:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_compression_measurement.sh
```

Run root:
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_compression_measurement_20260716_051922`.
The harness SHA-256 is
`49a2e0fa9dc72c9e9d42966bab8c2de993943b96b1a4aa7ac08dd5e1a0376341`.
It completed one excluded cold warm-up and exactly 20 measured cold
`fn_py_compression` launches in `log/fn_py_compression/`, with samples
`001`--`020`, and returned `run_rc=0`, `postflight_gate_rc=0`, and
`evidence_rc=0`. No retry, resume, graph, or second workload occurred.

The modules were unchanged: kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, `tdp_mmu=Y`. Each measured
container exited 0 with valid analyzer and timing records. Measured means were
`t_boot_cntr=15.065111267566682`, `t_boot_func=0.5306184649467468`,
`t_exec=0.6760802507400513`, and `t_e2e=16.27180998325348` seconds.

All 88 expected safety-gate results were ready. All 21 per-launch deltas and
the aggregate have zero private level-2 SEPT/TDP event, private 2M promotion,
canonical KVM/TDX stop marker, and new kernel-log-loss record. Final token
scoped CRI, Kata/QEMU process, and `/dev/kvm` owner checks were empty.
Forced-4K messages remain zero by design: the 64-entry patch-0025
module-lifetime counter was consumed by the earlier conclusive face smoke under
the same loaded modules; do not reload merely to replenish it.

The report, including the full timing table and dmesg hashes, is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_compression_measurement_20260716_051922/compression_measurement_validation_report.md`
(SHA-256 `d24d59a4fa6821ecbd24bcd68eefcb87c9bd2e7c4b96b789ad591531fd3c6123`).

Final measured data is complete for **3/12 workloads: video, DNA, and
compression**. No further launch is authorized by this result. If separately
approved, the next bounded collection is `fn_py_face_detection` only: one
excluded cold warm-up and exactly 20 measured cold samples.

## CURRENT FINAL STATUS — patch-0025 face final measurement passed 20/20

The owner ran exactly once after a fresh full ready gate, face parameter-helper,
and MinIO preflight:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_face_measurement.sh
```

Run root:
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_measurement_20260716_055921`.
The harness SHA-256 is
`b2e5bc0b4b1ba99301884136c96dc338827f9c4be564dc21590f66bc9ee4fc4e`.
It completed one excluded cold warm-up and exactly 20 measured cold
`fn_py_face_detection` launches in `log/fn_py_face_detection/`, with samples
`001`--`020`, and returned `run_rc=0`, `postflight_gate_rc=0`, and
`evidence_rc=0`. No retry, resume, graph, or second workload occurred.

The modules were unchanged: kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, `tdp_mmu=Y`. Each measured
container exited 0 with valid analyzer and timing records. Measured means were
`t_boot_cntr=14.964641952514649`, `t_boot_func=1.8674450635910034`,
`t_exec=0.5048944830894471`, and `t_e2e=17.336981499195097` seconds.

All 88 expected safety-gate results were ready. All 21 per-launch deltas and
the aggregate have zero private level-2 SEPT/TDP event, private 2M promotion,
canonical KVM/TDX stop marker, and new kernel-log-loss record. Final token
scoped CRI, Kata/QEMU process, and `/dev/kvm` owner checks were empty.
Forced-4K messages remain zero by design: the 64-entry patch-0025
module-lifetime counter was consumed by the earlier conclusive face smoke under
the same loaded modules; do not reload merely to replenish it.

The report, including the full timing table and dmesg hashes, is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_measurement_20260716_055921/face_measurement_validation_report.md`
(SHA-256 `3b07c164070a8e1b8bcdc356988823af65702629b34fcc430b572a45e685a4e3`).

Final measured data is complete for **4/12 workloads: video, DNA, compression,
and face detection**. No further launch is authorized by this result. A next
workload requires a separate owner-approved measurement boundary.

## 2026-07-16 `/Serverless` capacity hold

Do not import or launch the next workload yet. The read-only audit at
`/home/booklyn/BookArchive/StageBreakdownRuns/serverless_capacity_audit_20260716_063027.txt`
(SHA-256 `f10ddeb0e9db263acbfda15e19006eef622a84f023cdc9162852b86349e219ac`)
found 408,724,357,120 bytes available on `/Serverless`. Its analysis is
`/home/booklyn/BookArchive/StageBreakdownRuns/serverless_capacity_audit_20260716_063027_analysis.md`
(SHA-256 `5327c6e4cededae99f7dc654d0c842c52244cf67e7f7515a37f916e608b6e669`).

The blockfile store allocated 352,882,237,440 bytes, including
350,577,381,376 bytes under `kata-blockfile/snapshots`. Containerd reported 24
`default` and 140 `k8s.io` blockfile snapshots; all 164 were committed, with
no active or view snapshot. The growth is blockfile image-layer amplification,
not one leaked active snapshot per cold launch. Thirteen `k8s.io` leases date
from December 2025 and must not be changed.

The next approved administrative boundary is guarded removal of containerd
image references for completed measured workloads only: video, DNA,
compression, and face, including the old `default` face reference. Preserve
pending Alexa images, pause images, and all historical leases. Use synchronous
containerd image removal and let containerd garbage collection reclaim only
unreferenced resources. Never delete numeric blockfile snapshot files or call
snapshot removal directly. Capture full host gates, Docker source-image proof,
image/snapshot inventories, and `df` before and after. Resume with image
processing only after the post-cleanup host gate is ready and reclaimed space
is verified.

## 2026-07-16 completed-image cleanup: passed

The guarded cleanup completed in two mutating phases. The first removed eight
named `k8s.io` completed-workload references and the legacy `default` face
reference, reclaiming 50,203,860,992 free bytes. Full inventory then exposed
four digest-named references created by `ctr images import`. The final script
accepted only this exact residual state and removed those four references with
synchronous containerd GC.

The residual phase is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_completed_image_cleanup_20260716_070418`.
It reclaimed another 188,913,348,608 free bytes and reduced blockfile
allocation by 186,831,433,728 bytes. Final free space was 647,840,034,816
bytes; final blockfile allocation was 116,658,593,792 bytes. `k8s.io`
blockfile snapshots fell from 140 to 53. The 13 historical leases and the
pending Alexa and pause image references/digests were byte-for-byte unchanged.
Both gates were ready, all evidence checksums passed, and no Kata/QEMU or
container record remained.

The validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_completed_image_cleanup_20260716_070418_validation_report.md`
(SHA-256 `a394827f2412bccc36453ae9ed953a1d2fcfad1bb3c9938f355cb5bc6c6cfaca`).

Capacity now permits the next separately approved measurement. Continue
sequentially: import and measure one workload, validate it, then remove its
`latest`, immutable `source-*`, and digest-named image references before
importing another. Do not batch-import all remaining workloads.

## 2026-07-16 image-processing measurement: passed 20/20

The approved harness completed one excluded cold warm-up followed by exactly
20 measured cold launches at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_image_processing_measurement_20260716_130035`.
It returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0` without
retry or resume. The preserved harness SHA-256 is
`95a2755ba3aa348806e7b6dff8c1958aed3c9e9ea6a3da8938ea8c972e89d36f`.

All 20 measured containers exited 0 and produced valid analyzer/timing
records. Mean values were `t_boot_cntr=14.958906710147858`,
`t_boot_func=1.1850345492362977`, `t_exec=3.5160353541374207`, and
`t_e2e=19.659976613521575` seconds. All 88 safety gates were ready. The 21
independent launch deltas had zero private level-2 mapping event, private 2M
promotion, KVM/TDX stop marker, or new kernel-log-loss record. Final
run-token, CRI, Kata/QEMU, and `/dev/kvm` owner checks were clean.

The validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_image_processing_measurement_20260716_130035/image_processing_measurement_validation_report.md`
(SHA-256 `ee5b8a5987fec4a48ff2ca2a8db977fb2761dc86ebb488b039f774f9aeebc857`).

Final measured data is complete for **5/12 workloads: video, DNA,
compression, face detection, and image processing**. Before importing another
workload, remove the image-processing `latest`, immutable `source-*`, and
digest-named references through the guarded sequential cleanup.

That cleanup subsequently passed at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_measured_image_cleanup_20260716_135147`.
It removed exactly the three derived-image references, reclaimed
54,183,411,712 free bytes, and restored `/Serverless` free space to
647,821,127,680 bytes. `k8s.io` snapshots fell from 78 to 53; all 13 leases
were unchanged, all evidence checksums passed, and the post-cleanup host gate
was ready. The evidence-manifest SHA-256 is
`1a065c2669968ae8f2b6c070221ac2d249d5b715885358cc3be92260020a9db1`.
The sequential capacity boundary is restored for the next separately approved
workload.

## 2026-07-16 sentiment measurement: passed 20/20

The approved sentiment harness completed one excluded warm-up and 20/20
measured cold launches at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_sentiment_measurement_20260716_141812`.
It returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0` without
retry or resume. All measured containers exited 0. Mean values were
`t_boot_cntr=15.018592143058777`, `t_boot_func=0.7080303788185119`,
`t_exec=0.03785055875778198`, and `t_e2e=15.76447308063507` seconds.

All 88 host gates were ready, and all 21 launch deltas had zero private
level-2 mapping event, private 2M promotion, stop marker, and new kernel-log
loss. Final CRI/process/batch-token residue was zero. The validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_sentiment_measurement_20260716_141812/sentiment_measurement_validation_report.md`
(SHA-256 `6f3a74be7a131dd41e8055e20f8fd48eefe0658c327e4b040555bd0677461e76`).

Final measured data is complete for **6/12 workloads**. The sentiment image
consumed approximately 56.39 GB of blockfile capacity and must undergo the
guarded three-reference cleanup before any remaining workload is imported.

That cleanup passed at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_measured_image_cleanup_20260716_151539`,
reclaiming 56,388,481,024 free bytes and restoring `/Serverless` free space to
647,817,252,864 bytes. `k8s.io` snapshots fell from 79 to 53, all 13 leases
were unchanged, all evidence checksums passed, and the final host gate was
ready. Its evidence-manifest SHA-256 is
`45d1708ed2555de631365f5ce20de58a35738eee2dbe863fe679f0aabac9cfde`.

Sampling terminology was also audited against the paper and released
artifact. Every launch is a cold start because each creates a fresh CRI
sandbox and Kata VM. The artifact does not explicitly discard an initial
launch. Therefore the final paper-aligned graph will use the first `N` cold
launches: the separately stored initial cold launch plus measured launches 1
through `N-1`. The extra measured launch remains sensitivity evidence. See
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_fig11_sampling_methodology_20260716.md`
(SHA-256 `94f9bfda3c96a2568fb8547ca05ecf563c384ea95af97e6b2769fd22048d63d4`).

## 2026-07-16 exact-N remaining-workload automation

The approved sampling correction is implemented for the six remaining
workloads. The generic harness
`/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_exact_measurement.sh`
(SHA-256 `a1e524ed2b5f44103e952ce57c2e49dc52e79b30d788aa24eecb21486f79a27e`)
records exactly `N` fresh Kata VM launches with no discarded warm-up. Image
preparation remains untimed and creates no CRI sandbox.

The fail-fast driver
`/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_remaining_exact_batch.sh`
(SHA-256 `9ef007d801da92df019020368f463298e565ffcf2daaa6f8f021cad91a41ed9f`)
orders thumbnailer, uploader, Alexa frontend, interact, smarthome, and TV. It
collects exactly 20 cold samples for one workload, validates all harness
evidence, synchronously removes only that workload's three generated CRI image
references, verifies capacity and host safety, and only then advances. There
is no retry or resume path, and graph generation is disabled. Any launch,
kernel-delta, residue, cleanup, or safety-gate failure stops the batch and
records the active workload.

No VM has been launched by this new automation yet. The approved invocation is
`sudo -v && /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_remaining_exact_batch.sh`.

## 2026-07-16 exact-N remaining batch: passed 6/6

The batch completed all six workloads at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_remaining_exact_batch_20260716_174435`
with `batch_rc=0`, `postflight_gate_rc=0`, and 20/20 cold samples per
workload. All 120 containers exited 0. All 518 safety-gate results were ready,
and all 612 generated stop-marker, log-loss, private-level-2, promotion, and
residue evidence files were empty. No outlier was removed.

Every guarded image cleanup passed and its checksum manifest verifies. The six
cleanups increased free space by 329,805,012,992 bytes in total; final
`/Serverless` free space was 759,611,682,816 bytes. The validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_remaining_exact_batch_20260716_174435/remaining_exact_batch_validation_report.md`
(SHA-256 `0aa69fe234cab94ddaa13e458d9e60872f0eb3baabdbb773cbaba178d9272279`).

Vanilla Kata-TDX measurement coverage is now **12/12**. No further VM launch
or KVM change is required. Continue with read-only aggregation and Fig. 11
graph generation.

## 2026-07-16 final Vanilla Kata-TDX Fig. 11 graphs

Read-only artifact-first-N aggregation completed at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_fig11_final_20260716_185434`.
It selected 215 validated cold-start records across all 12 function paths and
generated the paper-level nine-bar stage views. No outlier was removed. The
Alexa bar is the sum of its four chain functions.

The full E2E stage graph is
`/home/booklyn/BookArchive/Images/fig11-kata-tdx-vanilla-20260716-185434-cold-stages.png`.
The setup/load graph is
`/home/booklyn/BookArchive/Images/fig11-kata-tdx-vanilla-20260716-185434-cold-startup-stages.png`.
Both were visually inspected and the plotted stacks independently matched the
canonical E2E aggregates with maximum absolute delta
`7.105427357601002e-15` seconds.

The graph validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_fig11_final_20260716_185434/graph_validation_report.md`
(SHA-256 `c56ae28e8d8b3b67d3241c575011f53160f7d0c8f87358384d6a629727612845`).
The complete output manifest is `SHA256SUMS` in that directory (SHA-256
`5e46b05508f3f82bcaf05cc4aa6a24469af7d3bd7c3cee04844bff5a3fbb3cfc`).
The Vanilla Kata-TDX Fig. 11 measurement and graph mission is complete.

## 2026-07-17 measured Native/CoFunc/Kata comparison

The finalized measured datasets were combined without launching another VM.
The canonical comparison bundle is
`/home/booklyn/cofunc-tdx/reports/measured_tdx_fig11_20260717_0003`.
Its PNG and PDF use the paper's nine-application order and a log latency axis;
Alexa is summed from four functions for every mode.

CoFunc is faster than Vanilla Kata in 8/9 measured applications. The
Kata/CoFunc geometric-mean latency ratio is 10.10x, with a range of 0.73x to
88.55x. Video is the exception: measured CoFunc is 63.470 seconds versus
46.210 seconds for Kata because CoFunc handler execution itself averages
63.435 seconds. Do not describe the 10.10x result as a universal speedup.

These are reproduction measurements, not the paper's target bars. The CoFunc
source run reports a mean 3.875x actual/artifact-target ratio. The comparison
also intentionally retains CoFunc's validated old-ABI 2 MiB optimization and
Kata's validated 4 KiB containment policy, matching the paper's optimization
scope.

The validation report is
`/home/booklyn/cofunc-tdx/reports/measured_tdx_fig11_20260717_0003/validation_report.md`
(SHA-256 `2c838a6528b7b6d0f992599e74f96bfac65a7d9bcbaf93e3e067fe917cd109d9`).
The bundle manifest is `SHA256SUMS` (SHA-256
`f8dd2d2111f5fefc2789ae87423ccf1ad9880871ab72ef060069054511844c33`).

## 2026-07-17 three-mode stage-breakdown bundle

Matching full and setup/load stage charts for Native, CoFunc TDX, and Vanilla
Kata TDX are in
`/home/booklyn/BookArchive/Images/measured_tdx_fig11_stages_20260717_054140`.
The directory also contains a focused Alexa tradeoff chart and machine-readable
JSON/CSV. Its guide is `README.md` (SHA-256
`33a79ba5ec202026f64c493ecb33fd04b996ef9ead06147ec1773bf2e7a8850d`),
and its complete manifest is `SHA256SUMS` (SHA-256
`992f6d80011ac27f5c1080406dd3be18ae44065144f5bf2195ed9a7cde7e33ba`).

Alexa Native is slower than CoFunc for a specific, validated reason. Native
uses 776.2 ms for cumulative setup/loading, versus 141.2 ms for CoFunc. CoFunc
then spends 437.4 ms more in handler execution but retains a net 197.6 ms
advantage, making its measured E2E 704.8 ms versus Native's 902.4 ms. This is
a startup-path win, not a faster-handler result.

## 2026-07-17 correction: JavaScript Native is fork-equivalent

The preceding JavaScript Native interpretation is superseded. The released
`scripts/plot_fig11.py` does not use raw `lean_launch` E2E as the JavaScript
Native bar. Python Native is measured with `lean_fork`; JavaScript Native is
modeled as CoFunc `t_boot_lean + t_boot_func`, Native launch `t_exec`, and
`n_cow * native_cow_latency` because the multithreaded runtime cannot use the
same direct Linux-fork path.

The corrected comparison is
`/home/booklyn/cofunc-tdx/reports/measured_tdx_fig11_paper_aligned_20260717_060234`.
The corrected stage bundle is
`/home/booklyn/BookArchive/Images/measured_tdx_fig11_paper_aligned_stages_20260717_060234`.
For Alexa, corrected Native fork-equivalent E2E is `0.226567 s`, versus
CoFunc `0.704844 s`; the earlier `0.902416 s` Native value is retained only as
a raw-launch diagnostic.

The June 2026 CoW `result` was also confirmed invalid: it contains an epoch
timestamp and its `exec_log` has no latency output. The corrected model uses
the preserved Figshare-v4 `latency 2269.959229` ns/page record. Only one valid
record is locally preserved, although the released evaluator intended 50, so
the CoW coefficient has an explicit sampling limitation.

## 2026-07-21 CoFunc pre-fault counter-unit correction

Chunked private pre-faulting is functionally validated for face detection,
pinned DNA, and video. The corrected private-syscall video pilot is preserved
at
`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_video_private_syscall_20260721_073012`.
It completed on one launch with ready pre/post safety gates, zero deferred
accepts, and no KVM/TDX stop marker.

The pilot proves a 64-bit raw page-fault cycle delta of 3,095,835,376. It does
not prove `t_pgfault_exec=3.095835376` seconds. The guest fault path accumulates
`get_cycles()`/`RDTSC`, while the legacy analyzer divided by 1e9 without the
guest TSC frequency. Host CPUID reports an invariant 2.8 GHz TSC and QEMU used
`-cpu host` with no override, implying approximately 1.105655491 seconds, but
the guest's PIT-calibrated frequency was not logged. The detailed corrected
report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_video_private_syscall_20260721_073012/validation_report.md`
(SHA-256 `2a6768126d25e7f6c2899d7ecbb9876326d75543a5d67da5716d9c17522ce61f`).

Patch 0007 now emits `t_pgfault_exec_cycles` and
`t_pgfault_import_cycles`; it no longer labels raw cycles as seconds. The next
fault-comparison phase must add both `sc_n_pgfault` and guest-calibrated TSC
frequency telemetry before collecting DNA or video measurements. Do not use
the legacy `t_pgfault_*` seconds fields from earlier analyzer JSON.
