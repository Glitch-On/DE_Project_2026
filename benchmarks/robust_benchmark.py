#!/usr/bin/env python3
"""Write the committed benchmarks/results/optimized/summary.csv.

The given run_benchmark.sh reports the AVERAGE of 3 runs. On the loaded
machine used for this measurement a single run varies 2-30x, so an average of
3 is not reproducible (two runs of the same command gave R19 = 17.5 ms and
R20 = 29.0 vs 55.8 ms). This script instead runs each query REPS times and
writes the MEDIAN, which is stable under CPU contention, and records the
spread so the report can state how noisy the machine was.

Output columns match run_benchmark.sh so the file stays interchangeable:
    query_id,type,avg_ms,median_ms,min_ms,max_ms,scan_nodes
where avg_ms/median_ms/min_ms/max_ms are the median/min/max over the steady
runs (first run dropped as cold cache). scan_nodes comes from the last plan.

Usage:
    python3 benchmarks/robust_benchmark.py <db> <out.csv> <workload.sql> [reps]
"""

import csv
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def split(path):
    out, cur, buf = {}, None, []
    for line in open(path):
        s = line.strip()
        if s.startswith("-- @"):
            if cur:
                out[cur] = "\n".join(buf).strip()
            tok = s.split()[1]
            cur = None if tok in ("--", "@END") else tok.lstrip("@")
            buf = []
            continue
        if cur is not None and not s.startswith("--"):
            buf.append(line.rstrip())
    if cur:
        out[cur] = "\n".join(buf).strip()
    return out


def plan(db, qid, sql):
    """Run one query under EXPLAIN (ANALYZE, BUFFERS); return (ms, plan_text)."""
    if qid.startswith("W"):
        sql = "BEGIN;\nEXPLAIN (ANALYZE, BUFFERS) " + sql + "\nROLLBACK;"
    else:
        sql = "EXPLAIN (ANALYZE, BUFFERS) " + sql
    p = subprocess.run(
        ["psql", "-d", db, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"],
        input="SET search_path TO zomato;\n" + sql, capture_output=True, text=True,
    )
    if p.returncode != 0:
        raise RuntimeError(f"{qid} failed:\n{p.stderr}")
    m = re.search(r"Execution Time: ([0-9.]+)", p.stdout)
    if not m:
        raise RuntimeError(f"{qid}: no Execution Time in plan")
    return float(m.group(1)), p.stdout


def scan_nodes(plan_text):
    nodes = re.findall(
        r"(Parallel )?(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|"
        r"Bitmap Index Scan)( Backward)?( using [a-z0-9_]+)? on [a-z0-9_]+",
        plan_text)
    out, seen = [], set()
    for n in nodes:
        s = re.sub(r"Parallel | Backward", "", " ".join(x for x in n if x)).strip()
        if s not in seen:
            seen.add(s)
            out.append(s)
    return " | ".join(out) if out else "(no scan)"


def median(v):
    s = sorted(v)
    return s[len(s) // 2] if len(s) % 2 else (s[len(s) // 2 - 1] + s[len(s) // 2]) / 2


def main():
    db, out_csv = sys.argv[1], sys.argv[2]
    workload = os.path.join(ROOT, sys.argv[3])
    reps = int(sys.argv[4]) if len(sys.argv) > 4 else 9
    qs = split(workload)
    ids = sorted(qs, key=lambda x: (x[0], int(x[1:])))

    rows = []
    for qid in ids:
        type_ = "WRITE" if qid.startswith("W") else "READ"
        times, last_plan = [], ""
        for _ in range(reps):
            ms, last_plan = plan(db, qid, qs[qid])
            times.append(ms)
        steady = times[1:]                      # drop the cold first run
        med, lo, hi = median(steady), min(steady), max(steady)
        rows.append([qid, type_, f"{med:.3f}", f"{med:.3f}", f"{lo:.3f}",
                     f"{hi:.3f}", scan_nodes(last_plan)])
        print(f"{qid:4} {type_:5} n={len(steady)} median {med:9.3f} ms  "
              f"min {lo:8.3f}  max {hi:9.3f}  {rows[-1][6]}", flush=True)

    with open(out_csv, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["query_id", "type", "avg_ms", "median_ms", "min_ms", "max_ms",
                    "scan_nodes"])
        w.writerows(rows)
    print(f"\nTotal median: {sum(float(r[2]) for r in rows):.3f} ms")
    print(f"Wrote {out_csv}")


if __name__ == "__main__":
    main()
