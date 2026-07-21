# CoFunc private-memory pre-fault experiment

## Protected baseline

All three repositories have the annotated tag
`pre-cofunc-prefault-20260720` on branch
`checkpoint/pre-cofunc-prefault-20260720`:

- Canonical artifact: `93d81593dd348993cd99a99a6a77f52b4114b461`
- Active old-ABI artifact: `02ac7da8bd5669e7c6a1e0746648b85a306d3c86`
- Reproduction/orchestration bundle: `f46602ba982610411716853d95a7a2e98803308d`

The experiment is isolated on `experiment/cofunc-prefault` in the active
old-ABI artifact and orchestration repositories. The canonical artifact was
not modified after its checkpoint.

## Experiment semantics

Patch `patches/cofunc-artifact-oldabi/0008-Add-opt-in-private-memory-prefault.patch`
adds `CHCORE_SPLIT_CONTAINER_PREFAULT`, disabled by default in
`config.cmake` and enabled in the experiment `.config`.

When enabled, `SYS_SC_OP_INIT_MEM` converts and accepts the complete private
buddy-allocator data range in one `MapGPA` request before restoring or
launching the function process. It then marks each 2 MiB allocator chunk as
accepted, preventing the normal `split_container_get_pages()` path from
double-accepting it. The pre-fault time remains inside the existing CoFunc
initialization and end-to-end interval. One kernel line per split container
reports GPA, accepted bytes, chunk count, and cycles.

This changes only when private memory is established. It does not remove
guest first-level demand paging or CoW faults.

## Build evidence

`./chbuild build kernel` recognized
`CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON`. The new split-container source
compiled, `kernel.img` linked, and `chcore.iso` packaged successfully:

- `kernel.img` SHA-256:
  `2b4965ffb9555dd5512f91b34894af4560ee32a79896a7390bb38aabcbd18f9f`
- `chcore.iso` SHA-256:
  `2f771404b4237fd34ba2a950160843b195bf92683839daa1aa2e9241e644d1c0`
- `split_container.c.obj` SHA-256:
  `a9f260d2ff98bbb82dc16eaf4899a6789f4d79c2d258e7e57e8c489ef312dd99`
- The linked image contains `CoFunc private pre-fault:`.
- Kernel compile flags contain `-DCHCORE_SPLIT_CONTAINER_PREFAULT`.

The first unprivileged packaging attempt failed because the existing build
tree is owned by `nobody:nogroup`. Re-running the packaging target with sudo
produced the final ISO at 2026-07-20 13:47:33 UTC. No VM was launched.

## Required validation boundary

After packaging, run one isolated face-detection smoke only. Required proof:

- pre/post host-safety gates are ready;
- exactly one pre-fault marker appears with the expected private-pool size;
- `n_accept_import=0` and `n_accept_exec=0` under runtime instrumentation;
- no private 2 MiB mapping, KVM/TDX stop marker, kernel-log loss, or residue;
- no automatic retry.

Do not run churn or the Fig. 11 matrix until this boundary passes.

## Isolated face-smoke validation

