#!/usr/bin/env python3
"""Validate app/opencode.json against the $schema URL it declares.

Fails fast in CI (app-test job) before the heavy boot test. Uses only
the stdlib plus the `jsonschema` package (pip-installed by the workflow).
"""
import json
import sys
import urllib.request
from pathlib import Path

import jsonschema

CONFIG = Path(__file__).resolve().parent.parent / "app" / "opencode.json"


def main() -> int:
    config = json.loads(CONFIG.read_text())
    schema_url = config.get("$schema")
    if not schema_url:
        print("FAIL: app/opencode.json declares no $schema")
        return 1
    req = urllib.request.Request(
        schema_url, headers={"User-Agent": "opencode-server-ci/1.0"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        schema = json.loads(resp.read().decode("utf-8"))
    jsonschema.validate(instance=config, schema=schema)
    print(f"PASS: app/opencode.json conforms to {schema_url}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
