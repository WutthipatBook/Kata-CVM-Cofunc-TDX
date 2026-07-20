# Measured TDX Fig. 11 comparison

| Application | Native s | CoFunc TDX s | Vanilla Kata TDX s | Kata / CoFunc | CoFunc / Native overhead |
| --- | ---: | ---: | ---: | ---: | ---: |
| `fn_py_face_detection` | 0.522 | 1.564 | 17.380 | 11.11x | +199.9% |
| `fn_py_image_processing` | 3.565 | 10.236 | 19.705 | 1.93x | +187.1% |
| `fn_py_sentiment` | 0.059 | 0.183 | 15.775 | 86.14x | +212.5% |
| `fn_py_video_processing` | 21.845 | 63.470 | 46.210 | 0.73x | +190.5% |
| `fn_py_compression` | 0.615 | 2.260 | 16.420 | 7.27x | +267.3% |
| `fn_py_dna_visualisation` | 8.711 | 18.640 | 24.810 | 1.33x | +114.0% |
| `fn_js_uploader` | 0.376 | 0.541 | 15.771 | 29.16x | +44.0% |
| `fn_js_thumbnailer` | 0.444 | 0.494 | 16.139 | 32.66x | +11.2% |
| `chain_js_alexa` | 0.902 | 0.705 | 62.412 | 88.55x | -21.9% |

Kata/CoFunc speedup range: 0.73x to 88.55x.
Kata/CoFunc geometric mean: 10.10x.
Mean CoFunc/native overhead: +133.9%.

Alexa is the sum of its four chained functions for every mode.
