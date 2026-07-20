#!/usr/bin/env python3
"""Render an E2E stage-breakdown JSON file as a compact table image."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


MODE_ORDER = {
    "cofunc-fork": 0,
    "native-fork": 1,
    "native-launch": 2,
    "cold-observed": 3,
    "cold-artifact-equivalent": 4,
}

MODE_LABELS = {
    "cofunc-fork": "CoFunc fork",
    "native-fork": "Native fork",
    "native-launch": "Native launch",
    "cold-observed": "Cold/Kata observed",
    "cold-artifact-equivalent": "Cold/Kata artifact-eq",
}

STAGE_COLUMNS = [
    ("setup_ms", "Host/VM\nsetup ms"),
    ("cvm_ms", "CVM\nsetup ms"),
    ("setup_load_ms", "Setup+load\nms"),
    ("func_ms", "Function\nload ms"),
    ("handler_ms", "Handler\nms"),
    ("security_ms", "Security\nadd-on ms"),
    ("grant_ms", "Grant/accept\nms"),
    ("encrypt_ms", "Encrypt\nms"),
    ("delegate_ms", "Delegate\nms"),
]

STAGE_TO_COLUMN = {
    "host_container_setup": "setup_ms",
    "native_setup": "setup_ms",
    "vm_container_boot": "setup_ms",
    "cvm_instance_setup": "cvm_ms",
    "setup_plus_function_loading": "setup_load_ms",
    "function_loading": "func_ms",
    "handler_execution": "handler_ms",
    "measurement_encryption_attestation": "security_ms",
    "import_attest": "security_ms",
    "handler_grant_accept": "grant_ms",
    "handler_encrypt": "encrypt_ms",
    "handler_delegate": "delegate_ms",
}

DEFAULT_IMAGE_DIR = Path.home() / "BookArchive" / "Images"


def load_rows(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    rows = data.get("rows")
    if not isinstance(rows, list):
        raise SystemExit(f"{path} does not look like a stage-breakdown JSON file")
    if not rows:
        raise SystemExit(f"{path} has no rows")
    return rows


def fmt_s(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.3f}"


def fmt_ms(value: float | None) -> str:
    if value is None:
        return "-"
    if abs(value) >= 1000.0:
        return f"{value:,.0f}"
    if abs(value) >= 100.0:
        return f"{value:.1f}"
    return f"{value:.2f}"


def fmt_gap_ms(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.3f}"


def compact_workload(name: str) -> str:
    return name.replace("chain_js_alexa/", "alexa/").replace("fn_py_", "py_").replace("fn_js_", "js_")


def pivot_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str], dict[str, Any]] = defaultdict(dict)
    for row in rows:
        key = (str(row["workload"]), str(row["mode"]))
        out = grouped[key]
        out["workload"] = key[0]
        out["mode"] = key[1]
        out["samples"] = max(int(out.get("samples", 0)), int(row.get("samples", 0)))
        out["e2e_s"] = float(row["e2e_mean_s"])
        if row.get("included_in_stage_sum"):
            out["gap_ms"] = float(row.get("stage_sum_gap_s") or 0.0) * 1000.0
        column = STAGE_TO_COLUMN.get(str(row["stage"]))
        if column:
            out[column] = out.get(column, 0.0) + float(row["stage_mean_s"]) * 1000.0

    return sorted(
        grouped.values(),
        key=lambda row: (
            row["workload"],
            MODE_ORDER.get(row["mode"], 99),
            row["mode"],
        ),
    )


def table_matrix(rows: list[dict[str, Any]]) -> tuple[list[str], list[list[str]]]:
    headers = ["Workload", "Mode", "n", "E2E\ns"]
    headers.extend(label for _, label in STAGE_COLUMNS)
    headers.append("Stage gap\nms")

    matrix: list[list[str]] = []
    for row in rows:
        line = [
            compact_workload(str(row["workload"])),
            MODE_LABELS.get(str(row["mode"]), str(row["mode"])),
            str(row.get("samples", "-")),
            fmt_s(row.get("e2e_s")),
        ]
        line.extend(fmt_ms(row.get(key)) for key, _ in STAGE_COLUMNS)
        line.append(fmt_gap_ms(row.get("gap_ms")))
        matrix.append(line)
    return headers, matrix


def render_table(headers: list[str], matrix: list[list[str]], out: Path, title: str) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    nrows = len(matrix) + 1
    ncols = len(headers)
    fig_width = max(14.0, ncols * 1.05)
    fig_height = max(2.4, 1.4 + nrows * 0.42)

    fig, ax = plt.subplots(figsize=(fig_width, fig_height))
    ax.axis("off")
    ax.set_title(title, fontsize=15, fontweight="bold", pad=14)

    table = ax.table(
        cellText=matrix,
        colLabels=headers,
        loc="center",
        cellLoc="right",
        colLoc="center",
        colWidths=column_widths(len(headers)),
    )
    table.auto_set_font_size(False)
    table.set_fontsize(8.8)
    table.scale(1.0, 1.35)

    for (row, col), cell in table.get_celld().items():
        cell.set_edgecolor("#c9ced6")
        cell.set_linewidth(0.6)
        if row == 0:
            cell.set_facecolor("#25313f")
            cell.set_text_props(color="white", weight="bold", ha="center")
        else:
            cell.set_facecolor("#f7f8fa" if row % 2 == 0 else "white")
            if col in (0, 1):
                cell.set_text_props(ha="left")
            else:
                cell.set_text_props(ha="right")

    fig.tight_layout()
    fig.savefig(out, dpi=220, bbox_inches="tight")
    plt.close(fig)


def default_output_path(input_path: Path, out_dir: Path) -> Path:
    parent = input_path.parent.name
    if parent:
        filename = f"{parent}-stage-breakdown-table.png"
    else:
        filename = "stage-breakdown-table.png"
    return out_dir / filename


def column_widths(ncols: int) -> list[float]:
    weights = [1.55, 1.45, 0.45, 0.70]
    weights.extend([0.92] * len(STAGE_COLUMNS))
    weights.append(0.75)
    if len(weights) != ncols:
        weights = [1.0] * ncols
    total = sum(weights)
    return [weight / total for weight in weights]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="stage-breakdown.json from cofunc_e2e_stage_breakdown.py")
    parser.add_argument("--out", type=Path, help="Output image path, e.g. table.png or table.pdf")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_IMAGE_DIR,
        help=f"Output directory when --out is omitted. Default: {DEFAULT_IMAGE_DIR}",
    )
    parser.add_argument("--title", default="E2E Stage Breakdown", help="Table title")
    args = parser.parse_args()

    out = args.out if args.out else default_output_path(args.input, args.out_dir)
    rows = pivot_rows(load_rows(args.input))
    headers, matrix = table_matrix(rows)
    render_table(headers, matrix, out, args.title)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
