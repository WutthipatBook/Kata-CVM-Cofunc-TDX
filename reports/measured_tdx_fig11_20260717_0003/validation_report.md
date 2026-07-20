# Measured TDX Fig. 11 comparison validation

## Scope

This report compares the finalized measured datasets for:

- Native: Python fork and JavaScript launch
- CoFunc TDX: CoFunc fork
- Vanilla Kata TDX: cold-observed Kata VM launch

It is a read-only comparison. No VM was launched and no KVM, containerd, or
host setting was changed while producing it.

## Inputs

- Native stage JSON:
  `/home/booklyn/BookArchive/Images/stage_breakdown_native_fig11_20260704_104545.json`
  (SHA-256 `8c93bea4d5187dff88d1c1e25563acf7fa9022fe84bfe435f960c64378230403`)
- CoFunc-TDX stage JSON:
  `/home/booklyn/BookArchive/Images/stage_breakdown_oldabi_tdx_fig11_20260708_073907.json`
  (SHA-256 `3866111f4973b9474999e3185c0ad5184693c5a9b0d4ca96dd6326ad179b947f`)
- Vanilla Kata-TDX stage JSON:
  `/home/booklyn/BookArchive/Images/stage_breakdown_kata_tdx_vanilla_fig11_20260716_185434.json`
  (SHA-256 `b814b6d72281a8fdcb5b69f81f2dbbb2f246d7c7b6763b1f47b39743853b02e2`)

All three inputs contain the same 12 function paths and artifact sample
counts. Alexa is summed from its four chain functions, yielding the paper's
nine application bars. Every selected mode's included stage total matches its
recorded E2E mean within 1 microsecond. No outlier was removed.

## Results

| Application | Native s | CoFunc TDX s | Vanilla Kata TDX s | Kata / CoFunc |
| --- | ---: | ---: | ---: | ---: |
| face detection | 0.522 | 1.564 | 17.380 | 11.11x |
| image processing | 3.565 | 10.236 | 19.705 | 1.93x |
| sentiment | 0.059 | 0.183 | 15.775 | 86.14x |
| video processing | 21.845 | 63.470 | 46.210 | 0.73x |
| compression | 0.615 | 2.260 | 16.420 | 7.27x |
| DNA visualisation | 8.711 | 18.640 | 24.810 | 1.33x |
| JavaScript uploader | 0.376 | 0.541 | 15.771 | 29.16x |
| JavaScript thumbnailer | 0.444 | 0.494 | 16.139 | 32.66x |
| Alexa chain | 0.902 | 0.705 | 62.412 | 88.55x |

CoFunc is faster than Vanilla Kata in 8/9 applications. The Kata/CoFunc
geometric-mean latency ratio is 10.10x, with a range of 0.73x to 88.55x.
Mean CoFunc/native overhead across the nine application ratios is +133.9%; the
Alexa chain is the sole application where CoFunc is faster than this measured
native baseline.

Video is a real exception in these measured inputs, not an aggregation error.
The raw CoFunc video log has five records, mean E2E 63.470 seconds, and mean
handler execution 63.435 seconds. Vanilla Kata video has mean E2E 46.210
seconds and mean handler execution 29.003 seconds. Therefore the reversal is
workload execution behavior rather than CoFunc startup cost.

## Interpretation boundary

This graph presents measured reproduction results, not the paper's expected
bars. The selected CoFunc run's own summary reports a mean 3.875x
actual/artifact-target ratio, so the graph must not be described as a direct
reproduction of the paper's absolute latency values.

The differing memory policies are intentional and match the optimization
scope under investigation: the validated CoFunc run uses its old-ABI 2 MiB
optimization path, while Vanilla Kata uses the patch-0023 4 KiB containment
path with patch-0025 telemetry. Forcing both modes onto the same private-page
mapping policy would answer a different question.

## Outputs

- PNG graph: `measured_tdx_fig11.png`, SHA-256
  `6749a81785ce5e1c51c2c48074dc8aef8c4f6adb644bee660ee83ba970e4ace3`
- PDF graph: `measured_tdx_fig11.pdf`, SHA-256
  `aea21985ed8116e75641d07bb1b1e24ab1fb9a82e178eaa754abf494dfdb55e5`
- CSV: `measured_tdx_fig11.csv`, SHA-256
  `df8cfda4a53999e640175e63f47e0d78357120f3c1f6e81f682d29a59e2de237`
- JSON with input provenance: `measured_tdx_fig11.json`, SHA-256
  `21fd28ed4247ee06082344c0290a347314e7a18533015e07e1e4c5d64cc92e34`
- Markdown table: `measured_tdx_fig11.md`, SHA-256
  `8ba3b43a1b6b76d895c31731172fcc5935142ebfd97f6c7c77bc691ed361baed`

The renderer is
`/home/booklyn/cofunc-tdx/scripts/plot_measured_tdx_fig11_comparison.py`
(SHA-256 `e61409aeebb87f0784e918aebf65b865f3fa9f6f476a420c966e8d6672f59206`).
The PNG was inspected at original resolution and has no clipping, overlap, or
illegible labels.