The required boundary passed on 2026-07-20. Evidence is preserved at:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_face_smoke_20260720_135605`

- The preflight and postflight host-safety gates both reported
  `host_safety=ready`.
- The runner completed on its only allowed attempt: `run_rc=0`,
  `postflight_gate_rc=0`, `STOP_AFTER_SMOKE=1`, and
  `COFUNC_KVM_BUSY_RETRIES=1`.
- The workload produced one canonical pre-fault event. The same console line
  is copied into the attempt log and canonical run log:

  ```text
  CoFunc private pre-fault: gpa=0x703600000 bytes=478150656 chunks=228 cycles=5579790134
  ```

  The 512 MiB host grant loses 2 MiB to the existing reservation and 48 MiB
  to the shared pool. Buddy metadata and 2 MiB alignment consume another
  6 MiB, leaving the reported 456 MiB private allocator data range. Thus the
  228 2 MiB chunks cover the complete private buddy data pool.
- Runtime instrumentation reported `n_accept_import=0` and
  `n_accept_exec=0`. The private acceptance work therefore finished during
  split-container initialization rather than import or handler execution.
- The workload still had `n_cow=3400`, `t_pgfault_import=0.000902878 s`, and
  `t_pgfault_exec=0.039062914 s`. This confirms that the experiment removes
  deferred TDX private-page acceptance, not guest first-level demand paging
  or CoW behavior.
- All 64 bounded private TDP-MMU records had `req=1`, `goal=1`, and
  `iter_level=1`. There were zero private level-2 records and zero private
  2 MiB promotions.
- Searches found zero KVM/TDX stop markers and zero kernel-log-loss markers.
  The successful postflight gate found no unsafe runtime residue.
- Functional timing was `t_boot_sc=2.043746948 s`, `t_exec=1.486075401 s`,
  and `t_e2e=3.544019461 s`. Pre-fault cost remains included in the cold
  start as intended.

The isolated validation boundary is passed. The next bounded step is one
memory-intensive workload smoke with the same one-attempt and safety-gate
rules. Churn and full-matrix measurements remain out of scope until that
step is clean.

## Excluded mislabeled DNA attempt

The directory
`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_dna_smoke_20260720_142136`
is not DNA evidence. Although its runner and safety gates returned zero, the
lower-level runner interpreted `STOP_AFTER_SMOKE=1` as its mandatory
face-detection smoke and exited before the selected DNA workload. Its only
result is `smoke-log/fn_py_face_detection/sc_fork.log` with
`t_e2e=3.551 s`; no DNA log exists.

To make bounded non-face validation explicit, the orchestration runner now
accepts `COFUNC_OLDABI_RUNTIME_REPETITIONS`. A one-shot non-face run must use
`STOP_AFTER_SMOKE=0`, `COFUNC_OLDABI_SKIP_FACE_SMOKE=1`, a single
`COFUNC_OLDABI_RUNTIME_WORKLOADS` entry, and
`COFUNC_OLDABI_RUNTIME_REPETITIONS=1`.

## DNA pre-fault failure and containment

The corrected one-shot DNA selection ran at:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_dna_smoke_corrected_20260720_142935`

It returned `run_rc=124`; the postflight gate remained
`host_safety=ready`. This run is failed evidence and must not be aggregated.

- Selection was correct: the run-local parameter file contains only
  `fn_py_dna_visualisation 1`, the mandatory face smoke was disabled, and
  automatic retries were disabled.
- The CVM booted normally and reached the ChCore shell.
- The DNA `sc-snapshot` stage granted 2 GiB and completed pre-faulting its
  entire 1,928 MiB private buddy data range:

  ```text
  CoFunc private pre-fault: gpa=0x904800000 bytes=2069889024 chunks=987 cycles=26680295360
  ```

- Immediately after the marker, ChCore reported
  `handle_trans_fault: no vmr found for va 0x3120` for
  `CMD: /usr/local/bin/python`. No `snapshot done` marker followed.
- `sc-snapshot.sh` had no internal timeout or child-exit check, so it waited
  until the outer 1,200-second workload timeout returned 124.
- Host logs contain no KVM/TDX stop marker, log loss, OOM, or page-state
  failure. Cleanup removed the CVM and the postflight safety gate passed.
- The transient workload log is preserved at
  `/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_dna_smoke_corrected_20260720_142935/failure-evidence/dna_snapshot_exec_log`
  with SHA-256
  `c1efea8bdac09ab56adb0f5dad68e4b5bf29521bba7dddd79fe38465f8975449`.

Known-good on-demand DNA evidence completed 10/10 in
`oldabi_guarded_0022_dna_only_retry_20260708_073256`. This was initially taken
as evidence that prefault was the differentiating trigger. Later historical
and image evidence, documented below, disproved that conclusion: the same DNA
snapshot fault predates the prefault experiment and depends on workload-image
state. Patch 0009 remains a valid MapGPA-granularity A/B, and patch 0010 bounds
the snapshot wait and preserves the last 80 diagnostic lines on failure.

After rebuilding, validation must restart with one isolated face smoke under
the changed prefault implementation, followed by one DNA smoke only if face
passes. No automatic retry, churn, or matrix run is permitted.

## Chunked pre-fault rebuild and infrastructure-only face attempt

The chunked pre-fault source was rebuilt on 2026-07-21. The regenerated
artifact is:

`cvm_os/build/kernel/arch/x86_64/boot/intel_tdx/chcore.iso`

Its SHA-256 is
`4132a8be22c28f5d45dfc6eeacfd1912a4ff464f91327ce0291dc4d55d559e5d`.
The split-container object and ISO are newer than the patched source, the
linked image contains the private pre-fault marker, and temporary diagnostic
patches 0001, 0002, 0003, 0004, 0006, and 0007 all pass dry-run application.

