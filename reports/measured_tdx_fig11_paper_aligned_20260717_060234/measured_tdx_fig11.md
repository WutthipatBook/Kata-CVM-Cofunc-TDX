# Paper-aligned measured TDX Fig. 11 comparison

| Application | Native s | CoFunc TDX s | Vanilla Kata TDX s | Kata / CoFunc | CoFunc / Native overhead |
| --- | ---: | ---: | ---: | ---: | ---: |
| `fn_py_face_detection` | 0.522 | 1.564 | 17.380 | 11.11x | +199.9% |
| `fn_py_image_processing` | 3.565 | 10.236 | 19.705 | 1.93x | +187.1% |
| `fn_py_sentiment` | 0.059 | 0.183 | 15.775 | 86.14x | +212.5% |
| `fn_py_video_processing` | 21.845 | 63.470 | 46.210 | 0.73x | +190.5% |
| `fn_py_compression` | 0.615 | 2.260 | 16.420 | 7.27x | +267.3% |
| `fn_py_dna_visualisation` | 8.711 | 18.640 | 24.810 | 1.33x | +114.0% |
| `fn_js_uploader` | 0.144 | 0.541 | 15.771 | 29.16x | +274.5% |
| `fn_js_thumbnailer` | 0.153 | 0.494 | 16.139 | 32.66x | +223.6% |
| `chain_js_alexa` | 0.227 | 0.705 | 62.412 | 88.55x | +211.1% |

Kata/CoFunc latency-ratio range: 0.73x to 88.55x.
Kata/CoFunc geometric-mean latency ratio: 10.10x.
CoFunc is faster than Kata in 8/9 applications.
Mean CoFunc/native overhead: +209.0%.

Alexa is the sum of its four chained functions for every mode.
Python Native is measured fork E2E. JavaScript Native is the released artifact's fork-equivalent model, not raw launch E2E.
