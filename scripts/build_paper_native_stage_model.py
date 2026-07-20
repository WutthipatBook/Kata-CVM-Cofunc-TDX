#!/usr/bin/env python3
"""Build the artifact's modeled Native-fork stages for JavaScript workloads."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
from pathlib import Path
from typing import Any


LATENCY_RE = re.compile(r"^latency\s+([0-9.eE+-]+)\s*$")


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


def parse_cow_latency_ns(path: Path) -> tuple[float, int]:
    values = []
    for line in path.read_text().splitlines():
        match = LATENCY_RE.match(line.strip())
        if match:
            values.append(float(match.group(1)))
    if not values:
        raise SystemExit(f"no 'latency <ns>' record in CoW evidence: {path}")
    latency = statistics.mean(values)
    if not 0.0 < latency < 1_000_000.0:
        raise SystemExit(f"implausible per-page CoW latency: {latency} ns")
    return latency, len(values)


def included_rows(
    rows: list[dict[str, Any]], workload: str, mode: str
) -> list[dict[str, Any]]:
    selected = [
        row
        for row in rows
        if row.get("workload") == workload
        and row.get("mode") == mode
        and row.get("included_in_stage_sum")
    ]
    if not selected:
        raise SystemExit(f"missing {mode} stages for {workload}")
    return selected


def one_stage(rows: list[dict[str, Any]], stage: str) -> dict[str, Any]:
    selected = [row for row in rows if row.get("stage") == stage]
    if len(selected) != 1:
        raise SystemExit(f"expected one {stage} row, found {len(selected)}")
    return selected[0]


def read_n_cow(source: Path) -> tuple[float, int]:
    values = []
    with source.open() as file:
        for line_number, line in enumerate(file, 1):
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"invalid JSON at {source}:{line_number}: {error}")
            value = record.get("n_cow")
            if not isinstance(value, (int, float)):
                raise SystemExit(f"missing numeric n_cow at {source}:{line_number}")
            values.append(float(value))
    if not values:
        raise SystemExit(f"empty CoFunc log: {source}")
    return statistics.mean(values), len(values)


def modeled_row(
    *,
    workload: str,
    stage: str,
    value: float,
    e2e: float,
    samples: int,
    source: str,
) -> dict[str, Any]:
    return {
        "e2e_mean_s": e2e,
        "included_in_stage_sum": True,
        "kind": "modeled_stage",
        "mode": "native-fork-model",
        "pct_e2e": value / e2e * 100.0,
        "samples": samples,
        "source": source,
        "stage": stage,
        "stage_mean_s": value,
        "stage_stdev_s": None,
        "stage_sum_gap_s": 0.0,
        "workload": workload,
    }


def build(
    native_path: Path,
    cofunc_path: Path,
    cow_evidence: Path,
) -> dict[str, Any]:
    native_rows = load_rows(native_path)
    cofunc_rows = load_rows(cofunc_path)
    cow_latency_ns, cow_latency_samples = parse_cow_latency_ns(cow_evidence)
    cow_latency_s = cow_latency_ns * 1e-9
    workloads = sorted(
        {
            str(row["workload"])
            for row in native_rows
            if row.get("mode") == "native-launch"
        }
    )
    modeled: list[dict[str, Any]] = []
    details = []

    for workload in workloads:
        native = included_rows(native_rows, workload, "native-launch")
        cofunc = included_rows(cofunc_rows, workload, "cofunc-fork")
        native_exec = one_stage(native, "handler_execution")
        boot_lean = one_stage(cofunc, "host_container_setup")
        boot_func = one_stage(cofunc, "function_loading")
        source = Path(str(boot_lean["source"]))
        mean_n_cow, source_samples = read_n_cow(source)
        expected_samples = int(boot_lean["samples"])
        if source_samples != expected_samples:
            raise SystemExit(
                f"CoFunc sample mismatch for {workload}: "
                f"stage={expected_samples} source={source_samples}"
            )
        stages = {
            "native_setup": float(boot_lean["stage_mean_s"]),
            "function_loading": float(boot_func["stage_mean_s"]),
            "handler_execution": float(native_exec["stage_mean_s"]),
            "copy_on_write": mean_n_cow * cow_latency_s,
        }
        e2e = sum(stages.values())
        source_text = (
            f"artifact JS Native model; cofunc={source}; "
            f"native={native_exec['source']}; cow={cow_evidence}"
        )
        for stage, value in stages.items():
            modeled.append(
                modeled_row(
                    workload=workload,
                    stage=stage,
                    value=value,
                    e2e=e2e,
                    samples=expected_samples,
                    source=source_text,
                )
            )
        details.append(
            {
                "workload": workload,
                "mean_n_cow": mean_n_cow,
                "cow_overhead_s": stages["copy_on_write"],
                "modeled_e2e_s": e2e,
            }
        )

    return {
        "inputs": {
            "native": {"path": str(native_path), "sha256": sha256(native_path)},
            "cofunc": {"path": str(cofunc_path), "sha256": sha256(cofunc_path)},
            "cow_evidence": {
                "path": str(cow_evidence),
                "sha256": sha256(cow_evidence),
                "latency_ns_per_page": cow_latency_ns,
                "latency_records": cow_latency_samples,
            },
        },
        "model": (
            "For JavaScript only: CoFunc t_boot_lean + CoFunc t_boot_func + "
            "Native launch t_exec + CoFunc n_cow * measured Linux CoW latency"
        ),
        "model_details": details,
        "rows": native_rows + modeled,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--cofunc", type=Path, required=True)
    parser.add_argument("--cow-evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite: {args.output}")
    result = build(args.native, args.cofunc, args.cow_evidence)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"output={args.output}")
    print(f"modeled_workloads={len(result['model_details'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