The first post-rebuild face attempt is preserved at:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_chunked_face_smoke_20260721_051618`

It returned `run_rc=1` with `postflight_gate_rc=0` and
`host_safety=ready`, but it did not launch a VM. Host huge-page setup stopped
first when `fallocate` could not populate the 512 MiB hugetlbfs backing file.
There are no guest logs, pre-fault markers, or KVM/TDX stop markers in this
attempt, so it is infrastructure-only failed evidence and must not be used to
evaluate patch 0009.

A subsequent no-VM capacity probe successfully reserved all 256 requested
2 MiB pages and populated a 512 MiB hugetlbfs file: immediately after
reservation `nr_hugepages=256` and `free_hugepages=256`; after `fallocate`,
`free_hugepages=0`; `probe_rc=0`. Its cleanup returned all huge-page counters
to zero and removed the probe file. This proves the requested backing
configuration is currently feasible and identifies the earlier stop as
transient huge-page availability rather than disk exhaustion.

## Chunked pre-fault face control

The new isolated face control passed on its only VM launch:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_chunked_face_smoke_20260721_053155`

- `run_rc=0`, `postflight_gate_rc=0`, and `host_safety=ready`.
- The run-local source backup matches commit `f7f46b8` and contains one
  `change_phys_state()` call per allocator chunk.
- The diagnostic ISO SHA-256 is
  `68acd006850963be1495de403ce83a2ac21abe6d8c39db70fd38b436d5041b2b`.
- Exactly one marker covers the full 456 MiB private data pool:
  `bytes=478150656 chunks=228 cycles=3843024732`.
- `n_accept_import=0`, `n_accept_exec=0`, `n_cow=3400`, and
  `t_e2e=2.520723342895508 s`.
- KVM/TDX stop markers, bad-page markers, log-loss markers, and private 2 MiB
  promotion markers are all zero. The postflight gate found no residue.

The detailed validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_chunked_face_smoke_20260721_053155/validation_report.md`
with SHA-256
`9c9634f5b7c2fb9f075317a7f26bb43cc38fabeaf9885d4072968c094b2b6e87`.

The face control boundary is passed. One correctly selected DNA smoke is now
the next separately bounded step. No retry, churn, measurement collection, or
full matrix is authorized by this result.

## Chunked pre-fault DNA result and image drift

The one permitted chunked-prefault DNA attempt ran at:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_chunked_dna_smoke_20260721_054037`

It returned `run_rc=1`, while the postflight gate returned zero and reported
`host_safety=ready`. Selection was correct and no retry occurred. The new
snapshot guard detected that the snapshot screen exited, preserved its final
80 log lines, and returned immediately.

The guest completed all 987 chunked pre-fault operations over its 1,928 MiB
private data pool, then reproduced the same failure as the bulk experiment:

```text
CoFunc private pre-fault: gpa=0x784800000 bytes=2069889024 chunks=987 cycles=26701253632
[INFO] handle_trans_fault: no vmr found for va 0x3120!
Thread ... IP: 3120 CMD: /usr/local/bin/python
```

This rules out one multi-gigabyte MapGPA request as the fix. It does not prove
that prefault causes the process fault:

- The exact `/usr/local/bin/python` VA/IP `0x3120` DNA snapshot failure was
  already preserved by the June 10 timeout probe, before the prefault
  experiment existed.
- The July 8 on-demand run later completed 10/10 with diagnostic image
  `sha256:07af20737395dd5418aae159341cf77dede70c772ebfd00cbafb0592e568131c`.
- That known-good image history contains
  `pip install minio numpy==1.26.4 squiggle==0.3.1`.
- The failed July 21 diagnostic image
  `sha256:7cc17a0391eeb9d14ed17460361f790583e5774a9a49f7c806b404ede505ec3f`
  was rebuilt from the current old-ABI Dockerfile without the NumPy pin. Its
  history contains only `pip install minio squiggle==0.3.1`.

Therefore this DNA attempt combines the prefault experiment with known
workload-image drift and is not a clean prefault A/B. Patch 0011 applies only
the missing DNA NumPy pin, matching the established dependency-fix patch and
the preserved successful image. Rebuild and image verification are required
before considering one further DNA launch. The current failed run must not be
aggregated.
