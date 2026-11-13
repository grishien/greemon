#!/usr/bin/env python3
"""Standalone hardware monitor with the Strata Overview look (code from github.com/Niko1221/Strata, MIT).

Runs the unmodified Strata Textual monitor against a tiny local /metrics endpoint that is fed by Strata's own
hardware sampler (serve/telemetry.py: NVML via ctypes, psutil). No Strata server, engine or model is needed.
LLM-specific tiles (speed, requests, experts, context) stay "--" / empty because nothing reports them.
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from serve.telemetry import Telemetry


def make_handler(tel: Telemetry, label: str):
    class H(BaseHTTPRequestHandler):
        def _json(self, code: int, body: dict) -> None:
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):  # noqa: N802
            if self.path == "/metrics":
                snap = tel.snapshot()
                self._json(200, {"live": {"state": "idle", "queued": 0}, "engine": {"model": label},
                                 "requests": [], "totals": {}, "hardware": snap["now"],
                                 "hardware_static": snap["static"], "history": snap["history"], "time": time.time()})
            elif self.path == "/v1/status":
                self._json(200, {"service": "hwmon", "model": label, "loaded": True, "concurrency": {}})
            else:
                self._json(404, {"error": "not found"})

        def log_message(self, *a):  # keep the TUI clean
            pass
    return H


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gpu", type=int, default=0, help="NVML index of the card (as nvidia-smi numbers them)")
    ap.add_argument("--label", default="hardware monitor", help="text shown where the model name is")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--theme", default="auto")
    ap.add_argument("--glyphs", default="auto", choices=["auto", "unicode", "solid", "ascii"])
    a = ap.parse_args()

    tel = Telemetry(gpu_index=a.gpu)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(tel, a.label))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{srv.server_address[1]}"

    from strata_cli.client import Endpoint
    from strata_cli.monitor import MonitorApp
    try:
        MonitorApp(Endpoint(url), None, interval=a.interval, theme=a.theme, glyphs=a.glyphs).run()
    finally:
        srv.shutdown()
        tel.close()


if __name__ == "__main__":
    main()
