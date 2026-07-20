# Vanilla Kata-TDX Fig. 11: no-2M handoff report (2026-07-15)

## Current status

Patch 0023's 4K containment and patch 0025's bounded validation telemetry are
applied, built, installed, and loaded. The isolated face smoke passed and
captured 64 correct 2M-to-4K containment decisions. A separately approved
five-launch face churn subsequently passed functionally and remained host-safe
5/5, with clean cleanup, zero private level-2 SEPT/promotion events, zero stop
markers, and no new kernel-log loss.

The churn does not receive an unconditional validation pass because it captured
zero new containment records. Patch 0025's module-lifetime 64-record counter
was exhausted by the isolated smoke and was not reset before churn. This is a
telemetry-boundary failure, not an observed 2M mapping or host regression, but
the earlier smoke records must not be counted as churn records. Therefore do
not recommend or run a multi-workload batch, measurement, or full matrix
without a new manager decision.

The receiving agent must rerun the gate before any source, module, or VM step;
do not assume this reported result remains current on the shared host.  Stop
immediately if the gate is no longer ready.

The completed smoke work is real and preserved, but the requested cold-start
measurement matrix and Fig. 11 graph are **not complete**.

## Active host configuration

| Item | Confirmed value |
|---|---|
| Kernel | `5.19.0-cofunc-tdx-5.19+` |
| Loaded `kvm` srcversion | `C01F58A5F36A5E9E75E4B99` |
| Loaded `kvm_intel` srcversion | `93A968602404A13EEF604A9` |
| Runtime handler | `kata-qemu-tdx` |
| Snapshotter | `blockfile` |
| Kata config | `/etc/kata-containers/configuration-qemu-tdx-blockroot.toml` |
| CRI endpoint | `unix:///run/containerd/containerd.sock` |
| Custom old-ABI 4K-to-2M promotion helper | Disabled by patch 0017 |
| Old-ABI private normal-slot mapping policy | Capped to 4K by patch 0023; bounded telemetry from patch 0025 |
| Built `kvm.ko` SHA-256 | `ea3d14e28114ab79445ce67d642ca2d9bfe2b6a4b8022028c2af63ee75741233` |
| Built `kvm-intel.ko` SHA-256 | `153e6ee934bb32ab34e269cef08d647829489b04a38a53b0e213d7b8b5630cdf` |
| Module rollback backup | `/mnt/new_disk/cofunc_tdx_artifact/module-backups/kvm-5.19/5.19.0-cofunc-tdx-5.19+-20260715_075826` |

The patch-0017 change was intended to avoid a suspected custom old-ABI private
2M split path.  Subsequent source and log review shows that it was not a true
no-2M configuration: it disabled only the custom promotion helper, while
`__kvm_mmu_max_mapping_level()` could still select 2M through the normal host
HVA/THP path.

## Patch-0023 isolated smoke result

Build/install evidence and the review are preserved in:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z
```

The actual smoke run is:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_face_smoke_20260715_070308
```

The face container exited 0 with `t_e2e=18.80324149131775`; the generic runner
reported success, CRI cleanup was clean, and all captured gates reported
`host_safety=ready`.  No canonical KVM/TDX stop marker is present.

The outer runner's `TDX.*EPT` expression falsely matched benign `TDX SEPT`
lifecycle messages.  It has been replaced with the canonical explicit
host-safety expression.  Kernel-log loss is now detected and reported as a
separate validation failure.

The smoke produced 438 `changed-zap-leaf level=1` and 438 matching
`changed-drop-leaf level=1` lines in a short teardown burst, causing 22
explicit `/dev/kmsg buffer overrun` notices.  Consequently, zero captured
private level-2 transitions is not a conclusive dynamic negative.

Zero `forced to 4K` markers also does not prove that patch 0023 was bypassed.
That marker is emitted only when `normal_req > PG_LEVEL_4K`; patch 0023 still
enters the containment branch and returns 4K when `normal_req` is already 4K.

An unapplied logging-only follow-up is prepared at:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0025-Diagnostic-make-4k-containment-telemetry-conclusive.patch
```

Patch 0025 logs containment-branch entry regardless of the incoming level,
keeps a bounded TDP level sample, and suppresses the per-4K diagnostics that
overflowed the log.  It applies cleanly to the current patch-0023 source and
passes strict kernel checkpatch with zero errors, warnings, or checks.  It has
not been applied, built, installed, or loaded.

## 2026-07-15 forensic correction

Do not interpret the failed batch as evidence that the fault is independent
of 2M private mappings.

Patch 0017 changes only `cofunc_tdx_oldabi_private_2m_capable()` to return
false.  In `kvm_mmu_hugepage_adjust()`, KVM first assigns `fault->req_level`
from `__kvm_mmu_max_mapping_level()`.  If the ordinary host mapping walk has
already returned `PG_LEVEL_2M`, patch 0017 neither logs nor caps that result.

The current-boot log proves that this occurred under the loaded patch-0017
module.  A successful earlier VM recorded:

```text
where=changed-live-split gfn=0x1200 level=2 old_present=1 old_last=1
```

and then removed 4K children from the demoted mapping.  The line is preserved
in the failed run's `dmesg-before.log`.  Therefore the empty
`promotion disabled` counter did not prove 4K-only operation; that counter is
specific to the custom helper.

The July 14 and July 15 host faults have the same stronger signature:

```text
KVM operation: level=1 / tdx_level=0 (requested 4K child)
TDX output:     out_rdx=0x101 (walk stopped at level 1, SEPT_BLOCKED)
```

Here, KVM's `level=1` is `PG_LEVEL_4K`, while the TDX module's failing SEPT
walk level 1 is the 2M ancestor.  On July 15, `out_rcx` describes the blocked
physical 2M range based at PFN `0x21bae00`; KVM then tried child PFNs
`0x21bae76` and `0x21bae77`.  On July 14, the same relation holds for blocked
range PFN `0x2f3a00` and child PFN `0x2f3a7d`.

The violated invariant is therefore: KVM's software TDP tree contains 4K
leaves, but the secure SEPT walk still encounters a blocked 2M ancestor.  The
exact earlier transition that left those structures inconsistent is not yet
proven because the finite lifecycle log budget was exhausted before the
failure.  The immediate containment is to prevent old-ABI private normal-slot
2M mappings entirely; it is not to retry or ignore the failed SEAMCALL.

An unapplied containment patch is prepared at:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0023-Diagnostic-force-oldabi-private-normal-slot-4K.patch
```

