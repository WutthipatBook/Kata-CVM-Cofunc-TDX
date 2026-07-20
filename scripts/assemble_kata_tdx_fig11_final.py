#!/usr/bin/env python3
"""Assemble the validated Vanilla Kata-TDX Fig. 11 logs artifact-first-N."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


ARCHIVE = Path("/home/booklyn/BookArchive/StageBreakdownRuns")

LEGACY_SOURCES = {
    "fn_py_face_detection": (
        ARCHIVE / "kata_tdx_0025_face_measurement_20260716_055921",
        20,
    ),
    "fn_py_image_processing": (
        ARCHIVE / "kata_tdx_0025_image_processing_measurement_20260716_130035",
        20,
    ),
    "fn_py_sentiment": (
        ARCHIVE / "kata_tdx_0025_sentiment_measurement_20260716_141812",
        20,
    ),
    "fn_py_video_processing": (
        ARCHIVE / "kata_tdx_0025_video_measurement_pilot_20260716_041102",
        5,
    ),
    "fn_py_compression": (
        ARCHIVE / "kata_tdx_0025_compression_measurement_20260716_051922",
        20,
    ),
    "fn_py_dna_visualisation": (
        ARCHIVE / "kata_tdx_0025_dna_measurement_20260716_044856",
        10,
    ),
}

EXACT_BATCH = (
    ARCHIVE
    / "kata_tdx_0025_remaining_exact_batch_20260716_174435"
    / "measurements"
)
EXACT_SOURCES = {
    "fn_js_uploader": (EXACT_BATCH / "fn_js_uploader", 20),
    "fn_js_thumbnailer": (EXACT_BATCH / "fn_js_thumbnailer", 20),
    "chain_js_alexa/fn_js_alexa_frontend": (
        EXACT_BATCH / "chain_js_alexa_fn_js_alexa_frontend",
        20,
    ),
    "chain_js_alexa/fn_js_alexa_interact": (
        EXACT_BATCH / "chain_js_alexa_fn_js_alexa_interact",
        20,
    ),
    "chain_js_alexa/fn_js_alexa_smarthome": (
        EXACT_BATCH / "chain_js_alexa_fn_js_alexa_smarthome",
        20,
    ),
    "chain_js_alexa/fn_js_alexa_tv": (
        EXACT_BATCH / "chain_js_alexa_fn_js_alexa_tv",
        20,
    ),
}

WORKLOAD_ORDER = [
    "fn_py_face_detection",
    "fn_py_image_processing",
    "fn_py_sentiment",
    "fn_py_video_processing",
    "fn_py_compression",
    "fn_py_dna_visualisation",
    "fn_js_uploader",
    "fn_js_thumbnailer",
    "chain_js_alexa/fn_js_alexa_frontend",
    "chain_js_alexa/fn_js_alexa_interact",
    "chain_js_alexa/fn_js_alexa_smarthome",
    "chain_js_alexa/fn_js_alexa_tv",
]

TIMING_KEYS = ("timestamp", "t_boot_cntr", "t_boot_func", "t_exec", "t_e2e")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json_lines(path: Path) -> list[dict[str, float]]:
    if not path.is_file():
        raise SystemExit(f"missing source log: {path}")
    rows: list[dict[str, float]] = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise SystemExit(f"non-object JSON at {path}:{line_number}")
        for key in TIMING_KEYS:
            if not isinstance(value.get(key), (int, float)):
                raise SystemExit(f"missing numeric {key} at {path}:{line_number}")
        stage_sum = value["t_boot_cntr"] + value["t_boot_func"] + value["t_exec"]
        if abs(stage_sum - value["t_e2e"]) > 1e-6:
            raise SystemExit(f"stage sum mismatch at {path}:{line_number}")
        rows.append({key: float(value[key]) for key in TIMING_KEYS})
    return rows


def mean(rows: list[dict[str, float]], key: str) -> float:
    return sum(row[key] for row in rows) / len(rows)


def assemble_legacy(
    workload: str, source_root: Path, count: int
) -> tuple[list[dict[str, float]], dict[str, Any]]:
    warmup_path = source_root / "warmup-log" / workload / "kata_launch.log"
    measured_path = source_root / "log" / workload / "kata_launch.log"
    warmup = load_json_lines(warmup_path)
    measured = load_json_lines(measured_path)
    if len(warmup) != 1:
        raise SystemExit(f"expected one initial cold launch for {workload}")
    if len(measured) < count - 1:
        raise SystemExit(f"insufficient measured rows for {workload}")
    selected = warmup + measured[: count - 1]
    return selected, {
        "selection": "initial-cold-plus-first-N-minus-1",
        "requested_samples": count,
        "selected_warmup_rows": 1,
        "selected_measured_rows": count - 1,
        "unused_measured_rows": len(measured) - (count - 1),
        "source_root": str(source_root),
        "warmup_log": str(warmup_path),
        "warmup_log_sha256": sha256(warmup_path),
        "measured_log": str(measured_path),
        "measured_log_sha256": sha256(measured_path),
    }


def assemble_exact(
    workload: str, source_root: Path, count: int
) -> tuple[list[dict[str, float]], dict[str, Any]]:
    source_path = source_root / "log" / workload / "kata_launch.log"
    rows = load_json_lines(source_path)
    if len(rows) != count:
        raise SystemExit(
            f"exact source count mismatch for {workload}: expected={count} actual={len(rows)}"
        )
    return rows, {
        "selection": "all-exact-N",
        "requested_samples": count,
        "selected_rows": count,
        "unused_rows": 0,
        "source_root": str(source_root),
        "source_log": str(source_path),
        "source_log_sha256": sha256(source_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()

    output_root = args.output_root
    if output_root.exists():
        raise SystemExit(f"refusing to reuse output root: {output_root}")
    log_root = output_root / "log"
    log_root.mkdir(parents=True)

    assembler_path = Path(__file__).resolve()

    manifest: dict[str, Any] = {
        "assembler": str(assembler_path),
        "assembler_sha256": sha256(assembler_path),
        "sampling_rule": "artifact-first-N",
        "outlier_policy": "none",
        "workload_order": WORKLOAD_ORDER,
        "workloads": {},
    }
    summary: dict[str, Any] = {
        "sampling_rule": "artifact-first-N",
        "workloads": {},
    }

    for workload in WORKLOAD_ORDER:
        if workload in LEGACY_SOURCES:
            rows, provenance = assemble_legacy(workload, *LEGACY_SOURCES[workload])
        else:
            rows, provenance = assemble_exact(workload, *EXACT_SOURCES[workload])
        expected = LEGACY_SOURCES.get(workload, EXACT_SOURCES.get(workload))[1]
        if len(rows) != expected:
            raise SystemExit(f"internal selected-count mismatch for {workload}")
        if any(a["timestamp"] >= b["timestamp"] for a, b in zip(rows, rows[1:])):
            raise SystemExit(f"timestamps are not strictly increasing for {workload}")

        destination = log_root / workload / "kata_launch.log"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in rows)
        )
        provenance["output_log"] = str(destination)
        provenance["output_log_sha256"] = sha256(destination)
        manifest["workloads"][workload] = provenance
        summary["workloads"][workload] = {
            "samples": len(rows),
            "t_boot_cntr_mean": mean(rows, "t_boot_cntr"),
            "t_boot_func_mean": mean(rows, "t_boot_func"),
            "t_exec_mean": mean(rows, "t_exec"),
            "t_e2e_mean": mean(rows, "t_e2e"),
            "t_e2e_min": min(row["t_e2e"] for row in rows),
            "t_e2e_max": max(row["t_e2e"] for row in rows),
        }

    (output_root / "fig11-input-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    (output_root / "aggregation-summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n"
    )
    print(f"output_root={output_root}")
    print(f"workloads={len(WORKLOAD_ORDER)}")
    print(f"selected_samples={sum(item['samples'] for item in summary['workloads'].values())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
