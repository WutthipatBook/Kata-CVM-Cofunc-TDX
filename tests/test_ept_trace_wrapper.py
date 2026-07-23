#!/usr/bin/env python3

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]


class EptTraceWrapperTest(unittest.TestCase):
    def test_root_launchers_are_not_checked_with_unprivileged_kill(self):
        wrapper = (REPO / "scripts/run_ept_trace_around.sh").read_text()
        self.assertIn(
            '! root_process_alive "$server_launcher_pid"',
            wrapper,
        )
        self.assertIn(
            '! root_process_alive "$trace_launcher_pid"',
            wrapper,
        )
        self.assertNotIn('! kill -0 "$server_launcher_pid"', wrapper)
        self.assertNotIn('! kill -0 "$trace_launcher_pid"', wrapper)

    def test_cleanup_refreshes_child_pids_and_stops_before_waiting(self):
        wrapper = (REPO / "scripts/run_ept_trace_around.sh").read_text()
        cleanup = wrapper[
            wrapper.index("stop_processes()") :
            wrapper.index("\n[[ $#", wrapper.index("stop_processes()"))
        ]
        self.assertIn('trace_pid=$(<"$trace_pidfile")', cleanup)
        self.assertIn('server_pid=$(<"$server_pidfile")', cleanup)
        self.assertLess(
            cleanup.index('kill -INT "$trace_pid"'),
            cleanup.index('wait "$trace_launcher_pid"'),
        )
        self.assertLess(
            cleanup.index('kill -TERM "$server_pid"'),
            cleanup.index('wait "$server_launcher_pid"'),
        )
        self.assertIn('kill -KILL "$trace_pid"', cleanup)
        self.assertIn('kill -KILL "$server_pid"', cleanup)


if __name__ == "__main__":
    unittest.main()
