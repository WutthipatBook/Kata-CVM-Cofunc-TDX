# CoFunc TDX Paper Targets

This note records TDX-related results from the CoFunc paper for later
experiment checks.

Primary source:

- Paper: "Serverless Functions Made Confidential and Efficient with Split
  Containers", USENIX Security 2025.
- Official page: https://www.usenix.org/conference/usenixsecurity25/presentation/shi-jiacheng
- PDF used for extraction:
  https://www.usenix.org/system/files/conference/usenixsecurity25/sec25cycle1-prepub-121-shi-jiacheng.pdf

Important local caveat:

- The local artifact table at
  `/mnt/nvme_500g/cofunc_tdx_artifact/cofunc-artifact/plots/fig11.txt`
  is a 3-series `K/N/C` table and the plotting script labels those series as
  SEV. Do not use that file alone as the TDX Fig. 11 target.
- Paper Fig. 11 is log-scaled and has separate Native/CoFunc/Kata bars for TDX
  and SEV. The paper text gives exact aggregate TDX claims, but not exact
  numeric per-workload TDX bar values.

## Evaluation Environment

Paper TDX testbed:

- Intel server with 4 Sapphire Rapids CPUs.
- 48 cores.
- 4 GHz.
- 503 GB DRAM.
- RHEL 8.7.
- Linux kernel 5.19.0.

TDX baselines:

- Confidential baseline: vanilla Kata-CVM on TDX.
- Native baseline: lean container, non-confidential native Linux container
  optimized for serverless.

## Fig. 11 End-To-End Latency

Scope:

- 28 functions from four serverless benchmarks.
- Fig. 11 plots 9 representative functions on a log-scale y-axis:
  face, image, sentiment, video, compress, dna, upload, thumbnail, alexa.
- The evaluated CoFunc mode for Fig. 11 is fork mode.

Exact TDX aggregate targets from the paper:

| Metric | TDX target |
| --- | ---: |
| CoFunc speedup over Kata-CVM, average | 44x |
| CoFunc speedup over Kata-CVM, range | 1.06x to 215x |
| CoFunc overhead over Native, average | 13.1% |
| CoFunc overhead over Native, range | 2.7% to 26.7% |

Approximate TDX values digitized from the log-scale Fig. 11 bars:

Method:

- Rendered the official PDF page at 3x.
- Used the PDF vector/text positions for the `10^1` and `10^-1` y-axis ticks
  to recover the logarithmic y mapping.
- Detected the first three bars in each workload group as Native TDX, CoFunc
  TDX, and Kata-CVM TDX.
- Treat these as approximate visual checks, not exact paper table values.

| Workload | Native TDX approx s | CoFunc TDX approx s | Kata-CVM TDX approx s | CoFunc/Native | Kata/CoFunc |
| --- | ---: | ---: | ---: | ---: | ---: |
| face | 0.324 | 0.346 | 2.55 | 1.07 | 7.4 |
| image | 2.23 | 2.39 | 4.06 | 1.07 | 1.7 |
| sentiment | 0.0073 | 0.0089 | 1.95 | 1.22 | 220 |
| video | 18.8 | 18.8 | 20.1 | 1.00 | 1.1 |
| compress | 0.370 | 0.422 | 2.23 | 1.14 | 5.3 |
| dna | 5.30 | 5.67 | 7.40 | 1.07 | 1.3 |
| upload | 0.0855 | 0.112 | 2.09 | 1.31 | 18.7 |
| thumbnail | 0.0913 | 0.104 | 2.23 | 1.14 | 21.4 |
| alexa | 0.0573 | 0.0655 | 7.91 | 1.14 | 121 |

Implication for our face-detection TDX run:

- Latest measured `fn_py_face_detection` TDX CoFunc fork:
  `1.152 s` mean E2E in
  `results/tdx_sc_fork_face_iso_20260610_110909`.
- Plain Docker/function-body probe on this host was about `0.328 s`.
- Digitized Fig. 11 has face TDX CoFunc at about `0.346 s`, so the latest
  local run is about `3.3x` slower than the paper's plotted TDX CoFunc bar.
