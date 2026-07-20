#!/usr/bin/env python3
"""Turn authenticated guest HTTP signals into host trace-marker writes."""

from __future__ import annotations

import argparse
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


MARKERS = {
    "begin": b"COFUNC_EPT_BEGIN",
    "end": b"COFUNC_EPT_END",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--trace-marker", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    return parser.parse_args()


class SignalState:
    def __init__(self, token: str, marker_path: Path, log_path: Path) -> None:
        self.token = token
        self.marker_fd = os.open(marker_path, os.O_WRONLY | os.O_CLOEXEC)
        self.log = log_path.open("w", encoding="ascii", buffering=1)
        self.log.write("wall_ns\tmonotonic_ns\tsample\tphase\n")
        self.lock = threading.Lock()
        self.active_sample: str | None = None
        self.completed: set[str] = set()

    def signal(self, sample: str, phase: str) -> tuple[int, str]:
        if phase not in MARKERS or not sample.isdigit():
            return 400, "invalid signal"

        with self.lock:
            if phase == "begin":
                if self.active_sample is not None or sample in self.completed:
                    return 409, "unexpected begin"
                self.active_sample = sample
            elif self.active_sample != sample:
                return 409, "unexpected end"

            os.write(self.marker_fd, MARKERS[phase])
            self.log.write(
                f"{time.time_ns()}\t{time.monotonic_ns()}\t{sample}\t{phase}\n"
            )
            if phase == "end":
                self.completed.add(sample)
                self.active_sample = None
        return 204, ""


class SignalHandler(BaseHTTPRequestHandler):
    server: "SignalServer"

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path == "/health":
            self.send_response(204)
            self.end_headers()
            return

        parts = path.strip("/").split("/")
        if len(parts) != 3 or parts[0] != self.server.state.token:
            self.send_error(404)
            return
        status, message = self.server.state.signal(parts[1], parts[2])
        self.send_response(status)
        if message:
            payload = message.encode("ascii")
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:
            self.end_headers()

    def log_message(self, _format: str, *_args: object) -> None:
        return


class SignalServer(ThreadingHTTPServer):
    state: SignalState


def main() -> None:
    args = parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("port must be between 1024 and 65535")
    if not args.token.isalnum():
        raise SystemExit("token must be alphanumeric")

    state = SignalState(args.token, args.trace_marker, args.log)
    server = SignalServer((args.bind, args.port), SignalHandler)
    server.state = state
    print(f"signal_server=ready port={args.port}", flush=True)
    server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    main()
