#!/usr/bin/env python3
"""Audit a CoFunc TDX setup/result against paper-critical checks."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_ARTIFACT = Path("/mnt/nvme_500g/cofunc_tdx_artifact/cofunc-artifact")
DEFAULT_EXPECTED_KVM = "0BD0A0612BCAACA2BE920F4"
DEFAULT_EXPECTED_KVM_INTEL = "65E9BDBE5E3D73DEA355ECB"


FIG11_TDX_TARGETS = {
    "fn_py_face_detection": {
        "label": "face",
        "native": 0.324,
        "cofunc": 0.346,
        "kata": 2.55,
    },
    "fn_py_image_processing": {
        "label": "image",
        "native": 2.23,
        "cofunc": 2.39,
        "kata": 4.06,
    },
    "fn_py_sentiment": {
        "label": "sentiment",
        "native": 0.0073,
        "cofunc": 0.0089,
        "kata": 1.95,
    },
    "fn_py_video_processing": {
        "label": "video",
        "native": 18.8,
        "cofunc": 18.8,
        "kata": 20.1,
    },
    "fn_py_compression": {
        "label": "compress",
        "native": 0.370,
        "cofunc": 0.422,
        "kata": 2.23,
    },
    "fn_py_dna_visualisation": {
        "label": "dna",
        "native": 5.30,
        "cofunc": 5.67,
        "kata": 7.40,
    },
    "fn_js_uploader": {
        "label": "upload",
        "native": 0.0855,
        "cofunc": 0.112,
        "kata": 2.09,
    },
    "fn_js_thumbnailer": {
        "label": "thumbnail",
        "native": 0.0913,
        "cofunc": 0.104,
        "kata": 2.23,
    },
    "chain_js_alexa": {
        "label": "alexa",
        "native": 0.0573,
        "cofunc": 0.0655,
        "kata": 7.91,
        "members": [
            "chain_js_alexa/fn_js_alexa_frontend",
            "chain_js_alexa/fn_js_alexa_interact",
            "chain_js_alexa/fn_js_alexa_smarthome",
            "chain_js_alexa/fn_js_alexa_tv",
        ],
    },
}

TABLE3_TDX_OVERHEADS = {
    "fn_py_face_detection": {
        "label": "F",
        "encrypt_pct": 0.57,
        "memgrant_pct": 2.58,
        "delegate_pct": 0.93,
        "others_pct": 1.13,
        "exits_per_ms": 0.55,
    },
    "fn_py_image_processing": {
        "label": "I",
        "encrypt_pct": 1.17,
        "memgrant_pct": 1.63,
        "delegate_pct": 1.02,
        "others_pct": 0.48,
        "exits_per_ms": 0.74,
    },
    "fn_py_sentiment": {
        "label": "S",
        "encrypt_pct": 0.00,
        "memgrant_pct": 15.6,
        "delegate_pct": 2.62,
        "others_pct": -2.43,
        "exits_per_ms": 2.40,
    },
    "fn_py_video_processing": {
        "label": "V",
        "encrypt_pct": 0.19,
        "memgrant_pct": 0.40,
        "delegate_pct": 0.19,
        "others_pct": 1.95,
        "exits_per_ms": 0.09,
    },
    "fn_py_compression": {
        "label": "C",
        "encrypt_pct": 6.54,
        "memgrant_pct": 2.77,
        "delegate_pct": 2.99,
        "others_pct": 2.11,
        "exits_per_ms": 1.47,
    },
    "fn_py_dna_visualisation": {
        "label": "D",
        "encrypt_pct": 3.97,
        "memgrant_pct": 3.44,
        "delegate_pct": 0.30,
        "others_pct": -0.43,
        "exits_per_ms": 0.12,
    },
    "fn_js_uploader": {
        "label": "U",
        "encrypt_pct": 10.0,
        "memgrant_pct": 12.6,
        "delegate_pct": 2.87,
        "others_pct": -1.31,
        "exits_per_ms": 4.40,
    },
    "fn_js_thumbnailer": {
        "label": "T",
        "encrypt_pct": 3.95,
        "memgrant_pct": 5.58,
        "delegate_pct": 2.43,
        "others_pct": 1.91,
        "exits_per_ms": 0.98,
    },
    "chain_js_alexa": {
        "label": "A",
        "encrypt_pct": 0.00,
        "memgrant_pct": 7.94,
        "delegate_pct": 2.15,
        "others_pct": 0.76,
        "exits_per_ms": 1.68,
    },
}

@dataclass
class Check:
    level: str
    name: str
    detail: str


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def read_one_line(path: Path) -> str | None:
    text = read_text(path)
    if text is None:
        return None
    return text.strip()


def run_quiet(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def active_background_load() -> list[str]:
    """Return short descriptions of experiment stacks that can disturb latency."""
    proc = run_quiet(["ps", "-eo", "pid,pcpu,args"])
    if proc.returncode != 0:
        return []
    patterns = (
        "org.apache.openwhisk",
        "cofunc_scenario/scripts/prepare_source.sh",
        "run_host_paging_fig11_matrix.sh",
    )
    matches = []
    for line in proc.stdout.splitlines()[1:]:
        if any(pattern in line for pattern in patterns):
            parts = line.split(None, 2)
            if len(parts) < 3:
                continue
            pid, cpu, args = parts
            short = args[:120] + ("..." if len(args) > 120 else "")
            matches.append(f"pid={pid} cpu={cpu}% {short}")
    return matches[:8]


def parse_cmdline_value(cmdline: str, key: str) -> str | None:
    prefix = key + "="
    for token in cmdline.split():
        if token == key:
            return "(set)"
        if token.startswith(prefix):
            return token[len(prefix) :]
    return None


def active_isolated_cpus(cmdline: str) -> str | None:
    raw = parse_cmdline_value(cmdline, "isolcpus")
    if not raw or raw == "(set)":
        return None
    fields = []
    for field in raw.split(","):
        if re.fullmatch(r"[0-9]+(?:-[0-9]+)?", field):
            fields.append(field)
    return ",".join(fields) if fields else None


def cpu_list_count(cpu_list: str | None) -> int | None:
    if not cpu_list:
        return None
    count = 0
    for part in cpu_list.replace(" ", "").split(","):
        if not part:
            continue
        if re.fullmatch(r"[0-9]+", part):
            count += 1
            continue
        match = re.fullmatch(r"([0-9]+)-([0-9]+)", part)
        if not match:
            return None
        start = int(match.group(1))
        end = int(match.group(2))
        if end < start:
            return None
        count += end - start + 1
    return count


def parse_key_value_file(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    text = read_text(path)
    if not text:
        return result
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip()
    return result


def parse_cmake_cache(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    text = read_text(path)
    if not text:
        return result
    for line in text.splitlines():
        if not line or line.startswith(("#", "//")) or "=" not in line:
            continue
        left, value = line.split("=", 1)
        key = left.split(":", 1)[0]
        result[key.strip()] = value.strip()
    return result


def latest_result_dir(root: Path) -> Path | None:
    if not root.exists():
        return None
    candidates = []
    for path in root.iterdir():
        if not path.is_dir():
            continue
        if (path / "tdx_sc_fork_summary.txt").exists() or list(path.glob("log/**/sc_fork.log")):
            candidates.append(path)
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def load_sc_fork_log(path: Path) -> list[dict[str, Any]]:
    rows = []
    text = read_text(path)
    if not text:
        return rows
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


def mean_key(rows: list[dict[str, Any]], key: str) -> float | None:
    vals = [float(row[key]) for row in rows if key in row and row[key] is not None]
    if not vals:
        return None
    return statistics.mean(vals)


def fmt_seconds(value: float | None) -> str:
    if value is None:
        return "-"
    if value < 0.01:
        return f"{value:.4f}s"
    return f"{value:.3f}s"


def fmt_ratio(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}x"


def add(checks: list[Check], level: str, name: str, detail: str) -> None:
    checks.append(Check(level, name, detail))


def inspect_ablation_task(artifact: Path, task_name: str) -> dict[str, Any]:
    task_dir = artifact / "testcases/tools/tasks" / task_name
    params = task_dir / "params"
    action = task_dir / "action.sh"
    action_target = action.resolve() if action.exists() else None
    action_text = read_text(action_target) if action_target else ""
    params_text = read_text(params) or ""
    param_rows = [
        line.split()
        for line in params_text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    suffixes = sorted({row[2] for row in param_rows if len(row) >= 3})
    action_consumes_ablation_arg = any(
        token in action_text
        for token in ("$3", "${3", "suffix", "mode", "noenc", "nomem")
    )
    action_uses_task_name = task_name in action_text
    valid_as_wired = bool(suffixes and (action_consumes_ablation_arg or action_uses_task_name))
    return {
        "task": task_name,
        "path": str(task_dir),
        "exists": task_dir.exists(),
        "params_exists": params.exists(),
        "action_exists": action.exists(),
        "action_is_symlink": action.is_symlink(),
        "action_target": str(action_target) if action_target else None,
        "param_columns": sorted({len(row) for row in param_rows}),
        "suffixes": suffixes,
        "action_consumes_ablation_arg": action_consumes_ablation_arg,
        "action_uses_task_name": action_uses_task_name,
        "valid_as_wired": valid_as_wired,
    }


def check_host(checks: list[Check], expected_kvm: str, expected_kvm_intel: str) -> dict[str, Any]:
    info: dict[str, Any] = {"kernel": platform.release()}

    tdx = read_one_line(Path("/sys/module/kvm_intel/parameters/tdx"))
    info["tdx"] = tdx
    if tdx == "Y":
        add(checks, "PASS", "host.tdx", "kvm_intel.tdx is enabled")
    else:
        add(checks, "FAIL", "host.tdx", f"kvm_intel.tdx is {tdx or 'missing'}")

    kvm_src = read_one_line(Path("/sys/module/kvm/srcversion"))
    kvm_intel_src = read_one_line(Path("/sys/module/kvm_intel/srcversion"))
    info["kvm_srcversion"] = kvm_src
    info["kvm_intel_srcversion"] = kvm_intel_src
    if kvm_src == expected_kvm:
        add(checks, "PASS", "host.kvm_srcversion", kvm_src)
    else:
        add(checks, "WARN", "host.kvm_srcversion", f"{kvm_src or 'missing'} != expected {expected_kvm}")
    if kvm_intel_src == expected_kvm_intel:
        add(checks, "PASS", "host.kvm_intel_srcversion", kvm_intel_src)
    else:
        add(
            checks,
            "WARN",
            "host.kvm_intel_srcversion",
            f"{kvm_intel_src or 'missing'} != expected {expected_kvm_intel}",
        )

    governors = []
    for path in sorted(Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_governor")):
        value = read_one_line(path)
        if value:
            governors.append(value)
    info["governors"] = governors
    if governors and all(value == "performance" for value in governors):
        add(checks, "PASS", "host.performance_governor", f"{len(governors)} CPUs set to performance")
    elif governors:
        counts = {value: governors.count(value) for value in sorted(set(governors))}
        add(checks, "WARN", "host.performance_governor", f"governors={counts}")
    else:
        add(checks, "WARN", "host.performance_governor", "no cpufreq governor files found")

    cmdline = read_one_line(Path("/proc/cmdline")) or ""
    info["cmdline"] = cmdline
    iso = active_isolated_cpus(cmdline)
    info["active_isolated_cpus"] = iso
    missing_isolation = [
        key for key in ("isolcpus", "nohz_full", "rcu_nocbs", "irqaffinity") if not parse_cmdline_value(cmdline, key)
    ]
    if iso and not missing_isolation:
        add(checks, "PASS", "host.core_isolation", f"active isolated CPUs: {iso}")
    else:
        add(
            checks,
            "WARN",
            "host.core_isolation",
            f"isolated={iso or 'missing'} missing={','.join(missing_isolation) or 'none'}",
        )

    numa_balancing = read_one_line(Path("/proc/sys/kernel/numa_balancing"))
    if numa_balancing == "0":
        add(checks, "PASS", "host.numa_balancing", "disabled")
    else:
        add(checks, "WARN", "host.numa_balancing", f"value={numa_balancing or 'missing'}")

    sudo = run_quiet(["sudo", "-n", "true"])
    if sudo.returncode == 0:
        add(checks, "PASS", "host.sudo_cached", "sudo credentials are cached")
    else:
        add(checks, "WARN", "host.sudo_cached", "sudo -n true failed; run sudo -v before artifact actions")

    background = active_background_load()
    info["background_load"] = background
    if background:
        add(
            checks,
            "WARN",
            "host.background_load",
            "active OpenWhisk/VMFork processes may contaminate E2E latency: " + "; ".join(background[:3]),
        )
    else:
        add(checks, "PASS", "host.background_load", "no active OpenWhisk/VMFork experiment processes found")

    shmem_enabled = read_one_line(Path("/sys/kernel/mm/transparent_hugepage/shmem_enabled"))
    nr_hugepages = read_one_line(Path("/proc/sys/vm/nr_hugepages"))
    info["shmem_enabled"] = shmem_enabled
    info["nr_hugepages"] = nr_hugepages
    if shmem_enabled and "[always]" in shmem_enabled:
        add(checks, "PASS", "host.thp_shmem", shmem_enabled)
    else:
        add(checks, "WARN", "host.thp_shmem", shmem_enabled or "missing")
    add(checks, "INFO", "host.nr_hugepages", f"current nr_hugepages={nr_hugepages or 'missing'}")
    return info


def check_artifact(checks: list[Check], artifact: Path) -> dict[str, Any]:
    info: dict[str, Any] = {"artifact": str(artifact)}
    if artifact.exists():
        add(checks, "PASS", "artifact.exists", str(artifact))
    else:
        add(checks, "FAIL", "artifact.exists", f"missing: {artifact}")
        return info

    cache_paths = [
        artifact / "cvm_os/build/CMakeCache.txt",
        artifact / "cvm_os/build/kernel/CMakeCache.txt",
        artifact / "cvm_os/build/user/system-services/CMakeCache.txt",
    ]
    merged_cache: dict[str, str] = {}
    for cache_path in cache_paths:
        merged_cache.update(parse_cmake_cache(cache_path))
    info["cmake"] = merged_cache

    for flag in (
        "CHCORE_SPLIT_CONTAINER",
        "CHCORE_SPLIT_CONTAINER_HPAGE",
        "CHCORE_SPLIT_CONTAINER_LIBTMPFS",
        "CHCORE_SPLIT_CONTAINER_SYNC",
    ):
        value = merged_cache.get(flag)
        if value == "ON":
            add(checks, "PASS", f"artifact.flag.{flag}", value)
        else:
            add(checks, "FAIL", f"artifact.flag.{flag}", f"value={value or 'missing'}")

    plat = merged_cache.get("CHCORE_PLAT")
    if plat == "intel_tdx":
        add(checks, "PASS", "artifact.platform", plat)
    elif plat:
        add(checks, "WARN", "artifact.platform", f"CHCORE_PLAT={plat}")
    else:
        tdx_boot = artifact / "cvm_os/kernel/arch/x86_64/boot/intel_tdx/CMakeLists.txt"
        if tdx_boot.exists():
            add(checks, "PASS", "artifact.platform", "intel_tdx boot support present")
        else:
            add(checks, "WARN", "artifact.platform", "CHCORE_PLAT missing and intel_tdx boot file missing")

    simulate = artifact / "cvm_os/build/simulate.sh"
    simulate_text = read_text(simulate) or ""
    if "tdx-guest" in simulate_text and "confidential-guest-support=tdx" in simulate_text:
        add(checks, "PASS", "artifact.qemu_tdx", "simulate.sh uses TDX guest options")
    else:
        add(checks, "WARN", "artifact.qemu_tdx", "simulate.sh TDX options not found")

    cvm_sh = artifact / "testcases/tools/cvm.sh"
    cvm_text = read_text(cvm_sh) or ""
    if "COFUNC_TDX_SMP" in cvm_text:
        add(checks, "PASS", "artifact.cvm_smp_override", "COFUNC_TDX_SMP supported")
    else:
        add(checks, "WARN", "artifact.cvm_smp_override", "COFUNC_TDX_SMP not found in cvm.sh")

    template = artifact / "testcases/tools/template.py"
    template_text = read_text(template) or ""
    for label in ("t_network", "SYS_SC_PRINT_STAT", "STAT_T_GRANT"):
        if label in template_text:
            add(checks, "INFO", f"artifact.template.{label}", "present in template.py")
        else:
            add(checks, "WARN", f"artifact.template.{label}", "missing in template.py")

    ablation_tasks = {}
    for task in ("run_sc_fork_noenc", "run_sc_fork_noenc_nomem"):
        task_info = inspect_ablation_task(artifact, task)
        ablation_tasks[task] = task_info
        if not task_info["params_exists"]:
            add(checks, "WARN", f"artifact.ablation.{task}", "params missing")
        elif not task_info["action_exists"]:
            add(checks, "WARN", f"artifact.ablation.{task}", "params exist but action.sh is missing")
        elif task_info["valid_as_wired"]:
            add(
                checks,
                "PASS",
                f"artifact.ablation.{task}",
                f"suffixes={','.join(task_info['suffixes'])} target={task_info['action_target']}",
            )
        else:
            add(
                checks,
                "FAIL",
                f"artifact.ablation.{task}",
                "params have ablation suffixes but action does not consume them; running this task would not prove the ablation",
            )
    info["ablation_tasks"] = ablation_tasks

    return info


def summarize_function_log(log_dir: Path, fn_name: str) -> dict[str, Any] | None:
    path = log_dir / fn_name / "sc_fork.log"
    rows = load_sc_fork_log(path)
    if not rows:
        return None
    keys = [
        "t_e2e",
        "t_exec",
        "t_boot_lean",
        "t_boot_sc",
        "t_boot_func",
        "t_encrypt_exec",
        "t_grant_exec",
        "t_delegate_exec",
        "t_grant_import",
        "n_hcalls_exec",
        "n_cow",
        "t_pgfault",
        "n_accept",
        "t_network",
    ]
    summary: dict[str, Any] = {
        "path": str(path),
        "samples": len(rows),
        "keys": sorted({key for row in rows for key in row}),
    }
    for key in keys:
        value = mean_key(rows, key)
        if value is not None:
            summary[key] = value
    return summary


def app_value_from_logs(log_dir: Path, app_name: str, target: dict[str, Any]) -> dict[str, Any] | None:
    members = target.get("members", [app_name])
    fn_summaries = []
    for member in members:
        summary = summarize_function_log(log_dir, member)
        if summary is None:
            return None
        fn_summaries.append(summary)
    app_summary: dict[str, Any] = {
        "members": members,
        "samples": min(int(s["samples"]) for s in fn_summaries),
        "member_summaries": fn_summaries,
    }
    for key in (
        "t_e2e",
        "t_exec",
        "t_boot_lean",
        "t_boot_sc",
        "t_boot_func",
        "t_encrypt_exec",
        "t_grant_exec",
        "t_delegate_exec",
        "n_hcalls_exec",
        "n_cow",
    ):
        vals = [s[key] for s in fn_summaries if key in s]
        if len(vals) == len(fn_summaries):
            app_summary[key] = sum(float(v) for v in vals)
    keys = set()
    for summary in fn_summaries:
        keys.update(summary.get("keys", []))
    app_summary["keys"] = sorted(keys)
    return app_summary


def check_result(checks: list[Check], result_dir: Path | None) -> dict[str, Any]:
    info: dict[str, Any] = {}
    if result_dir is None:
        add(checks, "WARN", "result.exists", "no result directory selected")
        return info
    info["result_dir"] = str(result_dir)
    if not result_dir.exists():
        add(checks, "FAIL", "result.exists", f"missing: {result_dir}")
        return info
    add(checks, "PASS", "result.exists", str(result_dir))

    run_env = parse_key_value_file(result_dir / "run-env.txt")
    info["run_env"] = run_env
    for key in (
        "tdx",
        "prepare_performance",
        "core_isolated",
        "taskset_cpus",
        "tdx_smp",
        "kvm_srcversion",
        "kvm_intel_srcversion",
    ):
        if key in run_env:
            add(checks, "INFO", f"result.env.{key}", run_env[key])
    if run_env.get("tdx") == "Y":
        add(checks, "PASS", "result.env.tdx", "recorded TDX run")
    elif run_env:
        add(checks, "WARN", "result.env.tdx", f"tdx={run_env.get('tdx', 'missing')}")

    taskset_count = cpu_list_count(run_env.get("taskset_cpus"))
    tdx_smp = run_env.get("tdx_smp")
    if taskset_count is not None and tdx_smp and tdx_smp.isdigit():
        tdx_smp_count = int(tdx_smp)
        if tdx_smp_count <= taskset_count:
            add(
                checks,
                "PASS",
                "result.env.tdx_smp_affinity",
                f"tdx_smp={tdx_smp_count} taskset_cpu_count={taskset_count}",
            )
        else:
            add(
                checks,
                "WARN",
                "result.env.tdx_smp_affinity",
                f"tdx_smp={tdx_smp_count} exceeds taskset_cpu_count={taskset_count}; guest vCPUs are oversubscribed",
            )

    for name in ("validation.txt", "dmesg-kvm-errors.log"):
        path = result_dir / name
        text = read_text(path)
        if text is None:
            add(checks, "WARN", f"result.{name}", "missing")
        elif text.strip():
            add(checks, "FAIL", f"result.{name}", f"non-empty: {path}")
        else:
            add(checks, "PASS", f"result.{name}", "empty")

    log_dir = result_dir / "log"
    if not log_dir.exists():
        add(checks, "FAIL", "result.log_dir", f"missing: {log_dir}")
        return info

    apps: dict[str, Any] = {}
    for app_name, target in FIG11_TDX_TARGETS.items():
        summary = app_value_from_logs(log_dir, app_name, target)
        if summary is None:
            continue
        actual = summary.get("t_e2e")
        target_cofunc = float(target["cofunc"])
        ratio = float(actual) / target_cofunc if actual is not None else None
        summary["fig11_target_cofunc"] = target_cofunc
        summary["fig11_ratio"] = ratio
        apps[app_name] = summary
        if ratio is None:
            add(checks, "WARN", f"result.fig11.{app_name}", "missing t_e2e")
        elif ratio <= 1.30:
            add(
                checks,
                "PASS",
                f"result.fig11.{app_name}",
                f"actual={fmt_seconds(float(actual))} target~={fmt_seconds(target_cofunc)} ratio={fmt_ratio(ratio)}",
            )
        else:
            add(
                checks,
                "FAIL",
                f"result.fig11.{app_name}",
                f"actual={fmt_seconds(float(actual))} target~={fmt_seconds(target_cofunc)} ratio={fmt_ratio(ratio)}",
            )

        boot_func = summary.get("t_boot_func")
        if isinstance(boot_func, (int, float)):
            if float(boot_func) <= 0.002:
                add(checks, "PASS", f"result.startup_stage2.{app_name}", f"t_boot_func={float(boot_func)*1000:.2f} ms")
            else:
                add(
                    checks,
                    "WARN",
                    f"result.startup_stage2.{app_name}",
                    f"t_boot_func={float(boot_func)*1000:.2f} ms > paper fork target <2 ms",
                )

        if app_name in TABLE3_TDX_OVERHEADS and "t_exec" in summary:
            exec_time = float(summary["t_exec"])
            grant = float(summary.get("t_grant_exec", 0.0))
            encrypt = float(summary.get("t_encrypt_exec", 0.0))
            delegate = float(summary.get("t_delegate_exec", 0.0))
            if exec_time > 0:
                grant_pct = grant / exec_time * 100.0
                encrypt_pct = encrypt / exec_time * 100.0
                delegate_pct = delegate / exec_time * 100.0
                paper = TABLE3_TDX_OVERHEADS[app_name]
                summary["observed_memgrant_pct_of_exec"] = grant_pct
                summary["observed_encrypt_pct_of_exec"] = encrypt_pct
                summary["observed_delegate_pct_of_exec"] = delegate_pct
                if grant_pct <= float(paper["memgrant_pct"]) * 2.0 + 1.0:
                    level = "PASS"
                else:
                    level = "WARN"
                add(
                    checks,
                    level,
                    f"result.table3_memgrant.{app_name}",
                    f"observed~{grant_pct:.1f}% of exec, paper={paper['memgrant_pct']}%",
                )

    if not apps:
        add(checks, "WARN", "result.fig11", "no Fig. 11 TDX workloads found in result logs")
    info["apps"] = apps

    all_keys = set()
    for app in apps.values():
        all_keys.update(app.get("keys", []))
    for key in ("t_pgfault", "n_accept", "t_network"):
        if key in all_keys:
            add(checks, "PASS", f"result.instrumentation.{key}", "present in sc_fork logs")
        else:
            add(checks, "WARN", f"result.instrumentation.{key}", "missing from sc_fork logs")
    if "t_grant_exec" in all_keys:
        add(
            checks,
            "INFO",
            "result.instrumentation.t_grant_exec",
            "present; in this TDX ChCore port it maps to sc_t_accept",
        )
    return info


def print_report(checks: list[Check], data: dict[str, Any]) -> None:
    print("CoFunc TDX paper-readiness check")
    print("target:   approximate CoFunc TDX bars digitized from paper PDF Fig. 11")
    print(f"artifact: {data.get('artifact', {}).get('artifact', '-')}")
    print(f"result:   {data.get('result', {}).get('result_dir', '-')}")
    print()

    groups = [
        ("Host", "host."),
        ("Artifact", "artifact."),
        ("Result", "result."),
    ]
    for title, prefix in groups:
        rows = [check for check in checks if check.name.startswith(prefix)]
        if not rows:
            continue
        print(title)
        for check in rows:
            print(f"  [{check.level:<4}] {check.name:<42} {check.detail}")
        print()

    result = data.get("result", {})
    apps = result.get("apps", {})
    if apps:
        print("Fig. 11 TDX approximate comparison")
        print(f"  {'app':<28} {'actual':>10} {'target~':>10} {'ratio':>8} {'t_exec':>10} {'grant':>10} {'n_cow':>8}")
        for app_name in FIG11_TDX_TARGETS:
            app = apps.get(app_name)
            if not app:
                continue
            print(
                f"  {app_name:<28} "
                f"{fmt_seconds(app.get('t_e2e')):>10} "
                f"{fmt_seconds(app.get('fig11_target_cofunc')):>10} "
                f"{fmt_ratio(app.get('fig11_ratio')):>8} "
                f"{fmt_seconds(app.get('t_exec')):>10} "
                f"{fmt_seconds(app.get('t_grant_exec')):>10} "
                f"{app.get('n_cow', '-'):>8.0f}" if isinstance(app.get("n_cow"), (int, float)) else
                f"  {app_name:<28} {fmt_seconds(app.get('t_e2e')):>10} {fmt_seconds(app.get('fig11_target_cofunc')):>10} {fmt_ratio(app.get('fig11_ratio')):>8}"
            )
        print()

    counts = {level: sum(1 for check in checks if check.level == level) for level in ("FAIL", "WARN", "PASS", "INFO")}
    print(f"Summary: FAIL={counts['FAIL']} WARN={counts['WARN']} PASS={counts['PASS']} INFO={counts['INFO']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact", type=Path, default=DEFAULT_ARTIFACT)
    parser.add_argument(
        "--results",
        type=Path,
        help="Result directory. Defaults to latest results/* directory with sc_fork logs.",
    )
    parser.add_argument("--results-root", type=Path, default=Path("results"))
    parser.add_argument("--expected-kvm-srcversion", default=os.environ.get("EXPECTED_KVM_SRCVERSION", DEFAULT_EXPECTED_KVM))
    parser.add_argument(
        "--expected-kvm-intel-srcversion",
        default=os.environ.get("EXPECTED_KVM_INTEL_SRCVERSION", DEFAULT_EXPECTED_KVM_INTEL),
    )
    parser.add_argument("--json", type=Path, help="Write machine-readable audit JSON to this path")
    parser.add_argument("--strict", action="store_true", help="Exit nonzero if any FAIL checks are found")
    args = parser.parse_args()

    checks: list[Check] = []
    data: dict[str, Any] = {}
    data["host"] = check_host(checks, args.expected_kvm_srcversion, args.expected_kvm_intel_srcversion)
    data["artifact"] = check_artifact(checks, args.artifact)
    selected_result = args.results if args.results else latest_result_dir(args.results_root)
    data["result"] = check_result(checks, selected_result)

    print_report(checks, data)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "checks": [check.__dict__ for check in checks],
            "data": data,
            "summary": {level: sum(1 for check in checks if check.level == level) for level in ("FAIL", "WARN", "PASS", "INFO")},
        }
        args.json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")

    if args.strict and any(check.level == "FAIL" for check in checks):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
