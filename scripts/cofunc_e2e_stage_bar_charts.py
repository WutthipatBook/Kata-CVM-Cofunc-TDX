#!/usr/bin/env python3
"""Render per-boot-path stacked bar charts from E2E stage-breakdown JSON."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


DEFAULT_IMAGE_DIR = Path.home() / "BookArchive" / "Images"

PATHS = {
    "cofunc": {
        "title": "CoFunc fork",
        "modes": ["cofunc-fork"],
        "filename": "cofunc",
    },
    "native": {
        "title": "Native fork baseline",
        "modes": ["native-fork", "native-fork-model"],
        "filename": "native",
    },
    "cold": {
        "title": "Cold/Kata",
        "modes": ["cold-artifact-equivalent", "cold-observed"],
        "filename": "cold",
    },
}

VIEWS = {
    "full": {
        "title": "E2E stage breakdown",
        "filename": "stages",
        "ylabel": "Mean E2E time (s)",
        "scale": 1.0,
        "label_suffix": "s",
        "exclude_stages": set(),
    },
    "startup": {
        "title": "Setup/load zoom",
        "filename": "startup-stages",
        "ylabel": "Mean setup/load time (ms)",
        "scale": 1000.0,
        "label_suffix": "ms",
        "exclude_stages": {"handler_execution"},
    },
}

PAPER_ORDER = [
    "fn_py_face_detection",
    "fn_py_image_processing",
    "fn_py_sentiment",
    "fn_py_video_processing",
    "fn_py_compression",
    "fn_py_dna_visualisation",
    "fn_js_uploader",
    "fn_js_thumbnailer",
    "chain_js_alexa",
]

PAPER_LABELS = {
    "fn_py_face_detection": "face",
    "fn_py_image_processing": "image",
    "fn_py_sentiment": "sentiment",
    "fn_py_video_processing": "video",
    "fn_py_compression": "compress",
    "fn_py_dna_visualisation": "dna",
    "fn_js_uploader": "upload",
    "fn_js_thumbnailer": "thumbnail",
    "chain_js_alexa": "alexa",
}

MODE_PRIORITY = {
    "cofunc-fork": 0,
    "native-fork": 0,
    "native-fork-model": 1,
    "cold-artifact-equivalent": 0,
    "cold-observed": 1,
}

STAGE_ORDER = {
    "host_container_setup": 0,
    "native_setup": 0,
    "vm_container_boot": 0,
    "cvm_instance_setup": 1,
    "setup_plus_function_loading": 1,
    "function_loading": 2,
    "handler_execution": 3,
    "copy_on_write": 4,
    "measurement_encryption_attestation": 5,
}

STAGE_LABELS = {
    "host_container_setup": "Host container setup",
    "native_setup": "Native setup",
    "vm_container_boot": "VM/container boot",
    "cvm_instance_setup": "CVM instance setup",
    "setup_plus_function_loading": "Setup + function load",
    "function_loading": "Function loading",
    "handler_execution": "Handler execution",
    "copy_on_write": "Modeled Linux CoW",
    "measurement_encryption_attestation": "Measurement/encryption/attestation",
}

STAGE_COLORS = {
    "host_container_setup": "#4C78A8",
    "native_setup": "#4C78A8",
    "vm_container_boot": "#4C78A8",
    "cvm_instance_setup": "#72B7B2",
    "setup_plus_function_loading": "#9D755D",
    "function_loading": "#F2CF5B",
    "handler_execution": "#E45756",
    "copy_on_write": "#8F6BB3",
    "measurement_encryption_attestation": "#B279A2",
}


def load_rows(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    rows = data.get("rows")
    if not isinstance(rows, list):
        raise SystemExit(f"{path} does not look like a stage-breakdown JSON file")
    if not rows:
        raise SystemExit(f"{path} has no rows")
    return rows


def compact_workload(name: str) -> str:
    return name.replace("chain_js_alexa/", "alexa/").replace("fn_py_", "py_").replace("fn_js_", "js_")


def paper_workload(name: str) -> str:
    if "/" in name:
        return name.split("/", 1)[0]
    return name


def workload_sort_key(name: str) -> tuple[int, str]:
    if name in PAPER_ORDER:
        return (PAPER_ORDER.index(name), name)
    return (len(PAPER_ORDER), name)


def select_path_rows(rows: list[dict[str, Any]], path_name: str) -> list[dict[str, Any]]:
    modes = set(PATHS[path_name]["modes"])
    candidates: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        if row.get("mode") in modes and row.get("included_in_stage_sum"):
            candidates[str(row["workload"])].append(row)

    selected: list[dict[str, Any]] = []
    for workload, workload_rows in candidates.items():
        modes_for_workload = sorted(
            {str(row["mode"]) for row in workload_rows},
            key=lambda mode: MODE_PRIORITY.get(mode, 99),
        )
        chosen_mode = modes_for_workload[0]
        selected.extend(row for row in workload_rows if row["mode"] == chosen_mode)
    return selected


def pivot(
    rows: list[dict[str, Any]],
    excluded_stages: set[str],
) -> tuple[list[str], list[str], dict[str, list[float]], list[float]]:
    filtered = [row for row in rows if str(row["stage"]) not in excluded_stages]
    workloads = sorted({paper_workload(str(row["workload"])) for row in filtered}, key=workload_sort_key)
    stages = sorted({str(row["stage"]) for row in filtered}, key=lambda stage: (STAGE_ORDER.get(stage, 99), stage))

    values = {stage: [0.0 for _ in workloads] for stage in stages}
    totals = [0.0 for _ in workloads]
    workload_index = {workload: i for i, workload in enumerate(workloads)}

    for row in filtered:
        workload = paper_workload(str(row["workload"]))
        stage = str(row["stage"])
        idx = workload_index[workload]
        value = float(row["stage_mean_s"])
        values[stage][idx] += value
        totals[idx] += value
    return workloads, stages, values, totals


def render_chart(
    path_name: str,
    rows: list[dict[str, Any]],
    out_dir: Path,
    prefix: str,
    title_prefix: str,
    image_format: str,
    view_name: str,
) -> Path | None:
    selected = select_path_rows(rows, path_name)
    if not selected:
        return None

    view = VIEWS[view_name]
    workloads, stages, values, totals = pivot(selected, view["exclude_stages"])
    if not stages:
        return None

    scale = float(view["scale"])
    values = {
        stage: [value * scale for value in stage_values]
        for stage, stage_values in values.items()
    }
    totals = [total * scale for total in totals]
    x = list(range(len(workloads)))
    fig_width = max(9.0, len(workloads) * 0.62)
    fig_height = 5.2

    fig, ax = plt.subplots(figsize=(fig_width, fig_height))
    bottom = [0.0 for _ in workloads]
    for stage in stages:
        ax.bar(
            x,
            values[stage],
            bottom=bottom,
            label=STAGE_LABELS.get(stage, stage),
            color=STAGE_COLORS.get(stage, "#8E8E8E"),
            edgecolor="white",
            linewidth=0.5,
        )
        bottom = [base + value for base, value in zip(bottom, values[stage])]

    ymax = max(totals) if totals else 1.0
    for idx, total in enumerate(totals):
        if view["label_suffix"] == "ms":
            label = f"{total:.1f}ms"
        else:
            label = f"{total:.2f}s"
        ax.text(idx, total + ymax * 0.015, label, ha="center", va="bottom", fontsize=8)

    ax.set_title(f"{title_prefix}: {PATHS[path_name]['title']} - {view['title']}", fontsize=14, fontweight="bold")
    ax.set_ylabel(str(view["ylabel"]))
    ax.set_xticks(x)
    ax.set_xticklabels([PAPER_LABELS.get(workload, compact_workload(workload)) for workload in workloads], rotation=40, ha="right")
    ax.set_ylim(0, ymax * 1.16 if ymax > 0 else 1)
    ax.grid(axis="y", color="#d9dde3", linestyle="-", linewidth=0.7)
    ax.set_axisbelow(True)
    ax.legend(loc="upper left", bbox_to_anchor=(1.01, 1.0), frameon=False)

    fig.tight_layout()
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{prefix}-{PATHS[path_name]['filename']}-{view['filename']}.{image_format}"
    fig.savefig(out, dpi=220, bbox_inches="tight")
    plt.close(fig)
    return out


def default_prefix(input_path: Path) -> str:
    parent = input_path.parent.name
    return parent if parent else "stage-breakdown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="stage-breakdown.json from cofunc_e2e_stage_breakdown.py")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_IMAGE_DIR, help=f"Output directory. Default: {DEFAULT_IMAGE_DIR}")
    parser.add_argument("--prefix", help="Output filename prefix. Defaults to the input directory name.")
    parser.add_argument("--title-prefix", default="E2E stage breakdown", help="Title prefix for each chart.")
    parser.add_argument("--format", default="png", choices=["png", "pdf", "svg"], help="Output image format.")
    parser.add_argument("--views", nargs="+", default=["full"], choices=sorted(VIEWS), help="Chart views to render.")
    args = parser.parse_args()

    rows = load_rows(args.input)
    prefix = args.prefix or default_prefix(args.input)
    outputs = []
    for path_name in ["cofunc", "native", "cold"]:
        for view_name in args.views:
            out = render_chart(path_name, rows, args.out_dir, prefix, args.title_prefix, args.format, view_name)
            if out is not None:
                outputs.append(out)

    if not outputs:
        raise SystemExit("no CoFunc, native, or cold stage rows found")
    for out in outputs:
        print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
