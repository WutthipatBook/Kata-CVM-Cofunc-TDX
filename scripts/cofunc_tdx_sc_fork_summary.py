#!/usr/bin/env python3
import argparse
import json
import statistics
from pathlib import Path


APPS = {
    "fn_py_bfs": ["fn_py_bfs"],
    "fn_py_chameleon": ["fn_py_chameleon"],
    "fn_py_compression": ["fn_py_compression"],
    "fn_py_duplicator": ["fn_py_duplicator"],
    "fn_py_face_detection": ["fn_py_face_detection"],
    "fn_py_float": ["fn_py_float"],
    "fn_py_gzip": ["fn_py_gzip"],
    "fn_py_image_processing": ["fn_py_image_processing"],
    "fn_py_json": ["fn_py_json"],
    "fn_py_linpack": ["fn_py_linpack"],
    "fn_py_matmul": ["fn_py_matmul"],
    "fn_py_mst": ["fn_py_mst"],
    "fn_py_pagerank": ["fn_py_pagerank"],
    "fn_py_pyaes": ["fn_py_pyaes"],
    "fn_py_sentiment": ["fn_py_sentiment"],
    "fn_py_thumbnailer": ["fn_py_thumbnailer"],
    "fn_py_uploader": ["fn_py_uploader"],
    "fn_py_video_processing": ["fn_py_video_processing"],
    "fn_py_dna_visualisation": ["fn_py_dna_visualisation"],
    "fn_js_auth": ["fn_js_auth"],
    "fn_js_dynamic_html": ["fn_js_dynamic_html"],
    "fn_js_encrypt": ["fn_js_encrypt"],
    "fn_js_thumbnailer": ["fn_js_thumbnailer"],
    "fn_js_uploader": ["fn_js_uploader"],
    "chain_js_alexa": [
        "chain_js_alexa/fn_js_alexa_frontend",
        "chain_js_alexa/fn_js_alexa_interact",
        "chain_js_alexa/fn_js_alexa_smarthome",
        "chain_js_alexa/fn_js_alexa_tv",
    ],
    "chain_py_map_reduce": [
        "chain_py_map_reduce/fn_py_mapper",
        "chain_py_map_reduce/fn_py_reducer",
    ],
    "chain_js_data_analysis": [
        "chain_js_data_analysis/fn_js_wage_analysis_merit_percent",
        "chain_js_data_analysis/fn_js_wage_analysis_realpay",
        "chain_js_data_analysis/fn_js_wage_analysis_result",
        "chain_js_data_analysis/fn_js_wage_analysis_total",
        "chain_js_data_analysis/fn_js_wage_fillup",
    ],
}


def load_expected(path: Path) -> dict[str, float]:
    expected = {}
    if not path:
        return expected
    for line in path.read_text().splitlines():
        cols = line.split()
        if len(cols) >= 4 and (cols[0].startswith("fn_") or cols[0].startswith("chain_")):
            expected[cols[0]] = float(cols[3])
    return expected


def mean_e2e(log_dir: Path, fn_name: str) -> float:
    path = log_dir / fn_name / "sc_fork.log"
    vals = []
    with path.open() as file:
        for line in file:
            line = line.strip()
            if line.startswith("{"):
                vals.append(json.loads(line)["t_e2e"])
    if not vals:
        raise RuntimeError(f"no t_e2e samples in {path}")
    return statistics.mean(vals)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log_dir", type=Path)
    parser.add_argument("--expected", type=Path)
    args = parser.parse_args()

    expected = load_expected(args.expected) if args.expected else {}
    rows = []
    covered = set()
    for app, fns in APPS.items():
        try:
            actual = sum(mean_e2e(args.log_dir, fn) for fn in fns)
        except FileNotFoundError:
            continue
        exp = expected.get(app)
        ratio = actual / exp if exp else None
        rows.append((app, actual, exp, ratio))
        covered.update(fns)

    for path in sorted(args.log_dir.glob("**/sc_fork.log")):
        fn = str(path.parent.relative_to(args.log_dir))
        if fn in covered:
            continue
        actual = mean_e2e(args.log_dir, fn)
        exp = expected.get(fn)
        ratio = actual / exp if exp else None
        rows.append((fn, actual, exp, ratio))

    print(f"{'Function':<24}\t{'TDX_CoFunc_fork(s)':>18}\t{'Artifact_C(s)':>13}\t{'actual/expected':>15}")
    for app, actual, exp, ratio in rows:
        exp_s = f"{exp:.3f}" if exp is not None else "-"
        ratio_s = f"{ratio:.3f}" if ratio is not None else "-"
        print(f"{app:<24}\t{actual:18.3f}\t{exp_s:>13}\t{ratio_s:>15}")

    if rows:
        ratios = [r for _, _, _, r in rows if r is not None]
        if ratios:
            print(f"{'Avg ratio':<24}\t{'':18}\t{'':13}\t{statistics.mean(ratios):15.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
