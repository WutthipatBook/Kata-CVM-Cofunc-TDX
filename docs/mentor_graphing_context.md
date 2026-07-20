# Mentor Graphing Context

This note is for a separate Codex/session that may need to generate graphs,
tables, or short performance summaries while the main session continues the TDX
page-size mismatch debugging.

## Working Directory

- Main local helper repo: `/home/booklyn/cofunc-tdx`
- Mounted artifact tree: `/mnt/new_disk/cofunc_tdx_artifact`
- Current mount state checked on 2026-07-02:
  `/mnt/new_disk` is `/dev/nvme1n1p2` mounted `ext4 ro,nosuid,nodev,relatime`.
- Prefer read-only analysis of `/mnt/new_disk`. Write new reports under
  `/home/booklyn/cofunc-tdx/reports/`.
- Do not use `/mnt/nvme_500g`; it is an old/forbidden workspace reference from
  earlier debugging.

## Existing Graphing Script

Use:

```bash
cd /home/booklyn/cofunc-tdx
scripts/plot_e2e_absolute_modes.py \
  --cofunc-summary <path-to-tdx_sc_fork_summary.txt> \
  --expected <path-to-fig11_expected.txt-or-fig11.txt> \
  --out-dir <report-output-dir> \
  --run-name '<human readable run name>'
```

Script path:

- `/home/booklyn/cofunc-tdx/scripts/plot_e2e_absolute_modes.py`

Outputs:

- `absolute_e2e_modes.csv`
- `absolute_e2e_modes.png`
- `absolute_e2e_modes.pdf`
- `absolute_e2e_deltas.png`
- `absolute_e2e_deltas.pdf`
- `summary.txt`

The script uses `matplotlib` with the non-GUI `Agg` backend. No browser or
display server is needed.

## Mode Mapping

The mentor asked for `cofunc/cofunc_huge/native/cold` in one graph. These are
the mappings used in this session:

- `cofunc`: measured `TDX_CoFunc_fork(s)` from a selected
  `tdx_sc_fork_summary.txt`.
- `cofunc_huge`: artifact/paper CoFunc target, column `C` in Fig. 11 data.
- `native`: artifact/paper Native target, column `N` in Fig. 11 data.
- `cold`: artifact/paper Kata-CVM/cold target, column `K` in Fig. 11 data.

Important caveat: `cofunc_huge` is a report label, not a name used in the
artifact repo. The artifact calls that value just `C: CoFunc`. We used
`cofunc_huge` to distinguish the artifact/paper target from our measured slow
TDX CoFunc run while debugging hugepage/page-size behavior.

## Paper/Artifact Expected Source

Primary source:

- `/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact/plots/fig11.txt`

Provenance copy:

- `/mnt/new_disk/cofunc_tdx_artifact/provenance/figshare-v4/cofunc-artifact/plots/fig11.txt`

The file header is:

```text
K: Kata-CVM (s), N: Native (s), C: CoFunc (s), OP: Optimization, OV: Overhead
```

Example rows for the nine workloads we usually compare:

```text
fn_py_compression        K=1.210   N=0.623   C=0.685
fn_py_face_detection     K=1.899   N=0.598   C=0.617
fn_py_image_processing   K=5.412   N=4.506   C=4.537
fn_py_sentiment          K=0.686   N=0.010   C=0.014
fn_py_video_processing   K=30.233  N=28.536  C=28.930
fn_py_dna_visualisation  K=10.181  N=9.104   C=9.395
fn_js_thumbnailer        K=1.121   N=0.169   C=0.193
fn_js_uploader           K=1.016   N=0.159   C=0.221
chain_js_alexa           K=2.822   N=0.106   C=0.156
```

Many result directories also contain a copied expected table named
`fig11_expected.txt`. The helper scripts copy it from
`$ARTIFACT/plots/fig11.txt`; for example:

- `/home/booklyn/cofunc-tdx/scripts/run_oldabi_5_19_fig11.sh`
- `/home/booklyn/cofunc-tdx/scripts/run_tdx_sc_fork_e2e.sh`

## Current Generated Reports

Main report for current 5.19 old-ABI debugging run:

- Directory:
  `/home/booklyn/cofunc-tdx/reports/e2e_absolute_modes_oldabi_5_19_20260702`
- Input measured summary:
  `/mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_020731/tdx_sc_fork_summary.txt`
- Input expected table:
  `/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/fig11_expected.txt`
- Headline:
  mean measured `cofunc / cofunc_huge = 5.659x`; mean measured
  `cofunc - cofunc_huge = +7.280 s`.
