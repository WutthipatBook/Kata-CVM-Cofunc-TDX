# Kata versus Native handler-time similarity

Date: 2026-07-20

## Bottom line

The measured stage called `handler_execution` is not a pure CPU-handler
measurement. It is a post-import invocation envelope. It includes function-code
evaluation, parameter-service requests, the handler itself, workload storage
traffic, and result submission. For Native Python it also includes real Linux
fork copy-on-write faults. These costs can mask or offset TDX second-level
translation overhead.

The preserved measurements also do not show universal equality. Kata ranges
from 15% faster to 43% slower than Native, depending on workload. Face, image,
and DNA are close in ratio, while compression, video, and the JavaScript
workloads show measurable Kata overhead.

The current evidence supports this explanation:

1. Normal TD instructions and successful nested translations execute in
   hardware.
2. Much of the observed private-mapping work was established during VM boot,
   before the measured invocation interval.
3. The invocation interval contains substantial application, service, and I/O
   work that is common to both baselines.
4. Native fork is not a zero-fault control: writes in the forked child trigger
   ordinary Linux CoW faults.
5. Native and Kata were measured on different days without CPU pinning or a
   recorded fixed-frequency/load protocol.

This is evidence for plausible masking and amortization, not proof that the Kata
handler had few EPT/SEPT violations. No handler-scoped KVM-exit counters were
collected.

## What `t_exec` actually includes

The Python template records `t_import_done`, then performs all of the following
inside `t_exec`:

```text
exec(function source)
HTTP get_param
handler(param)
HTTP set_retval
```

Source:

`/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/template.py:72`

The analyzer computes the complete interval without subtracting network time:

```text
t_exec = t_func_done - t_import_done
```

The former `t_network` subtraction is commented out:

`/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/analyze.py:72`

Several workloads explicitly measure their own network/storage time in a
`t_network` variable, but the template does not print it. For example, face
detection downloads the image and classifier from MinIO and uploads the result:

`/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/testcases/fn_py_face_detection/execute.py:53`

The preserved local inputs demonstrate nontrivial I/O:

| Workload | Input evidence |
| --- | ---: |
| face | 286,525-byte image plus 930,127-byte classifier |
| image | 2,853,364-byte image |
| DNA | 4,198,728-byte FASTA file |
| video | 10,498,677-byte video |

The Kata image is derived from the same workload image, but rewrites localhost
service addresses to the CNI gateway `172.16.0.1`:

`/home/booklyn/cofunc-tdx/scripts/run_kata_tdx_cri_workload.sh:316`

Native uses the host network namespace and localhost; Kata traverses its CNI
bridge. Therefore the measured interval also compares two networking paths, not
only CPU and memory translation.

## Native fork also incurs page faults

The Native Python path starts from a prewarmed interpreter and calls
`fork_lean_container()`:

`/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/template.py:63`

The binding reaches `setup_lean_container_w_double_fork()`, whose implementation
uses normal Linux `fork()`:

`/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/lean_container/lean_container.c:460`

Consequently, Native writes after the fork incur ordinary Linux CoW page faults
inside its measured `t_exec`.

Native minor-fault counters were not captured. As a bounded proxy, the matching
CoFunc runs report how many 4K pages the same function dirtied after its fork.
Multiplying those counts by the artifact's measured Linux CoW coefficient of
2,269.959229 ns/page gives:

| Workload | CoFunc `n_cow` proxy | Modeled Native CoW |
| --- | ---: | ---: |
| face | 3,371 | 7.65 ms |
| image | 3,453 | 7.84 ms |
| sentiment | 1,908 | 4.33 ms |
| video | 3,400 | 7.72 ms |
| compression | 2,252 | 5.11 ms |
| DNA | 2,726 | 6.19 ms |

This proxy is not a direct Native fault count. It is nevertheless sufficient to
show that Native fork execution is not an overhead-free denominator. The effect
is proportionally important for short handlers such as sentiment: its Native
mean is 44.52 ms, so the 4.33 ms proxy is almost 10% of the measured interval.

