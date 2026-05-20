#!/usr/bin/env python3
import csv
import re
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np


def read_tsv(path: Path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def to_float(value: str) -> float:
    try:
        return float(value)
    except Exception:
        return 0.0


def cfg_number(config: str, key: str):
    m = re.search(rf"{re.escape(key)}=([0-9]+)", config)
    return int(m.group(1)) if m else None


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name).strip("_")


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: plot_real_machine_results.py REAL_RUN_ROOT [OUT_DIR]", file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    out_dir = Path(sys.argv[2]) if len(sys.argv) == 3 else root / "figures"
    speedup_path = root / "real_speedup.tsv"
    median_path = root / "real_medians.tsv"
    if not speedup_path.exists() or not median_path.exists():
        print(f"missing {speedup_path} or {median_path}; run summarize first", file=sys.stderr)
        return 2

    out_dir.mkdir(parents=True, exist_ok=True)
    speed = read_tsv(speedup_path)
    med = read_tsv(median_path)

    plt.rcParams.update({
        "font.size": 10,
        "axes.titlesize": 12,
        "axes.labelsize": 10,
        "legend.fontsize": 9,
    })

    plot_overview(speed, out_dir)
    plot_micro_random(speed, out_dir)
    plot_micro_write(speed, out_dir)
    plot_tpcc(speed, out_dir)
    plot_tpch(speed, out_dir)
    plot_page_source_by_experiment(med, out_dir)

    print(f"figures written to {out_dir}")
    return 0


def plot_overview(rows, out_dir: Path):
    rows = [r for r in rows if to_float(r["wall_speedup"]) > 0]
    if not rows:
        return
    labels = [f"{r['experiment']}\n{short_config(r['config'])}" for r in rows]
    wall = [to_float(r["wall_speedup"]) for r in rows]
    logical = [to_float(r["logical_speedup"]) for r in rows]
    x = np.arange(len(rows))
    w = 0.38
    fig, ax = plt.subplots(figsize=(max(9, len(rows) * 0.85), 4.8))
    ax.axhline(1.0, color="black", lw=1, alpha=0.5)
    ax.bar(x - w / 2, wall, w, label="wall speedup", color="#4daf4a")
    ax.bar(x + w / 2, logical, w, label="logical speedup", color="#377eb8")
    ax.set_xticks(x, labels, rotation=35, ha="right")
    ax.set_ylabel("speedup (NO_DSM / DSM)")
    ax.set_title("Real-machine performance overview")
    ax.legend(frameon=False)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "real_overview_speedup.png", dpi=220)
    plt.close(fig)


def plot_micro_random(rows, out_dir: Path):
    rows = [r for r in rows if r["experiment"] == "micro_random_lookup"]
    if not rows:
        return
    rows.sort(key=lambda r: cfg_number(r["config"], "pages") or 0)
    labels = [str(cfg_number(r["config"], "pages")) for r in rows]
    no = [to_float(r["no_dsm_wall_s"]) for r in rows]
    dsm = [to_float(r["dsm_wall_s"]) for r in rows]
    no_disk = [to_float(r["no_dsm_disk_sync"]) for r in rows]
    dsm_runtime = [to_float(r["dsm_runtime_sync"]) for r in rows]
    dsm_disk = [to_float(r["dsm_disk_sync"]) for r in rows]
    x = np.arange(len(rows))
    w = 0.36
    fig, axes = plt.subplots(2, 1, figsize=(8.5, 7.0), sharex=True)
    axes[0].bar(x - w / 2, no, w, label="NO_DSM wall", color="#8da0cb")
    axes[0].bar(x + w / 2, dsm, w, label="DSM wall", color="#66c2a5")
    axes[0].set_ylabel("wall time (s)")
    axes[0].set_title("Micro random lookup on real hardware")
    axes[0].legend(frameon=False)
    axes[0].grid(axis="y", alpha=0.25)
    for i, r in enumerate(rows):
        axes[0].text(i, max(no[i], dsm[i]) * 1.03, f"{to_float(r['wall_speedup']):.2f}x", ha="center", fontsize=9)
    axes[1].bar(x - w / 2, no_disk, w, label="NO_DSM disk_sync", color="#fc8d62")
    axes[1].bar(x + w / 2, dsm_runtime, w, label="DSM runtime_sync", color="#66c2a5")
    axes[1].bar(x + w / 2, dsm_disk, w, bottom=dsm_runtime, label="DSM disk_sync", color="#e78ac3")
    axes[1].set_ylabel("sync page events")
    axes[1].set_xlabel("working set pages")
    axes[1].set_xticks(x, labels)
    axes[1].legend(frameon=False)
    axes[1].grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "real_micro_random_lookup.png", dpi=220)
    plt.close(fig)