- Largest `cofunc - cofunc_huge` gaps:
  `video +33.712 s`, `dna +17.044 s`, `image +8.080 s`,
  `compression +2.354 s`, `face +1.533 s`.

Command used:

```bash
cd /home/booklyn/cofunc-tdx
scripts/plot_e2e_absolute_modes.py \
  --cofunc-summary /mnt/new_disk/cofunc_tdx_artifact/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_020731/tdx_sc_fork_summary.txt \
  --expected /mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/fig11_expected.txt \
  --out-dir /home/booklyn/cofunc-tdx/reports/e2e_absolute_modes_oldabi_5_19_20260702 \
  --run-name '5.19 old-ABI measured CoFunc'
```

Secondary report for the earlier June 22 full TDX run:

- Directory:
  `/home/booklyn/cofunc-tdx/reports/e2e_absolute_modes_tdx_fig11_20260622`
- Input measured summary:
  `/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/tdx_sc_fork_summary.txt`
- Input expected table:
  `/mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/fig11_expected.txt`
- Headline:
  mean measured `cofunc / cofunc_huge = 3.072x`; mean measured
  `cofunc - cofunc_huge = +4.303 s`.
- Largest `cofunc - cofunc_huge` gaps:
  `video +23.748 s`, `dna +9.801 s`, `image +2.927 s`,
  `compression +0.689 s`, `face +0.564 s`.

Command used:

```bash
cd /home/booklyn/cofunc-tdx
scripts/plot_e2e_absolute_modes.py \
  --cofunc-summary /mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/tdx_sc_fork_summary.txt \
  --expected /mnt/new_disk/cofunc_tdx_artifact/results/tdx_fig11_20260622_053741/fig11_expected.txt \
  --out-dir /home/booklyn/cofunc-tdx/reports/e2e_absolute_modes_tdx_fig11_20260622 \
  --run-name 'June 22 measured TDX CoFunc'
```

## Finding More Result Inputs

Useful commands:

```bash
find /mnt/new_disk/cofunc_tdx_artifact/results -maxdepth 2 \
  -name tdx_sc_fork_summary.txt -o -name smoke-summary.txt | sort
```

```bash
find /mnt/new_disk/cofunc_tdx_artifact/results -maxdepth 2 \
  -name fig11_expected.txt | sort
```

For full nine-workload graphs, prefer a `tdx_sc_fork_summary.txt` that contains
all nine workloads:

- `fn_py_face_detection`
- `fn_py_image_processing`
- `fn_py_sentiment`
- `fn_py_video_processing`
- `fn_py_compression`
- `fn_py_dna_visualisation`
- `fn_js_uploader`
- `fn_js_thumbnailer`
- `chain_js_alexa`

Smoke summaries may contain only one workload and are useful for single-function
checks, but they are not enough for the mentor's four-mode Fig. 11-style graph.

## How Measured Summaries Are Produced

The measured summary tool is:

- `/home/booklyn/cofunc-tdx/scripts/cofunc_tdx_sc_fork_summary.py`

It reads `sc_fork.log` files and computes mean `t_e2e` per function. For chains,
it sums the component functions. It loads `Artifact_C(s)` from column `C` in the
expected Fig. 11 table.

If a new raw log directory is available, a summary can be regenerated with:

```bash
cd /home/booklyn/cofunc-tdx
scripts/cofunc_tdx_sc_fork_summary.py \
  <path-to-log-dir> \
  --expected <path-to-fig11_expected.txt-or-fig11.txt>
```

## Caveats For Mentor-Facing Answers

- Be explicit that `cofunc_huge` is interpreted as artifact/paper `C: CoFunc`,
  not a separately named local run.
- The artifact's JS/native values are computed by the artifact's Fig. 11 logic,
  not always by directly taking a raw `lean_launch.log` value. For JS workloads,
  the artifact script emulates native fork startup and CoW overhead.
- The generated graph intentionally uses log scale for the absolute latency
  bars, because values range from about `0.014 s` to over `60 s`.
- The delta graph is linear scale and is better for answering "where are the
  missing seconds?"
- Do not remount `/mnt/new_disk`, rebuild kernels, kill test processes, or run
  the TDX debugging scripts from this graphing-only context unless the user
  explicitly asks. Keep graphing outputs under `/home/booklyn/cofunc-tdx/reports`.

## If Asked For A Quick Verbal Summary

For the current 5.19 old-ABI full run:

```text
Measured CoFunc is 5.659x slower than the artifact CoFunc target on average
across the nine compared Fig. 11 workloads. The absolute loss is concentrated in
video (+33.712 s), dna (+17.044 s), and image (+8.080 s). Smaller workloads show
large ratios but small absolute deltas, such as sentiment (+0.244 s).
```
