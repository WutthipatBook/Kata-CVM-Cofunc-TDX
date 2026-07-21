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
- The workload still had `n_cow=3400` and nonzero raw page-fault counters.
  The legacy analyzer rendered those raw TSC-cycle values as
  `t_pgfault_import=0.000902878` and `t_pgfault_exec=0.039062914` by dividing
  by 1e9; they are not seconds. The nonzero counters still confirm that the
  experiment removes deferred TDX private-page acceptance, not guest
  first-level demand paging or CoW behavior.
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

The runtime runner now enforces that verification before launching a DNA VM.
After rebuilding the diagnostic base and final images, it requires both a
`numpy==1.26.4` base-history record and a successful NumPy 1.26.4 import from
the final image. It preserves the history, import output, and full image
metadata in the run backup. Any mismatch stops before the lower-level VM
runner is called.

## Corrected chunked pre-fault DNA result

The corrected, pinned-image run passed on its only VM launch:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_chunked_dna_pinned_20260721_060706`

- `run_rc=0` and the postflight gate reported `host_safety=ready`.
- The rebuilt final image imported NumPy 1.26.4 before VM launch. Its image ID
  was `sha256:7f3c9eb12927c75878ab2b59f58fde51befffef5414e85f862f0ed013daf9e54`.
- One pre-fault marker covered 1,008,730,112 bytes in exactly 481 2 MiB
  chunks. The marker reported 11,797,490,862 cycles.
- The workload completed with `n_accept_import=0`, `n_accept_exec=0`, and
  `t_e2e=26.4892840385437 s`.
- The previous VA `0x3120` process fault, early snapshot exit, KVM/TDX stop
  markers, bad-page markers, log loss, and private 2 MiB promotions were all
  absent.
- Temporary runtime source restoration matched the pre-run hashes exactly.

The detailed report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_chunked_dna_pinned_20260721_060706/validation_report.md`
(SHA-256
`87bf968684b6519516b6049116dfd838bbd52de7c39ad98c974b8318499c8d27`).

This establishes that the earlier failure was not a clean pre-fault result:
after restoring the known-good dependency set, chunked private pre-faulting
completes the memory-intensive DNA workload. The single timing record is a
functional smoke and must not be aggregated as performance data. One isolated
video-processing smoke is the next bounded functional boundary.

The artifact's video-processing Dockerfile is unchanged since its initial
commit and is not modified by the established workload-dependency patch, so
there is no known video image drift equivalent to DNA. The pre-launch runner
guard nevertheless now requires successful `cv2` and `boto3` imports from the
rebuilt final video image and preserves their versions, image history, and
image metadata before calling the VM runner.

## Chunked pre-fault video result

The isolated video-processing smoke passed on its only VM launch:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_chunked_video_20260721_063648`

- `run_rc=0` and the postflight gate reported `host_safety=ready`.
- The final diagnostic image imported boto3 1.43.34 and OpenCV 4.6.0 before
  launch. Its image ID was
  `sha256:4a3d6f5d187ed18648a0ed9a805d6ed904d6e545a8e2c018330bb48cb7c215ee`.
- One marker covered 211,812,352 bytes in exactly 101 2 MiB chunks and
  reported 1,703,329,282 cycles.
- The workload completed with `n_accept_import=0`, `n_accept_exec=0`, and
  `t_e2e=52.622435331344604 s`.
- KVM/TDX stop markers, bad-page markers, log loss, private 2 MiB promotions,
  process translation faults, and early snapshot exits were all absent.
- Temporary runtime-source restoration matched the pre-run hashes exactly.

The run exposed a diagnostic ABI defect: `sc_t_pgfault` is an unsigned long
in the guest kernel and `SYS_SC_GET_STAT` returns a long, but Python ctypes
used its undeclared default signed 32-bit return type. The after-execution
value therefore wrapped from at least 2,974,394,594 to -1,320,572,702. The
reported negative `t_pgfault_exec` is invalid and this smoke must not be used
for page-fault timing or performance aggregation. Patch 0007 now declares
`libc.syscall.restype = ctypes.c_long`; a later measurement pilot must rebuild
the runtime image and verify nonnegative 64-bit counters before collecting
comparison data.

Functionally, pre-faulting is now validated by isolated face, pinned DNA, and
video smokes. The next phase is not another workload expansion: it is a
bounded fault-counter/timing pilot under corrected instrumentation for the
memory-intensive DNA and video targets.

The detailed video validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_chunked_video_20260721_063648/validation_report.md`
(SHA-256
`49c69b8e46ddd9a661c38d2ca3227ef3ccef73139f7791575cba130e592d15c5`).