For JavaScript the current Native fork-equivalent model uses launch-mode
`t_exec` and adds a separate modeled CoW stage. The handler-only comparison
excludes that modeled CoW, so the Python and JavaScript Native handler columns
do not have identical semantics.

## The results are close only for some workloads

| Workload | Native mean | Kata mean | Kata / Native | Native SD | Kata SD |
| --- | ---: | ---: | ---: | ---: | ---: |
| face | 0.5024 s | 0.5054 s | 1.006x | 0.0045 s | 0.0043 s |
| image | 3.5494 s | 3.5176 s | 0.991x | 0.0122 s | 0.2506 s |
| sentiment | 0.0445 s | 0.0378 s | 0.850x | 0.0011 s | 0.0005 s |
| video | 21.8309 s | 29.0029 s | 1.329x | 5.3058 s | 0.5975 s |
| compression | 0.6018 s | 0.6763 s | 1.124x | 0.0562 s | 0.0060 s |
| DNA | 8.6957 s | 9.0078 s | 1.036x | 0.0432 s | 0.0279 s |
| uploader | 0.1225 s | 0.1754 s | 1.432x | 0.0094 s | 0.0067 s |
| thumbnailer | 0.1291 s | 0.1534 s | 1.189x | 0.0017 s | 0.0022 s |
| Alexa sum | 0.1262 s | 0.1624 s | 1.286x | n/a | n/a |

Face is practically equal. Image's 32 ms mean difference is much smaller than
Kata's 251 ms sample standard deviation. By contrast, compression, DNA, and the
JavaScript workloads consistently expose a Kata penalty. Video is 33% slower,
although its Native estimate has only five samples and high variance.

Kata being faster for sentiment and nominally faster for image is also a warning
against assigning every difference to virtualization. Scheduling, CPU
frequency, service state, and run-date differences can be comparable to the
small deltas.

## Front-loaded mapping evidence

The isolated face smoke recorded its bounded 64 private 4K-containment mapping
events at `08:39:28.036` through `08:39:28.526`. The function handler began at
`08:39:43.142`. Thus those sampled mappings occurred 14.6 to 15.1 seconds before
the measured handler interval:

`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_smoke_20260715_083921/dmesg-after.delta:10`

This proves front-loading for the sampled records only. Patch 0025's 64-record
module-lifetime budget prevents using it as an exhaustive handler fault count.

## Methodology limitations

- Native evidence was collected on 2026-07-04; final Kata evidence was collected
  on 2026-07-16.
- Native lean-fork's cgroup script pins its zygote and children to CPU 0, but
  the historical runs do not record a fixed CPU governor, effective frequency,
  NUMA placement, or host-load snapshot.
- Kata uses one vCPU with `enable_vcpus_pinning=false`, so the historical
  Native/Kata data has a CPU-placement asymmetry.
- Kata has `enable_mem_prealloc=false`, so handler-time lazy EPT/SEPT mappings
  remain possible.
- No guest minor/major-fault deltas, host `kvm:kvm_page_fault`, or
  `kvm:kvm_exit` events were recorded over the handler interval.

## Conclusive follow-up

A clean comparison should run Native and Kata back-to-back under the same host
state and record these nested substages:

1. function-source evaluation;
2. parameter-service request and response;
3. workload download;
4. pure compute;
5. workload upload;
6. result submission;
7. guest minor/major faults;
8. host KVM page-fault and exit counts, filtered to the Kata vCPU thread.

It should also pin both executions to an equivalent isolated physical CPU and
record the governor, effective frequency, NUMA node, host load, image digest,
and library versions. The already-computed `t_network` values can be exposed in
new evidence without changing handler behavior, but doing so requires new
measurements; they were not preserved in the current logs.

No VM or benchmark was launched during this investigation.
