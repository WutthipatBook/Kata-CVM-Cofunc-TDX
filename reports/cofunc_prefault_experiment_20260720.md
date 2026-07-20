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
