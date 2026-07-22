#!/usr/bin/env python3
"""Plot handler execution before and after CoFunc private pre-faulting."""

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
    ("CoFunc on-demand", "ondemand_cofunc_s", "#457B9D", ""),
    ("CoFunc pre-fault", "prefault_cofunc_s", "#2A9D8F", "////"),
    ("Vanilla Kata TDX", "kata_s", "#E76F51", ""),
]


def load_rows(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        raise SystemExit(f"invalid or empty stage JSON: {path}")
    return rows


def handler_row(
    rows: list[dict[str, Any]], workload: str, mode: str
) -> dict[str, Any]:
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
    return selected[0]


def build(
    baseline_rows: list[dict[str, Any]], prefault_rows: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for app, functions, label in APPS:
        values = {
            "native_s": 0.0,
            "ondemand_cofunc_s": 0.0,
            "prefault_cofunc_s": 0.0,
            "kata_s": 0.0,
        }
        prefault_samples: list[int] = []
        for workload in functions:
            native_mode = (
                "native-fork" if workload.startswith("fn_py_") else "native-fork-model"
            )
            values["native_s"] += float(
                handler_row(baseline_rows, workload, native_mode)["stage_mean_s"]
            )
            values["ondemand_cofunc_s"] += float(
                handler_row(baseline_rows, workload, "cofunc-fork")["stage_mean_s"]
            )
            values["kata_s"] += float(
                handler_row(baseline_rows, workload, "cold-observed")["stage_mean_s"]
            )
            prefault = handler_row(prefault_rows, workload, "cofunc-fork")
            values["prefault_cofunc_s"] += float(prefault["stage_mean_s"])
            prefault_samples.append(int(prefault["samples"]))

        delta_s = values["prefault_cofunc_s"] - values["ondemand_cofunc_s"]
        delta_pct = delta_s / values["ondemand_cofunc_s"] * 100.0
        output.append(
            {
                "app": app,
                "label": label,
                **values,
                "prefault_samples_per_function": prefault_samples,
                "prefault_minus_ondemand_s": delta_s,
                "prefault_change_pct": delta_pct,
                "prefault_over_ondemand": (
                    values["prefault_cofunc_s"] / values["ondemand_cofunc_s"]
                ),
            }
        )
    return output


def write_data(rows: list[dict[str, Any]], out_dir: Path) -> None:
    stem = out_dir / "cofunc_prefault_handler_comparison"
    stem.with_suffix(".json").write_text(
        json.dumps({"rows": rows}, indent=2, sort_keys=True) + "\n"
    )

    fields = [
        "app",
        "native_s",
        "ondemand_cofunc_s",
        "prefault_cofunc_s",
        "kata_s",
        "prefault_minus_ondemand_s",
        "prefault_change_pct",
        "prefault_over_ondemand",
        "prefault_samples_per_function",
    ]
    with stem.with_suffix(".csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    field: (
                        json.dumps(row[field])
                        if field == "prefault_samples_per_function"
                        else row[field]
                    )
                    for field in fields
                }
            )

    lines = [
        "# CoFunc private pre-fault handler comparison",
        "",
        "Only `t_exec` is compared; startup, pre-fault setup, function loading, "
        "and modeled CoW are excluded.",
        "",
        "| Application | Native s | CoFunc on-demand s | CoFunc pre-fault s | "
        "Vanilla Kata s | Pre-fault change |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            f"| `{row['app']}` | {row['native_s']:.4f} | "
            f"{row['ondemand_cofunc_s']:.4f} | {row['prefault_cofunc_s']:.4f} | "
            f"{row['kata_s']:.4f} | {row['prefault_change_pct']:+.2f}% |"
        )
    lines.extend(
        [
            "",
            "Negative change means pre-faulting reduced handler execution time.",
            "Alexa is the sum of its four function handlers in every series.",
        ]
    )
    stem.with_suffix(".md").write_text("\n".join(lines) + "\n")


def plot(rows: list[dict[str, Any]], out_dir: Path) -> None:
    x = np.arange(len(rows))
    width = 0.20
    fig, ax = plt.subplots(figsize=(13.2, 6.0))
    for index, (name, key, color, hatch) in enumerate(SERIES):
        values = [float(row[key]) for row in rows]
        positions = x + (index - 1.5) * width
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
                fontsize=6.8,
                rotation=90,
            )

    all_values = [float(row[key]) for row in rows for _, key, _, _ in SERIES]
    ax.set_yscale("log")
    ax.set_ylim(min(all_values) / 1.6, max(all_values) * 2.7)
    ax.set_ylabel("Mean handler execution time (s, log scale)")
    ax.set_title("Handler execution after CoFunc private pre-faulting")
    ax.set_xticks(x)
    ax.set_xticklabels([str(row["label"]) for row in rows])
    ax.grid(axis="y", which="both", linestyle=":", linewidth=0.7, alpha=0.6)
    ax.legend(loc="upper left", frameon=False, ncol=2)
    ax.margins(x=0.025)
    fig.subplots_adjust(left=0.085, right=0.99, bottom=0.15, top=0.90)
    stem = out_dir / "cofunc_prefault_handler_comparison"
    fig.savefig(stem.with_suffix(".png"), dpi=240)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--prefault", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    rows = build(load_rows(args.baseline), load_rows(args.prefault))
    write_data(rows, args.out_dir)
    plot(rows, args.out_dir)
    print(f"output={args.out_dir / 'cofunc_prefault_handler_comparison.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
