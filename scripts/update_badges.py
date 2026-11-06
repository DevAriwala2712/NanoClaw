"""Regenerate the README badge block from the repository's own evidence files.

Usage: python3 scripts/update_badges.py [--check]
--check exits 1 when the README block is stale. Never edit the block by hand.
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
START, END = "<!-- badges:start -->", "<!-- badges:end -->"
GRID = "docs/benchmarks/2026-11-06-quantization-grid"
VM = "docs/benchmarks/2026-11-05-linux-vm"
TARGET_PCT = 10.0  # error target from docs/PLAN.md, M2 item 2


def colour(passed: int, total: int) -> str:
    return "brightgreen" if passed == total else ("orange" if passed else "red")


def badge(label: str, message: str, col: str, link: str) -> str:
    esc = lambda s: quote(s.replace("-", "--").replace("_", "__"), safe="")
    return (f'  <a href="{link}"><img alt="{label}: {message}" '
            f'src="https://img.shields.io/badge/{esc(label)}-{esc(message)}-{col}"></a>')


def build() -> str:
    # 1. grid completion: rows with exit==0 and no OOM kill
    with open(ROOT / GRID / "measurements.csv", newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    done = sum(1 for r in rows if r["exit"] == "0" and r["oom_kills"] == "0")
    # 2. worst held-out RSS error across the six models
    summary = json.loads((ROOT / GRID / "summary.json").read_text(encoding="utf-8"))
    worst = max(m["max_absolute_error_pct"] for m in summary)
    # 3. capped comparison, fixed vs scheduler
    vm = json.loads((ROOT / VM / "summary.json").read_text(encoding="utf-8"))
    base, adap = vm["baseline"], vm["adaptive"]
    # 4. pinned Zig version from the requirements doc
    zig = re.search(r"Current Requirement: Zig (\d+\.\d+\.\d+)",
                    (ROOT / "docs/ZIG_VERSION_REQUIREMENT.md").read_text(encoding="utf-8")).group(1)
    # 5. number of Zig test declarations (declared, not a pass count)
    tests = sum(len(re.findall(r"^\s*test\b", p.read_text(encoding="utf-8"), re.M))
                for p in (ROOT / "src").rglob("*.zig"))
    lines = [
        badge("1.5 GiB cap, 5 runs", f"scheduler {adap['success']}/{adap['runs']}, fixed {base['success']}/{base['runs']}",
              "brightgreen" if adap["success"] == adap["runs"] and base["success"] < base["runs"] else "orange",
              f"{VM}/REPORT.md"),
        badge("RSS error, held out", f"max {worst:.4f}%", "brightgreen" if worst < TARGET_PCT else "red",
              f"{GRID}/summary.json"),
        badge("calibration grid", f"{done} of {len(rows)} runs completed", colour(done, len(rows)),
              f"{GRID}/REPORT.md"),
        badge("Zig", zig, "blue", "docs/ZIG_VERSION_REQUIREMENT.md"),
        badge("Zig tests declared", str(tests), "blue", "src/tests.zig"),
    ]
    return "\n".join([START, '<p align="center">', *lines, "</p>", END])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    check = ap.parse_args().check
    text = README.read_text(encoding="utf-8")
    pat = re.compile(re.escape(START) + ".*?" + re.escape(END), re.S)
    if not pat.search(text):
        sys.exit(f"README has no {START} ... {END} block")
    new = pat.sub(lambda _: build(), text)
    if check:
        return int(new != text)
    README.write_text(new, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
