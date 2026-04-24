#!/usr/bin/env python3
"""
plot_results.py
Parses raw benchmark output files and generates comparison charts.

Produces:
  figures/fig_cpu_comparison.png     — CPU events/sec by thread count
  figures/fig_memory_comparison.png  — Memory bandwidth (GB/s)
  figures/fig_storage_iops.png       — Random read/write IOPS
  figures/fig_redis_latency.png      — Redis GET/SET latency (µs)
  figures/fig_mysql_throughput.png   — MySQL TPS vs thread count (replicates Fig 4.1)

Usage:
  pip install matplotlib pandas numpy seaborn
  python3 scripts/benchmarks/plot_results.py
"""

import os
import re
import sys
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import numpy as np
except ImportError:
    print("ERROR: matplotlib not installed. Run: pip install matplotlib numpy")
    sys.exit(1)

# ── Paths ──────────────────────────────────────────────────────────────────── #
REPO_ROOT = Path(__file__).resolve().parents[2]
RESULTS   = REPO_ROOT / "results"
FIGURES   = REPO_ROOT / "figures"
FIGURES.mkdir(exist_ok=True)

# ── Style ──────────────────────────────────────────────────────────────────── #
plt.rcParams.update({
    "font.family":    "serif",
    "font.size":      11,
    "axes.titlesize": 13,
    "axes.labelsize": 11,
    "legend.fontsize": 9,
    "figure.dpi":     150,
})

COLORS = {
    "native":              "#e41a1c",   # red
    "docker_host_vol":     "#377eb8",   # blue
    "docker_nat_vol":      "#4daf4a",   # green
    "docker_nat_aufs":     "#984ea3",   # purple
    "kvm":                 "#00bcd4",   # cyan (matches IBM paper)
}

LABELS = {
    "native":              "Native",
    "docker_host_vol":     "Docker net=host volume",
    "docker_nat_vol":      "Docker NAT volume",
    "docker_nat_aufs":     "Docker NAT OverlayFS",
    "kvm":                 "KVM qcow2",
}

# ── Helpers ────────────────────────────────────────────────────────────────── #

def read_file(path: Path) -> str:
    """Return file contents or empty string if not found."""
    if path.exists():
        return path.read_text(errors="replace")
    print(f"  [MISSING] {path.relative_to(REPO_ROOT)}")
    return ""


def parse_sysbench_cpu(text: str) -> dict[int, float]:
    """Extract {threads: events_per_second} from sysbench cpu output."""
    results = {}
    blocks = re.split(r"--- Threads:\s*(\d+) ---", text)
    for i in range(1, len(blocks), 2):
        threads = int(blocks[i])
        block   = blocks[i + 1]
        m = re.search(r"events per second:\s+([\d.]+)", block)
        if m:
            results[threads] = float(m.group(1))
    return results


def parse_sysbench_memory(text: str) -> float:
    """Extract MB/s from sysbench memory output."""
    m = re.search(r"transferred\s+\(([0-9.]+)\s*MiB/sec\)", text)
    if m:
        return float(m.group(1)) / 1024  # Convert to GB/s
    return 0.0


def parse_fio_iops(text: str, rw: str) -> float:
    """Extract IOPS from fio output for given rw type ('read' or 'write')."""
    pattern = rf"{rw}\s*:\s*IOPS=([0-9.]+[kK]?)"
    m = re.search(pattern, text, re.IGNORECASE)
    if m:
        val = m.group(1)
        if val.lower().endswith("k"):
            return float(val[:-1]) * 1000
        return float(val)
    return 0.0


def parse_redis_ops(text: str, op: str) -> float:
    """Extract ops/sec from redis-benchmark output."""
    m = re.search(rf"{op}.*?([0-9]+\.[0-9]+) requests per second", text)
    if m:
        return float(m.group(1))
    return 0.0


def parse_mysql_tps(text: str) -> dict[int, float]:
    """Extract {threads: tps} from sysbench oltp output blocks."""
    results = {}
    blocks = re.split(r"--- Threads:\s*(\d+) ---", text)
    for i in range(1, len(blocks), 2):
        threads = int(blocks[i])
        block   = blocks[i + 1]
        # transactions: N (M per sec)  or  tps: M
        m = re.search(r"transactions:\s+\d+\s+\(([0-9.]+)\s+per sec\)", block)
        if m:
            results[threads] = float(m.group(1))
    return results


