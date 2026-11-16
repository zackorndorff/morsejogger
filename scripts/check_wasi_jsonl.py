#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Verify WASI JSON-lines contract and parity with the host Swift executable.

Usage: check_wasi_jsonl.py WASM_OUTPUT NATIVE_OUTPUT
No external Python dependencies.
"""
import json
import math
import sys
from pathlib import Path


def load_lines(filename):
    lines = Path(filename).read_text(encoding="utf-8").splitlines()
    if len(lines) != 5:
        raise AssertionError(f"{filename}: expected 5 JSON responses, got {len(lines)}")
    messages = []
    for number, line in enumerate(lines, start=1):
        message = json.loads(line)
        if not isinstance(message, dict) or "error" in message:
            raise AssertionError(f"{filename}: response {number} failed: {message}")
        if not all(field in message for field in ("snapshot", "events", "log")):
            raise AssertionError(f"{filename}: response {number} has missing fields")
        if not isinstance(message["events"], list) or not isinstance(message["log"], list):
            raise AssertionError(f"{filename}: response {number} has wrong events/log types")
        messages.append(message)
    return messages


def verify(messages):
    phases = [row["snapshot"]["phase"] for row in messages]
    if phases != ["ready", "listening", "listening", "listening", "finished"]:
        raise AssertionError(f"Wrong state transitions: {phases}")
    if messages[0]["snapshot"]["running"] or messages[-1]["snapshot"]["running"]:
        raise AssertionError("Ready/finished sessions must not be running")
    if messages[2]["snapshot"]["elapsed"] != 9:
        raise AssertionError("Tick did not advance session to nine seconds")
    tick_events = messages[2]["events"]
    if not any(e["kind"] == "receive" and e["voices"] for e in tick_events):
        raise AssertionError("Seeded tick should produce an on-air event with audio voices")
    if not any(e["kind"] == "transmit" and e["text"].startswith("CQ ") for e in messages[3]["events"]):
        raise AssertionError("CQ command did not cause a TX event")
    if not any(e["kind"] == "finished" for e in messages[4]["events"]):
        raise AssertionError("Stop command did not finish session")


def compare(wasm, native, path="root"):
    # Cross-target transcendental functions may differ by tiny amounts.
    if isinstance(wasm, float) and isinstance(native, (float, int)):
        if math.isclose(wasm, native, rel_tol=1e-8, abs_tol=1e-8):
            return
    if type(wasm) is not type(native):
        raise AssertionError(f"{path}: differing types {type(wasm).__name__} vs {type(native).__name__}")
    if isinstance(wasm, dict):
        if wasm.keys() != native.keys():
            raise AssertionError(f"{path}: keys differ: {wasm.keys()} vs {native.keys()}")
        for key in wasm:
            compare(wasm[key], native[key], f"{path}.{key}")
    elif isinstance(wasm, list):
        if len(wasm) != len(native):
            raise AssertionError(f"{path}: list lengths differ {len(wasm)} vs {len(native)}")
        for i, (left, right) in enumerate(zip(wasm, native)):
            compare(left, right, f"{path}[{i}]")
    elif wasm != native:
        raise AssertionError(f"{path}: WASM={wasm!r} native={native!r}")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: check_wasi_jsonl.py wasm.jsonl native.jsonl")
    wasm = load_lines(sys.argv[1])
    native = load_lines(sys.argv[2])
    verify(wasm)
    verify(native)
    compare(wasm, native)
    print("WASI protocol: 5/5 valid responses, transitions/TX/RX verified, deterministic native parity passed")


if __name__ == "__main__":
    main()
