#!/usr/bin/env python3
"""Plot paper-aligned Alexa stages for Native, CoFunc, and Kata."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


COLORS = {
    "setup": "#4C78A8",
    "function_loading": "#F2CF5B",
    "handler_execution": "#E45756",
    "copy_on_write": "#8F6BB3",
}


def load_rows(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        raise SystemExit(f"invalid stage JSON: {path}")
    return rows


def stage_sum(rows: list[dict[str, Any]], mode: str, stages: set[str]) -> float:
    selected = [
        row
        for row in rows
        if str(row.get("workload", "")).startswith("chain_js_alexa/")
        and row.get("mode") == mode
        and row.get("included_in_stage_sum")
        and row.get("stage") in stages
    ]
    if not selected:
        raise SystemExit(f"missing Alexa {mode} stages: {sorted(stages)}")
    return sum(float(row["stage_mean_s"]) for row in selected)


def build(rows: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    data = {
        "Native (fork-equivalent)": {
            "setup": stage_sum(rows, "native-fork-model", {"native_setup"}),
            "function_loading": stage_sum(rows, "native-fork-model", {"function_loading"}),
            "handler_execution": stage_sum(rows, "native-fork-model", {"handler_execution"}),
            "copy_on_write": stage_sum(rows, "native-fork-model", {"copy_on_write"}),
        },
        "CoFunc TDX": {
            "setup": stage_sum(
                rows,
                "cofunc-fork",
                {"host_container_setup", "cvm_instance_setup"},
            ),
            "function_loading": stage_sum(rows, "cofunc-fork", {"function_loading"}),
            "handler_execution": stage_sum(rows, "cofunc-fork", {"handler_execution"}),
            "copy_on_write": 0.0,
        },
        "Vanilla Kata TDX": {
            "setup": stage_sum(rows, "cold-observed", {"vm_container_boot"}),
            "function_loading": stage_sum(rows, "cold-observed", {"function_loading"}),
            "handler_execution": stage_sum(rows, "cold-observed", {"handler_execution"}),
            "copy_on_write": 0.0,
        },
    }
    for values in data.values():
        values["total"] = sum(values.values())
    return data


def write_outputs(data: dict[str, dict[str, float]], out_dir: Path) -> None:
    json_path = out_dir / "alexa_stage_tradeoff.json"
    csv_path = out_dir / "alexa_stage_tradeoff.csv"
    markdown_path = out_dir / "alexa_stage_tradeoff.md"
    json_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    with csv_path.open("w", newline="") as file:
        writer = csv.writer(file)
        writer.writerow(["mode", "setup_s", "function_loading_s", "handler_execution_s", "copy_on_write_s", "total_s"])
        for mode, values in data.items():
            writer.writerow(
                [
                    mode,
                    f"{values['setup']:.9f}",
                    f"{values['function_loading']:.9f}",
                    f"{values['handler_execution']:.9f}",
                    f"{values['copy_on_write']:.9f}",
                    f"{values['total']:.9f}",
                ]
            )

    native = data["Native (fork-equivalent)"]
    cofunc = data["CoFunc TDX"]
    setup_saving = (
        native["setup"]
        + native["function_loading"]
        - cofunc["setup"]
        - cofunc["function_loading"]
    )
    handler_penalty = cofunc["handler_execution"] - native["handler_execution"]
    cofunc_penalty = cofunc["total"] - native["total"]
    lines = [
        "# Paper-aligned Alexa chain stage comparison",
        "",
        "| Mode | Setup/boot ms | Function load ms | Handler ms | CoW ms | Total ms |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for mode, values in data.items():
        lines.append(
            f"| {mode} | {values['setup'] * 1000:.1f} | "
            f"{values['function_loading'] * 1000:.1f} | "
            f"{values['handler_execution'] * 1000:.1f} | "
            f"{values['copy_on_write'] * 1000:.1f} | "
            f"{values['total'] * 1000:.1f} |"
        )
    lines.extend(
        [
            "",
            f"CoFunc setup/loading minus Native is {-setup_saving * 1000:.1f} ms.",
            f"CoFunc handler execution minus Native is {handler_penalty * 1000:.1f} ms.",
            f"CoFunc is {cofunc_penalty * 1000:.1f} ms slower end to end "
            f"({cofunc_penalty / native['total'] * 100:.1f}% over modeled Native E2E).",
            "",
            "For JavaScript, Native is the released artifact's fork-equivalent model; it is not raw lean_launch E2E.",
            "For Kata, setup is VM/container boot; for CoFunc it is host-container plus CVM-instance setup.",
        ]
    )
    markdown_path.write_text("\n".join(lines) + "\n")


def stack_bar(ax: Any, modes: list[str], data: dict[str, dict[str, float]]) -> None:
    bottoms = [0.0] * len(modes)
    specs = [
        ("setup", "Setup / VM boot"),
        ("function_loading", "Function loading"),
        ("handler_execution", "Handler execution"),
        ("copy_on_write", "Modeled Linux CoW"),
    ]
    for key, label in specs:
        values = [data[mode][key] for mode in modes]
        ax.bar(
            modes,
            values,
            bottom=bottoms,
            label=label,
            color=COLORS[key],
            edgecolor="white",
            linewidth=0.7,
        )
        bottoms = [bottom + value for bottom, value in zip(bottoms, values)]
    maximum = max(data[mode]["total"] for mode in modes)
    for index, mode in enumerate(modes):
        total = data[mode]["total"]
        total_label = f"{total:.2f} s" if total >= 10.0 else f"{total * 1000:.1f} ms"
        ax.text(index, total + maximum * 0.025, total_label, ha="center", fontsize=9)
    ax.set_ylim(0, maximum * 1.17)
    ax.grid(axis="y", color="#d9dde3", linewidth=0.7)
    ax.set_axisbelow(True)


def plot(data: dict[str, dict[str, float]], out_dir: Path) -> None:
    fig, axes = plt.subplots(1, 2, figsize=(11.4, 5.2))
    stack_bar(axes[0], ["Native (fork-equivalent)", "CoFunc TDX"], data)
    axes[0].set_title("Native vs CoFunc")
    axes[0].set_ylabel("Mean Alexa chain latency (s)")
    stack_bar(axes[1], ["Vanilla Kata TDX"], data)
    axes[1].set_title("Vanilla Kata TDX")
    axes[1].set_ylabel("Mean Alexa chain latency (s)")
    handles, labels = axes[0].get_legend_handles_labels()
    fig.legend(
        handles,
        labels,
        ncol=3,
        loc="upper center",
        bbox_to_anchor=(0.5, 0.925),
        frameon=False,
    )
    fig.suptitle("Paper-aligned Alexa chain stage comparison", y=0.985, fontsize=15, fontweight="bold")
    fig.subplots_adjust(left=0.08, right=0.98, bottom=0.12, top=0.76, wspace=0.28)
    stem = out_dir / "alexa_stage_tradeoff"
    fig.savefig(stem.with_suffix(".png"), dpi=240)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    data = build(load_rows(args.input))
    write_outputs(data, args.out_dir)
    plot(data, args.out_dir)
    print(f"output={args.out_dir / 'alexa_stage_tradeoff.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
