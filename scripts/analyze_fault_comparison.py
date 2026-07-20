#!/usr/bin/env python3
"""Analyze paired Native/Kata process faults and Kata EPT service times."""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from pathlib import Path
from typing import Any


PROCESS_METRICS = (
    "t_exec",
    "t_cpu_exec",
    "t_network",
    "t_exec_minus_workload_network",
    "n_minflt_exec",
    "n_majflt_exec",
    "n_nvcsw_exec",
    "n_nivcsw_exec",
    "n_inblock_exec",
    "n_oublock_exec",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", required=True)
    parser.add_argument("--native-log", required=True, type=Path)
    parser.add_argument("--kata-log", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--native-minor-fault-proxy-ns",
        type=float,
        default=0,
        help="Optional modeled Linux CoW coefficient; omitted by default",
    )
    return parser.parse_args()


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    rows = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise SystemExit(f"invalid JSON at {path}:{line_number}: {error}")
            missing = [key for key in PROCESS_METRICS if key not in row]
            if missing:
                raise SystemExit(
                    f"missing instrumented metrics at {path}:{line_number}: "
                    + ", ".join(missing)
                )
            rows.append(row)
    if not rows:
        raise SystemExit(f"no analyzer rows: {path}")
    return rows


def parse_markers(path: Path) -> dict[str, float]:
    markers: dict[str, float] = {}
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            fields = line.split()
            if len(fields) == 2 and fields[0].startswith("t_"):
                try:
                    value = float(fields[1])
                except ValueError:
                    continue
                markers[fields[0]] = max(markers.get(fields[0], -math.inf), value)
    for required in ("t_launch_begin", "t_import_done", "t_func_done"):
        if required not in markers:
            raise SystemExit(f"missing {required} marker: {path}")
    return markers


def load_kata_intervals(kata_log: Path, expected: int) -> list[dict[str, Any]]:
    sample_dirs = sorted(kata_log.parent.glob("sample-[0-9][0-9][0-9]"))
    if len(sample_dirs) != expected:
        raise SystemExit(
            f"Kata sample count mismatch: analyzer={expected} dirs={len(sample_dirs)}"
        )

    intervals = []
    for sample_dir in sample_dirs:
        container_log = sample_dir / "container.log"
        markers = parse_markers(container_log)
        affinity_path = sample_dir / "vcpu-affinity.txt"
        affinity = affinity_path.read_text(encoding="utf-8", errors="replace")
        pid_match = re.search(r"^qemu_pid=([1-9][0-9]*)$", affinity, re.MULTILINE)
        if not pid_match:
            raise SystemExit(f"missing QEMU PID in {affinity_path}")
        intervals.append(
            {
                "sample": sample_dir.name,
                "qemu_pid": int(pid_match.group(1)),
                "launch_start": markers["t_launch_begin"],
                "start": markers["t_import_done"],
                "end": markers["t_func_done"],
                "container_log": str(container_log),
            }
        )
    return intervals


def parse_trace(path: Path) -> dict[str, Any]:
    events: dict[str, Any] = {
        "services": [],
        "aggregates": {
            "vm_ept_exits": {},
            "vm_ept_faults": {},
            "vm_service_count": {},
            "vm_service_ns": {},
        },
    }
    unknown_lines = []
    lost_lines = []
    map_pattern = re.compile(
        r"^@(vm_ept_exits|vm_ept_faults|vm_service_count|vm_service_ns)"
        r"\[([1-9][0-9]*)\]:\s*([0-9]+)$"
    )

    with path.open(encoding="utf-8", errors="replace") as stream:
        for line_number, raw_line in enumerate(stream, 1):
            line = raw_line.strip()
            if not line:
                continue
            if "lost" in line.lower():
                lost_lines.append({"line": line_number, "text": line})
            fields = line.split("\t")
            kind = fields[0]
            try:
                if kind == "EPT_SERVICE" and len(fields) == 9:
                    events["services"].append(
                        {
                        "wall_s": float(fields[1]),
                            "exit_nsecs": int(fields[2]),
                            "entry_nsecs": int(fields[3]),
                            "pid": int(fields[4]),
                            "tid": int(fields[5]),
                            "exit_cpu": int(fields[6]),
                            "cpu": int(fields[7]),
                            "duration_ns": int(fields[8]),
                        }
                    )
                elif kind in ("trace_status", "trace_window"):
                    continue
                elif line.startswith("Attaching "):
                    continue
                else:
                    match = map_pattern.match(line)
                    if match:
                        name, pid, value = match.groups()
                        events["aggregates"][name][int(pid)] = int(value)
                    else:
                        unknown_lines.append({"line": line_number, "text": line})
            except (ValueError, IndexError) as error:
                raise SystemExit(f"invalid trace row at {path}:{line_number}: {error}")

    events["unknown_lines"] = unknown_lines
    events["lost_lines"] = lost_lines
    return events


def percentile(values: list[float], quantile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "mean": None,
            "median": None,
            "p95": None,
            "p99": None,
            "min": None,
            "max": None,
            "sum": 0,
        }
    return {
        "count": len(values),
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "min": min(values),
        "max": max(values),
        "sum": sum(values),
    }


def summarize_process(rows: list[dict[str, Any]]) -> dict[str, Any]:
    summary = {key: stats([float(row[key]) for row in rows]) for key in PROCESS_METRICS}
    summary["minor_faults_per_exec_second"] = stats(
        [row["n_minflt_exec"] / row["t_exec"] for row in rows]
    )
    summary["process_cpu_over_wall"] = stats(
        [row["t_cpu_exec"] / row["t_exec"] for row in rows]
    )
    return summary


def select_interval(
    events: list[dict[str, Any]], start: float, end: float, key: str
) -> list[dict[str, Any]]:
    return [event for event in events if event.get(key) is not None and start <= event[key] <= end]


def analyze_kata_samples(
    rows: list[dict[str, Any]], intervals: list[dict[str, Any]], trace: dict[str, Any]
) -> list[dict[str, Any]]:
    samples = []
    for row, interval in zip(rows, intervals, strict=True):
        qemu_pid = interval["qemu_pid"]
        pid_services = [
            service for service in trace["services"] if service["pid"] == qemu_pid
        ]
        services = select_interval(pid_services, interval["start"], interval["end"], "wall_s")
        durations = [service["duration_ns"] for service in services]
        migrated = sum(
            service["exit_cpu"] != service["cpu"]
            for service in services
        )
        vm_faults = trace["aggregates"]["vm_ept_faults"][qemu_pid]
        boundary_counts = {}
        for label, width in (("1ms", 0.001), ("10ms", 0.010)):
            contracted = select_interval(
                pid_services, interval["start"] + width, interval["end"] - width,
                "wall_s",
            )
            expanded = select_interval(
                pid_services, interval["start"] - width, interval["end"] + width,
                "wall_s",
            )
            boundary_counts[label] = {
                "contracted_fault_count": len(contracted),
                "expanded_fault_count": len(expanded),
                "boundary_sensitive_fault_count": len(expanded) - len(contracted),
            }
        samples.append(
            {
                **interval,
                **{key: row[key] for key in PROCESS_METRICS},
                "ept_vm_lifetime_fault_count": vm_faults,
                "ept_non_handler_fault_count": vm_faults - len(services),
                "ept_fault_count": len(services),
                "ept_faults_per_exec_second": len(services) / row["t_exec"],
                "ept_service_ns": stats(durations),
                "ept_service_sum_over_wall": sum(durations) / 1e9 / row["t_exec"],
                "ept_vm_lifetime_service_sum_ns": trace["aggregates"]["vm_service_ns"][qemu_pid],
                "ept_reentry_cpu_migrations": migrated,
                "ept_host_pids": [qemu_pid],
                "ept_vcpu_tids": sorted({event["tid"] for event in services}),
                "ept_boundary_sensitivity": boundary_counts,
            }
        )
    return samples


def fmt(value: Any, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, int):
        return str(value)
    return f"{value:.{digits}f}"


def render_markdown(result: dict[str, Any]) -> str:
    native = result["native_summary"]
    kata = result["kata_summary"]
    ept = result["kata_ept_summary"]
    lines = [
        f"# Fault comparison: `{result['workload']}`",
        "",
        "## Process-level faults",
        "",
        "| Metric | Native | Kata guest |",
        "| --- | ---: | ---: |",
        f"| samples | {result['native_samples']} | {result['kata_samples']} |",
        f"| mean `t_exec` | {fmt(native['t_exec']['mean'], 6)} s | {fmt(kata['t_exec']['mean'], 6)} s |",
        f"| mean process CPU | {fmt(native['t_cpu_exec']['mean'], 6)} s | {fmt(kata['t_cpu_exec']['mean'], 6)} s |",
        f"| mean minor faults | {fmt(native['n_minflt_exec']['mean'], 2)} | {fmt(kata['n_minflt_exec']['mean'], 2)} |",
        f"| mean major faults | {fmt(native['n_majflt_exec']['mean'], 2)} | {fmt(kata['n_majflt_exec']['mean'], 2)} |",
        f"| mean minor faults/s | {fmt(native['minor_faults_per_exec_second']['mean'], 2)} | {fmt(kata['minor_faults_per_exec_second']['mean'], 2)} |",
        f"| mean workload network | {fmt(native['t_network']['mean'], 6)} s | {fmt(kata['t_network']['mean'], 6)} s |",
        f"| mean `t_exec` minus workload network | {fmt(native['t_exec_minus_workload_network']['mean'], 6)} s | {fmt(kata['t_exec_minus_workload_network']['mean'], 6)} s |",
        "",
        "Native second-level faults are `N/A`: Native has no EPT/SEPT layer.",
        "",
        "## Kata EPT/SEPT violations",
        "",
        f"- Mean faults per traced VM lifetime: {fmt(ept['vm_lifetime_fault_count']['mean'], 2)}",
        f"- Mean summed EPT service per traced VM lifetime: {fmt(ept['vm_lifetime_service_sum_ns']['mean'] / 1e9 if ept['vm_lifetime_service_sum_ns']['mean'] is not None else None, 6)} s",
        f"- Aggregate VM-lifetime exit-to-reentry mean: {fmt(ept['vm_lifetime_mean_service_ns'], 2)} ns",
        f"- Mean faults outside handler execution: {fmt(ept['non_handler_fault_count']['mean'], 2)}",
        f"- Mean faults during handler execution: {fmt(ept['fault_count']['mean'], 2)}",
        f"- Mean handler faults per second: {fmt(ept['faults_per_second']['mean'], 2)}",
        f"- Handler-window exit-to-reentry mean: {fmt(ept['service_ns']['mean'], 2)} ns",
        f"- Handler-window exit-to-reentry median: {fmt(ept['service_ns']['median'], 2)} ns",
        f"- Handler-window exit-to-reentry p95: {fmt(ept['service_ns']['p95'], 2)} ns",
        f"- Handler-window exit-to-reentry p99: {fmt(ept['service_ns']['p99'], 2)} ns",
        f"- Handler-window exit-to-reentry maximum: {fmt(ept['service_ns']['max'], 2)} ns",
        f"- Mean summed EPT service / `t_exec`: {fmt(ept['service_sum_over_wall']['mean'] * 100 if ept['service_sum_over_wall']['mean'] is not None else None, 4)}%",
        f"- Exit/reentry CPU migrations: {ept['cpu_migrations']}",
        f"- Host QEMU PIDs in measured intervals: {', '.join(map(str, ept['host_pids'])) or 'none'}",
        f"- Host vCPU TIDs in measured intervals: {', '.join(map(str, ept['vcpu_tids'])) or 'none'}",
        f"- Boundary-sensitive faults at 1 ms: {ept['boundary_sensitive_faults_1ms']}",
        f"- Boundary-sensitive faults at 10 ms: {ept['boundary_sensitive_faults_10ms']}",
        "",
        "Both VM-lifetime and handler-window exit-to-reentry intervals include",
        "KVM/TDX handling, tracing overhead,",
        "and any host scheduling delay before that vCPU re-enters the TD. It is an",
        "observed service-time distribution, not an instruction-level SEAMCALL cost.",
        "Events are VM-wide KVM tracepoints selected by each sample's handler wall-time",
        "interval. The single-vCPU pin, safety gates, PID/TID sets, and boundary",
        "sensitivity counts are the attribution controls; this is not guest-process",
        "address-space attribution by the host.",
        "",
        "## Integrity checks",
        "",
        f"- Aggregate EPT exits: {result['trace_totals']['exits']}",
        f"- Aggregate KVM page faults: {result['trace_totals']['faults']}",
        f"- Aggregate paired EPT reentries: {result['trace_totals']['services']}",
        f"- Gated service records (before wall-time filtering): {result['trace_totals']['gated_service_records']}",
        f"- Unpaired exits: {result['trace_totals']['unpaired_exits']}",
        f"- Trace loss markers: {result['trace_totals']['loss_markers']}",
        f"- Unparsed trace lines: {result['trace_totals']['unknown_lines']}",
        "",
    ]
    if result.get("native_minor_fault_proxy"):
        proxy = result["native_minor_fault_proxy"]
        lines.extend(
            [
                "## Native minor-fault proxy",
                "",
                f"Using the artifact's {proxy['coefficient_ns']:.6f} ns/page Linux CoW microbenchmark coefficient,",
                f"the mean Native minor-fault proxy is {proxy['mean_total_ns']:.2f} ns.",
                "This is not a measured workload fault-service time: `ru_minflt` includes",
                "minor faults other than CoW, and the coefficient comes from a separate microbenchmark.",
                "",
            ]
        )
    return "\n".join(lines)


def main() -> None:
    args = parse_args()
    native_rows = load_json_lines(args.native_log)
    kata_rows = load_json_lines(args.kata_log)
    intervals = load_kata_intervals(args.kata_log, len(kata_rows))
    trace = parse_trace(args.trace)
    if trace["lost_lines"]:
        raise SystemExit("trace contains event-loss markers; refusing analysis")
    if trace["unknown_lines"]:
        raise SystemExit("trace contains unparsed output; refusing analysis")
    expected_pids = {interval["qemu_pid"] for interval in intervals}
    for name, values in trace["aggregates"].items():
        if set(values) != expected_pids:
            raise SystemExit(
                f"aggregate PID mismatch for {name}: {sorted(values)} != {sorted(expected_pids)}"
            )
    for pid in expected_pids:
        exits = trace["aggregates"]["vm_ept_exits"][pid]
        faults = trace["aggregates"]["vm_ept_faults"][pid]
        services = trace["aggregates"]["vm_service_count"][pid]
        if exits != faults or exits != services:
            raise SystemExit(
                f"unpaired EPT lifecycle for QEMU PID {pid}: "
                f"exits={exits} faults={faults} services={services}"
            )
    kata_samples = analyze_kata_samples(kata_rows, intervals, trace)
    vm_lifetime_service_sums = [
        sample["ept_vm_lifetime_service_sum_ns"] for sample in kata_samples
    ]
    vm_lifetime_service_count = sum(
        sample["ept_vm_lifetime_fault_count"] for sample in kata_samples
    )
    vm_lifetime_service_ns = sum(vm_lifetime_service_sums)
    service_durations: list[float] = []
    # Re-select durations so the aggregate contains measured handler intervals only.
    for interval in intervals:
        services = select_interval(
            trace["services"], interval["start"], interval["end"], "wall_s"
        )
        service_durations.extend(service["duration_ns"] for service in services)

    result: dict[str, Any] = {
        "workload": args.workload,
        "native_log": str(args.native_log),
        "kata_log": str(args.kata_log),
        "trace": str(args.trace),
        "native_samples": len(native_rows),
        "kata_samples": len(kata_rows),
        "native_summary": summarize_process(native_rows),
        "kata_summary": summarize_process(kata_rows),
        "kata_sample_details": kata_samples,
        "kata_ept_summary": {
            "vm_lifetime_fault_count": stats(
                [sample["ept_vm_lifetime_fault_count"] for sample in kata_samples]
            ),
            "vm_lifetime_service_sum_ns": stats(vm_lifetime_service_sums),
            "vm_lifetime_mean_service_ns": (
                vm_lifetime_service_ns / vm_lifetime_service_count
                if vm_lifetime_service_count
                else None
            ),
            "non_handler_fault_count": stats(
                [sample["ept_non_handler_fault_count"] for sample in kata_samples]
            ),
            "fault_count": stats([sample["ept_fault_count"] for sample in kata_samples]),
            "faults_per_second": stats(
                [sample["ept_faults_per_exec_second"] for sample in kata_samples]
            ),
            "service_ns": stats(service_durations),
            "service_sum_over_wall": stats(
                [sample["ept_service_sum_over_wall"] for sample in kata_samples]
            ),
            "cpu_migrations": sum(
                sample["ept_reentry_cpu_migrations"] for sample in kata_samples
            ),
            "host_pids": sorted(
                {pid for sample in kata_samples for pid in sample["ept_host_pids"]}
            ),
            "vcpu_tids": sorted(
                {tid for sample in kata_samples for tid in sample["ept_vcpu_tids"]}
            ),
            "boundary_sensitive_faults_1ms": sum(
                sample["ept_boundary_sensitivity"]["1ms"]["boundary_sensitive_fault_count"]
                for sample in kata_samples
            ),
            "boundary_sensitive_faults_10ms": sum(
                sample["ept_boundary_sensitivity"]["10ms"]["boundary_sensitive_fault_count"]
                for sample in kata_samples
            ),
        },
        "trace_totals": {
            "exits": sum(trace["aggregates"]["vm_ept_exits"].values()),
            "faults": sum(trace["aggregates"]["vm_ept_faults"].values()),
            "services": sum(trace["aggregates"]["vm_service_count"].values()),
            "gated_service_records": len(trace["services"]),
            "unpaired_exits": sum(trace["aggregates"]["vm_ept_exits"].values())
            - sum(trace["aggregates"]["vm_service_count"].values()),
            "loss_markers": len(trace["lost_lines"]),
            "unknown_lines": len(trace["unknown_lines"]),
        },
        "trace_diagnostics": {
            "loss_markers": trace["lost_lines"],
            "unknown_lines": trace["unknown_lines"],
        },
    }

    if args.native_minor_fault_proxy_ns > 0:
        mean_faults = result["native_summary"]["n_minflt_exec"]["mean"]
        result["native_minor_fault_proxy"] = {
            "coefficient_ns": args.native_minor_fault_proxy_ns,
            "mean_total_ns": mean_faults * args.native_minor_fault_proxy_ns,
        }

    args.output_dir.mkdir(parents=True, exist_ok=False)
    json_path = args.output_dir / "fault_comparison.json"
    markdown_path = args.output_dir / "fault_comparison.md"
    json_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(render_markdown(result), encoding="utf-8")
    print(f"json={json_path}")
    print(f"report={markdown_path}")


if __name__ == "__main__":
    main()