- That is about `251%` over the plain function-body probe, which is far above
  the paper's TDX maximum overhead over Native (`26.7%`).
- Comparing `1.152 s` only against the local SEV artifact `C=0.617 s` hides the
  problem; the paper's TDX graph expects CoFunc TDX to be near Native TDX.

## Startup Stage 1: Containerization

Exact TDX targets:

| Metric | TDX target |
| --- | ---: |
| Kata-CVM container initialization | 1.8 s |
| CoFunc containerization latency | <15 ms |
| CoFunc speedup over Kata-CVM in startup-stage-1 | 120x |
| Shadow container initialization | 1.69 ms |
| Confidential-container setup overhead over Native | up to 10% |
| Create 16 MB confidential container | 0.71 ms |
| Create 1 GB confidential container | 10.2 ms |

## Startup Stage 2: Code Loading And Initialization

Exact TDX targets:

| Metric | TDX target |
| --- | ---: |
| CoFunc launch-mode startup-stage-2 for face detection/OpenCV | 657 ms |
| CoFunc fork-mode startup-stage-2 | <2 ms for all functions |
| Function handler code load/measurement | <0.2 ms |
| CoFunc speedup over Kata-CVM in startup-stage-2 | 148x to 499x |

Paper interpretation:

- Fork mode avoids library loading/initialization and the corresponding
  delegation, measurement, and memory-granting overhead because the Zygote is
  pre-initialized and cached inside the CVM.
- This is the mode used in Fig. 11.

Current consistency:

- Our latest face run has `t_boot_lean + t_boot_sc + t_boot_func ~= 45 ms`.
- `t_boot_func ~= 4.4 ms`, which is higher than the paper's startup-stage-2
  fork target (`<2 ms`) but not large enough to explain `1.152 s`.
- The dominant mismatch is execution-stage time.

## Table 3: Execution-Stage Overhead Breakdown

Units: percent overhead. `#Exits` is VM exits per ms.

Function abbreviations:

- F: face
- I: image
- S: sentiment
- V: video
- C: compress
- D: dna
- U: upload
- T: thumbnail
- A: alexa

TDX values only:

| Fn | Encrypt | MemGrant | Delegate | Others | #Exits |
| --- | ---: | ---: | ---: | ---: | ---: |
| F | 0.57 | 2.58 | 0.93 | 1.13 | 0.55 |
| I | 1.17 | 1.63 | 1.02 | 0.48 | 0.74 |
| S | 0.00 | 15.6 | 2.62 | -2.43 | 2.40 |
| V | 0.19 | 0.40 | 0.19 | 1.95 | 0.09 |
| C | 6.54 | 2.77 | 2.99 | 2.11 | 1.47 |
| D | 3.97 | 3.44 | 0.30 | -0.43 | 0.12 |
| U | 10.0 | 12.6 | 2.87 | -1.31 | 4.40 |
| T | 3.95 | 5.58 | 2.43 | 1.91 | 0.98 |
| A | 0.00 | 7.94 | 2.15 | 0.76 | 1.68 |

Other exact TDX execution-stage targets:

| Metric | TDX target |
| --- | ---: |
| Average encryption/decryption overhead | 2.9% |
| Upload delegation overhead before polling I/O optimization | 8.0% |
| Upload delegation overhead after polling I/O optimization | 2.9% |

Current consistency:

- Latest face run has `t_grant_exec ~= 144 ms` and `n_cow = 3395`.
- Current logs do not expose `t_pgfault`, `n_accept`, network time, or the
  Table 3 percent breakdown directly.
- The observed face overhead is much larger than Table 3's TDX face breakdown:
  `Encrypt 0.57% + MemGrant 2.58% + Delegate 0.93% + Others 1.13%`.

## Memory Granting Optimization

Exact TDX targets:

