#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


DEFAULT_COFUNC_SUMMARY = Path(
    "/mnt/new_disk/cofunc_tdx_artifact/results/"
    "oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_20260629_020731/"
    "tdx_sc_fork_summary.txt"
)
DEFAULT_EXPECTED = Path(
    "/mnt/new_disk/cofunc_tdx_artifact/results/"
    "tdx_fig11_20260622_053741/fig11_expected.txt"
)

WORKLOADS = [
    ("fn_py_face_detection", "face (py)", "face\n(py)"),
    ("fn_py_image_processing", "image (py)", "image\n(py)"),
    ("fn_py_sentiment", "sentiment (py)", "sentiment\n(py)"),
    ("fn_py_video_processing", "video (py)", "video\n(py)"),
    ("fn_py_compression", "compress (py)", "compress\n(py)"),
    ("fn_py_dna_visualisation", "dna (py)", "dna\n(py)"),
    ("fn_js_uploader", "upload (js)", "upload\n(js)"),
    ("fn_js_thumbnailer", "thumbnail (js)", "thumbnail\n(js)"),
    ("chain_js_alexa", "alexa (js)", "alexa\n(js)"),
]


@dataclass(frozen=True)
class ExpectedRow:
    cold_s: float
    native_s: float
    cofunc_huge_s: float


@dataclass(frozen=True)
class SummaryRow:
    cofunc_s: float
    artifact_c_s: float


def is_workload(name: str) -> bool:
    return name.startswith("fn_") or name.startswith("chain_")


def parse_expected(path: Path) -> dict[str, ExpectedRow]:
    rows: dict[str, ExpectedRow] = {}
    for line in path.read_text().splitlines():
        cols = line.split()
        if len(cols) >= 4 and is_workload(cols[0]):
            rows[cols[0]] = ExpectedRow(
                cold_s=float(cols[1]),
                native_s=float(cols[2]),
                cofunc_huge_s=float(cols[3]),
            )
    if not rows:
        raise RuntimeError(f"no workload rows found in {path}")
    return rows


def parse_cofunc_summary(path: Path) -> dict[str, SummaryRow]:
    rows: dict[str, SummaryRow] = {}
    for line in path.read_text().splitlines():
        cols = line.split()
        if len(cols) >= 3 and is_workload(cols[0]):
            rows[cols[0]] = SummaryRow(
                cofunc_s=float(cols[1]),
                artifact_c_s=float(cols[2]),
            )
    if not rows:
        raise RuntimeError(f"no measured CoFunc rows found in {path}")
    return rows


def build_rows(
    expected: dict[str, ExpectedRow], measured: dict[str, SummaryRow]
) -> list[dict[str, float | str]]:
    label_by_name = {name: label for name, label, _ in WORKLOADS}
    plot_label_by_name = {name: label for name, _, label in WORKLOADS}
    names = [name for name, _, _ in WORKLOADS if name in measured]
    names.extend(sorted(name for name in measured if name not in label_by_name))

    rows: list[dict[str, float | str]] = []
    missing_expected = []
    for name in names:
        if name not in expected:
            missing_expected.append(name)
            continue
        exp = expected[name]
        got = measured[name]
        cofunc_huge_s = exp.cofunc_huge_s
        cofunc_s = got.cofunc_s
        native_s = exp.native_s
        cold_s = exp.cold_s
        row = {
            "workload": name,
            "label": label_by_name.get(name, name.replace("_", " ")),
            "plot_label": plot_label_by_name.get(name, name.replace("_", "\n")),
            "cofunc_s": cofunc_s,
            "cofunc_huge_s": cofunc_huge_s,
            "native_s": native_s,
            "cold_s": cold_s,
            "artifact_c_from_summary_s": got.artifact_c_s,
            "cofunc_minus_cofunc_huge_s": cofunc_s - cofunc_huge_s,
            "cofunc_minus_native_s": cofunc_s - native_s,
            "cofunc_minus_cold_s": cofunc_s - cold_s,
            "abs_cofunc_minus_cofunc_huge_s": abs(cofunc_s - cofunc_huge_s),
            "abs_cofunc_minus_native_s": abs(cofunc_s - native_s),
            "abs_cofunc_minus_cold_s": abs(cofunc_s - cold_s),
            "cofunc_over_cofunc_huge": cofunc_s / cofunc_huge_s,
            "cofunc_over_native": cofunc_s / native_s,
            "cofunc_over_cold": cofunc_s / cold_s,
        }
        rows.append(row)

    if missing_expected:
        missing_s = ", ".join(missing_expected)
        raise RuntimeError(f"missing expected K/N/C rows for: {missing_s}")
    return rows