def save(fig, name):
    path = FIGURES / name
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved → {path.relative_to(REPO_ROOT)}")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 1 — CPU benchmark
# ══════════════════════════════════════════════════════════════════════════════
print("\n[1/5] Generating CPU comparison chart...")

cpu_data = {
    "native":          parse_sysbench_cpu(read_file(RESULTS / "native" / "cpu.txt")),
    "docker_host_vol": parse_sysbench_cpu(read_file(RESULTS / "docker" / "cpu.txt")),
    "kvm":             parse_sysbench_cpu(read_file(RESULTS / "kvm"    / "cpu.txt")),
}

if any(cpu_data.values()):
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for key, data in cpu_data.items():
        if data:
            threads = sorted(data)
            events  = [data[t] for t in threads]
            ax.plot(threads, events, marker="o", color=COLORS[key],
                    label=LABELS[key], linewidth=1.8)
    ax.set_xlabel("Number of Threads")
    ax.set_ylabel("Events per Second")
    ax.set_title("CPU Benchmark — Sysbench Prime (events/sec vs. threads)")
    ax.legend()
    ax.grid(True, linestyle="--", alpha=0.5)
    save(fig, "fig_cpu_comparison.png")
else:
    print("  No CPU data found — skipping chart.")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 2 — Memory bandwidth
# ══════════════════════════════════════════════════════════════════════════════
print("\n[2/5] Generating memory bandwidth chart...")

mem_data = {
    "native":          parse_sysbench_memory(read_file(RESULTS / "native" / "memory.txt")),
    "docker_host_vol": parse_sysbench_memory(read_file(RESULTS / "docker" / "memory.txt")),
    "kvm":             parse_sysbench_memory(read_file(RESULTS / "kvm"    / "memory.txt")),
}

if any(mem_data.values()):
    fig, ax = plt.subplots(figsize=(6, 4))
    keys   = [k for k, v in mem_data.items() if v > 0]
    values = [mem_data[k] for k in keys]
    bars   = ax.bar(range(len(keys)), values,
                    color=[COLORS[k] for k in keys], width=0.5)
    ax.set_xticks(range(len(keys)))
    ax.set_xticklabels([LABELS[k] for k in keys], rotation=15, ha="right")
    ax.set_ylabel("Throughput (GB/s)")
    ax.set_title("Memory Bandwidth — Write Throughput")
    for bar, val in zip(bars, values):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.1,
                f"{val:.1f} GB/s", ha="center", va="bottom", fontsize=9)
    ax.grid(True, axis="y", linestyle="--", alpha=0.5)
    save(fig, "fig_memory_comparison.png")
else:
    print("  No memory data found — skipping chart.")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 3 — Storage IOPS
# ══════════════════════════════════════════════════════════════════════════════
print("\n[3/5] Generating storage IOPS chart...")

storage_configs = [
    ("native",          RESULTS / "native" / "storage.txt"),
    ("docker_host_vol", RESULTS / "docker" / "storage_volume.txt"),
    ("docker_nat_aufs", RESULTS / "docker" / "storage_overlayfs.txt"),
    ("kvm",             RESULTS / "kvm"    / "storage.txt"),
]

read_iops  = {}
write_iops = {}
for key, path in storage_configs:
    text = read_file(path)
    r = parse_fio_iops(text, "read")
    w = parse_fio_iops(text, "write")
    if r or w:
        read_iops[key]  = r / 1000  # Convert to K IOPS
        write_iops[key] = w / 1000

if read_iops or write_iops:
    keys = sorted(set(list(read_iops) + list(write_iops)),
                  key=lambda k: list(COLORS).index(k))
    x     = np.arange(len(keys))
    width = 0.35
    fig, ax = plt.subplots(figsize=(8, 4.5))
    bars_r = ax.bar(x - width/2, [read_iops.get(k, 0)  for k in keys],
                    width, label="Random Read",
                    color=[COLORS[k] for k in keys], alpha=0.9)
    bars_w = ax.bar(x + width/2, [write_iops.get(k, 0) for k in keys],
                    width, label="Random Write",
                    color=[COLORS[k] for k in keys], alpha=0.55, hatch="//")
    ax.set_xticks(x)
    ax.set_xticklabels([LABELS[k] for k in keys], rotation=15, ha="right")
    ax.set_ylabel("IOPS (thousands)")
    ax.set_title("Storage I/O — 4K Random Read/Write IOPS (Direct I/O, QD=32)")
    ax.legend(["Random Read", "Random Write"])
    ax.grid(True, axis="y", linestyle="--", alpha=0.5)
    save(fig, "fig_storage_iops.png")
