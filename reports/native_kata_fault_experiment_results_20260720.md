# Native/Kata handler-fault experiment results

## Result summary

The DNA and Video pilots answer the original fault-frequency and
second-level-fault questions:

| Workload | Native minor faults | Kata minor faults | Native major | Kata major | Kata handler EPT violations |
| --- | ---: | ---: | ---: | ---: | ---: |
| DNA | 657,289.33 | 671,397.33 | 0 | 0 | 0 |
| Video | 4,060,330.33 | 4,056,820.67 | 0 | 2 | 0 |

First-level process-fault counts are comparable between Native and Kata. In
both workloads, every host-visible Kata EPT violation occurred before or
after handler execution; none occurred during the measured handlers.

| Workload | EPT violations per cold VM | Mean VM-lifetime EPT service | Aggregate exit-to-reentry mean |
| --- | ---: | ---: | ---: |
| DNA | 527,416 | 2.669549 s | 5,061.56 ns |
| Video | 527,416 | 2.682789 s | 5,086.67 ns |

The repeated 527,416 count is close to the number of 4 KiB pages in the 2 GiB
guest, plus fixed non-RAM mappings. This supports the inference that the
old-ABI 4K-contained Kata path establishes essentially all private guest
memory during cold-VM construction. Consequently, ordinary handler minor
faults reuse already-backed guest-physical pages and valid second-level
mappings.

## Timing interpretation

DNA averaged 8.810576 s Native and 9.140823 s Kata. The raw difference was
0.330246 s (3.75%); after subtracting workload network, it was 0.098735 s
(1.42%).

Video averaged 21.284375 s Native and 27.344127 s Kata. The raw difference
was 6.059753 s (28.47%), and workload network accounted for only 0.027881 s.
Video's extra time was mostly process CPU, despite nearly identical
first-level fault counts and zero handler EPT violations. The three-sample
Native mean is noisy because its first measured sample took 28.098 s and its
next two took about 17.9 s.

Video also recorded 550,280 block-output units per Kata sample versus zero in
Native, and roughly three times as many involuntary context switches. Its
handler repeatedly writes JPEG and AVI files under `/tmp`. These are concrete
non-EPT execution differences, but they do not by themselves establish a
single root cause.

## What is proven

1. A guest first-level page fault does not inherently produce a host EPT exit.
2. DNA and Video have comparable first-level fault counts across Native and
   Kata.
3. In these samples, Kata incurred no host-visible EPT fault service during
   handler execution.
4. Cold Kata VM construction incurred about 527,000 EPT exits and 2.67-2.68 s
   of aggregate observed exit-to-reentry service.
5. EPT violation handling cannot explain the Native/Kata handler-time
   differences observed here.

## What remains unmeasured

A valid nested translation can still cost more than Native translation due to
hardware nested page walks and TLB pressure without producing a VM exit.
Likewise, TDX memory-access overhead, non-EPT VM exits, guest filesystem work,
and CPU/codec feature differences remain possible. Measuring those requires a
different experiment, such as hardware page-walk counters, all-exit-reason
aggregation, and a Video variant with matched tmpfs/file-output behavior.

## Evidence

- DNA: `/home/booklyn/BookArchive/StageBreakdownRuns/native_kata_fault_fn_py_dna_visualisation_20260720_045726`
- Video: `/home/booklyn/BookArchive/StageBreakdownRuns/native_kata_fault_fn_py_video_processing_20260720_051306`

