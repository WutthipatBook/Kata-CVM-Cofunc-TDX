# Paper-aligned measured TDX Fig. 11 validation

## Status

Passed with a documented CoW-sampling limitation. This bundle supersedes
`measured_tdx_fig11_20260717_0003` for paper-style comparison.

## Baseline construction

- Python Native: measured `lean_fork.log` E2E.
- JavaScript Native: released artifact fork-equivalent formula, using modeled
  `native-fork-model` stage rows.
- CoFunc TDX: measured `sc_fork.log` E2E.
- Vanilla Kata TDX: validated cold-start E2E.
- Alexa: sum of four functions for every mode.
- Samples: artifact-first-N, with no outlier removal.

The released source implementing this distinction is
`cofunc-artifact/scripts/plot_fig11.py`: Python selects `lean_fork.log`; its
JavaScript branch combines CoFunc boot terms, Native `t_exec`, and modeled
Linux CoW because Linux does not support the required multithreaded fork path.

## CoW evidence

The June 2026 `cow/result` value `1782109727.091315` is timestamp-like and its
associated `exec_log` has no `latency` record. It was rejected. The model uses
the preserved Figshare-v4 `latency 2269.959229` record, or
`2269.959229 ns/page`.

Only one valid record is preserved locally, while `eval.py` intended 50
trials. This affects only the small JavaScript CoW substages: 3.4 ms for
thumbnailer, 3.8 ms for uploader, and 19.2 ms across Alexa.

## Key correction

Raw launch made Alexa Native appear slower than CoFunc:

- raw Native launch diagnostic: `0.902416 s`
- Native fork-equivalent model: `0.226567 s`
- measured CoFunc fork: `0.704844 s`

Therefore the earlier apparent CoFunc-over-Native Alexa win was a baseline
mismatch. In the paper-aligned comparison, CoFunc is `3.11x` Native latency
for Alexa. This does not change the measured Kata/CoFunc result.

## Input hashes

- Native: `8c93bea4d5187dff88d1c1e25563acf7fa9022fe84bfe435f960c64378230403`
- CoFunc: `3866111f4973b9474999e3185c0ad5184693c5a9b0d4ca96dd6326ad179b947f`
- Kata: `b814b6d72281a8fdcb5b69f81f2dbbb2f246d7c7b6763b1f47b39743853b02e2`
- Valid CoW evidence: `0db09041dd84312ba3a9c8767e268289da0d29c6e36323b2c380546d89de3885`
- Rejected timestamp-like result: `88eae0c057f12cebcb818df932b889a673fc2a93627911e7fe7ce9e090776d98`
