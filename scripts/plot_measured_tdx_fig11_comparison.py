#!/usr/bin/env python3
"""Plot paper-aligned Native, CoFunc-TDX, and Vanilla Kata-TDX Fig. 11 means."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
from typing import Any, Callable

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


APPS = [
    ("fn_py_face_detection", ["fn_py_face_detection"], "face\n(py)"),
    ("fn_py_image_processing", ["fn_py_image_processing"], "image\n(py)"),
    ("fn_py_sentiment", ["fn_py_sentiment"], "sentiment\n(py)"),
    ("fn_py_video_processing", ["fn_py_video_processing"], "video\n(py)"),
    ("fn_py_compression", ["fn_py_compression"], "compress\n(py)"),
    ("fn_py_dna_visualisation", ["fn_py_dna_visualisation"], "dna\n(py)"),
    ("fn_js_uploader", ["fn_js_uploader"], "upload\n(js)"),
    ("fn_js_thumbnailer", ["fn_js_thumbnailer"], "thumbnail\n(js)"),
    (
        "chain_js_alexa",
        [
            "chain_js_alexa/fn_js_alexa_frontend",
            "chain_js_alexa/fn_js_alexa_interact",
            "chain_js_alexa/fn_js_alexa_smarthome",
            "chain_js_alexa/fn_js_alexa_tv",
        ],
        "alexa\n(js)",
    ),
]

EXPECTED_SAMPLES = {
    "fn_py_video_processing": 5,
    "fn_py_dna_visualisation": 10,
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_rows(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        raise SystemExit(f"invalid or empty stage JSON: {path}")
    return rows


def expected_samples(workload: str) -> int:
    return EXPECTED_SAMPLES.get(workload, 20)


def extract_mode(
    path: Path,
    mode_for_workload: Callable[[str], str],
) -> dict[str, float]:
    rows = load_rows(path)
    workloads = {fn for _, functions, _ in APPS for fn in functions}
    values: dict[str, float] = {}
    for workload in workloads:
        mode = mode_for_workload(workload)
        selected = [
            row
            for row in rows
            if row.get("workload") == workload
            and row.get("mode") == mode
            and row.get("included_in_stage_sum")
        ]
        if not selected:
            raise SystemExit(f"missing {mode} rows for {workload} in {path}")
        e2e_values = {float(row["e2e_mean_s"]) for row in selected}
        sample_values = {int(row["samples"]) for row in selected}
        if len(e2e_values) != 1 or len(sample_values) != 1:
            raise SystemExit(f"inconsistent stage rows for {workload} in {path}")
        samples = sample_values.pop()
        if samples != expected_samples(workload):
            raise SystemExit(
                f"sample mismatch for {workload} in {path}: "
                f"expected={expected_samples(workload)} actual={samples}"
            )
        stage_total = sum(float(row["stage_mean_s"]) for row in selected)
        e2e = e2e_values.pop()
        if abs(stage_total - e2e) > 1e-6:
            raise SystemExit(f"stage total mismatch for {workload} in {path}")
        values[workload] = e2e
    return values


def geometric_mean(values: list[float]) -> float:
    return math.exp(sum(math.log(value) for value in values) / len(values))


def build_rows(
    native: dict[str, float],
    cofunc: dict[str, float],
    kata: dict[str, float],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for app, functions, label in APPS:
        native_s = sum(native[fn] for fn in functions)
        cofunc_s = sum(cofunc[fn] for fn in functions)
        kata_s = sum(kata[fn] for fn in functions)
        rows.append(
            {
                "app": app,
                "label": label,
                "functions": functions,
                "native_s": native_s,
                "cofunc_s": cofunc_s,
                "kata_s": kata_s,
                "kata_over_cofunc": kata_s / cofunc_s,
                "cofunc_over_native": cofunc_s / native_s,
                "cofunc_over_native_pct": (cofunc_s / native_s - 1.0) * 100.0,
            }
        )
    return rows


def write_csv(rows: list[dict[str, Any]], path: Path) -> None:
    fields = [
        "app",
        "native_s",
        "cofunc_s",
        "kata_s",
        "kata_over_cofunc",
        "cofunc_over_native",
        "cofunc_over_native_pct",
    ]
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    field: f"{row[field]:.9f}" if field != "app" else row[field]
                    for field in fields
                }
            )


def write_markdown(rows: list[dict[str, Any]], path: Path) -> None:
    speedups = [float(row["kata_over_cofunc"]) for row in rows]
    overheads = [float(row["cofunc_over_native_pct"]) for row in rows]
    lines = [
        "# Paper-aligned measured TDX Fig. 11 comparison",
        "",
        "| Application | Native s | CoFunc TDX s | Vanilla Kata TDX s | Kata / CoFunc | CoFunc / Native overhead |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| `{row['app']}` | {row['native_s']:.3f} | {row['cofunc_s']:.3f} | "
            f"{row['kata_s']:.3f} | {row['kata_over_cofunc']:.2f}x | "
            f"{row['cofunc_over_native_pct']:+.1f}% |"
        )
    lines.extend(
        [
            "",
            f"Kata/CoFunc latency-ratio range: {min(speedups):.2f}x to {max(speedups):.2f}x.",
            f"Kata/CoFunc geometric-mean latency ratio: {geometric_mean(speedups):.2f}x.",
            f"CoFunc is faster than Kata in {sum(value > 1.0 for value in speedups)}/{len(speedups)} applications.",
            f"Mean CoFunc/native overhead: {float(np.mean(overheads)):+.1f}%.",
            "",
            "Alexa is the sum of its four chained functions for every mode.",
            "Python Native is measured fork E2E. JavaScript Native is the released artifact's fork-equivalent model, not raw launch E2E.",
        ]
    )
    path.write_text("\n".join(lines) + "\n")


def plot(rows: list[dict[str, Any]], path: Path) -> None:
    x = np.arange(len(rows))
    width = 0.25
    series = [
        ("Native (fork-equivalent)", "native_s", "#B8BDC5", ""),
        ("CoFunc TDX", "cofunc_s", "#2A9D8F", "////"),
        ("Vanilla Kata TDX", "kata_s", "#E76F51", ""),
    ]
    fig, ax = plt.subplots(figsize=(12.6, 5.8))
    for index, (name, key, color, hatch) in enumerate(series):
        positions = x + (index - 1) * width
        values = [float(row[key]) for row in rows]
        bars = ax.bar(
            positions,
            values,
            width,
            label=name,
            color=color,
            hatch=hatch,
            edgecolor="#30343B",
            linewidth=0.55,
            zorder=3,
        )
        for bar, value in zip(bars, values):
            ax.annotate(
                f"{value:.2f}",
                (bar.get_x() + bar.get_width() / 2.0, value),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=7,
                rotation=90,
            )

    ax.set_yscale("log")
    all_values = [
        float(row[key])
        for row in rows
        for key in ("native_s", "cofunc_s", "kata_s")
    ]
    ax.set_ylim(min(all_values) / 1.35, max(all_values) * 2.4)
    ax.set_ylabel("Mean end-to-end latency (s, log scale)")
    ax.set_title("Paper-aligned measured TDX Fig. 11")
    ax.set_xticks(x)
    ax.set_xticklabels([str(row["label"]) for row in rows])
    ax.grid(axis="y", which="both", linestyle=":", linewidth=0.7, alpha=0.6, zorder=0)
    ax.legend(ncol=1, loc="upper left", frameon=False)
    ax.margins(x=0.025)
    fig.subplots_adjust(left=0.09, right=0.985, bottom=0.15, top=0.90)
    fig.savefig(path.with_suffix(".png"), dpi=240)
    fig.savefig(path.with_suffix(".pdf"))
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--cofunc", type=Path, required=True)
    parser.add_argument("--kata", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=False)
    native = extract_mode(
        args.native,
        lambda workload: "native-fork" if workload.startswith("fn_py_") else "native-fork-model",
    )
    cofunc = extract_mode(args.cofunc, lambda _workload: "cofunc-fork")
    kata = extract_mode(args.kata, lambda _workload: "cold-observed")
    rows = build_rows(native, cofunc, kata)

    csv_path = args.out_dir / "measured_tdx_fig11.csv"
    json_path = args.out_dir / "measured_tdx_fig11.json"
    markdown_path = args.out_dir / "measured_tdx_fig11.md"
    graph_stem = args.out_dir / "measured_tdx_fig11"
    write_csv(rows, csv_path)
    write_markdown(rows, markdown_path)
    json_path.write_text(
        json.dumps(
            {
                "inputs": {
                    "native": {"path": str(args.native), "sha256": sha256(args.native)},
                    "cofunc": {"path": str(args.cofunc), "sha256": sha256(args.cofunc)},
                    "kata": {"path": str(args.kata), "sha256": sha256(args.kata)},
                },
                "sample_policy": "artifact-first-N; no outlier removal",
                "native_policy": (
                    "measured native-fork for Python; released artifact's "
                    "fork-equivalent model for JavaScript"
                ),
                "rows": rows,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    plot(rows, graph_stem)
    print(f"out_dir={args.out_dir}")
    print(f"applications={len(rows)}")
    print(f"graph={graph_stem.with_suffix('.png')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
