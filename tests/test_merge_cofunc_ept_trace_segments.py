#!/usr/bin/env python3

import csv
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
MERGER = REPO / "scripts/merge_cofunc_ept_trace_segments.py"


class MergeCoFuncEptTraceSegmentsTest(unittest.TestCase):
    def write_segment(
        self,
        root: Path,
        samples: range,
        *,
        command_rc: int,
        unpaired: bool = False,
    ) -> None:
        trace = root / "ept-trace"
        trace.mkdir(parents=True)
        signal_lines = ["wall_ns\tmonotonic_ns\tsample\tphase"]
        trace_lines = ["trace_status\tready"]
        map_lines = []
        for local, sample in enumerate(samples, start=1):
            signal_lines.extend(
                [
                    f"{sample}00\t{sample}0\t{sample}\tbegin",
                    f"{sample}01\t{sample}1\t{sample}\tend",
                ]
            )
            trace_lines.extend(
                [
                    f"trace_window\tbegin\t{local}\t100.{sample}",
                    f"trace_window\tend\t{local}\t101.{sample}",
                ]
            )
            faults = sample * 100
            services = faults - 1 if unpaired and sample == 7 else faults
            map_lines.extend(
                [
                    f"@window_ept_exits[{local}]: {faults}",
                    f"@window_ept_faults[{local}]: {faults}",
                    f"@window_error_code[{local}, 2]: {faults}",
                    f"@window_service_count[{local}]: {services}",
                    f"@window_service_ns[{local}]: {faults * 10}",
                ]
            )
        trace_lines.extend(["trace_status\tstopped", *map_lines])
        (trace / "signals.tsv").write_text(
            "\n".join(signal_lines) + "\n", encoding="ascii"
        )
        (trace / "ept-events.tsv").write_text(
            "\n".join(trace_lines) + "\n", encoding="ascii"
        )
        count = len(samples)
        (trace / "trace-result.txt").write_text(
            f"command_rc={command_rc}\n"
            "trace_ready=1\n"
            "trace_stopped=1\n"
            f"signal_begin_count={count}\n"
            f"signal_end_count={count}\n"
            "loss_markers=0\n",
            encoding="ascii",
        )

    def run_merge(self, *, unpaired: bool = False):
        directory = tempfile.TemporaryDirectory()
        root = Path(directory.name)
        partial = root / "partial"
        thumbnail = root / "thumbnail"
        resume = root / "resume"
        output = root / "merged"
        self.write_segment(partial, range(1, 7), command_rc=124)
        self.write_segment(
            thumbnail, range(7, 8), command_rc=0, unpaired=unpaired
        )
        self.write_segment(resume, range(8, 13), command_rc=0)
        command = [str(MERGER), "merge"]
        for segment, samples, command_rc in (
            (partial, "1-6", "124"),
            (thumbnail, "7-7", "0"),
            (resume, "8-12", "0"),
        ):
            command.extend(
                [
                    "--segment",
                    str(segment),
                    "--segment-samples",
                    samples,
                    "--segment-command-rc",
                    command_rc,
                ]
            )
        command.extend(["--output-dir", str(output)])
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
        return directory, completed, output

    def test_merges_local_windows_to_stable_sample_ids(self):
        directory, completed, output = self.run_merge()
        self.addCleanup(directory.cleanup)
        self.assertEqual(completed.returncode, 0, completed.stderr)

        with (output / "signals.tsv").open(newline="", encoding="ascii") as file:
            signals = list(csv.DictReader(file, delimiter="\t"))
        self.assertEqual(
            [(row["sample"], row["phase"]) for row in signals],
            [
                (str(sample), phase)
                for sample in range(1, 13)
                for phase in ("begin", "end")
            ],
        )
        trace = (output / "ept-events.tsv").read_text()
        self.assertIn("trace_window\tbegin\t7\t100.7", trace)
        self.assertIn("@window_ept_faults[7]: 700", trace)
        self.assertIn("@window_ept_faults[12]: 1200", trace)
        result = (output / "trace-result.txt").read_text()
        self.assertIn("signal_begin_count=12", result)
        provenance = json.loads((output / "merge-provenance.json").read_text())
        self.assertEqual(provenance["samples"], list(range(1, 13)))
        self.assertEqual(len(provenance["segments"]), 3)

    def test_rejects_unpaired_segment(self):
        directory, completed, output = self.run_merge(unpaired=True)
        self.addCleanup(directory.cleanup)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("unpaired EPT lifecycle", completed.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
