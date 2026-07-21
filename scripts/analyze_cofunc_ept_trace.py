#!/usr/bin/env python3
"""Validate one CoFunc handler-window EPT trace."""

from __future__ import annotations

import argparse
import json
import re
import statistics
from pathlib import Path
from typing import Any


AGGREGATE_NAMES = (
    "vm_ept_exits",
    "vm_ept_faults",
    "vm_service_count",
    "vm_service_ns",
)
TDX_SHARED_GPA_MASK_CANDIDATES = (1 << 47, 1 << 51)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workload", required=True)
    parser.add_argument("--analyzer-log", required=True, type=Path)
    parser.add_argument("--run-log", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--signals", required=True, type=Path)
    parser.add_argument("--trace-result", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    return parser.parse_args()


def load_single_json_line(path: Path) -> dict[str, Any]:
    rows = []
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise SystemExit(f"invalid JSON at {path}:{line_number}: {error}")
    if len(rows) != 1:
        raise SystemExit(f"expected one analyzer row at {path}, found {len(rows)}")
    required = (
        "t_exec",
        "n_accept_exec",
        "n_pgfault_exec",
        "t_pgfault_exec",
        "t_pgfault_exec_cycles",
        "sc_guest_tsc_hz",
        "sc_host_gpa",
        "sc_host_mem_size",
    )
    missing = [key for key in required if key not in rows[0]]
    if missing:
        raise SystemExit("missing CoFunc metrics: " + ", ".join(missing))
    return rows[0]


def parse_markers(path: Path) -> dict[str, float]:
    markers: dict[str, float] = {}
    pre_fault_pattern = re.compile(
        r"^CoFunc private pre-fault: gpa=(0x[0-9a-f]+) "
        r"bytes=([0-9]+) chunks=([0-9]+) cycles=([0-9]+)$"
    )
    pre_faults = []
    with path.open(encoding="utf-8", errors="replace") as stream:
        for line in stream:
            stripped = line.strip()
            fields = stripped.split()
            if len(fields) == 2 and fields[0].startswith("t_"):
                try:
                    value = float(fields[1])
                except ValueError:
                    continue
                markers[fields[0]] = max(markers.get(fields[0], value), value)
            match = pre_fault_pattern.match(stripped)
            if match:
                gpa, byte_count, chunks, cycles = match.groups()
                pre_faults.append(
                    {
                        "gpa": gpa,
                        "bytes": int(byte_count),
                        "chunks": int(chunks),
                        "cycles": int(cycles),
                    }
                )
    for required in ("t_import_done", "t_func_done"):
        if required not in markers:
            raise SystemExit(f"missing {required} marker: {path}")
    if markers["t_func_done"] <= markers["t_import_done"]:
        raise SystemExit("invalid CoFunc handler interval")
    if len(pre_faults) != 1:
        raise SystemExit(f"expected one pre-fault marker, found {len(pre_faults)}")
    markers["pre_fault"] = pre_faults[0]  # type: ignore[assignment]
    return markers


def parse_signals(path: Path) -> dict[str, float]:
    rows = []
    with path.open(encoding="ascii") as stream:
        header = stream.readline().strip()
        if header != "wall_ns\tmonotonic_ns\tsample\tphase":
            raise SystemExit(f"invalid signal log header: {header!r}")
        for line_number, line in enumerate(stream, 2):
            fields = line.strip().split("\t")
            if len(fields) != 4:
                raise SystemExit(f"invalid signal row at {path}:{line_number}")
            wall_ns, monotonic_ns, sample, phase = fields
            if sample != "1" or phase not in ("begin", "end"):
                raise SystemExit(f"unexpected signal at {path}:{line_number}: {line.strip()}")
            rows.append(
                {
                    "wall_ns": int(wall_ns),
                    "monotonic_ns": int(monotonic_ns),
                    "phase": phase,
                }
            )
    if [row["phase"] for row in rows] != ["begin", "end"]:
        raise SystemExit(f"expected exactly one ordered begin/end pair, got {rows}")
    if rows[1]["wall_ns"] <= rows[0]["wall_ns"]:
        raise SystemExit("non-positive signal window")
    if rows[1]["monotonic_ns"] <= rows[0]["monotonic_ns"]:
        raise SystemExit("non-positive monotonic signal window")
    return {
        "begin_wall_s": rows[0]["wall_ns"] / 1e9,
        "end_wall_s": rows[1]["wall_ns"] / 1e9,
        "begin_monotonic_ns": rows[0]["monotonic_ns"],
        "end_monotonic_ns": rows[1]["monotonic_ns"],
        "duration_s": (rows[1]["monotonic_ns"] - rows[0]["monotonic_ns"])
        / 1e9,
    }


def parse_trace_result(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    with path.open(encoding="ascii") as stream:
        for line in stream:
            key, separator, value = line.strip().partition("=")
            if separator and value.isdigit():
                values[key] = int(value)
    expected = {
        "command_rc": 0,
        "trace_ready": 1,
        "trace_stopped": 1,
        "signal_begin_count": 1,
        "signal_end_count": 1,
        "loss_markers": 0,
    }
    for key, value in expected.items():
        if values.get(key) != value:
            raise SystemExit(
                f"trace-result mismatch for {key}: {values.get(key)} != {value}"
            )
    if "ept_service_records" not in values:
        raise SystemExit("trace result omits ept_service_records")
    aggregate_records = values.get("vm_aggregate_records", 0)
    if aggregate_records <= 0 or aggregate_records % len(AGGREGATE_NAMES):
        raise SystemExit(
            "trace-result vm_aggregate_records must be a positive multiple of "
            f"{len(AGGREGATE_NAMES)}, got {aggregate_records}"
        )
    return values


def parse_trace(path: Path) -> dict[str, Any]:
    services = []
    aggregates: dict[str, dict[int, int]] = {name: {} for name in AGGREGATE_NAMES}
    unknown = []
    lost = []
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
                lost.append({"line": line_number, "text": line})
            fields = line.split("\t")
            if fields[0] == "EPT_SERVICE" and len(fields) in (9, 11):
                service = {
                    "wall_s": float(fields[1]),
                    "exit_nsecs": int(fields[2]),
                    "entry_nsecs": int(fields[3]),
                    "pid": int(fields[4]),
                    "tid": int(fields[5]),
                    "exit_cpu": int(fields[6]),
                    "entry_cpu": int(fields[7]),
                    "duration_ns": int(fields[8]),
                    "fault_address": None,
                    "error_code": None,
                }
                if len(fields) == 11:
                    service["fault_address"] = int(fields[9])
                    service["error_code"] = int(fields[10])
                services.append(service)
            elif fields[0] in ("trace_status", "trace_window"):
                continue
            elif line.startswith("Attaching "):
                continue
            else:
                match = map_pattern.match(line)
                if match:
                    name, pid, value = match.groups()
                    aggregates[name][int(pid)] = int(value)
                else:
                    unknown.append({"line": line_number, "text": line})
    if lost:
        raise SystemExit(f"trace contains event-loss markers: {lost}")
    if unknown:
        raise SystemExit(f"trace contains unparsed output: {unknown}")
    pid_sets = {name: set(values) for name, values in aggregates.items()}
    if any(not pids for pids in pid_sets.values()):
        raise SystemExit(f"expected a nonempty QEMU PID set in every map: {pid_sets}")
    expected_pids = next(iter(pid_sets.values()))
    if any(pids != expected_pids for pids in pid_sets.values()):
        raise SystemExit(f"aggregate PID mismatch: {pid_sets}")
    for qemu_pid in sorted(expected_pids):
        exits = aggregates["vm_ept_exits"][qemu_pid]
        faults = aggregates["vm_ept_faults"][qemu_pid]
        reentries = aggregates["vm_service_count"][qemu_pid]
        if exits != faults or exits != reentries:
            raise SystemExit(
                f"unpaired EPT lifecycle for PID {qemu_pid}: "
                f"exits={exits} faults={faults} reentries={reentries}"
            )
    if any(service["pid"] not in expected_pids for service in services):
        raise SystemExit("gated service record belongs to an unexpected QEMU PID")
    return {
        "qemu_pids": sorted(expected_pids),
        "services": services,
        "aggregates": aggregates,
    }


def service_stats(services: list[dict[str, Any]]) -> dict[str, Any]:
    durations = [service["duration_ns"] for service in services]
    if not durations:
        return {
            "count": 0,
            "sum_ns": 0,
            "mean_ns": None,
            "median_ns": None,
            "max_ns": None,
        }
    return {
        "count": len(durations),
        "sum_ns": sum(durations),
        "mean_ns": statistics.fmean(durations),
        "median_ns": statistics.median(durations),
        "max_ns": max(durations),
    }


def burst_stats(
    services: list[dict[str, Any]], gate_begin_ns: int, gap_ns: int = 1_000_000
) -> list[dict[str, Any]]:
    bursts = []
    current = []
    for service in sorted(services, key=lambda row: row["exit_nsecs"]):
        if current and service["exit_nsecs"] - current[-1]["exit_nsecs"] > gap_ns:
            bursts.append(current)
            current = []
        current.append(service)
    if current:
        bursts.append(current)
    return [
        {
            "count": len(burst),
            "offset_from_gate_begin_ms": (
                burst[0]["exit_nsecs"] - gate_begin_ns
            )
            / 1e6,
            "span_ms": (burst[-1]["exit_nsecs"] - burst[0]["exit_nsecs"])
            / 1e6,
            "service_sum_ns": sum(row["duration_ns"] for row in burst),
        }
        for burst in bursts
    ]


def fault_attribution(
    services: list[dict[str, Any]], guest: dict[str, Any], pre_fault: dict[str, Any]
) -> dict[str, Any]:
    if not services:
        return {
            "record_format": "empty",
            "counts_by_range": {},
            "unique_pages_by_range": {},
            "error_code_counts": {},
        }
    addressed = [row for row in services if row["fault_address"] is not None]
    if not addressed:
        return {
            "record_format": "legacy_without_address",
            "counts_by_range": {},
            "unique_pages_by_range": {},
            "error_code_counts": {},
        }
    if len(addressed) != len(services):
        raise SystemExit("trace mixes addressed and legacy EPT service records")

    total_start = int(guest["sc_host_gpa"])
    total_end = total_start + int(guest["sc_host_mem_size"])
    private_start = int(pre_fault["gpa"], 16)
    private_end = private_start + int(pre_fault["bytes"])
    if not total_start <= private_start < private_end <= total_end:
        raise SystemExit(
            "invalid granted/private memory ranges: "
            f"granted={total_start:#x}..{total_end:#x} "
            f"private={private_start:#x}..{private_end:#x}"
        )

    ranges = (
        ("shared_prefix", total_start, private_start),
        ("private_prefault", private_start, private_end),
        ("reserved_tail", private_end, total_end),
    )
    counts = {name: 0 for name, _, _ in ranges}
    counts["outside_granted_memory"] = 0
    pages = {name: set() for name in counts}
    visibility_counts = {
        "private": 0,
        "shared_alias": 0,
        "outside_granted_memory": 0,
    }
    shared_masks: dict[str, int] = {}
    error_codes: dict[str, int] = {}
    for service in addressed:
        raw_address = service["fault_address"]
        address = raw_address
        visibility = "private"
        if not total_start <= address < total_end:
            aliases = [
                (mask, raw_address & ~mask)
                for mask in TDX_SHARED_GPA_MASK_CANDIDATES
                if raw_address & mask
                and total_start <= raw_address & ~mask < total_end
            ]
            if len(aliases) > 1:
                raise SystemExit(
                    f"ambiguous TDX shared GPA mask for address {raw_address:#x}"
                )
            if aliases:
                mask, address = aliases[0]
                visibility = "shared_alias"
                mask_name = f"0x{mask:x}"
                shared_masks[mask_name] = shared_masks.get(mask_name, 0) + 1
            else:
                visibility = "outside_granted_memory"
        range_name = "outside_granted_memory"
        for name, start, end in ranges:
            if start <= address < end:
                range_name = name
                break
        counts[range_name] += 1
        visibility_counts[visibility] += 1
        pages[range_name].add(address >> 12)
        error_code = f"0x{service['error_code']:x}"
        error_codes[error_code] = error_codes.get(error_code, 0) + 1

    return {
        "record_format": "addressed",
        "granted_range": {"start": total_start, "end": total_end},
        "private_prefault_range": {"start": private_start, "end": private_end},
        "counts_by_range": counts,
        "counts_by_visibility": visibility_counts,
        "unique_pages_by_range": {
            name: len(range_pages) for name, range_pages in pages.items()
        },
        "shared_alias_masks_observed": shared_masks,
        "error_code_counts": error_codes,
    }


def render_markdown(result: dict[str, Any]) -> str:
    handler_upper_bound = result["handler_ept_service_upper_bound"]
    gated = result["gated_ept_service"]
    vm = result["vm_lifetime"]
    attribution = result["gated_fault_attribution"]
    target = "PASS" if result["prefault_target_passed"] else "FAIL"
    return "\n".join(
        [
            f"# CoFunc pre-fault EPT trace: `{result['workload']}`",
            "",
            "## Result",
            "",
            f"- Pre-fault zero-handler-EPT target: **{target}**",
            f"- Authenticated gated-window EPT violations: {gated['count']}",
            f"- Handler EPT violation upper bound: {handler_upper_bound['count']}",
            f"- VM-lifetime EPT faults: {vm['fault_count']}",
            f"- VM-lifetime paired service: {vm['service_sum_ns'] / 1e9:.9f} s",
            "- QEMU PIDs: " + ", ".join(map(str, result["qemu_pids"])),
            "",
            "The instrumentation control flow opens the authenticated trace gate before",
            "recording `t_import_done`, then closes it after recording `t_func_done`.",
            "The gated count is therefore a conservative handler upper bound. A zero",
            "gated count proves a zero handler count for this launch.",
            "",
            "Guest `time.time()` and host trace timestamps are separate clock domains and",
            "are intentionally not compared numerically.",
            "",
            "## Gated-fault attribution",
            "",
            f"- Trace record format: {attribution['record_format']}",
            "- Counts by range: "
            + json.dumps(attribution["counts_by_range"], sort_keys=True),
            "- Unique 4 KiB pages by range: "
            + json.dumps(attribution["unique_pages_by_range"], sort_keys=True),
            "- Counts by TDX visibility: "
            + json.dumps(attribution.get("counts_by_visibility", {}), sort_keys=True),
            "- Shared alias masks: "
            + json.dumps(
                attribution.get("shared_alias_masks_observed", {}), sort_keys=True
            ),
            "- Error codes: "
            + json.dumps(attribution["error_code_counts"], sort_keys=True),
            f"- Burst counts: {[row['count'] for row in result['gated_bursts']]}",
            "",
            "## Guest telemetry",
            "",
            f"- `t_exec`: {result['guest']['t_exec']:.9f} s",
            f"- First-level faults: {result['guest']['n_pgfault_exec']}",
            f"- First-level fault time: {result['guest']['t_pgfault_exec']:.9f} s",
            f"- Deferred accepts: {result['guest']['n_accept_exec']}",
            f"- Pre-fault bytes: {result['pre_fault']['bytes']}",
            f"- Pre-fault chunks: {result['pre_fault']['chunks']}",
            "",
            "## Integrity",
            "",
            "- Exactly one ordered authenticated begin/end pair",
            "- Identical nonempty QEMU PID sets in all four aggregate maps",
            "- EPT exits, KVM page faults, and reentries paired per PID",
            "- No trace-loss or unparsed-output markers",
            f"- Host authenticated-gate duration: {result['clock_domains']['host_signal_duration_s']:.9f} s",
            f"- Guest handler duration: {result['clock_domains']['guest_handler_duration_s']:.9f} s",
            "",
        ]
    )


def main() -> None:
    args = parse_args()
    guest = load_single_json_line(args.analyzer_log)
    markers = parse_markers(args.run_log)
    signals = parse_signals(args.signals)
    trace_result = parse_trace_result(args.trace_result)
    trace = parse_trace(args.trace)
    services = trace["services"]
    if trace_result["ept_service_records"] != len(services):
        raise SystemExit(
            "gated service count mismatch: "
            f"{trace_result['ept_service_records']} != {len(services)}"
        )
    aggregate_records = sum(len(values) for values in trace["aggregates"].values())
    if trace_result["vm_aggregate_records"] != aggregate_records:
        raise SystemExit(
            "VM aggregate record count mismatch: "
            f"{trace_result['vm_aggregate_records']} != {aggregate_records}"
        )

    handler_start = markers["t_import_done"]
    handler_end = markers["t_func_done"]
    guest_handler_duration = handler_end - handler_start
    host_signal_duration = signals["duration_s"]
    qemu_pids = trace["qemu_pids"]
    aggregates = trace["aggregates"]
    per_pid = {
        str(qemu_pid): {
            "exit_count": aggregates["vm_ept_exits"][qemu_pid],
            "fault_count": aggregates["vm_ept_faults"][qemu_pid],
            "reentry_count": aggregates["vm_service_count"][qemu_pid],
            "service_sum_ns": aggregates["vm_service_ns"][qemu_pid],
        }
        for qemu_pid in qemu_pids
    }
    vm_faults = sum(row["fault_count"] for row in per_pid.values())
    vm_service_ns = sum(row["service_sum_ns"] for row in per_pid.values())
    result = {
        "workload": args.workload,
        "qemu_pids": qemu_pids,
        "guest": {
            "t_exec": guest["t_exec"],
            "n_accept_exec": guest["n_accept_exec"],
            "n_pgfault_exec": guest["n_pgfault_exec"],
            "t_pgfault_exec": guest["t_pgfault_exec"],
            "t_pgfault_exec_cycles": guest["t_pgfault_exec_cycles"],
            "sc_guest_tsc_hz": guest["sc_guest_tsc_hz"],
            "sc_host_gpa": guest["sc_host_gpa"],
            "sc_host_mem_size": guest["sc_host_mem_size"],
        },
        "pre_fault": markers["pre_fault"],
        "handler_interval": {
            "clock_domain": "guest_wall",
            "start": handler_start,
            "end": handler_end,
        },
        "signal_window": signals,
        "clock_domains": {
            "comparison": "not_comparable",
            "guest_handler_duration_s": guest_handler_duration,
            "host_signal_duration_s": host_signal_duration,
            "guest_to_host_duration_ratio": guest_handler_duration
            / host_signal_duration,
            "enclosure_basis": "authenticated_instrumentation_control_flow",
        },
        "handler_ept_service_upper_bound": service_stats(services),
        "gated_ept_service": service_stats(services),
        "gated_bursts": burst_stats(services, signals["begin_monotonic_ns"]),
        "gated_fault_attribution": fault_attribution(
            services, guest, markers["pre_fault"]
        ),
        "vm_lifetime": {
            "exit_count": sum(row["exit_count"] for row in per_pid.values()),
            "fault_count": vm_faults,
            "reentry_count": sum(row["reentry_count"] for row in per_pid.values()),
            "service_sum_ns": vm_service_ns,
            "mean_service_ns": vm_service_ns / vm_faults if vm_faults else None,
            "per_pid": per_pid,
        },
        "prefault_target_passed": len(services) == 0,
        "trace_result": trace_result,
    }
    args.output_dir.mkdir(parents=True, exist_ok=False)
    json_path = args.output_dir / "cofunc_ept_trace.json"
    report_path = args.output_dir / "cofunc_ept_trace.md"
    json_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    report_path.write_text(render_markdown(result), encoding="utf-8")
    print(f"json={json_path}")
    print(f"report={report_path}")
    print(f"prefault_target_passed={int(result['prefault_target_passed'])}")


if __name__ == "__main__":
    main()
