#!/usr/bin/env python3
"""Compare count-only CoFunc handler EPT traces with and without pre-faulting."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


WORKLOADS = [
    "fn_py_compression",
    "fn_py_face_detection",
    "fn_py_image_processing",
    "fn_py_sentiment",
    "fn_py_video_processing",
    "fn_py_dna_visualisation",
    "fn_js_thumbnailer",
    "fn_js_uploader",
    "chain_js_alexa/fn_js_alexa_frontend",
    "chain_js_alexa/fn_js_alexa_interact",
    "chain_js_alexa/fn_js_alexa_smarthome",
    "chain_js_alexa/fn_js_alexa_tv",
]

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

MAP_RE = re.compile(r"^@(?P<name>[A-Za-z0-9_]+)\[(?P<keys>[0-9, ]+)\]: (?P<value>[0-9]+)$")
WINDOW_RE = re.compile(
    r"^trace_window\s+(?P<phase>begin|end)\s+(?P<window>[0-9]+)\s+"
)


def parse_result(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    required = {
        "command_rc": "0",
        "trace_ready": "1",
        "trace_stopped": "1",
        "signal_begin_count": str(len(WORKLOADS)),
        "signal_end_count": str(len(WORKLOADS)),
        "loss_markers": "0",
    }
    for key, expected in required.items():
        if result.get(key) != expected:
            raise SystemExit(
                f"invalid trace result {path}: {key}={result.get(key)!r}, "
                f"expected={expected!r}"
            )
    return result


def parse_signals(path: Path) -> None:
    with path.open(newline="") as file:
        rows = list(csv.DictReader(file, delimiter="\t"))
    expected = []
    for sample in range(1, len(WORKLOADS) + 1):
        expected.extend([(str(sample), "begin"), (str(sample), "end")])
    actual = [(row["sample"], row["phase"]) for row in rows]
    if actual != expected:
        raise SystemExit(f"unexpected signal sequence in {path}: {actual!r}")


def parse_trace(path: Path) -> dict[str, dict[tuple[int, ...], int]]:
    maps: dict[str, dict[tuple[int, ...], int]] = {}
    windows: list[tuple[int, str]] = []
    ready = 0
    stopped = 0
    for line in path.read_text().splitlines():
        if re.match(r"^trace_status\s+ready$", line):
            ready += 1
        if re.match(r"^trace_status\s+stopped$", line):
            stopped += 1
        window_match = WINDOW_RE.match(line)
        if window_match:
            windows.append(
                (int(window_match.group("window")), window_match.group("phase"))
            )
        map_match = MAP_RE.match(line)
        if map_match:
            keys = tuple(int(value.strip()) for value in map_match.group("keys").split(","))
            maps.setdefault(map_match.group("name"), {})[keys] = int(
                map_match.group("value")
            )
    expected_windows = []
    for window in range(1, len(WORKLOADS) + 1):
        expected_windows.extend([(window, "begin"), (window, "end")])
    if ready != 1 or stopped != 1 or windows != expected_windows:
        raise SystemExit(
            f"invalid trace framing in {path}: ready={ready} stopped={stopped} "
            f"windows={windows!r}"
        )
    return maps


def map_value(
    maps: dict[str, dict[tuple[int, ...], int]], name: str, *keys: int
) -> int:
    return maps.get(name, {}).get(tuple(keys), 0)


def analyzer_row(log_root: Path, workload: str) -> dict[str, Any]:
    path = log_root / workload / "sc_fork.log"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if len(rows) != 1:
        raise SystemExit(f"expected one analyzer row in {path}, found {len(rows)}")
    row = rows[0]
    for key in ("n_pgfault_exec", "t_pgfault_exec", "t_exec"):
        if not isinstance(row.get(key), (int, float)):
            raise SystemExit(f"missing numeric {key} in {path}")
    return row


def load_mode(root: Path) -> list[dict[str, Any]]:
    trace_dir = root / "ept-trace"
    parse_result(trace_dir / "trace-result.txt")
    parse_signals(trace_dir / "signals.tsv")
    maps = parse_trace(trace_dir / "ept-events.tsv")
    rows: list[dict[str, Any]] = []
    for window, workload in enumerate(WORKLOADS, start=1):
        exits = map_value(maps, "window_ept_exits", window)
        faults = map_value(maps, "window_ept_faults", window)
        services = map_value(maps, "window_service_count", window)
        if not exits == faults == services:
            raise SystemExit(
                f"unpaired EPT accounting: workload={workload} exits={exits} "
                f"faults={faults} services={services}"
            )
        analyzer = analyzer_row(root / "cofunc-out" / "log", workload)
        rows.append(
            {
                "workload": workload,
                "window": window,
                "ept_faults": faults,
                "ept_service_ns": map_value(maps, "window_service_ns", window),
                "ept_error_codes": {
                    str(keys[1]): value
                    for keys, value in maps.get("window_error_code", {}).items()
                    if keys[0] == window
                },
                "first_level_faults": int(analyzer["n_pgfault_exec"]),
                "first_level_fault_s": float(analyzer["t_pgfault_exec"]),
                "handler_s": float(analyzer["t_exec"]),
            }
        )
    return rows


def compare(
    on_demand: list[dict[str, Any]], prefault: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for on_row, pre_row in zip(on_demand, prefault):
        if on_row["workload"] != pre_row["workload"]:
            raise SystemExit("mode workload ordering differs")
        on_faults = int(on_row["ept_faults"])
        pre_faults = int(pre_row["ept_faults"])
        saved = on_faults - pre_faults
        rows.append(
            {
                "workload": on_row["workload"],
                "on_demand_ept_faults": on_faults,
                "prefault_ept_faults": pre_faults,
                "ept_faults_saved": saved,
                "ept_fault_reduction_pct": (
                    saved / on_faults * 100.0 if on_faults else None
                ),
                "on_demand_ept_service_ns": on_row["ept_service_ns"],
                "prefault_ept_service_ns": pre_row["ept_service_ns"],
                "ept_service_ns_saved": (
                    int(on_row["ept_service_ns"])
                    - int(pre_row["ept_service_ns"])
                ),
                "on_demand_first_level_faults": on_row["first_level_faults"],
                "prefault_first_level_faults": pre_row["first_level_faults"],
                "first_level_fault_delta": (
                    int(on_row["first_level_faults"])
                    - int(pre_row["first_level_faults"])
                ),
                "on_demand_handler_s_diagnostic": on_row["handler_s"],
                "prefault_handler_s_diagnostic": pre_row["handler_s"],
                "on_demand_error_codes": on_row["ept_error_codes"],
                "prefault_error_codes": pre_row["ept_error_codes"],
            }
        )
    return rows


def app_rows(function_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_workload = {row["workload"]: row for row in function_rows}
    output: list[dict[str, Any]] = []
    for app, workloads, label in APPS:
        selected = [by_workload[workload] for workload in workloads]
        on_faults = sum(row["on_demand_ept_faults"] for row in selected)
        pre_faults = sum(row["prefault_ept_faults"] for row in selected)
        saved = on_faults - pre_faults
        output.append(
            {
                "app": app,
                "label": label,
                "functions": workloads,
                "on_demand_ept_faults": on_faults,
                "prefault_ept_faults": pre_faults,
                "ept_faults_saved": saved,
                "ept_fault_reduction_pct": (
                    saved / on_faults * 100.0 if on_faults else None
                ),
            }
        )
    return output


def write_outputs(
    function_rows: list[dict[str, Any]], apps: list[dict[str, Any]], out_dir: Path
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = out_dir / "cofunc_prefault_fault_savings"
    stem.with_suffix(".json").write_text(
        json.dumps(
            {
                "metric": "handler-window host EPT page-fault tracepoint events",
                "samples_per_function_per_mode": 1,
                "function_rows": function_rows,
                "app_rows": apps,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )

    fields = [
        "workload",
        "on_demand_ept_faults",
        "prefault_ept_faults",
        "ept_faults_saved",
        "ept_fault_reduction_pct",
        "on_demand_first_level_faults",
        "prefault_first_level_faults",
        "first_level_fault_delta",
    ]
    with stem.with_suffix(".csv").open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        writer.writerows({field: row[field] for field in fields} for row in function_rows)

    lines = [
        "# CoFunc private pre-fault fault savings",
        "",
        "`EPT faults saved` is the paired difference in host KVM EPT page-fault "
        "tracepoint events during the authenticated handler window. It is not "
        "the guest first-level page-fault count.",
        "",
        "| Function | On-demand EPT faults | Pre-fault EPT faults | Saved | Reduction |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for row in function_rows:
        reduction = row["ept_fault_reduction_pct"]
        reduction_text = "n/a" if reduction is None else f"{reduction:.2f}%"
        lines.append(
            f"| `{row['workload']}` | {row['on_demand_ept_faults']:,} | "
            f"{row['prefault_ept_faults']:,} | {row['ept_faults_saved']:,} | "
            f"{reduction_text} |"
        )
    lines.extend(
        [
            "",
            "## Fig. 11 applications",
            "",
            "| Application | On-demand EPT faults | Pre-fault EPT faults | Saved | Reduction |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
    )
    for row in apps:
        reduction = row["ept_fault_reduction_pct"]
        reduction_text = "n/a" if reduction is None else f"{reduction:.2f}%"
        lines.append(
            f"| `{row['app']}` | {row['on_demand_ept_faults']:,} | "
            f"{row['prefault_ept_faults']:,} | {row['ept_faults_saved']:,} | "
            f"{reduction_text} |"
        )
    lines.extend(
        [
            "",
            "Alexa is the sum of its four function windows. Each function has one "
            "diagnostic launch per mode; these counts are not performance samples.",
        ]
    )
    stem.with_suffix(".md").write_text("\n".join(lines) + "\n")

    x = np.arange(len(apps))
    width = 0.36
    fig, ax = plt.subplots(figsize=(13.2, 5.8))
    ax.bar(
        x - width / 2,
        [row["on_demand_ept_faults"] for row in apps],
        width,
        label="CoFunc on-demand",
        color="#457B9D",
        edgecolor="#30343B",
        linewidth=0.55,
    )
    ax.bar(
        x + width / 2,
        [row["prefault_ept_faults"] for row in apps],
        width,
        label="CoFunc pre-fault",
        color="#2A9D8F",
        hatch="////",
        edgecolor="#30343B",
        linewidth=0.55,
    )
    ax.set_yscale("symlog", linthresh=1)
    ax.set_ylabel("Handler-window EPT faults (single diagnostic launch)")
    ax.set_title("Host EPT faults moved out of CoFunc handler execution")
    ax.set_xticks(x)
    ax.set_xticklabels([row["label"] for row in apps])
    ax.grid(axis="y", which="both", linestyle=":", linewidth=0.7, alpha=0.6)
    ax.legend(frameon=False)
    fig.subplots_adjust(left=0.09, right=0.99, bottom=0.16, top=0.90)
    fig.savefig(stem.with_suffix(".png"), dpi=240)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--on-demand-root", type=Path, required=True)
    parser.add_argument("--prefault-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    function_rows = compare(load_mode(args.on_demand_root), load_mode(args.prefault_root))
    apps = app_rows(function_rows)
    write_outputs(function_rows, apps, args.output_dir)
    print(f"output={args.output_dir / 'cofunc_prefault_fault_savings.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
