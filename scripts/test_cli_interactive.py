#!/usr/bin/env python3
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

"""Check that each JSON-lines request receives a response before stdin closes."""
import json
import selectors
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: test_cli_interactive.py COMMAND [ARG ...]")
    process = subprocess.Popen(
        sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    def request(line):
        process.stdin.write(line + "\n")
        process.stdin.flush()
        if not selector.select(timeout=2):
            raise AssertionError("CLI did not flush a response while stdin remained open")
        result = process.stdout.readline()
        if not result:
            raise AssertionError("CLI exited without a response")
        return json.loads(result)

    try:
        request('{"action":"configure","settings":{"seed":123,"mode":"single"}}')
        started = request('{"action":"start"}')
        assert started["snapshot"]["running"] is True
        request('{"action":"stop"}')
        restarted = request('{"action":"start"}')
        assert "single-use" in restarted["error"]
        invalid = request("not-json")
        assert invalid == {"error": "Invalid JSON or request"}
    finally:
        process.stdin.close()
        process.terminate()
        process.wait(timeout=2)
        selector.close()


if __name__ == "__main__":
    main()
