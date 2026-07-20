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