def write_csv(rows: list[dict[str, float | str]], path: Path) -> None:
    fieldnames = [
        "workload",
        "label",
        "cofunc_s",
        "cofunc_huge_s",
        "native_s",
        "cold_s",
        "artifact_c_from_summary_s",
        "cofunc_minus_cofunc_huge_s",
        "cofunc_minus_native_s",
        "cofunc_minus_cold_s",
        "abs_cofunc_minus_cofunc_huge_s",
        "abs_cofunc_minus_native_s",
        "abs_cofunc_minus_cold_s",
        "cofunc_over_cofunc_huge",
        "cofunc_over_native",
        "cofunc_over_cold",
    ]
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    key: f"{value:.6f}" if isinstance(value, float) else value
                    for key, value in row.items()
                    if key in fieldnames
                }
            )


def write_summary(
    rows: list[dict[str, float | str]],
    path: Path,
    run_name: str,
    cofunc_summary: Path,
    expected: Path,
) -> None:
    gap_rows = sorted(
        rows,
        key=lambda row: float(row["abs_cofunc_minus_cofunc_huge_s"]),
        reverse=True,
    )
    cold_rows = sorted(
        rows,
        key=lambda row: float(row["cofunc_minus_cold_s"]),
        reverse=True,
    )
    mean_ratio = float(np.mean([float(row["cofunc_over_cofunc_huge"]) for row in rows]))
    mean_gap = float(np.mean([float(row["cofunc_minus_cofunc_huge_s"]) for row in rows]))

    lines = [
        "Absolute E2E mode comparison",
        "============================",
        "",
        f"Run: {run_name}",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        f"Measured cofunc source: {cofunc_summary}",
        f"Expected K/N/C source: {expected}",
        "",
        "Mode mapping:",
        "- cofunc = measured TDX_CoFunc_fork(s) from the selected summary",
        "- cofunc_huge = artifact/paper CoFunc target C / Artifact_C(s)",
        "- native = artifact/paper Native target N",
        "- cold = artifact/paper Kata-CVM/cold target K",
        "",
        f"Mean measured cofunc / cofunc_huge ratio: {mean_ratio:.3f}x",
        f"Mean measured cofunc - cofunc_huge gap: {mean_gap:.3f} s",
        "",
        "Largest absolute cofunc - cofunc_huge gaps:",
    ]
    for row in gap_rows[:5]:
        lines.append(
            f"- {row['workload']}: {float(row['cofunc_minus_cofunc_huge_s']):+.3f} s "
            f"({float(row['cofunc_s']):.3f} vs {float(row['cofunc_huge_s']):.3f})"
        )

    lines.extend(["", "Measured cofunc vs cold/Kata-CVM:"])
    for row in cold_rows:
        delta = float(row["cofunc_minus_cold_s"])
        direction = "slower" if delta > 0 else "faster"
        lines.append(f"- {row['workload']}: {abs(delta):.3f} s {direction}")

    path.write_text("\n".join(lines) + "\n")


def values(rows: list[dict[str, float | str]], column: str) -> list[float]:
    return [float(row[column]) for row in rows]


def labels(rows: list[dict[str, float | str]]) -> list[str]:
    return [str(row["plot_label"]) for row in rows]


def save_all(fig: plt.Figure, stem: Path) -> None:
    fig.savefig(stem.with_suffix(".png"), dpi=220)
    fig.savefig(stem.with_suffix(".pdf"))
    plt.close(fig)


