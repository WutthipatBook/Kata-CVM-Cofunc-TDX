#!/usr/bin/env python3
"""Validate and merge stable-sample CoFunc EPT trace segments."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MAP_RE = re.compile(
    r"^@(?P<name>[A-Za-z0-9_]+)\[(?P<keys>[0-9, ]+)\]: (?P<value>[0-9]+)$"
)
WINDOW_RE = re.compile(
    r"^trace_window\s+(?P<phase>begin|end)\s+"
    r"(?P<window>[0-9]+)\s+(?P<timestamp>\S+)$"
)
WINDOW_MAPS = {
    "window_ept_exits",
    "window_ept_faults",
    "window_error_code",
    "window_service_count",
    "window_service_ns",
}


@dataclass(frozen=True)
class Segment:
    root: Path
    samples: tuple[int, ...]
    command_rc: int
    signal_rows: tuple[dict[str, str], ...]
    frames: tuple[tuple[int, str, str], ...]
    maps: dict[str, dict[tuple[int, ...], int]]
    hashes: dict[str, str]


def sample_range(value: str) -> tuple[int, ...]:
    match = re.fullmatch(r"([1-9][0-9]*)-([1-9][0-9]*)", value)
    if not match:
        raise argparse.ArgumentTypeError("sample range must have START-END form")
    start, end = (int(part) for part in match.groups())
    if start > end:
        raise argparse.ArgumentTypeError("sample range start exceeds end")
    return tuple(range(start, end + 1))


def parse_result(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_segment(root: Path, samples: tuple[int, ...], command_rc: int) -> Segment:
    root = root.resolve(strict=True)
    trace_dir = root / "ept-trace"
    paths = {
        name: trace_dir / name
        for name in ("trace-result.txt", "signals.tsv", "ept-events.tsv")
    }
    for path in paths.values():
        if not path.is_file():
            raise ValueError(f"missing trace input: {path}")

    result = parse_result(paths["trace-result.txt"])
    required = {
        "command_rc": str(command_rc),
        "trace_ready": "1",
        "trace_stopped": "1",
        "signal_begin_count": str(len(samples)),
        "signal_end_count": str(len(samples)),
        "loss_markers": "0",
    }
    for key, expected in required.items():
        if result.get(key) != expected:
            raise ValueError(
                f"invalid {root} trace result: {key}={result.get(key)!r}, "
                f"expected {expected!r}"
            )

    with paths["signals.tsv"].open(newline="", encoding="ascii") as file:
        signal_rows = tuple(csv.DictReader(file, delimiter="\t"))
    expected_signals = [
        (str(sample), phase)
        for sample in samples
        for phase in ("begin", "end")
    ]
    actual_signals = [(row["sample"], row["phase"]) for row in signal_rows]
    if actual_signals != expected_signals:
        raise ValueError(
            f"unexpected signal sequence in {root}: {actual_signals!r}"
        )
    for row in signal_rows:
        int(row["wall_ns"])
        int(row["monotonic_ns"])

    frames: list[tuple[int, str, str]] = []
    maps: dict[str, dict[tuple[int, ...], int]] = {}
    ready = 0
    stopped = 0
    for line in paths["ept-events.tsv"].read_text(encoding="ascii").splitlines():
        if re.fullmatch(r"trace_status\s+ready", line):
            ready += 1
        if re.fullmatch(r"trace_status\s+stopped", line):
            stopped += 1
        frame = WINDOW_RE.match(line)
        if frame:
            frames.append(
                (
                    int(frame.group("window")),
                    frame.group("phase"),
                    frame.group("timestamp"),
                )
            )
        map_match = MAP_RE.match(line)
        if map_match and map_match.group("name") in WINDOW_MAPS:
            keys = tuple(
                int(value.strip()) for value in map_match.group("keys").split(",")
            )
            name = map_match.group("name")
            if keys in maps.setdefault(name, {}):
                raise ValueError(f"duplicate map key in {root}: {name}{keys!r}")
            maps[name][keys] = int(map_match.group("value"))

    expected_frames = [
        (local_window, phase)
        for local_window in range(1, len(samples) + 1)
        for phase in ("begin", "end")
    ]
    actual_frames = [(window, phase) for window, phase, _ in frames]
    if ready != 1 or stopped != 1 or actual_frames != expected_frames:
        raise ValueError(
            f"invalid trace framing in {root}: ready={ready} stopped={stopped} "
            f"frames={actual_frames!r}"
        )

    for local_window in range(1, len(samples) + 1):
        values = [
            maps.get(name, {}).get((local_window,))
            for name in (
                "window_ept_exits",
                "window_ept_faults",
                "window_service_count",
            )
        ]
        if any(value is None for value in values) or len(set(values)) != 1:
            raise ValueError(
                f"unpaired EPT lifecycle in {root} local window "
                f"{local_window}: {values!r}"
            )
        if (local_window,) not in maps.get("window_service_ns", {}):
            raise ValueError(
                f"missing EPT service duration in {root} local window "
                f"{local_window}"
            )

    return Segment(
        root=root,
        samples=samples,
        command_rc=command_rc,
        signal_rows=signal_rows,
        frames=tuple(frames),
        maps=maps,
        hashes={name: sha256(path) for name, path in paths.items()},
    )


def segment_summary(segment: Segment) -> dict[str, Any]:
    return {
        "root": str(segment.root),
        "samples": list(segment.samples),
        "command_rc": segment.command_rc,
        "input_sha256": segment.hashes,
        "window_counts": {
            str(sample): segment.maps["window_ept_faults"][(local_window,)]
            for local_window, sample in enumerate(segment.samples, start=1)
        },
    }


def remap_segment(
    segment: Segment,
) -> tuple[
    list[dict[str, str]],
    list[tuple[int, str, str]],
    dict[str, dict[tuple[int, ...], int]],
]:
    rows = list(segment.signal_rows)
    frames: list[tuple[int, str, str]] = []
    maps: dict[str, dict[tuple[int, ...], int]] = {}
    local_to_sample = {
        local: sample for local, sample in enumerate(segment.samples, start=1)
    }
    for local, phase, timestamp in segment.frames:
        frames.append((local_to_sample[local], phase, timestamp))
    for name, entries in segment.maps.items():
        for keys, value in entries.items():
            remapped = (local_to_sample[keys[0]], *keys[1:])
            if remapped in maps.setdefault(name, {}):
                raise ValueError(f"duplicate merged map key: {name}{remapped!r}")
            maps[name][remapped] = value
    return rows, frames, maps


def write_merge(segments: list[Segment], output_dir: Path) -> None:
    all_samples = tuple(sample for segment in segments for sample in segment.samples)
    if all_samples != tuple(range(1, 13)):
        raise ValueError(
            f"merged sample sequence must be exactly 1-12, found {all_samples!r}"
        )
    output_dir = output_dir.absolute()
    if output_dir.exists() or output_dir.is_symlink():
        raise ValueError(f"refusing to reuse output directory: {output_dir}")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temp_dir = Path(
        tempfile.mkdtemp(prefix=f".{output_dir.name}.tmp.", dir=output_dir.parent)
    )
    try:
        signal_rows: list[dict[str, str]] = []
        frames: list[tuple[int, str, str]] = []
        maps: dict[str, dict[tuple[int, ...], int]] = {}
        for segment in segments:
            segment_rows, segment_frames, segment_maps = remap_segment(segment)
            signal_rows.extend(segment_rows)
            frames.extend(segment_frames)
            for name, entries in segment_maps.items():
                target = maps.setdefault(name, {})
                overlap = target.keys() & entries.keys()
                if overlap:
                    raise ValueError(
                        f"overlapping merged map keys for {name}: {sorted(overlap)!r}"
                    )
                target.update(entries)

        with (temp_dir / "signals.tsv").open(
            "w", newline="", encoding="ascii"
        ) as file:
            writer = csv.DictWriter(
                file,
                fieldnames=("wall_ns", "monotonic_ns", "sample", "phase"),
                delimiter="\t",
                lineterminator="\n",
            )
            writer.writeheader()
            writer.writerows(signal_rows)

        trace_lines = ["trace_status\tready"]
        trace_lines.extend(
            f"trace_window\t{phase}\t{sample}\t{timestamp}"
            for sample, phase, timestamp in frames
        )
        trace_lines.append("trace_status\tstopped")
        for name in sorted(maps):
            for keys, value in sorted(maps[name].items()):
                key_text = ", ".join(str(key) for key in keys)
                trace_lines.append(f"@{name}[{key_text}]: {value}")
        (temp_dir / "ept-events.tsv").write_text(
            "\n".join(trace_lines) + "\n", encoding="ascii"
        )

        (temp_dir / "trace-result.txt").write_text(
            f"finished={datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
            "command_rc=0\n"
            "trace_ready=1\n"
            "trace_stopped=1\n"
            "ept_service_records=0\n"
            "vm_aggregate_records=0\n"
            "signal_begin_count=12\n"
            "signal_end_count=12\n"
            "loss_markers=0\n",
            encoding="ascii",
        )
        provenance = {
            "format": "cofunc-ept-trace-segment-merge-v1",
            "samples": list(all_samples),
            "segments": [segment_summary(segment) for segment in segments],
        }
        (temp_dir / "merge-provenance.json").write_text(
            json.dumps(provenance, indent=2, sort_keys=True) + "\n",
            encoding="ascii",
        )
        with (temp_dir / "source-inputs.sha256").open("w", encoding="ascii") as file:
            for segment in segments:
                for name, digest in sorted(segment.hashes.items()):
                    file.write(f"{digest}  {segment.root / 'ept-trace' / name}\n")
        os.rename(temp_dir, output_dir)
    except BaseException:
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--root", type=Path, required=True)
    validate.add_argument("--samples", type=sample_range, required=True)
    validate.add_argument("--command-rc", type=int, required=True)
    validate.add_argument("--report", type=Path, required=True)

    merge = subparsers.add_parser("merge")
    merge.add_argument("--segment", type=Path, action="append", required=True)
    merge.add_argument(
        "--segment-samples", type=sample_range, action="append", required=True
    )
    merge.add_argument(
        "--segment-command-rc", type=int, action="append", required=True
    )
    merge.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "validate":
        segment = load_segment(args.root, args.samples, args.command_rc)
        if args.report.exists() or args.report.is_symlink():
            raise SystemExit(f"refusing to reuse report: {args.report}")
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(
            json.dumps(segment_summary(segment), indent=2, sort_keys=True) + "\n",
            encoding="ascii",
        )
        print(f"validated_samples={args.samples[0]}-{args.samples[-1]}")
        return 0

    if not (
        len(args.segment)
        == len(args.segment_samples)
        == len(args.segment_command_rc)
    ):
        raise SystemExit(
            "--segment, --segment-samples, and --segment-command-rc counts differ"
        )
    segments = [
        load_segment(root, samples, command_rc)
        for root, samples, command_rc in zip(
            args.segment,
            args.segment_samples,
            args.segment_command_rc,
            strict=True,
        )
    ]
    write_merge(segments, args.output_dir)
    print(f"merged_trace={args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
