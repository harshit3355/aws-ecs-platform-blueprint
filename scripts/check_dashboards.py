#!/usr/bin/env python3
"""Validate every PromQL expression in the committed Grafana dashboards.

Grafana will happily load a dashboard whose queries are syntactically invalid;
the panels simply render empty. That failure mode is indistinguishable from "no
traffic yet", which is exactly when someone is looking at the dashboard. This
check parses each expression with promtool so a broken query fails the build
instead of failing an incident.

Requires promtool on PATH (ships with Prometheus).
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

DASHBOARD_DIR = (
    Path(__file__).resolve().parent.parent / "platform/observability/grafana/dashboards"
)


def expressions(dashboard: dict):
    """Yield (panel title, expr) for every query in a dashboard."""
    for panel in dashboard.get("panels", []):
        for target in panel.get("targets", []):
            expr = target.get("expr", "").strip()
            if expr:
                yield panel.get("title", "<untitled>"), expr


def main() -> int:
    promtool = shutil.which("promtool")
    if promtool is None:
        print("promtool not found on PATH; install Prometheus to run this check.")
        return 2

    files = sorted(DASHBOARD_DIR.glob("*.json"))
    if not files:
        print(f"no dashboards found under {DASHBOARD_DIR}")
        return 1

    checked = failed = 0
    for path in files:
        dashboard = json.loads(path.read_text(encoding="utf-8"))
        for title, expr in expressions(dashboard):
            checked += 1
            # S603: the argument list is fixed and the only variable is a
            # PromQL string read from a file in this repository, passed as
            # an argv element with no shell involved.
            result = subprocess.run(  # noqa: S603
                [promtool, "--experimental", "promql", "format", expr],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                failed += 1
                print(f"INVALID  {path.name} :: {title}")
                print(f"         {result.stderr.strip().splitlines()[0]}")
                print(f"         {expr}")

    print(
        f"checked {checked} PromQL expressions across {len(files)} "
        f"dashboards; {failed} invalid"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
