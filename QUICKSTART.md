# Quick Start

Use this when starting from a clean machine/workspace. Pick a large directory
for sources, builds, installs, and results.

```bash
tar -xf cofunc-tdx-e2e-standalone-20260612.tar.gz
export BUNDLE=$PWD/cofunc-tdx-e2e-standalone-20260612
export ROOT=/mnt/nvme_500g/asdf
```

Clone original repos, checkout the expected commits, and apply patches:

```bash
"$BUNDLE/setup_cofunc_tdx_e2e.sh" prepare-sources --root "$ROOT"
```

Build kernel, QEMU, and CoFunc artifact:

```bash
"$BUNDLE/setup_cofunc_tdx_e2e.sh" all --root "$ROOT"
```

Install the kernel, then reboot:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-kernel --root "$ROOT"
sudo reboot
```

After reboot, install CPU isolation once, then reboot again:

```bash
export BUNDLE=/path/to/cofunc-tdx-e2e-standalone-20260612
export ROOT=/mnt/nvme_500g/asdf
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" install-isolation --root "$ROOT"
sudo reboot
```

After the second reboot, check the host and run a smoke test:

```bash
export BUNDLE=/path/to/cofunc-tdx-e2e-standalone-20260612
export ROOT=/mnt/nvme_500g/asdf
"$BUNDLE/setup_cofunc_tdx_e2e.sh" check-host --root "$ROOT"
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-face-smoke --root "$ROOT"
```

Run the Fig. 11 TDX E2E subset:

```bash
sudo -v
"$BUNDLE/setup_cofunc_tdx_e2e.sh" run-fig11 --root "$ROOT"
```

Results are written under:

```text
$ROOT/results/
```

Notes:

- Use a fresh `$ROOT` if possible.
- If reusing an old root, add `--reset-existing` to `prepare-sources`.
- Kernel install and CPU isolation require reboot.
- This bundle is E2E-only; it intentionally excludes Table 4 microbench WIP.