def plot_micro_write(rows, out_dir: Path):
    rows = [r for r in rows if r["experiment"] == "micro_random_update"]
    if not rows:
        return
    rows.sort(key=lambda r: cfg_number(r["config"], "pages") or 0)
    labels = [str(cfg_number(r["config"], "pages")) for r in rows]
    x = np.arange(len(rows))
    w = 0.36
    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.6))
    axes[0].bar(x - w / 2, [to_float(r["no_dsm_wall_s"]) for r in rows], w, label="NO_DSM wall", color="#8da0cb")
    axes[0].bar(x + w / 2, [to_float(r["dsm_wall_s"]) for r in rows], w, label="DSM wall", color="#66c2a5")
    axes[0].set_xticks(x, labels)
    axes[0].set_xlabel("update working set pages")
    axes[0].set_ylabel("wall time (s)")
    axes[0].set_title("Random update wall time")
    axes[0].legend(frameon=False)
    axes[0].grid(axis="y", alpha=0.25)
    axes[1].bar(x - w / 2, [to_float(r["no_dsm_disk_sync"]) for r in rows], w, label="NO_DSM disk_sync", color="#fc8d62")
    axes[1].bar(x + w / 2, [to_float(r["dsm_runtime_sync"]) for r in rows], w, label="DSM runtime_sync", color="#66c2a5")
    axes[1].bar(x + w / 2, [to_float(r["dsm_disk_sync"]) for r in rows], w,
                bottom=[to_float(r["dsm_runtime_sync"]) for r in rows], label="DSM disk_sync", color="#e78ac3")
    axes[1].set_xticks(x, labels)
    axes[1].set_xlabel("update working set pages")
    axes[1].set_ylabel("sync page events")
    axes[1].set_title("Update-before-read replacement")
    axes[1].legend(frameon=False)
    axes[1].grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "real_micro_random_update.png", dpi=220)
    plt.close(fig)


def plot_tpcc(rows, out_dir: Path):
    rows = [r for r in rows if r["experiment"] == "tpcc"]
    if not rows:
        return
    rows.sort(key=lambda r: cfg_number(r["config"], "conns") or 0)
    labels = [str(cfg_number(r["config"], "conns")) for r in rows]
    x = np.arange(len(rows))
    fig, axes = plt.subplots(2, 1, figsize=(8.5, 7.0), sharex=True)
    axes[0].plot(x, [to_float(r["wall_speedup"]) for r in rows], marker="o", label="wall speedup", color="#4daf4a")
    axes[0].plot(x, [to_float(r["logical_speedup"]) for r in rows], marker="s", label="logical speedup", color="#377eb8")
    axes[0].axhline(1.0, color="black", lw=1, alpha=0.5)
    axes[0].set_ylabel("speedup")
    axes[0].set_title("TPC-C concurrency trend")
    axes[0].legend(frameon=False)
    axes[0].grid(axis="y", alpha=0.25)
    w = 0.36
    axes[1].bar(x - w / 2, [to_float(r["no_dsm_disk_sync"]) for r in rows], w, label="NO_DSM disk_sync", color="#fc8d62")
    axes[1].bar(x + w / 2, [to_float(r["dsm_runtime_sync"]) for r in rows], w, label="DSM runtime_sync", color="#66c2a5")
    axes[1].bar(x + w / 2, [to_float(r["dsm_disk_sync"]) for r in rows], w,
                bottom=[to_float(r["dsm_runtime_sync"]) for r in rows], label="DSM disk_sync", color="#e78ac3")
    axes[1].set_xlabel("connections")
    axes[1].set_ylabel("sync page events")
    axes[1].set_xticks(x, labels)
    axes[1].legend(frameon=False)
    axes[1].grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "real_tpcc_concurrency.png", dpi=220)
    plt.close(fig)


