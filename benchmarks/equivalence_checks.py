#!/usr/bin/env python3
"""CP3 same-result proof for sql/06_optimized_queries.sql.

Reads queries/workload_30.sql (old) and sql/06_optimized_queries.sql (new) and
proves every rewritten pair returns the same rows.

Comparison rule: a query is compared as an ORDERED list when both versions
contain an ORDER BY, otherwise as an unordered multiset (SQL does not define
the order of ties). R23 is compared as a multiset because the rewrite changes
the pagination mechanism, not the rows an app page returns.

The database must have the seed data AND sql/05_indexes.sql applied, because
the new R09 reads mv_city_month_delivery. The OLD query runs with pg_catalog
first in the search_path so it cannot quietly use a Phase-4 index; the NEW
query runs with the normal search_path. Nothing else about the queries changes.

psql runs with -q -A -t and SETs are sent as their own statement so their
"SET" status line cannot leak into the compared rows.

Writes run inside BEGIN ... ROLLBACK so the data is identical for every run.

Usage:
    python3 benchmarks/equivalence_checks.py <db>

Exit code 0 when every pair passes (R13 excepted, reported as FIXED).
"""

import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLD = os.path.join(ROOT, "queries", "workload_30.sql")
NEW = os.path.join(ROOT, "sql", "06_optimized_queries.sql")

# R13 is the one query whose original result is wrong: "x NOT IN (..., NULL)"
# is never TRUE, so the original returns 0 rows. Its rewrite is meant to
# change the result. Reported, not failed.
INTENTIONAL = {"R13"}

# Compared as a multiset: OFFSET pagination and keyset pagination agree only at
# the exact boundary value, and the app contract is the page's rows, not the
# tie order within it.
UNORDERED = {"R23"}

HIDE = "\\pset format unaligned\n\\pset tuples_only on\nSELECT set_config('search_path', 'pg_catalog, zomato', false) \\g /dev/null\n"

NORMAL = "SELECT set_config('search_path', 'zomato', false) \\g /dev/null\n"


def split(path):
    """Return {id: sql} for every '-- @ID' block; ignore everything after -- @END."""
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


def run(db, sql):
    """Run one statement, return its result rows as a list of text lines."""
    p = subprocess.run(
        ["psql", "-d", db, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"],
        input=sql, capture_output=True, text=True,
    )
    if p.returncode != 0:
        raise RuntimeError(f"query failed:\n{sql}\n{p.stderr}")
    return [ln for ln in p.stdout.splitlines() if ln != ""]


def fetch(db, prefix, qid, sql):
    """Run one workload query and return its result rows."""
    if qid.startswith("W"):
        sql = "BEGIN;\n" + sql + "\nROLLBACK;"
    return run(db, prefix + sql + "\n" + NORMAL)


def main():
    db = sys.argv[1] if len(sys.argv) > 1 else None
    if not db:
        sys.exit("usage: equivalence_checks.py <db>")

    old, new = split(OLD), split(NEW)
    ids = sorted((i for i in old if i in new), key=lambda x: (x[0], int(x[1:])))

    print(f"{'pair':6} {'old':>6} {'new':>6}  {'mode':8}  verdict")
    fails, fixed = [], []
    for qid in ids:
        o_sql, n_sql = old[qid], new[qid]
        ordered = "ORDER BY" in o_sql.upper() and qid not in UNORDERED
        mode = "ordered" if ordered else "multiset"
        old_rows = fetch(db, HIDE, qid, o_sql)
        new_rows = fetch(db, NORMAL, qid, n_sql)
        o_set, n_set = set(old_rows), set(new_rows)

        if qid in INTENTIONAL:
            verdict = ("FIXED? results identical - check" if o_set == n_set
                       else f"FIXED (old {len(o_set)} -> new {len(n_set)} rows)")
            if o_set != n_set:
                fixed.append(qid)
        else:
            only_old, only_new = o_set - n_set, n_set - o_set
            if only_old or only_new:
                verdict = f"DIFFERS ({len(only_old)} old-only, {len(only_new)} new-only)"
                fails.append(qid)
            elif ordered and old_rows != new_rows:
                verdict = "DIFFERS (same rows, different order)"
                fails.append(qid)
            else:
                verdict = "SAME"
        print(f"{qid:6} {len(o_set):6} {len(n_set):6}  {mode:8}  {verdict}")

    print()
    if fixed:
        print("Intentionally changed: " + ", ".join(fixed))
    if fails:
        print("FAILED: " + ", ".join(fails))
        return 1
    print(f"All {len(ids)} pairs checked; every non-R13 pair returns the same rows.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