def plot_absolute_modes(rows: list[dict[str, float | str]], path: Path, run_name: str) -> None:
    x = np.arange(len(rows))
    width = 0.19
    series = [
        ("cofunc", "cofunc_s", "#c44e52"),
        ("cofunc_huge", "cofunc_huge_s", "#4c72b0"),
        ("native", "native_s", "#55a868"),
        ("cold", "cold_s", "#8172b3"),
    ]

    fig, ax = plt.subplots(figsize=(12.8, 6.4), constrained_layout=True)
    offsets = np.linspace(-1.5 * width, 1.5 * width, len(series))
    for offset, (name, column, color) in zip(offsets, series):
        ax.bar(x + offset, values(rows, column), width, label=name, color=color)

    ax.set_title(f"Absolute E2E latency by mode: {run_name}")
    ax.set_ylabel("seconds (log scale)")
    ax.set_yscale("log")
    ax.set_xticks(x)
    ax.set_xticklabels(labels(rows))
    ax.grid(axis="y", which="both", linestyle=":", alpha=0.45)
    ax.legend(ncol=4, loc="upper left")
    ax.margins(x=0.02)
    save_all(fig, path)


def plot_deltas(rows: list[dict[str, float | str]], path: Path, run_name: str) -> None:
    x = np.arange(len(rows))
    width = 0.24
    series = [
        ("cofunc - cofunc_huge", "cofunc_minus_cofunc_huge_s", "#4c72b0"),
        ("cofunc - native", "cofunc_minus_native_s", "#55a868"),
        ("cofunc - cold", "cofunc_minus_cold_s", "#8172b3"),
    ]

    fig, ax = plt.subplots(figsize=(12.8, 6.4), constrained_layout=True)
    offsets = np.linspace(-width, width, len(series))
    for offset, (name, column, color) in zip(offsets, series):
        ax.bar(x + offset, values(rows, column), width, label=name, color=color)

    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_title(f"Absolute E2E differences from measured cofunc: {run_name}")
    ax.set_ylabel("seconds; positive means measured cofunc is slower")
    ax.set_xticks(x)
    ax.set_xticklabels(labels(rows))
    ax.grid(axis="y", linestyle=":", alpha=0.45)
    ax.legend(ncol=3, loc="upper left")
    ax.margins(x=0.02)
    save_all(fig, path)


def default_out_dir() -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    return Path("/home/booklyn/cofunc-tdx/reports") / f"e2e_absolute_modes_{stamp}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Plot absolute E2E CoFunc/native/cold mode comparisons."
    )
    parser.add_argument("--cofunc-summary", type=Path, default=DEFAULT_COFUNC_SUMMARY)
    parser.add_argument("--expected", type=Path, default=DEFAULT_EXPECTED)
    parser.add_argument("--out-dir", type=Path, default=None)
    parser.add_argument("--run-name", default="measured CoFunc")
    args = parser.parse_args()

    out_dir = args.out_dir or default_out_dir()
    out_dir.mkdir(parents=True, exist_ok=True)

    expected = parse_expected(args.expected)
    measured = parse_cofunc_summary(args.cofunc_summary)
    rows = build_rows(expected, measured)

    write_csv(rows, out_dir / "absolute_e2e_modes.csv")
    write_summary(
        rows,
        out_dir / "summary.txt",
        args.run_name,
        args.cofunc_summary,
        args.expected,
    )
    plot_absolute_modes(rows, out_dir / "absolute_e2e_modes", args.run_name)
    plot_deltas(rows, out_dir / "absolute_e2e_deltas", args.run_name)

    print(f"Wrote report to {out_dir}")
    print(f"Rows: {len(rows)}")
    print(f"CSV: {out_dir / 'absolute_e2e_modes.csv'}")
    print(f"Graphs: {out_dir / 'absolute_e2e_modes.png'}, {out_dir / 'absolute_e2e_deltas.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