def plot_tpch(rows, out_dir: Path):
    rows = [r for r in rows if r["experiment"] in ("tpch", "tpch_isolated")]
    if not rows:
        return
    rows.sort(key=lambda r: (r["experiment"], cfg_number(r["config"], "q") or 0, r["config"]))
    labels = [tpch_label(r) for r in rows]
    x = np.arange(len(rows))
    w = 0.36
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.8))
    axes[0].bar(x - w / 2, [to_float(r["no_dsm_wall_s"]) for r in rows], w, label="NO_DSM wall", color="#8da0cb")
    axes[0].bar(x + w / 2, [to_float(r["dsm_wall_s"]) for r in rows], w, label="DSM wall", color="#66c2a5")
    axes[0].set_xticks(x, labels, rotation=20, ha="right")
    axes[0].set_ylabel("wall time (s)")
    axes[0].set_title("TPC-H wall time")
    axes[0].legend(frameon=False)
    axes[0].grid(axis="y", alpha=0.25)
    axes[1].bar(x - w / 2, [to_float(r["no_dsm_disk_sync"]) for r in rows], w, label="NO_DSM disk_sync", color="#fc8d62")
    axes[1].bar(x + w / 2, [to_float(r["dsm_runtime_sync"]) for r in rows], w, label="DSM runtime_sync", color="#66c2a5")
    axes[1].bar(x + w / 2, [to_float(r["dsm_disk_sync"]) for r in rows], w,
                bottom=[to_float(r["dsm_runtime_sync"]) for r in rows], label="DSM disk_sync", color="#e78ac3")
    axes[1].set_xticks(x, labels, rotation=20, ha="right")
    axes[1].set_ylabel("sync page events")
    axes[1].set_title("TPC-H sync page-source replacement")
    axes[1].legend(frameon=False)
    axes[1].grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "real_tpch_summary.png", dpi=220)
    plt.close(fig)


def plot_page_source_by_experiment(med_rows, out_dir: Path):
    # One compact evidence figure using median rows only.
    dsm_rows = [r for r in med_rows if r.get("mode") == "dsm"]
    if not dsm_rows:
        return
    labels = [f"{r['experiment']}\n{short_config(r['config'])}" for r in dsm_rows]
    runtime = [to_float(r["runtime_sync_median"]) for r in dsm_rows]
    disk = [to_float(r["disk_sync_median"]) for r in dsm_rows]
    x = np.arange(len(dsm_rows))
    fig, ax = plt.subplots(figsize=(max(10, len(dsm_rows) * 0.8), 4.8))
    ax.bar(x, runtime, label="DSM runtime_sync", color="#66c2a5")
    ax.bar(x, disk, bottom=runtime, label="DSM remaining disk_sync", color="#e78ac3")
    ax.set_xticks(x, labels, rotation=35, ha="right")
    ax.set_ylabel("sync page events")
    ax.set_title("DSM mode residual disk reads by experiment")
    ax.legend(frameon=False)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out_dir / "real_dsm_residual_disk_by_experiment.png", dpi=220)
    plt.close(fig)


def short_config(config: str) -> str:
    if "pages=" in config:
        return f"pages={cfg_number(config, 'pages')}"
    if "hot_pages=" in config:
        return f"hot={cfg_number(config, 'hot_pages')}"
    if "conns=" in config:
        return f"conns={cfg_number(config, 'conns')}"
    if config.startswith("dataset="):
        q = config.split("_bp=", 1)[0].replace("dataset=", "")
        return q
    return config[:32]


def tpch_label(row) -> str:
    if row["experiment"] == "tpch_isolated":
        qid = cfg_number(row["config"], "q")
        return f"Q{qid}" if qid is not None else short_config(row["config"])
    return short_config(row["config"])


if __name__ == "__main__":
    raise SystemExit(main())
