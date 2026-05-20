#!/usr/bin/env python3
import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def to_int(value: str) -> int:
    try:
        return int(float(value))
    except Exception:
        return 0


def median_int(rows, key):
    return int(statistics.median(to_int(r[key]) for r in rows))


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: summarize_real_machine_results.py real_all.tsv real_medians.tsv", file=sys.stderr)
        return 2

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    if not src.exists():
        print(f"missing input: {src}", file=sys.stderr)
        return 2

    rows = []
    with src.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            rows.append(row)

    groups = defaultdict(list)
    for row in rows:
        if row.get("status") != "OK":
            continue
        key = (row["experiment"], row["workload"], row["mode"], row["config"])
        groups[key].append(row)

    fields = [
        "experiment",
        "workload",
        "mode",
        "config",
        "n",
        "buf_hit_median",
        "runtime_sync_median",
        "runtime_async_median",
        "disk_sync_median",
        "disk_async_median",
        "wall_time_ns_median",
        "logical_wall_ns_median",
    ]

    with dst.open("w", newline="") as f:
        writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
        writer.writeheader()
        for key in sorted(groups):
            gr = groups[key]
            writer.writerow(
                {
                    "experiment": key[0],
                    "workload": key[1],
                    "mode": key[2],
                    "config": key[3],
                    "n": len(gr),
                    "buf_hit_median": median_int(gr, "buf_hit"),
                    "runtime_sync_median": median_int(gr, "runtime_sync"),
                    "runtime_async_median": median_int(gr, "runtime_async"),
                    "disk_sync_median": median_int(gr, "disk_sync"),
                    "disk_async_median": median_int(gr, "disk_async"),
                    "wall_time_ns_median": median_int(gr, "wall_time_ns"),
                    "logical_wall_ns_median": median_int(gr, "logical_wall_ns"),
                }
            )

    print(f"wrote {dst}")
    write_speedup(dst, dst.with_name("real_speedup.tsv"))
    return 0


def write_speedup(medians_path: Path, out_path: Path) -> None:
    with medians_path.open(newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    by_key = {}
    for row in rows:
        by_key[(row["experiment"], row["config"], row["mode"])] = row

    fields = [
        "experiment",
        "config",
        "workload",
        "no_dsm_wall_s",
        "dsm_wall_s",
        "wall_speedup",
        "no_dsm_logical_s",
        "dsm_logical_s",
        "logical_speedup",
        "no_dsm_disk_sync",
        "dsm_runtime_sync",
        "dsm_disk_sync",
        "sync_disk_replaced_pct",
    ]

    with out_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
        writer.writeheader()
        pairs = sorted({(r["experiment"], r["config"]) for r in rows})
        for exp, cfg in pairs:
            no = by_key.get((exp, cfg, "no_dsm"))
            dsm = by_key.get((exp, cfg, "dsm"))
            if not no or not dsm:
                continue
            no_wall = to_int(no["wall_time_ns_median"]) / 1e9
            dsm_wall = to_int(dsm["wall_time_ns_median"]) / 1e9
            no_logical = to_int(no["logical_wall_ns_median"]) / 1e9
            dsm_logical = to_int(dsm["logical_wall_ns_median"]) / 1e9
            no_disk = to_int(no["disk_sync_median"])
            dsm_runtime = to_int(dsm["runtime_sync_median"])
            dsm_disk = to_int(dsm["disk_sync_median"])
            replaced = ((no_disk - dsm_disk) / no_disk * 100.0) if no_disk else 0.0
            writer.writerow(
                {
                    "experiment": exp,
                    "config": cfg,
                    "workload": no["workload"],
                    "no_dsm_wall_s": f"{no_wall:.6f}",
                    "dsm_wall_s": f"{dsm_wall:.6f}",
                    "wall_speedup": f"{(no_wall / dsm_wall) if dsm_wall else 0:.4f}",
                    "no_dsm_logical_s": f"{no_logical:.6f}",
                    "dsm_logical_s": f"{dsm_logical:.6f}",
                    "logical_speedup": f"{(no_logical / dsm_logical) if dsm_logical else 0:.4f}",
                    "no_dsm_disk_sync": no_disk,
                    "dsm_runtime_sync": dsm_runtime,
                    "dsm_disk_sync": dsm_disk,
                    "sync_disk_replaced_pct": f"{replaced:.2f}",
                }
            )
    print(f"wrote {out_path}")


if __name__ == "__main__":
    raise SystemExit(main())
