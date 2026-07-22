#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ANALYZER = REPO / "scripts/analyze_cofunc_prefault_fault_savings.py"
WORKLOADS = [
    "fn_py_compression",
    "fn_py_face_detection",
    "fn_py_image_processing",
    "fn_py_sentiment",
    "fn_py_video_processing",
    "fn_py_dna_visualisation",
    "fn_js_thumbnailer",
    "fn_js_uploader",
    "chain_js_alexa/fn_js_alexa_frontend",
    "chain_js_alexa/fn_js_alexa_interact",
    "chain_js_alexa/fn_js_alexa_smarthome",
    "chain_js_alexa/fn_js_alexa_tv",
]


class AnalyzeCoFuncPrefaultFaultSavingsTest(unittest.TestCase):
    def write_mode(self, root: Path, *, prefault: bool, unpaired: bool = False) -> None:
        trace_dir = root / "ept-trace"
        trace_dir.mkdir(parents=True)
        signal_lines = ["wall_ns\tmonotonic_ns\tsample\tphase"]
        trace_lines = ["trace_status\tready"]
        map_lines = []
        for sample, workload in enumerate(WORKLOADS, start=1):
            faults = (10 + sample) if prefault else (1000 + sample)
            services = faults - 1 if unpaired and sample == 2 else faults
            signal_lines.extend(
                [
                    f"{sample * 100}\t{sample * 10}\t{sample}\tbegin",
                    f"{sample * 100 + 1}\t{sample * 10 + 1}\t{sample}\tend",
                ]
            )
            trace_lines.extend(
                [
                    f"trace_window\tbegin\t{sample}\t100.{sample}",
                    f"trace_window\tend\t{sample}\t101.{sample}",
                ]
            )
            map_lines.extend(
                [
                    f"@window_ept_exits[{sample}]: {faults}",
                    f"@window_ept_faults[{sample}]: {faults}",
                    f"@window_service_count[{sample}]: {services}",
                    f"@window_service_ns[{sample}]: {faults * 100}",
                    f"@window_error_code[{sample}, 2]: {faults}",
                ]
            )
            log = root / "cofunc-out" / "log" / workload / "sc_fork.log"
            log.parent.mkdir(parents=True)
            log.write_text(
                json.dumps(
                    {
                        "n_pgfault_exec": 2000 + sample,
                        "t_pgfault_exec": 0.01,
                        "t_exec": 1.0,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
        trace_lines.extend(["trace_status\tstopped", *map_lines])
        (trace_dir / "ept-events.tsv").write_text(
            "\n".join(trace_lines) + "\n", encoding="ascii"
        )
        (trace_dir / "signals.tsv").write_text(
            "\n".join(signal_lines) + "\n", encoding="ascii"
        )
        (trace_dir / "trace-result.txt").write_text(
            "command_rc=0\n"
            "trace_ready=1\n"
            "trace_stopped=1\n"
            "signal_begin_count=12\n"
            "signal_end_count=12\n"
            "loss_markers=0\n",
            encoding="ascii",
        )

    def run_analyzer(self, *, unpaired: bool = False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            on_demand = root / "on-demand"
            prefault = root / "prefault"
            output = root / "analysis"
            self.write_mode(on_demand, prefault=False, unpaired=unpaired)
            self.write_mode(prefault, prefault=True)
            completed = subprocess.run(
                [
                    str(ANALYZER),
                    "--on-demand-root",
                    str(on_demand),
                    "--prefault-root",
                    str(prefault),
                    "--output-dir",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            result = None
            if completed.returncode == 0:
                result = json.loads(
                    (output / "cofunc_prefault_fault_savings.json").read_text()
                )
            return completed, result

    def test_reports_function_and_alexa_savings(self):
        completed, result = self.run_analyzer()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(len(result["function_rows"]), 12)
        self.assertEqual(result["function_rows"][0]["ept_faults_saved"], 990)
        alexa = next(row for row in result["app_rows"] if row["app"] == "chain_js_alexa")
        self.assertEqual(alexa["ept_faults_saved"], 3960)

    def test_rejects_unpaired_ept_lifecycle(self):
        completed, _ = self.run_analyzer(unpaired=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("unpaired EPT accounting", completed.stderr)


if __name__ == "__main__":
    unittest.main()
