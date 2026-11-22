#!/usr/bin/env python3
"""Phase 5: show that an ordered "DIFFERS (same rows, different order)"
verdict from equivalence_checks.py is only a difference in the order of ties.

For one query id it runs the original (queries/workload_30.sql) and the new
version (a workload file), and checks that
  1. both return the same multiset of rows, and
  2. the ORDER BY key, read row by row, is the same sequence in both.
If both hold, only rows that tie on the ORDER BY key changed places, which
SQL leaves undefined. As a control it also runs the NEW query a second time:
tied rows move between two runs of the very same text too (parallel workers
hand rows to the sort in a different order each time).

Usage:
    python3 benchmarks/tie_order_check.py <db> <new_workload.sql> <query_id> <key>
    key: comma-separated 0-based columns of the ORDER BY key, e.g. "0,3" for
         R08 (restaurant_id, rnk), or "duration" for R10, whose key is
         delivered_at - placed_at (columns 4 and 3).
"""
import os
import subprocess
import sys
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "benchmarks"))
from equivalence_checks import OLD, split  # noqa: E402


def rows(db, sql):
    p = subprocess.run(["psql", "-d", db, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"],
                       input="SET search_path TO zomato;\n" + sql,
                       capture_output=True, text=True, check=True)
    return [tuple(ln.split("|")) for ln in p.stdout.splitlines() if ln and ln != "SET"]


def key(row, spec):
    if spec == "duration":
        return datetime.fromisoformat(row[4]) - datetime.fromisoformat(row[3])
    return tuple(row[int(i)] for i in spec.split(","))


def main():
    db, new_path, qid, spec = sys.argv[1:5]
    old_rows = rows(db, split(OLD)[qid])
    new_sql = split(new_path)[qid]
    new_rows, new_again = rows(db, new_sql), rows(db, new_sql)

    same_rows = sorted(old_rows) == sorted(new_rows)
    same_keys = [key(r, spec) for r in old_rows] == [key(r, spec) for r in new_rows]
    moved = sum(x != y for x, y in zip(old_rows, new_rows))
    moved_again = sum(x != y for x, y in zip(new_rows, new_again))
    print(f"{qid}: rows={len(new_rows)}  same_rows={same_rows}  same_order_by_key_sequence={same_keys}  "
          f"tied_rows_moved old->new={moved}  new->new_rerun={moved_again}")
    return 0 if same_rows and same_keys else 1


if __name__ == "__main__":
    sys.exit(main())
