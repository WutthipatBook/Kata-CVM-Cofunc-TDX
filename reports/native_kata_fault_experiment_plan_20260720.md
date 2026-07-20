# Native/Kata handler-fault experiment

## Question

Determine why Native lean-fork and Vanilla Kata-TDX have similar measured
handler times for the DNA and video FunctionBench workloads.

The experiment tests two specific hypotheses:

1. Native and Kata execute a similar number of first-level process page faults
   during the handler.
2. Kata's host-visible EPT/SEPT violations are mostly established before the
   handler, or their measured host service is too small to explain the handler
   time.

Native has no second-level translation layer, so a Native second-level-fault
count or latency is not defined.

## Translation semantics

- A TLB miss with valid guest and EPT/SEPT page-table entries is resolved by
  the processor's page walkers and does not cause a VM exit.
- An ordinary guest first-level page fault normally enters the guest kernel;
  it does not inherently exit to KVM.
- In this old-ABI TDX stack, a host-visible EPT violation exits the TD. The
  local KVM TDX handler emits `kvm:kvm_page_fault`, resolves the violation, and
  then re-enters the TD.

Local source evidence:

- `arch/x86/kvm/vmx/tdx.c`: `tdx_vcpu_run()` emits `kvm_entry` and `kvm_exit`.
- `arch/x86/kvm/vmx/tdx.c`: `tdx_handle_ept_violation()` emits
  `kvm_page_fault` and dispatches the EPT violation into KVM MMU handling.
- `arch/x86/kvm/trace.h`: definitions of all three tracepoints.

## Measurements

The reversible source patch records `getrusage(RUSAGE_SELF)` deltas over the
existing exact handler interval, `t_import_done` through `t_func_done`:

- minor and major faults;
- process CPU time;
- voluntary and involuntary context switches;
- block input/output operation counts;
- the workload's existing network time.

These counters are collected inside the Native process and inside the Kata
guest process using the same instrumented FunctionBench source image.

For Kata only, root bpftrace records:

- aggregate VM-lifetime counts of KVM exits whose lower 16-bit exit reason is
  EPT violation (48), `kvm:kvm_page_fault`, and paired re-entry events;
- one compact exit-to-next-entry record for each EPT violation in an
  authenticated guest-signaled handler window.

This avoids per-page text output during the 2 GiB guest's cold boot. The
analyzer reports EPT faults for both the traced VM lifetime and the exact
handler interval. It uses the preserved handler wall timestamps to remove the
signal request boundaries from the detailed records. Exit-to-next-entry time
is an observed host service interval. It includes KVM/TDX handling, BPF map
update cost, and scheduling delay, while excluding
unobserved hardware transition time before `kvm_exit` and after `kvm_entry`.
It is not an instruction-level SEAMCALL measurement.

## Controls

- One workload per approved run; DNA and video are separate boundaries.
- One excluded warm-up and three measured samples by default (maximum five).
- No retry and no automatic advance to the other workload.
- Native lean-fork's existing cgroup pins the zygote and children to CPU 0.
- The pilot opts in to pin Kata's single KVM vCPU thread to CPU 0 and records
  the QEMU PID, vCPU TID, and verified affinity for every sample.
- Existing before/between/after host safety gates remain mandatory.
- Kernel stop markers, trace loss, an unpaired EPT exit, failed affinity
  verification, or residual Kata state makes the run fail.
- Host state, load, governors, module srcversions, image identities, scripts,
  tracepoint formats, and dmesg deltas are preserved.

## Attribution limits

Host KVM tracepoints describe the VM, not a guest process. The analysis filters
events by the wall-time markers emitted around the handler. It records host
QEMU PIDs and vCPU TIDs and reports count sensitivity to moving both interval
boundaries by 1 ms and 10 ms. Safety gates exclude another Kata/QEMU VM.

Direct first-level fault service latency is intentionally not claimed. A fair
Native/Kata measurement would require calibrated probes in both the host and
guest kernels. The present experiment directly measures comparable process
fault counts and the additional host-visible EPT service imposed on Kata.

## Files

- `patches/measurement/0001-Measure-exec-faults-cpu-and-network.patch`
- `scripts/manage_fault_instrumentation.sh`
- `scripts/kata_tdx_ept_fault_trace.bt`
- `scripts/ept_trace_signal_server.py`
- `scripts/run_ept_trace_around.sh`
- `scripts/analyze_fault_comparison.py`
- `scripts/run_native_kata_fault_pilot.sh`

The instrumentation is not applied by creating these files. Apply and revert
it explicitly with `manage_fault_instrumentation.sh` after the tracepoint
preflight succeeds.

## DNA pilot result

The three-sample DNA pilot completed on 2026-07-20. Its workload and trace
were successful, but the harness initially reported `run_rc=125` because
`verify_trace_result()` referenced a same-command `local` variable under
`set -u`. That verifier is fixed. The preserved run was validated and
analyzed without launching another VM:

`/home/booklyn/BookArchive/StageBreakdownRuns/native_kata_fault_fn_py_dna_visualisation_20260720_045726`

Native and Kata averaged 657,289 and 671,397 minor faults during the handler,
respectively, with zero major faults in both. Kata recorded 527,416
host-visible EPT violations per cold VM and zero during every measured handler
window. Aggregate VM-lifetime exit-to-reentry service averaged 5,061.56 ns
per EPT violation and 2.669549 s per VM, but measured handler EPT service was
zero. See `salvage_validation_report.md` and `analysis-final/` in the run root.

Do not infer that EPT violation handling is intrinsically free: the result is
that no EPT violations occurred during these DNA handler samples. Video
remains a separate approval boundary.

## Video pilot result and experiment conclusion

The three-sample Video pilot completed successfully on 2026-07-20:

`/home/booklyn/BookArchive/StageBreakdownRuns/native_kata_fault_fn_py_video_processing_20260720_051306`

Native and Kata averaged 4,060,330 and 4,056,821 minor faults, respectively.
Kata again recorded 527,416 host-visible EPT violations per cold VM and zero
during every handler window. The mean whole-VM service sum was 2.682789 s,
or 5,086.67 ns per observed exit-to-reentry interval.

Video's Kata handler was slower than Native, but the difference was almost
entirely process CPU and did not correlate with first-level fault count or EPT
violations. See `reports/native_kata_fault_experiment_results_20260720.md` for
the combined conclusion, limitations, and evidence paths.