Patch 0023 caps the ordinary KVM mapping decision at 4K for old-ABI private
faults backed by normal memslots and returns before the custom promotion
helper.  It is a Vanilla Kata A/B, not a root fix, and it must not be used to
collect CoFunc measurements because it also disables CoFunc's private 2M
optimization.

### Upstream design corroboration

Intel's much newer TDX private-huge-page RFC treats splitting as a dedicated,
fallible external-page-table operation.  It requires the sequence
`RANGE_BLOCK -> TRACK/kick vCPUs -> PAGE_DEMOTE`, retries restartable/BUSY
SEAMCALL outcomes, and supports the operation under the exclusive MMU lock.
The series also avoids private huge-page splitting from the shared-lock fault
path.  See [RFC patch 15/21](https://patchew.org/linux/20250424030033.32635-1-yan.y.zhao%40intel.com/20250424030800.452-1-yan.y.zhao%40intel.com/)
and [RFC patch 21/21](https://patchew.org/linux/20250424030033.32635-1-yan.y.zhao%40intel.com/20250424030926.554-1-yan.y.zhao%40intel.com/).

That design is materially different from this September 2022 tree, where the
software non-leaf is published through `tdp_mmu_link_sp()` and a void callback
then updates the secure SEPT.  A modern huge-page-series backport is therefore
not a minimal or low-risk repair for the artifact kernel.  The true-4K cap is
the appropriate containment for obtaining the Vanilla Kata baseline while the
2M split implementation remains a separate kernel-engineering task.

### Source-level cause assessment

The highest-confidence cause is a failed private 2M-to-4K split whose failure
cannot be propagated back through the September 2022 TDP callback interface.
The relevant commit order is:

1. `tdp_mmu_split_huge_page()` constructs a 4K child software page table.
2. `tdp_mmu_link_sp()` calls `tdp_mmu_set_spte_atomic()` under the shared MMU
   lock, or `tdp_mmu_set_spte()` under the write lock.
3. KVM freezes or writes the software SPTE, invokes
   `__handle_changed_spte()`, and then publishes the new non-leaf software
   SPTE.
4. The TDX `handle_changed_private_spte` callback executes
   `RANGE_BLOCK -> TRACK -> PAGE_DEMOTE` for a live 2M leaf.
5. `tdx_sept_split_private_spte()` returns an error when `PAGE_DEMOTE` fails,
   but `tdx_handle_changed_private_spte()` and the KVM callback are `void`.
   `tdp_mmu_link_sp()` therefore returns success and has no rollback path.

This directly permits the observed invariant violation: software 4K children
can remain installed while the secure SEPT still contains the blocked 2M leaf.
The same weakness exists in the write-lock split path: the software non-leaf
is installed before the protected-page-table callback and callback failure is
not observable by the caller.

The likely trigger paths, in descending order, are:

1. The shared-lock page-fault split in `kvm_tdp_mmu_map()`, especially the
   unzap-then-split path for a `private_zapped` 2M SPTE.  The newer RFC
   explicitly avoids this private split under the shared lock.
2. A partial `MAP_GPA` range operation under the write lock, which splits a 2M
   leaf before zapping selected 4K children.
3. The already-blocked split path, which demotes a blocked parent and then
   blocks 512 children without propagating an intermediate failure.

The A/D suppression changes do not explain the structural mismatch.  They can
affect host-page flag cleanup during teardown, but the fatal failure occurs
earlier when a 4K `MAP_GPA` operation walks into a blocked 2M secure ancestor.

An unapplied, behavior-preserving diagnostic patch is prepared at:

```text
/home/booklyn/cofunc-tdx/patches/host-kernel/0024-Diagnostic-trace-private-2m-split-commit-order.patch
```

Patch 0024 records the TDP split lock mode, live versus already-blocked TDX
path, every 2M `PAGE_DEMOTE` result, and unbudgeted SEAMCALL failure context.
It applies cleanly to the current source and passes strict kernel checkpatch
with zero errors, warnings, or checks.  It has not been applied, built,
installed, or loaded.

The decisive diagnostic signature would be:

```text
phase=demote-end ... err=<nonzero>
phase=tdp-end ... ret=0 linked=1
```

for the same KVM, GFN, level, task, and adjacent log sequence.  That pair would
prove that secure demotion failed while KVM nevertheless committed the 4K
software tree.  A successful `demote-end err=0` followed by later divergence
would instead move the investigation to the already-blocked child loop or
subsequent secure-page-table removal/reconstruction.

## Confirmed successful work

### Host and short-run stability

- The isolated no-2M face smoke passed:
  `/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_face_smoke_20260714_184027`.
- The ten-launch no-2M face churn passed 10/10, with clean gates and analyzer
  records:
  `/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_face_churn10_20260715_035310`.
- Mean churn `t_e2e`: `10.474375772476197` seconds.

### Complete 12-workload no-2M smoke coverage

Every Fig. 11 entry completed one fresh cold CRI smoke, exited zero, wrote an
analyzer record, released its temporary image pin, and passed the runner's
pre/post/exit host-safety gates.  The evidence is split at clean boundaries:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_smokes_20260715_041408
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_smokes_remaining_20260715_042836
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_smoke_tv_20260715_044440
```

Completed workloads:

1. `fn_py_dna_visualisation`
2. `fn_py_compression`
3. `fn_py_face_detection`
4. `fn_py_image_processing`
5. `fn_py_sentiment`
6. `fn_py_video_processing`
7. `fn_js_thumbnailer`
8. `fn_js_uploader`
9. `chain_js_alexa/fn_js_alexa_frontend`
10. `chain_js_alexa/fn_js_alexa_interact`
11. `chain_js_alexa/fn_js_alexa_smarthome`
12. `chain_js_alexa/fn_js_alexa_tv`

The first smoke run stopped before an uploader VM when the required file
server was absent from port 8080.  The second stopped before an Alexa TV VM
when the device helper was absent from port 9090.  These were pre-launch helper
readiness exits, not Kata/TDX faults.  The documented `scenv_file_server` and
`scenv_device` helpers were then started; do not stop or alter unrelated
OpenWhisk containers.

## Current failure: first timed no-2M DNA sample

Run directory:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717
```

The batch selected only `fn_py_dna_visualisation` (ten requested samples).
Preflight, image preparation, and one warm-up passed.  Measurement sample 1
started at `04:49:36Z` and failed before the guest agent was reachable.

### Primary evidence

At `04:49:41Z`, the host reported:

```text
WARNING ... tdx_sept_zap_private_spte [kvm_intel]
TDH_MEM_RANGE_BLOCK: TDX_EPT_WALK_FAILED ... SEPT_BLOCKED
TDH_MEM_PAGE_REMOVE: TDX_EPT_WALK_FAILED ... SEPT_BLOCKED
```

The kernel's diagnostic context is significant:

```text
op=range_block
gfn=0x7d276
gpa=0x7d276000
level=1
tdx_level=0
slot_private=0
blocked=1
```

KVM was operating on a normal `slot_private=0`, 4K (`tdx_level=0`) software
leaf, but `out_rdx=0x101` says the secure SEPT walk stopped at a blocked 2M
ancestor.  This is evidence of KVM/SEPT structural-state divergence, not proof
that the VM contained no private 2M mapping.

QEMU then logged:

```text
error: kvm run failed Input/output error
```

and exited `134`.  The later CRI failure,
`timed out connecting to vsock 2924031104:1024`, is downstream of the QEMU
abort.  During teardown, the host also warned in `tdx_reclaim_page` and KVM
`__handle_changed_spte` / TDP-MMU code.

The runner's exit gate reported `host_safety=not-ready`.  It did not retry or
force cleanup after the marker.  There is no measured analyzer JSON record;
`log/fn_py_dna_visualisation/sample-001` contains only failed sandbox input/log
evidence.  This batch is invalid, cannot be resumed, and must not be graphed.

### Preserved evidence

- [Batch runner log](/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/runner.log)
- [Kernel failure delta](/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/dmesg-failure.delta)
- [Full post-failure kernel capture](/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/dmesg-failure.log)
- [Copied QEMU stderr](/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/failure-evidence/kata-qemu-tdx-oldabi-qemu.0.log)
- [Copied QEMU wrapper log](/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_no2m_fig11_measurements_20260715_044717/failure-evidence/kata-qemu-tdx-oldabi-wrapper.0.log)

Copied QEMU-log SHA-256 values:

```text
qemu.0.log    52607dd4c9af37d47228c01f5942b9335c143b4ef3a3e786d10624f88cd13615
wrapper.0.log 82a32edcec8c779cde0bf82db80e47ab47daabaf7d9aeac083fccdec41ab0b52
```

## Reproduction tooling implemented

The following user-space safeguards are in place and syntax-validated with
`bash -n`:

- `scripts/kata_tdx_host_safety_gate.sh` fails closed on current-boot KVM/TDX
  markers, active QEMU/Kata processes, `/dev/kvm` owners, and stale Kata
  container records.
- `scripts/run_kata_tdx_cri_workload.sh` runs the safety gate before and after
  each sample, verifies CRI cleanup, protects an active image from kubelet GC,
  releases only runner-created pins, and supports `START_ITERATION` without
  overwriting existing `sample-NNN` evidence.
- `scripts/run_kata_tdx_cri_fig11.sh` defaults to `FIG11_MODE=smokes`.
  `FIG11_MODE=batch` requires an explicit bounded `FIG11_WORKLOADS` list;
  manual `FIG11_RESUME=1` validates existing analyzer records and artifacts
  before appending.  It refuses inconsistent or failed sample boundaries.
  `FIG11_MODE=render` validates all complete workloads before graphing.

The old July 14 interrupted measurement run is also correctly rejected by
render/resume validation because it has nine DNA analyzer records but ten
sample directories.

## Required next actions

1. Do not resume the failed DNA batch or generate a graph from it.
2. Rerun the exact read-only gate before any source, module, or VM operation:

   ```bash
   sudo /home/booklyn/cofunc-tdx/scripts/kata_tdx_host_safety_gate.sh pre-0025-churn
   ```

   Continue only if it reports `host_safety=ready`.
3. Do not reapply, rebuild, reinstall, or reload patches 0023/0025.  Their
   loaded srcversions and the successful isolated-smoke evidence are recorded
   above.  Reconfirm them read-only if the host state is in doubt.
4. Do **not** reapply patch 0020: official TDX 1.5 source showed its
   child-unblock theory was wrong.
5. Do not rerun the isolated face smoke.  After separate owner approval, the
   next VM action is a bounded multi-launch face churn with a new run directory,
   a gate before and after every launch, and before/after kernel snapshots.
   Stop without retry on any failed gate, workload failure, stop marker,
   private level-2 event, or kernel-log-loss notice.
6. Only after that clean churn, run one small per-workload smoke or measurement
   batch.  A clean patch-0023/0025 run validates 4K containment; it does not
   repair the old 2M split path.  Use that configuration to finish the Vanilla
   Kata baseline; do not make baseline collection depend on reproducing the
   host fault.
7. Patch 0024 supplies the separate root-cause diagnostics.  Use it with 2M
   enabled only in an owner-approved diagnostic boot, one isolated smoke at a
   time, with the host-safety gate before and after every launch.  Stop on the
   first marker.  Do not perform that reproduction merely to continue Fig. 11.

For extended historical detail, read
`docs/tdx_reproduction_handoff.md`, especially its July 14–15 host-safety,
no-2M, smoke-matrix, and measurement-failure sections.

## 2026-07-15 patch-0023 apply/build checkpoint

Patch 0023 was applied exactly once and the KVM module set was built.  It is
**not installed or loaded**.  No VM was launched, no kernel-log delta was
collected, and no Fig. 11/CoFunc measurement was run.

Evidence is preserved at:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z
```

The source is
`/mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot`
at base commit `8298dd80cf482b58dec935832e1afc9d3a00587f`.  Its worktree already
contained the expected CoFunc/patch-0017 changes.  Patch 0023 changes only
`arch/x86/kvm/mmu/mmu.c`; the pre-change source SHA-256 was
`8aa4e22909611bba12dff2b988ffcc5bcdba319d8a8d0c35172e3b42a22f3583` and the
post-change SHA-256 is
`b26d3f6096db117ac33b5017b3dc932496fc7f693ef52d191226f0b4ca6f7dbb`.
Both source versions and the exact patch are preserved below the evidence
directory's `backup/` subdirectory.

Patch validation was run from the source root with:

```bash
patch --batch --dry-run -p1 -i /home/booklyn/cofunc-tdx/patches/host-kernel/0023-Diagnostic-force-oldabi-private-normal-slot-4K.patch
patch --batch --dry-run -R -p1 -i /home/booklyn/cofunc-tdx/patches/host-kernel/0023-Diagnostic-force-oldabi-private-normal-slot-4K.patch
git apply --check /home/booklyn/cofunc-tdx/patches/host-kernel/0023-Diagnostic-force-oldabi-private-normal-slot-4K.patch
perl scripts/checkpatch.pl --strict --no-tree /home/booklyn/cofunc-tdx/patches/host-kernel/0023-Diagnostic-force-oldabi-private-normal-slot-4K.patch
```

The forward dry run passed; reverse dry run reported `Unreversed patch
detected!`, proving the patch was not already applied; `git apply --check`
passed; and strict checkpatch reported zero errors, warnings, and checks.
After application, forward dry run reported the patch reversed/already
applied, reverse dry run succeeded, and `git diff --check` was clean.

The established build command was:

```bash
make -C /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc M=arch/x86/kvm -j16 modules
```

It exited zero.  Built module metadata:

```text
kvm.ko       sha256=64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752
             srcversion=604B04FCEE16BFBF96BA96D
kvm-intel.ko sha256=d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
             srcversion=5E9FE6DC9A74E201D9D3C2E
vermagic: 5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions
```

The rebuilt `kvm.ko` contains `CoFunc old-ABI private mapping forced to 4K`.
The evidence directory contains copies of both raw modules.  The currently
installed compressed-module payloads remain the pre-0023 modules:

```text
kvm.ko.zst payload       90e38c3a4f52afe1c2b2913ab4d7cea2796ff6ee5d076801a4ecf923117c4704
kvm-intel.ko.zst payload d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
```

The currently loaded modules also remain pre-0023:

```text
kvm       22B2A410CCC77E86F9E3BC7
kvm_intel 5E9FE6DC9A74E201D9D3C2E
kvm_intel.tdx=Y
```

No 4K-containment validation counts exist yet: forced-4K=0, private
`changed-live-split ... level=2`=0, custom private-2M promotions=0, and
KVM/TDX stop markers=0 are **not test results** because the new module has not
been loaded and no smoke was launched.

Before installation, the owner must run these exact commands and retain the
complete output.  Continue only if the gate says `host_safety=ready`, `/dev/kvm`
has no users, and both CRI listings are empty; do not force any cleanup.

```bash
sudo /home/booklyn/cofunc-tdx/scripts/kata_tdx_host_safety_gate.sh pre-4k-containment
sudo fuser -v /dev/kvm
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods
```

If and only if all are clean, the safe installation command is:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
```

It creates a rollback backup and replaces only on-disk compressed modules; it
does not reload KVM.  Do not run `--reload`, reboot, restart a service, or
launch a VM without explicit owner approval after installation.

## 2026-07-15 patch-0023 installed on disk (not reloaded)

The owner ran the guarded install successfully:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --install
```

The installer created the rollback backup:

```text
/mnt/new_disk/cofunc_tdx_artifact/module-backups/kvm-5.19/5.19.0-cofunc-tdx-5.19+-20260715_063552
```

Its `module-hashes.txt` is copied to the evidence directory.  The backup
preserves the prior modules, and the freshly installed compressed payloads are
verified equal to the built outputs:

```text
backup kvm.ko.zst payload       90e38c3a4f52afe1c2b2913ab4d7cea2796ff6ee5d076801a4ecf923117c4704
backup kvm-intel.ko.zst payload d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
installed kvm.ko.zst payload    64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752
installed kvm-intel payload     d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794
```

The installer and immediate post-install check found no `/dev/kvm` owner.  No
reload, reboot, service restart, or VM launch happened.  Loaded modules remain
the old pair: `kvm=22B2A410CCC77E86F9E3BC7`,
`kvm_intel=5E9FE6DC9A74E201D9D3C2E`, `kvm_intel.tdx=Y`.  All 4K-containment
smoke/marker counts remain not-applicable because the new `kvm.ko` has not
been loaded.

Before an explicitly approved reload, rerun the fresh gate and record empty
KVM/CRI state. Do not force cleanup if any result is non-empty or not-ready.

```bash
sudo /home/booklyn/cofunc-tdx/scripts/kata_tdx_host_safety_gate.sh pre-4k-containment-reload
sudo fuser -v /dev/kvm
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods
```

The reload command, which requires separate explicit owner approval, is:

```bash
sudo /home/booklyn/cofunc-tdx/scripts/install_5_19_patched_kvm_modules.sh --reload
```

## 2026-07-15 pre-reload gate confirmed clean

The owner supplied the full transcript at evidence path
`owner-pre-reload-gate-and-cri.txt` (SHA-256
`7bce296fca24a235ef5bc58c39d1252698c58da203d6f9876534447fed97ab68`). It
reports `host_safety=ready`: no known current-boot KVM/TDX stop marker,
`kvm_intel.tdx=Y`, zero KVM use count, no `/dev/kvm` owner, no Kata/QEMU
process, and no Kata CRI record in either `default` or `k8s.io`.

The owner's broad CRI listings do show months-old exited non-Kata records in
`openfaas`, `openfaas-fn`, and `kube-system`; their runtime is `(default)`.
They are outside the relevant Kata namespaces and are not to be removed or
otherwise modified.  This satisfies the no-stale-Kata-record condition. The
only remaining prerequisite for reload is separate explicit owner approval.

## 2026-07-15 patch-0023 loaded-version proof

The owner approved and ran the guarded reload. Direct host verification proves
that the loaded module versions now match the built/install pair:

```text
kernel=5.19.0-cofunc-tdx-5.19+
loaded kvm=604B04FCEE16BFBF96BA96D
built  kvm=604B04FCEE16BFBF96BA96D
loaded kvm_intel=5E9FE6DC9A74E201D9D3C2E
built  kvm_intel=5E9FE6DC9A74E201D9D3C2E
kvm_intel.tdx=Y
```

The installed compressed payload hashes still equal the raw build hashes:
`kvm=64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752`,
`kvm-intel=d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794`.
`/dev/kvm` has no owner. Evidence:
`post_reload_loaded_module_verification.md` in the containment run directory.
No VM has been launched after reload; require a fresh clean pre-smoke gate
before the one isolated Vanilla Kata face smoke.

## 2026-07-15 first patch-0023 face smoke stopped before VM creation

The single guarded face-smoke invocation is preserved at:

```text
/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_face_smoke_20260715_064738
```

All three gates were ready: the outer Fig. 11 preflight, the generic runner's
workload entry, and its runner exit. The run then stopped before image
preparation/pod creation because `127.0.0.1:8888/get_param` refused a
connection for `testcases/fn_py_face_detection`. `ss -ltnp 'sport = :8888'`
found no listener.

This is a parameter-helper readiness boundary, not a 4K-containment result:
no VM launched; no CRI pod or container with the run token exists; the
before-to-failure kernel-log delta is empty; and no KVM/TDX warning or stop
marker appeared. The runner exited 1 solely because it refuses to start shared
helpers automatically. Counts are therefore: forced-4K=n/a, private level-2
split=n/a, private promotion=n/a, stop markers=0 (no-launch delta). Do not
retry until only the required `scenv_param` helper is restored and its HTTP
readiness is independently confirmed.

Read-only inspection also establishes that the face smoke needs exactly two
absent helpers: no `scenv_param`/`scenv_minio` container exists, no process is
listening on ports 8888/9000, and MinIO health is unavailable. Both images are
already present, so do not pull, remove, or restart anything unrelated. The
owner-only recovery commands are:

```bash
sudo docker run -d --rm --name scenv_param --net=host \
  -v /mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases:/testcases \
  scenv_param:latest
sudo docker run -d --rm --name scenv_minio --net=host \
  -e MINIO_ROOT_USER=root -e MINIO_ROOT_PASSWORD=password \
  minio/minio:latest server /data
curl --connect-timeout 5 --max-time 15 -fsS -X POST http://127.0.0.1:8888/get_param \
  --data-urlencode fn_name=testcases/fn_py_face_detection
curl --connect-timeout 5 --max-time 15 -fsS http://127.0.0.1:9000/minio/health/ready
```

Run no VM command until both curls exit zero.  The next attempt must use a new
run directory; do not resume or overwrite the preserved pre-launch boundary.

The helpers were subsequently verified running without removal/replacement:
`scenv_param` (`6abd49ffca7c`) and `scenv_minio` (`0ee90474e910`) were both
`Up`, started at `2026-07-15T07:00:09Z`. Parameter lookup now returns the face
JSON and MinIO health exits zero. The next permitted action is one new,
guarded face-smoke attempt only; its runner must provide the fresh pre/post/exit
gates and kernel delta.

## 2026-07-15 patch-0023 isolated smoke: functional guest success, evidence hard stop

The sole post-reload smoke is preserved in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_face_smoke_20260715_070308`.
The guest function exited `0` (`t_e2e=18.80324149131775`), cleanup left zero
test-token CRI records, and all five runner gates were `host_safety=ready`.

The outer runner exited `1` because its generic `TDX.*EPT` delta rule matched
the loaded diagnostic's normal `TDX SEPT` lifecycle telemetry. The delta has
876 level-1 events (438 zap plus 438 drop) and 22 systemd-journald
`/dev/kmsg buffer overrun` notices. Gate-defined KVM/TDX stop markers are zero,
but lost kmsg messages make the kernel capture incomplete. Do not retry, churn,
measure, reload, or launch another VM on this boot.

Counts are forced-4K=0, private live level-2 split=0, custom private-2M
promotion=0, and gate stop markers=0. Forced-4K=0 does not prove the cap branch
was bypassed: the marker was conditional on an incoming request above 4K, while
the branch also handles requests already at 4K. Dynamic containment remains
inconclusive because of log loss, so it is not safe to proceed to bounded
churn. The targeted no-VM read-only
verification and copied evidence are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/smoke_failure_summary.md`.

The independent review is preserved at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_4k_containment_20260715_062336Z/smoke_failure_review.md`.
It records the runner-regex correction and the then-unapplied patch-0025 follow-up.

## 2026-07-15 patch-0025 telemetry follow-up: built, intentionally not installed

With the owner-provided `pre-0025` safety gate reporting `host_safety=ready`,
the host was reconfirmed to have no `/dev/kvm` owners and no Kata/QEMU process.
Patch 0025 was proved unapplied by forward/reverse dry runs, `git apply --check`,
and strict `checkpatch`; the three affected files were backed up with
pre-change SHA-256 records before it was applied exactly once to the patch-0023
source tree. Forward dry-run then reported the patch as already applied, reverse
dry-run passed, `git diff --check` was clean, and strict checkpatch reported
0 errors, 0 warnings, and 0 checks (69 lines checked). The exact validation
commands and the three backups are recorded in `pre_apply_evidence.md` below.

The preserved build/evidence directory is
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042`.
It contains the command, dry-run records, source hashes, backups, copied modules,
and post-build evidence. The successful command was:

```
make -C /mnt/new_disk/cofunc_tdx_artifact/build/kernel-intel-tdx-5.19-cofunc M=arch/x86/kvm -j16 modules
```

The pre-change backup paths are
`backup/arch/x86/kvm/mmu/mmu.c.before-0025`,
`backup/arch/x86/kvm/mmu/tdp_mmu.c.before-0025`, and
`backup/arch/x86/kvm/vmx/tdx.c.before-0025`, relative to that evidence directory.

The new modules are `kvm.ko`
`ea3d14e28114ab79445ce67d642ca2d9bfe2b6a4b8022028c2af63ee75741233`
(`srcversion=C01F58A5F36A5E9E75E4B99`) and `kvm-intel.ko`
`153e6ee934bb32ab34e269cef08d647829489b04a38a53b0e213d7b8b5630cdf`
(`srcversion=93A968602404A13EEF604A9`). Both have vermagic
`5.19.0-cofunc-tdx-5.19+ SMP preempt mod_unload modversions`.

They are deliberately not installed or loaded. The active patch-0023 pair remains
`kvm=604B04FCEE16BFBF96BA96D` and
`kvm_intel=5E9FE6DC9A74E201D9D3C2E` (`kvm_intel.tdx=Y`). No reload, reboot,
service action, or VM launch occurred. Installation requires separate owner
approval after rerunning the gate and confirming no `/dev/kvm` owners.

### 2026-07-15 patch-0025 installation: payloads updated, KVM deliberately not reloaded

The owner ran the full `pre-0025-install` gate, which returned
`host_safety=ready` with no `/dev/kvm` owners, Kata/QEMU processes, stale Kata
CRI records, or current-boot stop markers. The safe installer then backed up
the previous installed pair to
`/mnt/new_disk/cofunc_tdx_artifact/module-backups/kvm-5.19/5.19.0-cofunc-tdx-5.19+-20260715_075826`.

Its pre-install compressed-payload SHA-256 values were patch-0023 `kvm`
`64d17855dd287870ddc7e4e72a64e82cb5b013a9c85d889a164d933bc1187752` and
`kvm-intel` `d7892ea75b98c46db69be78c586ead7d6e26303ccfe8ec39287048333c59e794`.
The installed compressed payloads now match the patch-0025 build exactly:
`kvm=ea3d14e28114ab79445ce67d642ca2d9bfe2b6a4b8022028c2af63ee75741233` and
`kvm-intel=153e6ee934bb32ab34e269cef08d647829489b04a38a53b0e213d7b8b5630cdf`.
The installer did not reload KVM. Preserve this boundary: no reload, reboot,
service action, or VM launch without separate owner approval. The full record is
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/install_evidence.md`.

### 2026-07-15 patch-0025 reload: loaded versions proven

The owner next ran `pre-0025-reload`; the full gate returned `host_safety=ready`
with no `/dev/kvm` users, Kata/QEMU process, stale Kata CRI record, or known
current-boot stop marker. The safe `--reload` helper loaded
`kvm=C01F58A5F36A5E9E75E4B99` and
`kvm_intel=93A968602404A13EEF604A9`, exactly matching the patch-0025 build;
the loaded `kvm_intel` path is
`/lib/modules/5.19.0-cofunc-tdx-5.19+/kernel/arch/x86/kvm/kvm-intel.ko.zst` and
`kvm_intel.tdx=Y`. The matching proof is preserved at
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/reload_evidence.md`.

This establishes the intended loaded-module state only. Do not launch a VM or
start a smoke without a new safety gate and separate owner approval.

The owner ran that fresh full gate as `post-0025-reload`; it also reported
`host_safety=ready` with no current-boot stop markers, `/dev/kvm` users,
Kata/QEMU process, or stale Kata CRI record. No VM has been launched after this
gate; the required smoke authority remains separate.

## 2026-07-15 patch-0025 isolated face smoke: containment proven

The owner approved and ran exactly one Vanilla Kata-TDX
`fn_py_face_detection` smoke in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_smoke_20260715_083921`.
It was not retried. No churn, CoFunc measurement, matrix, or further VM was run.

The container exited 0 and all six runner gates reported
`host_safety=ready`; post-run CRI JSON has zero run-token records. The 83-line
kernel delta contains 64 containment records, and every record is
`normal_req=2 capped_req=1 would_cap=1`. Counts are private live level-2
split=0, any private SEPT level-2 lifecycle=0, private 2M promotion=0,
canonical stop marker=0, and new kernel-log loss=0. Historical 07:06
`/dev/kmsg` overrun records predate this smoke and do not appear in its delta.

TDP MMU was enabled, but the retained `tdp_adjust`/`tdp_target` logger produced
zero records because its fixed GFN window is `0x500000..0x7fffff` while this
run's containment samples are `0x0..0x8000`. Do not misstate zero target records
as observed level-1 targets. Static flow closes the mapping decision: each fault
starts with `goal_level=PG_LEVEL_4K`; the normal-slot private branch caps
`req_level` to 4K and returns before any code can raise `goal_level`; the TDP
walker installs at that goal. Along with 64 runtime caps and zero huge SEPT
transitions, this proves 4K containment for the exercised workload.

Detailed counts, hashes, source-flow proof, and the direct-target telemetry
limitation are preserved at
`/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-0025-4k-containment-telemetry-20260715_074042/smoke_validation_20260715_083921.md`.
No additional run is authorized.

## 2026-07-15 patch-0025 bounded face churn: stable 5/5, telemetry criterion unmet

The single approved churn is preserved at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_churn5_20260715_140851`.
It invoked `run_kata_tdx_cri_workload.sh fn_py_face_detection 5` exactly once,
without retry or any subsequent VM.

All five containers reached `CONTAINER_EXITED` with exit code 0, all five
analyzer JSON records and required timing markers exist, the generic runner's
12 gates and the wrapper's pre/post gates were all `host_safety=ready`, and no
run-token CRI object or Kata/QEMU process remained. Mean `t_e2e` was
`17.404940938949586` seconds.

The 101-line kernel delta has private level-2 SEPT/lifecycle=0, private 2M
promotion=0, canonical stop-marker=0, and new kernel-log-loss=0. It has zero new
containment records. Both full snapshots contain the same 64 records from the
earlier smoke: the source budget is `ATOMIC_INIT(64)`, and the smoke consumed
all 64 without a subsequent module reload. This explains the absence but does
not satisfy the explicit requirement that churn containment telemetry occur.

The concise report, all five timings, exact command, module identities, gate
counts, cleanup proof, warning classification, and dmesg hashes are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_churn5_20260715_140851/churn_validation_report.md`
(SHA-256
`3a90498d403582b832b97300a074cb39258bc3e48b1a970441d22b4eef92bbe3`).
The stability exercise passed, but the overall validation is qualified rather
than unconditional. Under the stated if-and-only-if rule, do not recommend the
small multi-workload smoke batch. No retry, reload, patch, measurement, matrix,
or additional VM is authorized.

## 2026-07-15 manager disposition of the bounded churn

The zero churn-local containment count is accepted as an exhausted-telemetry
condition, not a failed mapping or stability condition. Patch 0025 uses a
static module-lifetime `ATOMIC_INIT(64)` budget; the immediately preceding
isolated smoke consumed all 64 records while proving that every sampled normal
2M request was capped to 4K. The same loaded module identities remained active
through the five-launch churn, which then passed 5/5 with zero private level-2
event, promotion, stop marker, log loss, or cleanup residue.

Do not reload or modify KVM merely to reset this diagnostic counter. Taken
together, the isolated containment proof and bounded churn satisfy the current
decision boundary. After a fresh ready gate and separate owner approval, the
next VM action may be one small, smoke-only batch of diverse workloads. It must
use new evidence directories, one cold launch per workload, per-launch gates,
and stop without retry on the first failed gate, workload failure, private
level-2 event, stop marker, or kernel-log-loss notice. Measurements and the full
Fig. 11 matrix remain unauthorized.

## 2026-07-15 patch-0025 diverse smokes: passed 3/3

The approved fail-fast diverse batch ran once at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_diverse_smokes_20260715_144250`.
It completed one cold launch each for `fn_py_dna_visualisation`,
`fn_py_video_processing`, and `chain_js_alexa/fn_js_alexa_interact`, without a
retry or subsequent VM.

All three containers exited 0 and produced one complete analyzer record. The
18 child-runner gates and two wrapper gates were ready, cleanup left zero
run-token CRI objects and no Kata/QEMU process, and every per-workload and
aggregate kernel check was clean. Counts are private level-2 SEPT/TDP=0,
private 2M promotion=0, canonical stop-marker=0, and new kernel-log-loss=0.
The loaded patch-0023/0025 module identities remained unchanged.

The full validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_diverse_smokes_20260715_144250/diverse_smokes_validation_report.md`
(SHA-256
`52827092f310be1b1ce47343afee7b1d76495a1666838888411ff9c9512fc902`).

True-4K smoke coverage now includes four of twelve workloads: face, DNA,
video, and Alexa interaction. After a fresh ready gate and separate owner
approval, complete smoke coverage in two fail-fast groups: the five remaining
non-chain workloads, then the three remaining Alexa chain workloads. Use one
cold launch per workload with independent kernel deltas and no retry. Measured
batches, the full matrix, and graph generation remain unauthorized until all
twelve workloads have clean smoke evidence.

## 2026-07-15 patch-0025 remaining non-chain smokes: passed 5/5

After a fresh full safety gate, five parameter-helper checks, MinIO readiness,
and the required uploader file-helper check on port 8080 all passed, the owner
ran exactly once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_nonchain_smokes.sh
```

The fail-fast one-shot harness completed at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_nonchain_smokes_20260715_181858`
with `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`; it was not
retried. One cold CRI launch each of `fn_py_compression`,
`fn_py_image_processing`, `fn_py_sentiment`, `fn_js_thumbnailer`, and
`fn_js_uploader` reached `CONTAINER_EXITED` with exit code 0. All five valid
timing records contain every required marker.

The loaded configuration was unchanged: kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`. The two wrapper
gates plus six child gates per workload produced 32 ready results; the final
gate found no `/dev/kvm` owner, Kata/QEMU process, stale Kata CRI record, or
run-token residue. Across the aggregate and all five individual deltas, private
level-2 SEPT/TDP=0, private 2M promotion=0, canonical KVM/TDX stop marker=0,
and new kernel-log loss=0.

There are zero new forced-4K messages in this batch because patch 0025's
module-lifetime 64-entry budget was consumed by the earlier conclusive face
smoke under these same loaded modules. This is expected and is not a new
containment failure; do not reload solely to replenish telemetry. The detailed
report, timing values, command, cleanup proof, and aggregate/per-child dmesg
SHA-256 values are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_nonchain_smokes_20260715_181858/nonchain_smokes_validation_report.md`
(report SHA-256
`f950c6708590c83151bd93a79e41b2aea7e1b53f58e6a562caadf0851f7b3b20`).

True-4K smoke coverage is now 9/12: face, DNA, video, Alexa interact, and all
five non-chain workloads above. After a new ready gate and separate owner
approval, the only appropriate next VM action is one fail-fast smoke each of
`chain_js_alexa/fn_js_alexa_frontend`,
`chain_js_alexa/fn_js_alexa_smarthome`, and
`chain_js_alexa/fn_js_alexa_tv`. Do not run measurements, graph generation, or
the full Fig. 11 matrix.

## 2026-07-15 patch-0025 remaining Alexa smokes: passed 3/3

The first fresh Alexa preflight stopped before any VM because the device helper
was absent from port 9090. The scoped documented `scenv_device` helper was then
started with `DEVICE_NAME=tv`; its listener and HTTP 200 response were verified.
A second full gate, all three parameter checks, and the port-9090 check passed
before the owner ran exactly once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_alexa_smokes.sh
```

The fail-fast harness completed at
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_alexa_smokes_20260715_191148`
with `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`; it was not
retried. One cold CRI launch each of Alexa frontend, smarthome, and TV reached
`CONTAINER_EXITED` with exit code 0 and all required timing markers.

The loaded configuration was unchanged: kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`. The two wrapper
gates plus six child gates per workload produced 20 ready results; final CRI
and process checks found no run-token object, Kata/QEMU process, or `/dev/kvm`
owner. Across the aggregate and all three individual deltas, private level-2
SEPT/TDP=0, private 2M promotion=0, canonical KVM/TDX stop marker=0, and new
kernel-log loss=0.

New forced-4K messages remain zero because patch 0025's 64-entry
module-lifetime budget was already consumed by the conclusive face smoke under
these unchanged modules. Do not reload KVM merely to replenish telemetry. The
full timing table, command, helper proof, cleanup proof, and dmesg SHA-256
values are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_alexa_smokes_20260715_191148/alexa_smokes_validation_report.md`
(report SHA-256
`83ae5d3bbd8ed2ed1e45527841a7d9206c0a2b7f6c90ad343de41dcc3f7b520f`).

True-4K cold-smoke coverage is now **12/12**. This demonstrates full functional
smoke coverage and stable host behavior; it does not authorize measurements,
the full Fig. 11 matrix, graph generation, a patch, or a KVM reload. Any next
VM action requires a new owner decision after reviewing all smoke reports and
host capacity.

## 2026-07-16 patch-0025 video measurement pilot: passed 5/5

The owner approved a video-only Fig. 11 measurement pilot after a fresh full
gate, video parameter-helper, and MinIO readiness check. The dedicated harness
ran exactly once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_video_measurement_pilot.sh
```

The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_video_measurement_pilot_20260716_041102`.
It preserved one explicitly excluded warm-up and exactly five measured cold
samples in the standard later-aggregation path
`log/fn_py_video_processing/`. The harness returned `run_rc=0`,
`postflight_gate_rc=0`, and `evidence_rc=0`; no retry, graph rendering, or
other workload ran.

The modules remained kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`. All five measured
containers exited 0 with valid timing records. Their mean `t_e2e` was
`46.070450925827025` seconds. Twenty-eight gates were ready; all six
per-launch deltas (warm-up plus five samples) and the aggregate delta have
private level-2 SEPT/TDP=0, private 2M promotion=0, canonical KVM/TDX stop
marker=0, and new kernel-log loss=0. Final CRI/process evidence has no
run-token residue, Kata/QEMU process, or `/dev/kvm` user.

The new forced-4K count is zero as expected because patch 0025's 64-entry
module-lifetime budget remains exhausted by the earlier conclusive face smoke
under these unchanged modules. Do not reload solely to replenish telemetry.
The full timing table, helper/capacity proof, exact command, per-launch dmesg
hashes, and aggregation-layout proof are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_video_measurement_pilot_20260716_041102/video_measurement_pilot_validation_report.md`
(report SHA-256
`d4748d8a044464251b35059a3c4c576224cd99e2e651907339ff8cdf976cd21b`).

Video's required five measured cold samples are complete. Do not render graphs
or start another workload in this mission. The next measured workload, only
after separate owner approval and a fresh preflight, should be DNA visualization
with one untimed warm-up and its required ten measured cold samples.

## 2026-07-16 patch-0025 DNA final measurement: passed 10/10

After a fresh ready full gate plus DNA parameter-helper and MinIO checks, the
owner ran once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_dna_measurement.sh
```

The dedicated harness SHA-256 is
`c6c8d57e8063795de454385cd1d487d643ecf17d9b8c8e029e53e92bca8287d0`.
The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_dna_measurement_20260716_044856`.
It retained one explicitly excluded cold warm-up in `warmup-log/` and exactly
ten measured cold samples in the standard aggregation path
`log/fn_py_dna_visualisation/sample-001` through `sample-010`. The harness
returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`; it was not
retried, resumed, or followed by a graph or another workload.

The loaded configuration remained kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`; `/Serverless`
had `549238976512` bytes free (42% used) at preflight. All ten measured
containers exited 0 and all required analyzer/timing evidence exists. Measured
mean values were `t_boot_cntr=14.953594517707824`,
`t_boot_func=0.7740473985671997`, `t_exec=9.021167850494384`, and
`t_e2e=24.74880976676941` seconds.

All 48 expected safety-gate results were ready. The warm-up plus each of ten
measured launches produced 11 individual deltas (209 total lines), and
their concatenation matched the aggregate delta. Every individual and aggregate
count is zero for private level-2 SEPT/TDP lifecycle evidence, private 2M
promotion, canonical KVM/TDX stop marker, and new kernel-log loss. Final
run-token CRI/pod/container, Kata/QEMU process, and `/dev/kvm` owner checks
were empty. New forced-4K messages are zero as expected because patch 0025's
64-entry module-lifetime budget was spent by the earlier conclusive face smoke;
do not reload KVM to reset it.

The complete timing table, exact helper and cleanup proof, and all dmesg hashes
are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_dna_measurement_20260716_044856/dna_measurement_validation_report.md`
(SHA-256 `d7e2bc5ef0832fcaead7df815fe2e677fc970f4c3763556179a72b2332e9df49`).

Final measured data is complete for **2/12 workloads: video and DNA**. Do not
launch another VM, render graphs, or modify KVM in this mission. The next
separately approved measurement boundary should be one remaining 20-sample
workload only; `fn_py_compression` is the recommended next canonical Fig. 11
candidate.

## 2026-07-16 patch-0025 compression final measurement: passed 20/20

After a fresh ready full gate plus compression parameter-helper and MinIO
checks, the owner ran exactly once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_compression_measurement.sh
```

The harness SHA-256 is
`49a2e0fa9dc72c9e9d42966bab8c2de993943b96b1a4aa7ac08dd5e1a0376341`.
The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_compression_measurement_20260716_051922`.
It preserved one explicitly excluded cold warm-up and exactly twenty measured
cold samples in `log/fn_py_compression/sample-001` through `sample-020`.
The harness returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`;
it was not retried, resumed, or followed by a graph or another workload.

The loaded configuration remained kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`; `/Serverless`
had `490921000960` bytes free (48% used) at preflight. All twenty measured
containers exited 0 with valid analyzer/timing records. Measured mean values
were `t_boot_cntr=15.065111267566682`,
`t_boot_func=0.5306184649467468`, `t_exec=0.6760802507400513`, and
`t_e2e=16.27180998325348` seconds.

All 88 expected safety-gate results were ready. The warm-up plus each of 20
measured launches produced 21 individual deltas (399 total lines), and their
concatenation SHA-256 exactly matches the aggregate delta. Every individual
and aggregate count is zero for private level-2 SEPT/TDP lifecycle evidence,
private 2M promotion, canonical KVM/TDX stop marker, and new kernel-log loss.
Final run-token CRI/pod/container, Kata/QEMU process, and `/dev/kvm` owner
checks were empty. New forced-4K messages are zero as expected because patch
0025's 64-entry module-lifetime budget was spent by the earlier conclusive face
smoke; do not reload KVM to reset it.

The complete timing table, exact command, helper/capacity and cleanup proof,
and all dmesg hashes are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_compression_measurement_20260716_051922/compression_measurement_validation_report.md`
(SHA-256 `d24d59a4fa6821ecbd24bcd68eefcb87c9bd2e7c4b96b789ad591531fd3c6123`).

Final measured data is complete for **3/12 workloads: video, DNA, and
compression**. Do not launch another VM, render graphs, or modify KVM in this
mission. The next separately approved measurement boundary is
`fn_py_face_detection`, with one excluded cold warm-up and exactly 20 measured
cold samples.

## 2026-07-16 patch-0025 face final measurement: passed 20/20

After a fresh ready full gate plus face parameter-helper and MinIO checks, the
owner ran exactly once:

```bash
sudo -v && \
/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_0025_face_measurement.sh
```

The harness SHA-256 is
`b2e5bc0b4b1ba99301884136c96dc338827f9c4be564dc21590f66bc9ee4fc4e`.
The run root is
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_measurement_20260716_055921`.
It preserved one explicitly excluded cold warm-up and exactly twenty measured
cold samples in `log/fn_py_face_detection/sample-001` through `sample-020`.
The harness returned `run_rc=0`, `postflight_gate_rc=0`, and `evidence_rc=0`;
it was not retried, resumed, or followed by a graph or another workload.

The loaded configuration remained kernel `5.19.0-cofunc-tdx-5.19+`,
`kvm=C01F58A5F36A5E9E75E4B99`,
`kvm_intel=93A968602404A13EEF604A9`, `tdx=Y`, and `tdp_mmu=Y`; `/Serverless`
had `445233188864` bytes free (53% used) at preflight. All twenty measured
containers exited 0 with valid analyzer/timing records. Measured mean values
were `t_boot_cntr=14.964641952514649`,
`t_boot_func=1.8674450635910034`, `t_exec=0.5048944830894471`, and
`t_e2e=17.336981499195097` seconds.

All 88 expected safety-gate results were ready. The warm-up plus each of 20
measured launches produced 21 individual deltas (399 total lines), and their
concatenation SHA-256 exactly matches the aggregate delta. Every individual
and aggregate count is zero for private level-2 SEPT/TDP lifecycle evidence,
private 2M promotion, canonical KVM/TDX stop marker, and new kernel-log loss.
Final run-token CRI/pod/container, Kata/QEMU process, and `/dev/kvm` owner
checks were empty. New forced-4K messages are zero as expected because patch
0025's 64-entry module-lifetime budget was spent by the earlier conclusive face
smoke; do not reload KVM to reset it.

The complete timing table, exact command, helper/capacity and cleanup proof,
and all dmesg hashes are in
`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_measurement_20260716_055921/face_measurement_validation_report.md`
(SHA-256 `3b07c164070a8e1b8bcdc356988823af65702629b34fcc430b572a45e685a4e3`).

Final measured data is complete for **4/12 workloads: video, DNA, compression,
and face detection**. Do not launch another VM, render graphs, or modify KVM in
this mission. A next workload requires a separate owner-approved measurement
boundary.

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