| Metric | TDX target |
| --- | ---: |
| Single 2 MB granting | 370 us |
| Single 4 KB granting | 15.7 us |
| Persistent huge pages reduce 2 MB granting latency by | 280 us |
| Huge-page granting E2E latency reduction, average | 42.2% |

Paper interpretation:

- 2 MB granting amortizes page allocation, page accept, page ownership, and VM
  exit costs.
- TDX memory granting is slower than SEV because TDX memory accept and page
  ownership operations are slower.

Current consistency:

- Build flags show `CHCORE_SPLIT_CONTAINER_HPAGE=ON`.
- Latest face run still reports `n_cow = 3395` and `t_grant_exec ~= 144 ms`.
- Existing logs do not expose `n_accept` or whether the accepts were 2 MB or
  4 KB granularity during execution. Add instrumentation before claiming this
  optimization is fully effective.

## Local Run Notes

### 2026-06-10 Fig. 11 TDX Subset Attempt

Result directory:

`/home/ljhhasang/perf_proto/results/tdx_fig11_pdf_compare_20260610_115842`

Observed behavior:

- Host readiness was correct: TDX enabled, performance governor active,
  `isolcpus/nohz_full/rcu_nocbs/irqaffinity` present, and workload actions
  pinned to CPUs `16-31`.
- The run completed `fn_py_compression` but failed when launching the next
  workload, `fn_py_dna_visualisation`.
- Failure root cause for the early exit:
  `ioctl(KVM_CREATE_VM) failed: Device or resource busy`. This indicates the
  previous TDX VM teardown had not fully released KVM/TDX state before the next
  workload tried to create a new TDX VM.
- The failed run launched the TDX guest with `tdx_smp=32` while QEMU was pinned
  to the 16 isolated host CPUs `16-31`. This oversubscribes guest vCPUs onto the
  measurement CPU mask and is not a clean paper-comparison setup.
- `fn_py_compression` mean E2E was `1.362 s`. The digitized PDF Fig. 11 TDX
  CoFunc bar is about `0.422 s`, so this run was about `3.23x` slower than the
  paper target.
- The compression breakdown was dominated by execution time:
  `t_exec ~= 1.329 s`, while `t_boot_lean + t_boot_sc + t_boot_func` was only
  about `35 ms`. That makes VM boot logging an unlikely primary explanation for
  the E2E gap.

Fixes added to the local runner after this attempt:

- `run_tdx_sc_fork_e2e.sh` now defaults `--tdx-smp auto` to the pinned CPU
  count, so `--core-isolated` on this host uses `tdx_smp=16`.
- The runner now cools down between workloads and retries only the specific
  transient `KVM_CREATE_VM` busy failure after CVM/snapshot cleanup.
- The runner now applies a per-workload action timeout, so a failed snapshot
  path fails with logs and cleanup instead of blocking forever.
- `cofunc_tdx_paper_check.py` now warns if recorded `tdx_smp` exceeds the
  pinned taskset CPU count.

### 2026-06-10 TDX Timeout Probe

Result directory:

`/home/ljhhasang/perf_proto/results/tdx_timeout_probe_20260610_122140`

Command shape:

`run_tdx_sc_fork_e2e.sh --workloads fn_py_compression,fn_py_dna_visualisation --skip-build --prepare-performance --core-isolated --quiet-workload-output --workload-timeout 300`

Environment recorded by the runner:

- Modified TDX KVM matched the expected fingerprints:
  `kvm=0BD0A0612BCAACA2BE920F4`,
  `kvm_intel=65E9BDBE5E3D73DEA355ECB`.
- Host TDX was enabled and all CPUs were in `performance` governor.
- Boot isolation was active: `isolcpus/nohz_full/rcu_nocbs=16-31` and
  `irqaffinity=0-15`.
- The measured action was pinned to `taskset_cpus=16-31`.
- `tdx_smp=16`, matching the 16 pinned CPUs. This removed the previous
  `tdx_smp=32` oversubscription.

Observed behavior:

- `fn_py_compression` completed 20/20 samples.
- `fn_py_dna_visualisation` launched the TDX CVM successfully; the previous
  `KVM_CREATE_VM: Device or resource busy` failure did not recur.
