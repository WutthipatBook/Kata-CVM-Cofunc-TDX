#!/usr/bin/env python3
"""Compare handler execution across Native, CoFunc TDX, and Vanilla Kata TDX."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

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

SERIES = [
    ("Native (fork-equivalent)", "native_s", "#B8BDC5", ""),
    ("CoFunc TDX", "cofunc_s", "#2A9D8F", "////"),
    ("Vanilla Kata TDX", "kata_s", "#E76F51", ""),
]


def load_rows(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        raise SystemExit(f"invalid or empty stage JSON: {path}")
    return rows


def handler_value(rows: list[dict[str, Any]], workload: str, mode: str) -> float:
    selected = [
        row
        for row in rows
        if row.get("workload") == workload
        and row.get("mode") == mode
        and row.get("stage") == "handler_execution"
        and row.get("included_in_stage_sum")
    ]
    if len(selected) != 1:
        raise SystemExit(
            f"expected one handler row for workload={workload} mode={mode}; "
            f"found={len(selected)}"
        )
    return float(selected[0]["stage_mean_s"])


def build(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for app, functions, label in APPS:
        values = {"native_s": 0.0, "cofunc_s": 0.0, "kata_s": 0.0}
        for workload in functions:
            native_mode = (
                "native-fork" if workload.startswith("fn_py_") else "native-fork-model"
            )
            values["native_s"] += handler_value(rows, workload, native_mode)
            values["cofunc_s"] += handler_value(rows, workload, "cofunc-fork")
            values["kata_s"] += handler_value(rows, workload, "cold-observed")
        output.append(
            {
                "app": app,
                "label": label,
                **values,
                "cofunc_over_native": values["cofunc_s"] / values["native_s"],
                "kata_over_native": values["kata_s"] / values["native_s"],
                "kata_over_cofunc": values["kata_s"] / values["cofunc_s"],
            }
        )
    return output


def write_data(rows: list[dict[str, Any]], out_dir: Path) -> None:
    json_path = out_dir / "handler_execution_comparison.json"
    csv_path = out_dir / "handler_execution_comparison.csv"
    markdown_path = out_dir / "handler_execution_comparison.md"
    json_path.write_text(json.dumps({"rows": rows}, indent=2, sort_keys=True) + "\n")

    fields = [
        "app",
        "native_s",
        "cofunc_s",
        "kata_s",
        "cofunc_over_native",
        "kata_over_native",
        "kata_over_cofunc",
    ]
    with csv_path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    field: row[field] if field == "app" else f"{float(row[field]):.9f}"
                    for field in fields
                }
            )

    lines = [
        "# Handler execution comparison",
        "",
        "Startup, boot, function loading, and modeled CoW are excluded.",
        "",
        "| Application | Native s | CoFunc TDX s | Vanilla Kata TDX s | CoFunc / Native | Kata / Native | Kata / CoFunc |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| `{row['app']}` | {row['native_s']:.4f} | {row['cofunc_s']:.4f} | "
            f"{row['kata_s']:.4f} | {row['cofunc_over_native']:.2f}x | "
            f"{row['kata_over_native']:.2f}x | {row['kata_over_cofunc']:.2f}x |"
        )
    lines.extend(
        [
            "",
            "Python Native handler time comes from measured `lean_fork` execution.",
            "JavaScript Native handler time comes from measured `lean_launch t_exec`, the handler component used by the artifact's fork-equivalent model.",
            "Alexa is the sum of its four function handlers in every baseline.",
        ]
    )
    markdown_path.write_text("\n".join(lines) + "\n")


def plot(rows: list[dict[str, Any]], out_dir: Path) -> None:
    x = np.arange(len(rows))
    width = 0.25
    fig, ax = plt.subplots(figsize=(12.6, 5.8))
    for index, (name, key, color, hatch) in enumerate(SERIES):
        values = [float(row[key]) for row in rows]
        positions = x + (index - 1) * width
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
                f"{value:.3f}",
                (bar.get_x() + bar.get_width() / 2.0, value),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=7,
                rotation=90,
            )

    all_values = [float(row[key]) for row in rows for _, key, _, _ in SERIES]
    ax.set_yscale("log")
    ax.set_ylim(min(all_values) / 1.5, max(all_values) * 2.4)
    ax.set_ylabel("Mean handler execution time (s, log scale)")
    ax.set_title("Handler execution: Native vs CoFunc vs Vanilla Kata TDX")
    ax.set_xticks(x)
    ax.set_xticklabels([str(row["label"]) for row in rows])
    ax.grid(axis="y", which="both", linestyle=":", linewidth=0.7, alpha=0.6, zorder=0)
    ax.legend(loc="upper left", frameon=False)
    ax.margins(x=0.025)
    fig.subplots_adjust(left=0.09, right=0.985, bottom=0.15, top=0.90)
    stem = out_dir / "handler_execution_comparison"
    fig.savefig(stem.with_suffix(".png"), dpi=240)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    rows = build(load_rows(args.input))
    write_data(rows, args.out_dir)
    plot(rows, args.out_dir)
    print(f"output={args.out_dir / 'handler_execution_comparison.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