The pre-launch Python workload guard now also inspects the rebuilt final image
and requires `/func/main.py` to contain the 64-bit ctypes syscall return
declaration. This makes a stale cached template a pre-VM failure rather than
another invalid timing run.

## First 64-bit counter pilot and workload-global collision

The first attempted 64-bit video counter pilot completed functionally at:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_video_64bit_counter_20260721_070038`

It returned zero and the postflight gate was ready. One marker pre-faulted
211,812,352 bytes in 101 chunks, both accept deltas were zero, and no host stop
marker occurred. However, the raw after-execution page-fault value was still
negative (`-1170137668`), so the timing validation failed.

The configured `c_long` declaration was present in the final image. The
remaining truncation came from the workload's `execute.py`, which runs in the
template's global namespace and assigns a new `libc = ctypes.CDLL(None)`.
This replaces the object before the after-execution stat reads.

Patch 0012 fixes the namespace collision by retaining a private
`_cofunc_syscall` function handle and using it for every template-owned
syscall. The orchestration runner now applies 0012 after 0007 and refuses to
launch unless the rebuilt final image proves both the private 64-bit binding
and its use for `t_pgfault_after_exec`. Sequential patch application and shell
syntax checks pass. No VM has run with patch 0012 yet.

The detailed failed-counter validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_video_64bit_counter_20260721_070038/validation_report.md`
(SHA-256
`800b567ca28f4eea4fd8c777478510db56c86b107a358d17986e9d8ddd43d967`).

## Successful private-syscall counter pilot

The corrected follow-up passed on its only VM launch:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_video_private_syscall_20260721_073012`

- `run_rc=0` and postflight `host_safety=ready`.
- Pre-launch evidence proved the final image used `_cofunc_syscall` both for
  the `c_long` return declaration and the post-execution counter read.
- One marker pre-faulted 211,812,352 bytes in 101 chunks.
- Raw page-fault values were 853,952 before and 3,096,689,328 after execution.
  Their exact nonnegative delta was 3,095,835,376 TSC cycles. The analyzer
  reported `t_pgfault_exec=3.095835376`, but that value is not seconds: the
  page-fault path accumulates `get_cycles()`/`RDTSC` deltas, whereas the
  analyzer divided by 1e9 without applying the guest TSC frequency.
- Host CPUID leaf 0x15 reports a 2.8 GHz invariant TSC, and this run used
  QEMU `-cpu host` without a TSC-frequency override. Under that inherited
  frequency the delta is approximately 1.105655491 seconds. The guest's
  PIT-calibrated `cur_freq` was not logged, so the preserved run does not
  independently establish an exact seconds conversion.
- Both accept deltas were zero. Stop markers, bad-page markers, log loss,
  private 2 MiB promotions, process translation faults, and early exits were
  absent.
- Runtime source restoration matched the pre-run hashes exactly.

This confirms patch 0012 and completes bounded functional validation of
chunked private pre-faulting for face, pinned DNA, and video. The one timing
record remains a counter-validation smoke and is not a performance sample.

Patch 0012 now provides a usable cumulative first-level page-fault cycle
counter, but exact time and count remain measurement gaps. `n_cow` is only a
subset of faults. A comparable fault-frequency experiment requires separately
bounded `sc_n_pgfault` and guest TSC-frequency telemetry before DNA/video
sampling. The analyzer patch now emits `t_pgfault_*_cycles` instead of
mislabeling raw cycles as seconds.

Detailed validation:
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_video_private_syscall_20260721_073012/validation_report.md`
(SHA-256
`2a6768126d25e7f6c2899d7ecbb9876326d75543a5d67da5716d9c17522ce61f`).