- DNA then hung in `sc-snapshot.sh` because `snapshot done` never appeared in
  `exec_log`.
- The fresh DNA snapshot log reproduced:
  `handle_trans_fault: no vmr found for va 0x3120`, faulting IP `0x3120`,
  command `/usr/local/bin/python`.
- The new `--workload-timeout 300` guard killed the stuck action and the
  runner cleanup removed the artifact QEMU/snapshot state.

Compression result from the paper audit:

| Metric | Measured | Paper target |
| --- | ---: | ---: |
| `t_e2e` | 1.364 s | approx 0.422 s |
| `t_exec` | 1.333 s | n/a |
| `t_boot_func` | 4.16 ms | <2 ms fork-mode startup-stage-2 |
| `t_grant_exec` | 183 ms | Table 3 compress memgrant 2.77% |
| `n_cow` | 2261 | n/a |

Interpretation:

- Quiet outer logging, performance mode, core isolation, and `tdx_smp=16` did
  not close the compression gap; it remains about `3.23x` slower than the
  digitized Fig. 11 TDX CoFunc bar.
- The large compression gap is mostly execution-stage time, not VM launch or
  wrapper logging.
- DNA is a separate correctness/root-cause issue in the ChCore split-container
  snapshot path. The workload imports `squiggle==0.3.1` during prewarm and then
  faults inside `/usr/local/bin/python` at `SYS_SC_SNAPSHOT`; compression uses
  the same Python/alpine base and storage layer but does not import `squiggle`.

## Other TDX Optimizations

Exact TDX targets:

| Optimization | TDX target |
| --- | ---: |
| In-CVM tmpfs average E2E reduction | 7.2% |
| In-CVM thread synchronization average E2E reduction on 7 Node.js functions | 17.1% |

Current consistency:

- Build flags show `CHCORE_SPLIT_CONTAINER_LIBTMPFS=ON`.
- Build flags show `CHCORE_SPLIT_CONTAINER_SYNC=ON`.
- These flags suggest the optimizations are compiled in, but the current face
  workload is Python/OpenCV and does not validate Node.js synchronization.

## Reproduction Checklist

Before considering TDX Fig. 11 reproduced, collect:

1. Native/lean baseline on the same host and CPU mask.
2. TDX CoFunc fork E2E for all Fig. 11 workloads.
3. Table 3-style execution breakdown:
   `t_encrypt`, memory grant/accept, delegated I/O, other, VM exits/ms.
4. Huge-page grant proof:
   accept granularity, `n_accept`, accept time, and whether persistent huge
   pages were active during the measured window.
5. Optional ablations:
   no encryption and no memory-granting paths. The current artifact has
   `run_sc_fork_noenc` and `run_sc_fork_noenc_nomem` parameter files, and those
   params carry `_noenc` / `_noenc_nomem` as a third column. However, both task
   action scripts are symlinks to the normal `run_sc_fork/action.sh`, which only
   consumes `$1` and `$2`. The third-column ablation suffix is ignored, so these
   tasks are not valid ablation experiments as wired.

## Current Local Conclusion

As of the clean 2026-06-11 full TDX fork run in
`results/tdx_all_full_clean_20260611_0538`:

- Correctness is now good for the selected E2E set: all 36 fork workloads
  completed and the run validation/KVM error logs were clean.
- The run still does not reproduce the paper's Fig. 11 TDX CoFunc fork bars.
  Representative workloads are about `2.76x` to `15.69x` slower than the
  digitized CoFunc TDX bars.
- The residual gap is mostly in execution-stage latency, not process logging or
  VM launch. `t_boot_func` is above the paper's `<2 ms` fork-stage-2 target, but
  the larger multi-x gap is already visible in `t_exec`.
- Table 3-style evidence is incomplete because current `sc_fork.log` rows do
  not include `t_pgfault`, `n_accept`, or network time. `t_grant_exec` is
  present and maps to ChCore `sc_t_accept` in this TDX port.
