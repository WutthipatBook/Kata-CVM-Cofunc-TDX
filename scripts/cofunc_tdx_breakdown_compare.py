#!/usr/bin/env python3
"""Compare a TDX CoFunc fork result with Fig. 11 and Table 3 paper targets."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any

from cofunc_tdx_paper_check import FIG11_TDX_TARGETS, TABLE3_TDX_OVERHEADS


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


def mean(rows: list[dict[str, Any]], key: str) -> float | None:
    vals = [float(row[key]) for row in rows if key in row and row[key] is not None]
    if not vals:
        return None
    return statistics.mean(vals)


def fmt_s(value: float | None) -> str:
    if value is None:
        return "-"
    if abs(value) < 0.01:
        return f"{value:.4f}"
    return f"{value:.3f}"


def fmt_ms(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value * 1000.0:.2f}"


def fmt_pct(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.1f}"


def fmt_ratio(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.2f}x"


def summarize_member(log_dir: Path, workload: str) -> dict[str, Any] | None:
    rows = load_rows(log_dir / workload / "sc_fork.log")
    if not rows:
        return None
    keys = {
        "t_e2e",
        "t_exec",
        "t_boot_lean",
        "t_boot_sc",
        "t_boot_func",
        "t_encrypt_exec",
        "t_grant_exec",
        "t_delegate_exec",
        "t_attest_import",
        "t_grant_import",
        "t_delegate_import",
        "n_hcalls_exec",
        "n_cow",
        "t_pgfault",
        "n_accept",
        "t_network",
    }
    summary: dict[str, Any] = {
        "workload": workload,
        "samples": len(rows),
        "keys": sorted({key for row in rows for key in row}),
    }
    for key in keys:
        value = mean(rows, key)
        if value is not None:
            summary[key] = value
    return summary


def summarize_app(log_dir: Path, app_name: str, target: dict[str, Any]) -> dict[str, Any] | None:
    members = target.get("members", [app_name])
    member_summaries = []
    for member in members:
        summary = summarize_member(log_dir, member)
        if summary is None:
            return None
        member_summaries.append(summary)

    app: dict[str, Any] = {
        "app": app_name,
        "label": target["label"],
        "members": members,
        "samples": min(int(summary["samples"]) for summary in member_summaries),
        "member_summaries": member_summaries,
        "paper_native_s": target["native"],
        "paper_cofunc_s": target["cofunc"],
        "paper_kata_s": target["kata"],
    }

    sum_keys = [
        "t_e2e",
        "t_exec",
        "t_boot_lean",
        "t_boot_sc",
        "t_boot_func",
        "t_encrypt_exec",
        "t_grant_exec",
        "t_delegate_exec",
        "t_attest_import",
        "t_grant_import",
        "t_delegate_import",
        "n_hcalls_exec",
        "n_cow",
    ]
    for key in sum_keys:
        vals = [summary[key] for summary in member_summaries if key in summary]
        if len(vals) == len(member_summaries):
            app[key] = sum(float(value) for value in vals)

    e2e = app.get("t_e2e")
    exec_s = app.get("t_exec")
    if isinstance(e2e, (int, float)):
        app["actual_over_paper_cofunc"] = float(e2e) / float(target["cofunc"])
        app["actual_over_paper_native"] = float(e2e) / float(target["native"])
        app["paper_kata_over_actual"] = float(target["kata"]) / float(e2e)
    boot_keys = ["t_boot_lean", "t_boot_sc", "t_boot_func"]
    if all(key in app for key in boot_keys):
        app["t_boot_total"] = sum(float(app[key]) for key in boot_keys)
    if isinstance(e2e, (int, float)) and "t_boot_total" in app:
        app["boot_pct_e2e"] = float(app["t_boot_total"]) / float(e2e) * 100.0

    if isinstance(exec_s, (int, float)) and exec_s > 0:
        encrypt = float(app.get("t_encrypt_exec", 0.0))
        grant = float(app.get("t_grant_exec", 0.0))
        delegate = float(app.get("t_delegate_exec", 0.0))
        app["encrypt_pct_exec"] = encrypt / float(exec_s) * 100.0
        app["grant_pct_exec"] = grant / float(exec_s) * 100.0
        app["delegate_pct_exec"] = delegate / float(exec_s) * 100.0
        app["other_pct_exec"] = (float(exec_s) - encrypt - grant - delegate) / float(exec_s) * 100.0
        if "n_hcalls_exec" in app:
            app["hcalls_per_ms"] = float(app["n_hcalls_exec"]) / (float(exec_s) * 1000.0)

    return app


def make_markdown(result_dir: Path, apps: list[dict[str, Any]]) -> str:
    lines = [
        "# CoFunc TDX Fig. 11 And Breakdown Comparison",
        "",
        f"Result: `{result_dir}`",
        "",
        "Important caveats:",
        "",
        "- Fig. 11 targets are approximate values digitized from the paper's log-scale PDF bars.",
        "- `grant%` is computed from `t_grant_exec`; in this TDX port that counter maps to ChCore `sc_t_accept`.",
        "- `hcalls/ms` is from `n_hcalls_exec`; it is not guaranteed to be identical to the paper's true `#Exits/ms` counter.",
        "- Current logs do not include `t_pgfault`, `n_accept`, or `t_network`, so this is a best-effort Table 3 comparison, not a full reproduction of every paper breakdown field.",
        "",
        "## Fig. 11 TDX Fork E2E",
        "",
        "| App | Actual CoFunc fork s | Paper CoFunc TDX approx s | Actual/Paper | Actual/Paper Native | Paper Kata/Actual |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for app in apps:
        lines.append(
            "| {label} | {actual} | {target} | {ratio} | {native_ratio} | {kata_ratio} |".format(
                label=app["label"],
                actual=fmt_s(app.get("t_e2e")),
                target=fmt_s(app.get("paper_cofunc_s")),
                ratio=fmt_ratio(app.get("actual_over_paper_cofunc")),
                native_ratio=fmt_ratio(app.get("actual_over_paper_native")),
                kata_ratio=fmt_ratio(app.get("paper_kata_over_actual")),
            )
        )

    lines += [
        "",
        "## Startup And Execution Split",
        "",
        "| App | E2E s | boot lean ms | boot sc ms | boot func ms | boot % E2E | exec s |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for app in apps:
        lines.append(
            "| {label} | {e2e} | {lean} | {sc} | {func} | {boot_pct} | {exec_s} |".format(
                label=app["label"],
                e2e=fmt_s(app.get("t_e2e")),
                lean=fmt_ms(app.get("t_boot_lean")),
                sc=fmt_ms(app.get("t_boot_sc")),
                func=fmt_ms(app.get("t_boot_func")),
                boot_pct=fmt_pct(app.get("boot_pct_e2e")),
                exec_s=fmt_s(app.get("t_exec")),
            )
        )

    lines += [
        "",
        "## Table 3-Like Execution Breakdown",
        "",
        "| App | encrypt % obs/paper | grant % obs/paper | delegate % obs/paper | other % obs/paper | hcalls/ms obs | paper #Exits/ms | n_cow |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for app in apps:
        paper = TABLE3_TDX_OVERHEADS.get(app["app"], {})
        lines.append(
            "| {label} | {enc}/{paper_enc} | {grant}/{paper_grant} | {delegate}/{paper_delegate} | {other}/{paper_other} | {hcalls} | {paper_exits} | {cow} |".format(
                label=app["label"],
                enc=fmt_pct(app.get("encrypt_pct_exec")),
                paper_enc=paper.get("encrypt_pct", "-"),
                grant=fmt_pct(app.get("grant_pct_exec")),
                paper_grant=paper.get("memgrant_pct", "-"),
                delegate=fmt_pct(app.get("delegate_pct_exec")),
                paper_delegate=paper.get("delegate_pct", "-"),
                other=fmt_pct(app.get("other_pct_exec")),
                paper_other=paper.get("others_pct", "-"),
                hcalls=fmt_pct(app.get("hcalls_per_ms")),
                paper_exits=paper.get("exits_per_ms", "-"),
                cow=f"{app.get('n_cow', 0):.0f}" if isinstance(app.get("n_cow"), (int, float)) else "-",
            )
        )

    worst = sorted(
        [app for app in apps if isinstance(app.get("actual_over_paper_cofunc"), (int, float))],
        key=lambda app: float(app["actual_over_paper_cofunc"]),
        reverse=True,
    )
    lines += [
        "",
        "## Initial Interpretation",
        "",
    ]
    if worst:
        worst_text = ", ".join(
            f"{app['label']} {float(app['actual_over_paper_cofunc']):.2f}x"
            for app in worst[:4]
        )
        lines.append(
            f"- Worst Fig. 11 gaps: {worst_text}."
        )
    grant_heavy = [
        app
        for app in apps
        if isinstance(app.get("grant_pct_exec"), (int, float))
        and app["app"] in TABLE3_TDX_OVERHEADS
        and float(app["grant_pct_exec"]) > float(TABLE3_TDX_OVERHEADS[app["app"]]["memgrant_pct"]) * 2.0 + 1.0
    ]
    if grant_heavy:
        lines.append(
            f"- Memory accept/grant share is much higher than Table 3 for: {', '.join(app['label'] for app in grant_heavy)}."
        )
    lines.append("- Startup-stage-2 `boot_func` is several ms in this run; the paper claims fork-mode stage 2 is under 2 ms, but that alone does not explain the multi-x e2e gaps.")
    lines.append("- The main gap is execution-stage latency: for most representative workloads, `t_exec` is already near the full e2e time.")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, required=True, help="TDX e2e result directory")
    parser.add_argument("--markdown", type=Path, help="Write Markdown report")
    parser.add_argument("--json", type=Path, help="Write JSON summary")
    args = parser.parse_args()

    log_dir = args.results / "log"
    apps = []
    for app_name, target in FIG11_TDX_TARGETS.items():
        summary = summarize_app(log_dir, app_name, target)
        if summary is not None:
            apps.append(summary)

    if not apps:
        raise SystemExit(f"no Fig. 11 workload logs found under {log_dir}")

    markdown = make_markdown(args.results, apps)
    print(markdown)

    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(markdown + "\n")
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({"result_dir": str(args.results), "apps": apps}, indent=2, sort_keys=True) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
