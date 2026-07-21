#!/usr/bin/env python3

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
ANALYZER = REPO / "scripts/analyze_cofunc_ept_trace.py"


class AnalyzeCoFuncEptTraceTest(unittest.TestCase):
    def run_analyzer(
        self,
        *,
        gated_event: bool,
        paired: bool = True,
        addressed: bool = True,
        fault_address: int = 6144,
    ):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            analyzer_log = root / "analyzer.jsonl"
            run_log = root / "run.log"
            trace = root / "trace.tsv"
            signals = root / "signals.tsv"
            trace_result = root / "trace-result.txt"
            output = root / "analysis"

            analyzer_log.write_text(
                json.dumps(
                    {
                        "t_exec": 1.0,
                        "n_accept_exec": 0,
                        "n_pgfault_exec": 10,
                        "t_pgfault_exec": 0.01,
                        "t_pgfault_exec_cycles": 20,
                        "sc_guest_tsc_hz": 2000,
                        "sc_host_gpa": 0,
                        "sc_host_mem_size": 12288,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            run_log.write_text(
                "CoFunc private pre-fault: gpa=0x1000 bytes=4096 chunks=1 cycles=2\n"
                "t_import_done 100.0\n"
                "t_func_done 300.0\n",
                encoding="utf-8",
            )
            service = ""
            if gated_event:
                service = "EPT_SERVICE\t100.5\t1000001\t1000010\t101\t1001\t2\t2\t9"
                if addressed:
                    service += f"\t{fault_address}\t3"
                service += "\n"
            reentries_202 = 7 if paired else 6
            trace.write_text(
                "Attaching 7 probes...\n"
                "trace_status\tready\n"
                + service
                + "trace_status\tstopped\n"
                "@vm_ept_exits[101]: 5\n"
                "@vm_ept_exits[202]: 7\n"
                "@vm_ept_faults[101]: 5\n"
                "@vm_ept_faults[202]: 7\n"
                "@vm_service_count[101]: 5\n"
                f"@vm_service_count[202]: {reentries_202}\n"
                "@vm_service_ns[101]: 1100\n"
                "@vm_service_ns[202]: 2100\n",
                encoding="utf-8",
            )
            signals.write_text(
                "wall_ns\tmonotonic_ns\tsample\tphase\n"
                "99900000000\t1\t1\tbegin\n"
                "110000000000\t10100000001\t1\tend\n",
                encoding="ascii",
            )
            trace_result.write_text(
                "command_rc=0\n"
                "trace_ready=1\n"
                "trace_stopped=1\n"
                f"ept_service_records={int(gated_event)}\n"
                "vm_aggregate_records=8\n"
                "signal_begin_count=1\n"
                "signal_end_count=1\n"
                "loss_markers=0\n",
                encoding="ascii",
            )
            completed = subprocess.run(
                [
                    str(ANALYZER),
                    "--workload",
                    "fn_py_video_processing",
                    "--analyzer-log",
                    str(analyzer_log),
                    "--run-log",
                    str(run_log),
                    "--trace",
                    str(trace),
                    "--signals",
                    str(signals),
                    "--trace-result",
                    str(trace_result),
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
                    (output / "cofunc_ept_trace.json").read_text(encoding="utf-8")
                )
            return completed, result

    def test_accepts_multiple_pids_with_zero_gated_events(self):
        completed, result = self.run_analyzer(gated_event=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["qemu_pids"], [101, 202])
        self.assertEqual(result["vm_lifetime"]["fault_count"], 12)
        self.assertEqual(result["gated_ept_service"]["count"], 0)
        self.assertEqual(result["handler_ept_service_upper_bound"]["count"], 0)
        self.assertEqual(result["clock_domains"]["comparison"], "not_comparable")
        self.assertEqual(result["clock_domains"]["guest_handler_duration_s"], 200.0)
        self.assertEqual(result["clock_domains"]["host_signal_duration_s"], 10.1)
        self.assertTrue(result["prefault_target_passed"])

    def test_reports_nonzero_gated_event(self):
        completed, result = self.run_analyzer(gated_event=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(result["gated_ept_service"]["count"], 1)
        self.assertEqual(result["handler_ept_service_upper_bound"]["count"], 1)
        self.assertEqual(
            result["gated_fault_attribution"]["counts_by_range"][
                "private_prefault"
            ],
            1,
        )
        self.assertEqual(
            result["gated_fault_attribution"]["error_code_counts"], {"0x3": 1}
        )
        self.assertEqual([row["count"] for row in result["gated_bursts"]], [1])
        self.assertNotIn("handler_ept_service", result)
        self.assertFalse(result["prefault_target_passed"])

    def test_accepts_legacy_gated_event_without_address(self):
        completed, result = self.run_analyzer(gated_event=True, addressed=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            result["gated_fault_attribution"]["record_format"],
            "legacy_without_address",
        )

    def test_classifies_all_granted_memory_ranges_and_outside(self):
        cases = (
            (2048, "shared_prefix"),
            (6144, "private_prefault"),
            (10240, "reserved_tail"),
            (16384, "outside_granted_memory"),
        )
        for address, expected_range in cases:
            with self.subTest(expected_range=expected_range):
                completed, result = self.run_analyzer(
                    gated_event=True, fault_address=address
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(
                    result["gated_fault_attribution"]["counts_by_range"][
                        expected_range
                    ],
                    1,
                )

    def test_normalizes_tdx_shared_gpa_alias(self):
        completed, result = self.run_analyzer(
            gated_event=True, fault_address=(1 << 47) | 2048
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        attribution = result["gated_fault_attribution"]
        self.assertEqual(attribution["counts_by_range"]["shared_prefix"], 1)
        self.assertEqual(attribution["counts_by_visibility"]["shared_alias"], 1)
        self.assertEqual(
            attribution["shared_alias_masks_observed"], {"0x800000000000": 1}
        )

    def test_rejects_unpaired_lifecycle_per_pid(self):
        completed, _ = self.run_analyzer(gated_event=False, paired=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("unpaired EPT lifecycle for PID 202", completed.stderr)


if __name__ == "__main__":
    unittest.main()
