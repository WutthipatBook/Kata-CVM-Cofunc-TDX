# Kata-TDX Handler Translation Investigation

Date: 2026-07-19

## Conclusion

Second-level translation participates in every guest memory access, but that does
not imply a host/KVM world switch for every guest page fault. EPT/SEPT walks and
TLB hits are hardware operations. Host intervention is needed when the
second-level mapping itself cannot complete, for example because an EPT/SEPT
entry is missing, blocked, or lacks the required permissions.

A guest virtual page fault and an EPT/SEPT violation are separate events:

1. A missing guest PTE causes a guest #PF. With direct EPT/TDP, the processor can
   inject this fault into the guest without asking KVM to emulate the guest page
   tables.
2. After the guest installs a PTE, the retried access may complete entirely in
   hardware if the selected GPA already has a usable second-level mapping.
3. If that GPA lacks a usable private EPT/SEPT mapping, the retry causes a TD
   exit and KVM must establish or repair the mapping. Later accesses can reuse
   the mapping and cached combined translation.

The defensible interpretation of the present results is therefore narrower than
"KVM intervention is uncommon": the measured Kata handler interval shows little
net penalty relative to Native for several workloads, and the bounded private
mapping telemetry available for the isolated face smoke occurred well before the
handler interval. We did not collect handler-scoped KVM exit or EPT-violation
counters, so we cannot yet claim that the handler incurred zero or few host
interventions.

Primary architectural references:

- Linux KVM MMU documentation:
  <https://docs.kernel.org/7.0/virt/kvm/x86/mmu.html>
- Intel's EPT translation and EPT-violation explanation:
  <https://www.intel.com/content/www/us/en/developer/articles/technical/increase-performance-of-vm-workloads-with-thp.html>
- Linux TDX guest-memory acceptance and TD-exit documentation:
  <https://docs.kernel.org/next/x86/tdx.html>

## Local Evidence

The isolated face smoke is preserved at:

`/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_smoke_20260715_083921`

Its timing markers were:

| Event | UTC timestamp |
| --- | --- |
| Kata launch | 08:39:26.042703900 |
| First sampled private 4K mapping | 08:39:28.036139 |
| Last of 64 sampled private 4K mappings | 08:39:28.525730 |
| Function import begins | 08:39:41.241423400 |
| Handler begins / import completes | 08:39:43.141646000 |
| Handler completes | 08:39:43.653565600 |

Thus all 64 bounded telemetry records occurred about 14.6 to 15.1 seconds before
the handler began. This supports front-loading of the observed private mapping
work into VM boot, but it is not an exhaustive trace: patch 0025 records only the
first 64 matching events over the module lifetime.

The analyzer deliberately excludes VM launch and import from `t_exec`:

`/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/testcases/tools/analyze.py:134`

It computes:

```text
t_boot_cntr = t_import_begin - t_launch_begin
t_boot_func = t_import_done - t_import_begin
t_exec      = t_func_done - t_import_done
```

Consequently, expensive private mappings during VM boot do not appear in the
handler-only comparison.

The host configuration does not preallocate all guest RAM:

`/etc/kata-containers/configuration-qemu-tdx-blockroot.toml:286`

`enable_mem_prealloc=false` and `enable_hugepages=false`. Lazy second-level
faults can therefore still occur, including during a handler whose working set
touches previously unused guest memory.

The old-ABI TDX KVM source confirms that a private EPT violation is expensive
when one occurs:

`/mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot/arch/x86/kvm/mmu/mmu.c:3694`

The private path declines KVM's fast page-fault handling because the EPT entry is
read and written using TDX SEAMCALLs. The TDX EPT-violation handler records the
standard KVM page-fault tracepoint here:

`/mnt/new_disk/cofunc_tdx_artifact/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot/arch/x86/kvm/vmx/tdx.c:2488`

## What The Current Data Does Not Prove

- It does not prove that the Kata handler generated no guest #PFs.
- It does not prove that the handler generated no EPT/SEPT violations or VM
  exits.
- It does not isolate virtualization overhead from differences in the guest and
  Native software environments.
- Similar total handler time is not evidence that individual TDX faults are
  cheap; unrelated execution costs can dominate the total.

## Conclusive Next Experiment

Run one separately approved isolated face workload and collect, only over the
`t_import_done` to `t_func_done` interval:

1. Guest minor and major page-fault deltas for the handler process.
2. Host `kvm:kvm_page_fault` events for the Kata QEMU vCPU threads.
3. Host `kvm:kvm_exit` counts and exit reasons for the same threads.
4. A second invocation in the same VM, or a controlled pre-touch variant, to
   compare cold versus already-mapped handler memory.

That experiment will distinguish guest demand paging from host-visible private
EPT/SEPT faults and quantify whether either explains the observed Kata/Native
handler similarity. No additional VM was launched for this investigation.