## Prepared fault-count and calibrated-time instrumentation

No further VM has been launched. The next bounded phase is implemented and
the persistent kernel portion is now applied to the active old-ABI source:

- Patch 0013 adds an atomic per-cap-group first-level page-fault count and
  makes the existing cumulative cycle update atomic.
- Patch 0006 exposes the count, raw cycles, accept count, and guest-calibrated
  `cur_freq` through `SYS_SC_GET_STAT`.
- Patch 0014 reads count and frequency around handler execution. The analyzer
  preserves `t_pgfault_*_cycles` and derives `t_pgfault_*` seconds only by
  dividing by the guest-reported frequency.
- The instrumented runner refuses to launch if the source change is absent,
  the kernel ISO predates any changed source, or the rebuilt workload image
  lacks the count/frequency markers.

The complete patch sequence was applied to a fresh source clone and both
Python files passed `py_compile`. A synthetic 2.8 GHz analyzer fixture emitted
`n_pgfault_exec=4056821`, `t_pgfault_exec_cycles=3095835376`, and
`t_pgfault_exec=1.1056554914285714`. This validates plumbing and arithmetic,
not guest behavior.

Patch 0013 was subsequently applied and committed as old-ABI source commit
`1242aa3`. The rebuilt `kernel.img` SHA-256 is
`056a5924a71b97717004c8b1fc52018a5bb45af9e29e94b5b561b8ea2762a6cb`.
The kernel-build and runtime copies of `chcore.iso` are byte-identical with
SHA-256
`9a2267022e1cd4d8c8c1ded854ef3b4c85a8c1fb55a7b8f106d411955b42e3e1`.
Both are newer than all four changed sources, and all three artifacts contain
the `n_pgfault` format marker. One isolated pre-fault video telemetry smoke is
now the next permitted runtime boundary.

## Video fault-telemetry result

The isolated Video run passed on one launch with ready pre/post safety gates:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_video_fault_telemetry_20260721_095235`

It recorded 4,080,876 first-level execution faults, 3,221,283,012 fault-path
cycles, and a guest-calibrated TSC frequency of 2,800,756,372 Hz. This gives
1.150147526 seconds in `do_page_fault`, 281.838391 ns per fault, and 1.983050%
of the 57.998925686-second handler execution interval. Of those faults, 3,431
were CoW faults (0.084075%). The pre-fault operation covered exactly 101 2 MiB
chunks and took 0.884459478 seconds. Both import and execution reported zero
deferred accepts.

The first-level fault count is close to the earlier three-sample means: it is
0.506010% above Native (4,060,330.333) and 0.592960% above Kata
(4,056,820.667). This supports the conclusion that first-level Video fault
frequency is essentially the same across the three systems. The run had zero
private 2 MiB promotions, private level-2 mappings, KVM/TDX stop markers,
kernel-log loss, or residual Kata/QEMU objects.

This is one diagnostic sample, not a performance aggregation. It does not
measure Native/Linux fault-handler service time, and it did not independently
trace host-side CoFunc SEPT/EPT service. The CoFunc timing interval surrounds
`do_page_fault`, so VM exits inside that function are included in its measured
cycles. The validation report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_video_fault_telemetry_20260721_095235/validation_report.md`
(SHA-256
`07957a510fa69a191ba7943178cec15223aecec3af112c83afc183eeeab84e8f`).
The next bounded runtime step is one isolated DNA telemetry smoke.

