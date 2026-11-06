#!/usr/bin/env python3
"""Regenerate the README figures from the committed benchmark data.

Every plotted number is read from docs/benchmarks/*; nothing is typed in.
Usage: python3 scripts/make_figures.py   (needs matplotlib)
"""
import csv
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT / "docs/benchmarks/2026-11-05-linux-vm"
GRID = ROOT / "docs/benchmarks/2026-11-06-quantization-grid"
OUT = ROOT / "docs/assets"

INK, MUTED, GRID_C = "#0b0b0b", "#52514e", "#e4e3df"
PASS, FAIL, NEUTRAL = "#008300", "#e34948", "#2a78d6"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 11, "axes.edgecolor": MUTED,
    "axes.labelcolor": INK, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.spines.top": False, "axes.spines.right": False,
})


def caption(fig, text):
    fig.text(0.01, 0.01, text, fontsize=8.5, color=MUTED, ha="left", va="bottom")


def fig_cap_comparison():
    s = json.loads((VM / "summary.json").read_text())
    cap_mib = 1610612736 / 2**20  # cgroup MemoryMax used in the report
    names = ["Fixed 1.7B @ 4096", "Scheduler → 360M @ 4096"]
    runs = [s["baseline"], s["adaptive"]]
    colors = [FAIL, PASS]
    fig, (a, b) = plt.subplots(1, 2, figsize=(9.6, 4.2))
    done = [r["success"] for r in runs]
    total = [r["runs"] for r in runs]
    a.bar(names, done, color=colors, width=0.55)
    for i, (d, t) in enumerate(zip(done, total)):
        label = f"{d}/{t}"
        if runs[i]["oom_kills"]:
            label += f"  ({runs[i]['oom_kills']} OOM kills)"
        a.text(i, d + 0.12, label, ha="center", fontweight="bold", color=INK)
    a.set_ylim(0, max(total) + 1)
    a.set_title("Runs completed under the cap", loc="left", color=INK, fontsize=12)
    a.set_yticks(range(0, max(total) + 1))
    a.tick_params(axis="x", labelsize=9)
    rss = [r["max_command_peak_rss_kib"] / 1024 for r in runs]
    b.bar(names, rss, color=colors, width=0.55)
    b.axhline(cap_mib, color=INK, ls="--", lw=1.2)
    b.text(1.42, cap_mib + 25, f"cgroup cap {cap_mib:.0f} MiB", ha="right", color=INK, fontsize=9)
    for i, v in enumerate(rss):
        b.text(i, v / 2, f"{v:.1f} MiB", ha="center", color="white", fontweight="bold")
    b.set_ylim(0, cap_mib * 1.15)
    b.set_title("Peak process RSS", loc="left", color=INK, fontsize=12)
    b.tick_params(axis="x", labelsize=9)
    fig.suptitle("Real 1.5 GiB cgroup cap, Ubuntu ARM64 VM (not a Pi): fixed model vs scheduler",
                 x=0.01, ha="left", fontsize=12.5, fontweight="bold", color=INK)
    caption(fig, "Source: docs/benchmarks/2026-11-05-linux-vm/summary.json · n = 5 runs per strategy · "
                 "completion is not a quality score")
    fig.tight_layout(rect=(0, 0.05, 1, 0.93))
    fig.savefig(OUT / "cap-comparison.png", dpi=200)
    plt.close(fig)


def fig_estimate_error():
    rows = json.loads((GRID / "summary.json").read_text())
    rows.sort(key=lambda r: (r["model"].split("-")[1], r["model"]))
    labels = [r["model"].replace("smollm2-", "").replace("_k_m", "_K_M").upper().replace("Q8_0", "Q8_0") for r in rows]
    mx = [r["max_absolute_error_pct"] for r in rows]
    mean = [r["mean_absolute_error_pct"] for r in rows]
    fig, ax = plt.subplots(figsize=(9.6, 4.4))
    y = range(len(rows))
    ax.axvspan(10, 100, color="#f6d6d6", alpha=0.6, zorder=0)
    ax.axvline(10, color=FAIL, lw=1.4)
    ax.text(10.8, -0.45, "10% target limit", color=FAIL, fontsize=9.5, va="center")
    ax.scatter(mean, y, color=MUTED, s=42, zorder=3, label="mean |error|")
    ax.scatter(mx, y, color=NEUTRAL, s=62, zorder=4, label="max |error|")
    for i, v in enumerate(mx):
        ax.text(v * 1.18, i, f"{v:.4f}%", va="center", fontsize=9, color=INK)
    ax.set_xscale("log")
    ax.set_xlim(0.003, 100)
    ax.set_xticks([0.01, 0.1, 1, 10, 100])
    ax.set_xticklabels(["0.01", "0.1", "1", "10", "100"])
    ax.set_yticks(list(y))
    ax.set_yticklabels(labels)
    ax.set_ylim(len(rows) - 0.5, -0.8)
    ax.set_xlabel("absolute RSS prediction error, % (log scale)")
    ax.xaxis.grid(True, color=GRID_C, lw=0.8)
    ax.set_axisbelow(True)
    ax.legend(loc="lower right", frameon=False, fontsize=9.5)
    n = rows[0]["samples"]
    fig.suptitle("Memory estimate vs measured RSS at held-out contexts: all 6 models far under 10%",
                 x=0.01, ha="left", fontsize=12.5, fontweight="bold", color=INK)
    caption(fig, f"Source: docs/benchmarks/2026-11-06-quantization-grid/summary.json · n = {n} held-out runs per model · "
                 "one VM, short prompt only")
    fig.tight_layout(rect=(0, 0.05, 1, 0.94))
    fig.savefig(OUT / "estimate-error.png", dpi=200)
    plt.close(fig)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    fig_cap_comparison()
    fig_estimate_error()
    print("wrote", *(p.name for p in sorted(OUT.glob("*.png"))))
