#!/usr/bin/env python3
"""Sample CPU and memory of a process tree (the root plus all descendants, re-scanned every tick).

CPU comes from cumulative CPU-time deltas, so it's exact rather than ps's decaying %cpu. 100% = one core.
Memory is the summed phys_footprint (what Activity Monitor calls "Memory"), gathered with `footprint`.

Examples:
  scripts/perf/sample.py --match 'MyScreenArt Dev.app/Contents/MacOS' --duration 60
  scripts/perf/sample.py --pid 1234 --csv /tmp/run.csv      # until the process exits or Ctrl-C
"""

import argparse
import csv
import re
import signal
import subprocess
import sys
import time


def cpu_seconds(text: str) -> float:
    """Parse ps `time` output: [[dd-]hh:]mm:ss[.cc]."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    parts = [float(p) for p in text.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0.0)
    h, m, s = parts
    return days * 86400 + h * 3600 + m * 60 + s


def process_table() -> dict[int, tuple[int, float]]:
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,time="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        pid, ppid, t = line.split()
        table[int(pid)] = (int(ppid), cpu_seconds(t))
    return table


def tree(root: int, table: dict[int, tuple[int, float]]) -> set[int]:
    members, frontier = {root}, [root]
    while frontier:
        parent = frontier.pop()
        for pid, (ppid, _) in table.items():
            if ppid == parent and pid not in members:
                members.add(pid)
                frontier.append(pid)
    return members & table.keys()


def footprint_bytes(pids: set[int]) -> int | None:
    args = ["footprint", "-f", "bytes", "--noCategories"]
    for pid in sorted(pids):
        args += ["-p", str(pid)]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    summary = re.search(r"Summary Footprint:\s+(\d+)", out)
    if summary:
        return int(summary.group(1))
    single = re.search(r"Footprint:\s+(\d+)", out)
    return int(single.group(1)) if single else None


def find_root(pattern: str) -> int:
    out = subprocess.run(["pgrep", "-o", "-f", pattern], capture_output=True, text=True).stdout.strip()
    if not out:
        sys.exit(f"No process matches {pattern!r}")
    return int(out.splitlines()[0])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--pid", type=int, help="root process ID")
    target.add_argument("--match", help="pgrep -f pattern; the oldest match is the root")
    parser.add_argument("--interval", type=float, default=0.5, help="CPU sampling interval in seconds")
    parser.add_argument("--footprint-every", type=float, default=2.0, help="memory sampling interval in seconds")
    parser.add_argument("--duration", type=float, help="stop after this many seconds")
    parser.add_argument("--csv", help="write per-tick samples to this CSV file")
    parser.add_argument("--label", default="", help="label printed with the summary")
    args = parser.parse_args()

    root = args.pid or find_root(args.match)
    stop = False

    def request_stop(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    last_cpu: dict[int, float] = {}
    rows, cpu_samples, mem_samples = [], [], []
    start = last_tick = time.monotonic()
    last_footprint = float("-inf")
    total_cpu = 0.0

    while not stop:
        time.sleep(args.interval)
        now = time.monotonic()
        table = process_table()
        if root not in table:
            break
        members = tree(root, table)

        delta = 0.0
        for pid in members:
            cpu = table[pid][1]
            delta += max(0.0, cpu - last_cpu.get(pid, 0.0 if now - start > args.interval * 1.5 else cpu))
            last_cpu[pid] = cpu
        elapsed = now - last_tick
        last_tick = now
        total_cpu += delta
        cpu_pct = 100.0 * delta / elapsed if elapsed > 0 else 0.0
        cpu_samples.append(cpu_pct)

        mem = None
        if now - last_footprint >= args.footprint_every:
            mem = footprint_bytes(members)
            last_footprint = now
            if mem is not None:
                mem_samples.append(mem)

        rows.append((round(now - start, 2), len(members), round(cpu_pct, 1), mem))
        if args.duration and now - start >= args.duration:
            break

    wall = time.monotonic() - start
    if args.csv:
        with open(args.csv, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["t_s", "processes", "cpu_pct", "footprint_bytes"])
            writer.writerows(rows)

    def mb(v: float) -> str:
        return f"{v / 1_048_576:.0f} MB"

    print(f"== {args.label or f'pid {root}'} ==")
    print(f"wall:        {wall:.1f} s")
    print(f"cpu time:    {total_cpu:.1f} s (first-tick CPU of pre-existing processes excluded)")
    if cpu_samples:
        print(f"cpu avg/max: {sum(cpu_samples) / len(cpu_samples):.1f}% / {max(cpu_samples):.1f}%  (100% = 1 core)")
    if mem_samples:
        print(f"memory avg/max: {mb(sum(mem_samples) / len(mem_samples))} / {mb(max(mem_samples))}  (phys_footprint)")
    print(f"max processes: {max((r[1] for r in rows), default=0)}")


if __name__ == "__main__":
    main()