else:
    print("  No storage data found — skipping chart.")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 4 — Redis latency
# ══════════════════════════════════════════════════════════════════════════════
print("\n[4/5] Generating Redis latency chart...")

redis_configs = [
    ("native",          RESULTS / "native" / "redis.txt"),
    ("docker_host_vol", RESULTS / "docker" / "redis_host_net.txt"),
    ("docker_nat_aufs", RESULTS / "docker" / "redis_nat.txt"),
    ("kvm",             RESULTS / "kvm"    / "redis.txt"),
]

redis_get  = {}
redis_set  = {}
for key, path in redis_configs:
    text = read_file(path)
    g = parse_redis_ops(text, "GET")
    s = parse_redis_ops(text, "SET")
    if g or s:
        redis_get[key] = g / 1000  # K ops/sec
        redis_set[key] = s / 1000

if redis_get or redis_set:
    keys  = [k for k in COLORS if k in redis_get or k in redis_set]
    x     = np.arange(len(keys))
    width = 0.35
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(x - width/2, [redis_get.get(k, 0) for k in keys],
           width, label="GET", color=[COLORS[k] for k in keys], alpha=0.9)
    ax.bar(x + width/2, [redis_set.get(k, 0) for k in keys],
           width, label="SET", color=[COLORS[k] for k in keys], alpha=0.55, hatch="//")
    ax.set_xticks(x)
    ax.set_xticklabels([LABELS[k] for k in keys], rotation=15, ha="right")
    ax.set_ylabel("Throughput (K operations/sec)")
    ax.set_title("Redis Benchmark — GET/SET Throughput")
    ax.legend(["GET", "SET"])
    ax.grid(True, axis="y", linestyle="--", alpha=0.5)
    save(fig, "fig_redis_latency.png")
else:
    print("  No Redis data found — skipping chart.")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 5 — MySQL OLTP throughput vs. concurrency  ← KEY CHART (Fig 4.1)
# ══════════════════════════════════════════════════════════════════════════════
print("\n[5/5] Generating MySQL throughput chart (replicates Figure 4.1)...")

mysql_configs = [
    ("native",          RESULTS / "native" / "mysql.txt"),
    ("docker_host_vol", RESULTS / "docker" / "mysql_hostnet_volume.txt"),
    ("docker_nat_vol",  RESULTS / "docker" / "mysql_nat_overlayfs.txt"),
    ("kvm",             RESULTS / "kvm"    / "mysql.txt"),
]

mysql_data = {}
for key, path in mysql_configs:
    data = parse_mysql_tps(read_file(path))
    if data:
        mysql_data[key] = data

if mysql_data:
    fig, ax = plt.subplots(figsize=(7, 4.5))
    for key, data in mysql_data.items():
        threads = sorted(data)
        tps     = [data[t] / 1000 for t in threads]  # Convert to K TPS
        ax.plot(threads, tps, marker="o", color=COLORS[key],
                label=LABELS[key], linewidth=1.8)
    ax.set_xlabel("Number of SysBench Threads")
    ax.set_ylabel("1000 Transactions / sec")
    ax.set_title("MySQL OLTP Throughput vs. Concurrency\n(Replication of Felter et al., 2015, Fig. 1)")
    ax.legend(loc="lower right")
    ax.grid(True, linestyle="--", alpha=0.5)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)
    save(fig, "fig_mysql_throughput.png")
    print("  This chart directly replicates Figure 4.1 in the seminar report.")
else:
    print("  No MySQL data found — skipping chart.")
    print("  Run 05_mysql_benchmark.sh to collect data first.")


# ══════════════════════════════════════════════════════════════════════════════
print(f"\nAll charts saved to: {FIGURES}/")
print("Done.")