## DNA fault-telemetry result and combined conclusion

The isolated DNA run passed on one launch with ready pre/post safety gates:

`/mnt/new_disk/cofunc_tdx_artifact/results/cofunc_prefault_dna_fault_telemetry_20260721_101315`

It recorded 680,115 first-level execution faults and 919,355,966 fault-path
cycles at a guest-calibrated 2,800,182,785 Hz. This is 0.328319984 seconds in
`do_page_fault`, 482.741865 ns per fault, and 1.780566% of the
18.439082861-second handler interval. There were 2,728 CoW faults (0.401109%)
and zero deferred accepts. The complete 1,008,730,112-byte private pool was
pre-faulted in 481 chunks over approximately 2.901099435 seconds.

The CoFunc count is 3.472697% above the earlier Native DNA mean
(657,289.333) and 1.298436% above the Kata mean (671,397.333). The prior
Native/Kata pilot's `run_rc=125` was independently validated as a
post-collection shell error; all six samples and the EPT trace completed. The
Kata trace found zero EPT violations in the DNA handler window, just as it did
for Video. Its 527,416 violations per VM occurred during cold-VM setup.

Together, Video and DNA show similar first-level fault frequency across
Native, Kata, and pre-fault CoFunc. CoFunc `do_page_fault` time was only
1.983050% of Video execution and 1.780566% of DNA execution. Therefore,
neither first-level fault frequency nor the measured CoFunc first-level fault
path explains the large remaining CoFunc execution-time gap. Native/Linux
per-fault service and host-side CoFunc SEPT/EPT exits remain unmeasured and
require separate instrumentation.

The DNA run had zero private 2 MiB promotions, private level-2 mapping
markers, KVM/TDX stop markers, kernel-log loss, or residual Kata/QEMU objects.
Its detailed report is
`/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_dna_fault_telemetry_20260721_101315/validation_report.md`
(SHA-256
`732a9a43a3004db96f013b2b17edd6fb05123ed4a20150dacd249a9771aeb7e2`).

## Prepared host-side CoFunc EPT verification

No additional VM has been launched. A separate one-launch boundary now
directly tests the remaining pre-fault claim:

- `patches/cofunc-artifact-oldabi/0015-Signal-CoFunc-handler-EPT-trace-window.patch`
  carries a one-use authenticated URL into the split-container `/tmp` and
  signals immediately around the Python handler interval.
- `scripts/run_cofunc_prefault_ept_pilot.sh` allows exactly one Video or DNA
  workload, one sample, no warm-up, and no retry. It runs before/after safety
  gates, captures the kernel delta, and verifies exact runtime-source
  restoration.
- `scripts/analyze_cofunc_ept_trace.py` requires one QEMU PID in all four
  aggregate maps, paired EPT exit/page-fault/reentry counts, one ordered
  authenticated signal pair, and zero trace loss or unparsed output.

The authenticated gate is a strict superset of `t_import_done` through
`t_func_done`. Therefore, zero gated EPT service records prove zero handler
EPT violations for that launch. A nonzero count remains a valid experimental
result rather than being mislabeled as a workload failure.

Patch 0015 applies after patches 0004, 0007, 0012, and 0014 in a fresh fixture;
the patched Python and shell files compile or pass syntax checks. Synthetic
zero- and one-event traces produce `prefault_target_passed=true` and `false`,
respectively. The relevant SHA-256 values are:

- Patch 0015: `bd66bc9cffdab3c9bfab0f9e81eb37167dae66cc52a23db0173b9ba3c5d02869`
- Analyzer: `52c43fe1040cd9976d45b1fcb77cf838b93fc97382d813a4f53e2ab8070ae34a`
- Pilot harness: `222926e49c9ff60d02db357008d7e99837da4155a1e6e5ac0b5430dcc8ddad21`

The next permitted runtime boundary is one traced Video launch. DNA remains a
separate decision after reviewing Video and the postflight safety evidence.
