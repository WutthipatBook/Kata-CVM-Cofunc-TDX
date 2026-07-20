#!/usr/bin/env python3
"""Summarize CoFunc/native/cold E2E logs into comparable stage rows."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path
from typing import Any, Iterable


LOG_NAMES = {
    "cofunc-fork": "sc_fork.log",
    "native-fork": "lean_fork.log",
    "native-launch": "lean_launch.log",
    "cold-observed": "kata_launch.log",
    "sc-launch": "sc_launch.log",
}

MODE_ORDER = {
    "cofunc-fork": 0,
    "native-fork": 1,
    "native-launch": 2,
    "cold-observed": 3,
    "cold-artifact-equivalent": 4,
}

KIND_ORDER = {
    "stage": 0,
    "artifact_add_on": 1,
    "runtime_add_on": 1,
    "handler_substage": 2,
}

STAGE_ORDER = {
    "host_container_setup": 0,
    "native_setup": 0,
    "vm_container_boot": 0,
    "cvm_instance_setup": 1,
    "setup_plus_function_loading": 1,
    "function_loading": 2,
    "handler_execution": 3,
    "measurement_encryption_attestation": 4,
    "handler_grant_accept": 10,
    "handler_encrypt": 11,
    "handler_delegate": 12,
    "import_attest": 13,
}


def load_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


def mean(values: Iterable[float]) -> float | None:
    vals = list(values)
    if not vals:
        return None
    return statistics.mean(vals)


def stdev(values: Iterable[float]) -> float:
    vals = list(values)
    if len(vals) < 2:
        return 0.0
    return statistics.stdev(vals)


def fmt_s(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.6f}"


def fmt_ms(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 1000.0:.3f}"


def fmt_pct(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}"


def discover_workloads(log_root: Path) -> list[str]:
    workloads: set[str] = set()
    for log_name in LOG_NAMES.values():
        for path in log_root.rglob(log_name):
            workloads.add(path.parent.relative_to(log_root).as_posix())
    return sorted(workloads)


def stage_values(mode: str, row: dict[str, Any]) -> list[tuple[str, float, str, bool]]:
    if mode == "cofunc-fork":
        stages = [
            ("host_container_setup", row.get("t_boot_lean"), "stage", True),
            ("cvm_instance_setup", row.get("t_boot_sc"), "stage", True),
            ("function_loading", row.get("t_boot_func"), "stage", True),
            ("handler_execution", row.get("t_exec"), "stage", True),
            ("handler_grant_accept", row.get("t_grant_exec"), "handler_substage", False),
            ("handler_encrypt", row.get("t_encrypt_exec"), "handler_substage", False),
            ("handler_delegate", row.get("t_delegate_exec"), "handler_substage", False),
        ]
    elif mode in {"native-fork", "native-launch"}:
        if all(key in row for key in ("t_setup", "t_func_load", "t_handler")):
            stages = [
                ("native_setup", row.get("t_setup"), "stage", True),
                ("function_loading", row.get("t_func_load"), "stage", True),
                ("handler_execution", row.get("t_handler"), "stage", True),
            ]
        else:
            stages = [
                ("setup_plus_function_loading", row.get("t_boot"), "stage", True),
                ("handler_execution", row.get("t_exec"), "stage", True),
            ]
    elif mode == "cold-observed":
        stages = [
            ("vm_container_boot", row.get("t_boot_cntr"), "stage", True),
            ("function_loading", row.get("t_boot_func"), "stage", True),
            ("handler_execution", row.get("t_exec"), "stage", True),
        ]
    elif mode == "sc-launch":
        stages = [
            ("setup_plus_function_loading", row.get("t_boot"), "stage", True),
            ("handler_execution", row.get("t_exec"), "stage", True),
            ("handler_grant_accept", row.get("t_grant_exec"), "handler_substage", False),
            ("handler_encrypt", row.get("t_encrypt_exec"), "handler_substage", False),
            ("handler_delegate", row.get("t_delegate_exec"), "handler_substage", False),
            ("import_attest", row.get("t_attest_import"), "runtime_add_on", False),
        ]
    else:
        stages = []

    return [
        (name, float(value), kind, included)
        for name, value, kind, included in stages
        if value is not None
    ]


def summarize_mode(workload: str, mode: str, path: Path) -> list[dict[str, Any]]:
    rows = load_rows(path)
    if not rows:
        return []

    e2e_values = [float(row["t_e2e"]) for row in rows if "t_e2e" in row]
    e2e_mean = mean(e2e_values)
    if e2e_mean is None:
        return []

    per_stage: dict[tuple[str, str, bool], list[float]] = {}
    gaps: list[float] = []
    for row in rows:
        if "t_e2e" not in row:
            continue
        stages = stage_values(mode, row)
        included_sum = sum(value for _, value, _, included in stages if included)
        gaps.append(float(row["t_e2e"]) - included_sum)
        for name, value, kind, included in stages:
            per_stage.setdefault((name, kind, included), []).append(value)

    gap_mean = mean(gaps)
    result_rows: list[dict[str, Any]] = []
    for (stage, kind, included), values in sorted(per_stage.items()):
        stage_mean = mean(values)
        pct = None if stage_mean is None else stage_mean / e2e_mean * 100.0
        result_rows.append(
            {
                "workload": workload,
                "mode": mode,
                "stage": stage,
                "kind": kind,
                "included_in_stage_sum": included,
                "samples": len(values),
                "source": str(path),
                "e2e_mean_s": e2e_mean,
                "stage_mean_s": stage_mean,
                "stage_stdev_s": stdev(values),
                "pct_e2e": pct,
                "stage_sum_gap_s": gap_mean,
            }
        )
    return result_rows


def summarize_artifact_cold(workload: str, log_root: Path) -> list[dict[str, Any]]:
    kata_path = log_root / workload / LOG_NAMES["cold-observed"]
    sc_path = log_root / workload / LOG_NAMES["sc-launch"]
    kata_rows = load_rows(kata_path)
    sc_rows = load_rows(sc_path)
    if not kata_rows or not sc_rows:
        return []

    kata_e2e = mean(float(row["t_e2e"]) for row in kata_rows if "t_e2e" in row)
    if kata_e2e is None:
        return []

    security_values = []
    for row in sc_rows:
        if "t_encrypt_exec" in row and "t_attest_import" in row:
            security_values.append(float(row["t_encrypt_exec"]) + float(row["t_attest_import"]))
    security_mean = mean(security_values)
    if security_mean is None:
        return []

    mode = "cold-artifact-equivalent"
    e2e_mean = kata_e2e + security_mean
    stage_specs = [
        ("vm_container_boot", [float(row["t_boot_cntr"]) for row in kata_rows if "t_boot_cntr" in row], "stage", True, kata_path),
        ("function_loading", [float(row["t_boot_func"]) for row in kata_rows if "t_boot_func" in row], "stage", True, kata_path),
        ("handler_execution", [float(row["t_exec"]) for row in kata_rows if "t_exec" in row], "stage", True, kata_path),
        ("measurement_encryption_attestation", security_values, "artifact_add_on", True, sc_path),
    ]
    stage_sum = sum(mean(values) or 0.0 for _, values, _, included, _ in stage_specs if included)
    gap = e2e_mean - stage_sum
    result_rows: list[dict[str, Any]] = []
    for stage, values, kind, included, source in stage_specs:
        if not values:
            continue
        stage_mean = mean(values)
        pct = None if stage_mean is None else stage_mean / e2e_mean * 100.0
        result_rows.append(
            {
                "workload": workload,
                "mode": mode,
                "stage": stage,
                "kind": kind,
                "included_in_stage_sum": included,
                "samples": len(values),
                "source": str(source),
                "e2e_mean_s": e2e_mean,
                "stage_mean_s": stage_mean,
                "stage_stdev_s": stdev(values),
                "pct_e2e": pct,
                "stage_sum_gap_s": gap,
            }
        )
    return result_rows


def build_rows(log_root: Path, workloads: list[str]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for workload in workloads:
        for mode, log_name in LOG_NAMES.items():
            if mode == "sc-launch":
                continue
            output.extend(summarize_mode(workload, mode, log_root / workload / log_name))
        output.extend(summarize_artifact_cold(workload, log_root))
    return output


def row_sort_key(row: dict[str, Any]) -> tuple[Any, ...]:
    return (
        row["workload"],
        MODE_ORDER.get(row["mode"], 99),
        KIND_ORDER.get(row["kind"], 99),
        STAGE_ORDER.get(row["stage"], 99),
        row["mode"],
        row["stage"],
    )


def make_markdown(log_root: Path, rows: list[dict[str, Any]], max_gap_ms: float) -> str:
    lines = [
        "# E2E Stage Breakdown",
        "",
        f"Log root: `{log_root}`",
        f"Stage-sum tolerance: {max_gap_ms:.3f} ms",
        "",
        "| Workload | Mode | Stage | Kind | Samples | E2E mean s | Stage mean ms | Stdev ms | % E2E | Sum gap ms |",
        "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            "| {workload} | {mode} | {stage} | {kind} | {samples} | {e2e} | {mean_ms} | {stdev_ms} | {pct} | {gap_ms} |".format(
                workload=row["workload"],
                mode=row["mode"],
                stage=row["stage"],
                kind=row["kind"],
                samples=row["samples"],
                e2e=fmt_s(row["e2e_mean_s"]),
                mean_ms=fmt_ms(row["stage_mean_s"]),
                stdev_ms=fmt_ms(row["stage_stdev_s"]),
                pct=fmt_pct(row["pct_e2e"]),
                gap_ms=fmt_ms(row["stage_sum_gap_s"]),
            )
        )
    return "\n".join(lines) + "\n"


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "workload",
        "mode",
        "stage",
        "kind",
        "included_in_stage_sum",
        "samples",
        "e2e_mean_s",
        "stage_mean_s",
        "stage_stdev_s",
        "pct_e2e",
        "stage_sum_gap_s",
        "source",
    ]
    with path.open("w", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: row.get(field) for field in fields})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-root", type=Path, required=True, help="Directory containing workload log subdirectories.")
    parser.add_argument("--workloads", nargs="*", help="Workload paths relative to --log-root. Defaults to discovery.")
    parser.add_argument("--markdown", type=Path, help="Write Markdown output.")
    parser.add_argument("--csv", type=Path, help="Write CSV output.")
    parser.add_argument("--json", type=Path, help="Write JSON output.")
    parser.add_argument("--max-gap-ms", type=float, default=1.0, help="Stage-sum tolerance shown in Markdown.")
    args = parser.parse_args()

    log_root = args.log_root
    workloads = args.workloads if args.workloads else discover_workloads(log_root)
    rows = build_rows(log_root, workloads)
    if not rows:
        raise SystemExit(
            "no stage rows found. Use --log-root pointing at a run log directory "
            "that directly contains workload subdirectories, for example "
            "/mnt/new_disk/cofunc_tdx_artifact/results/<run-name>/log"
        )
    rows.sort(key=row_sort_key)

    markdown = make_markdown(log_root, rows, args.max_gap_ms)
    print(markdown, end="")

    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown)
    if args.csv:
        write_csv(args.csv, rows)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({"log_root": str(log_root), "rows": rows}, indent=2, sort_keys=True) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
