#! /bin/bash

# Regression test for the vacuum_summary unique-constraint failure that
# bit `pgcopydb clone --resume` whenever a previous run had recorded any
# rows in vacuum_summary (catalog.c: "unique(tableoid)"). The vacuum
# worker used to call summary_add_vacuum unconditionally, hitting SQLite
# constraint error 19 ("Failed to vacuum table with oid N ... constraint
# failed"). It now looks up an existing row and skips if done, or
# overwrites with INSERT OR REPLACE if the row is from a prior incomplete
# attempt.
#
# Triggering the bug requires the vacuum worker to actually receive a
# table OID on resume. There are two code paths that enqueue a table for
# vacuum: indexes.c (after the last index is built) and table-data.c
# (after the COPY when indexCount == 0). On a fully-resumed clone both
# steps short-circuit. To exercise the bug deterministically we:
#   - Use a tiny custom schema with NO indexes, so the table-data path
#     is the only one that can queue vacuum. This avoids the unrelated
#     "index is already associated with a constraint" failure that bites
#     pagila on the indexes path (upstream issue #808).
#   - Clear the COPY_DATA timing in the catalog so the table-data step
#     re-runs on --resume. Per-table COPY is still skipped (data is
#     already present), but the worker falls through to the vacuum
#     enqueue at the bottom of copydb_process_table_data.
#
# Two paths covered:
#   Case 1 — vacuum_summary row for the table is "done"
#            (done_time_epoch > 0). Worker must skip.
#   Case 2 — row is "in flight" (done_time_epoch == 0), simulating a
#            previous attempt that crashed between summary_add_vacuum
#            and summary_finish_vacuum. Worker must re-run and the
#            INSERT OR REPLACE must overwrite the stale row.

set -x
set -e

WORKDIR=${TMPDIR:-/tmp}/pgcopydb
rm -rf "${WORKDIR}"

CATALOG="${WORKDIR}/schema/source.db"
# The pagila image ships a .sqliterc with .echo on + column mode +
# headers, which corrupts single-value extraction. -init /dev/null
# bypasses it.
SQ() { sqlite3 -batch -init /dev/null -noheader -bail "${CATALOG}" "$1"; }

pgcopydb ping

# Tiny schema with no indexes / no constraints — keeps the test focused
# on the vacuum enqueue + idempotency code paths.
psql -d "${PGCOPYDB_SOURCE_PGURI}" <<'SQL'
drop schema if exists v cascade;
create schema v;
create table v.t1 (val text);
create table v.t2 (val text);
insert into v.t1 select 'a' || g from generate_series(1, 100) g;
insert into v.t2 select 'b' || g from generate_series(1, 100) g;
SQL

# Long-lived snapshot holder — the exported snapshot dies with its
# transaction, so without this clone --resume would fail with
# "invalid snapshot identifier" on subsequent invocations.
coproc SNAP ( pgcopydb snapshot )
sleep 1

# First clone: populates the catalog including completed vacuum_summary
# rows for v.t1 and v.t2.
pgcopydb clone --resume --notice

test -f "${CATALOG}" || { echo "BUG: catalog missing at ${CATALOG}"; exit 1; }

t1_oid=$(SQ "select oid from s_table where nspname = 'v' and relname = 't1';")
t2_oid=$(SQ "select oid from s_table where nspname = 'v' and relname = 't2';")
test -n "${t1_oid}" -a -n "${t2_oid}" || \
    { echo "BUG: couldn't resolve v.t1 / v.t2 table oids"; exit 1; }

t1_done=$(SQ "select done_time_epoch from vacuum_summary where tableoid = ${t1_oid};")
t2_done=$(SQ "select done_time_epoch from vacuum_summary where tableoid = ${t2_oid};")
if [ -z "${t1_done}" ] || [ "${t1_done}" = "0" ] || \
   [ -z "${t2_done}" ] || [ "${t2_done}" = "0" ]; then
    echo "BUG: expected v.t1 / v.t2 to have completed vacuum_summary rows"
    echo "     got t1_done='${t1_done}' t2_done='${t2_done}'"
    exit 1
fi
echo "Precondition OK: v.t1 (${t1_oid}) and v.t2 (${t2_oid}) vacuum done."

# Force the table-data step to re-enter on --resume so the
# zero-index path at the bottom of copydb_process_table_data fires
# `vacuum_add_table` for v.t1 and v.t2 again. Both `tableCopyIsDone`
# and `indexCopyIsDone` must be false for the path that queues
# vacuum (table-data.c:979) — clear both timings. Our schema has no
# indexes, so re-running the index step is a no-op (no constraint
# re-attach risk that bites pagila).
SQ "delete from timings where label = 'COPY (cumulative)';"
SQ "delete from timings where label = 'CREATE INDEX (cumulative)';"

# Case 2 setup: replace v.t2's vacuum_summary row with an "in-flight"
# row so the lookup must NOT skip. Without the fix the insert-or-replace
# wouldn't help here either — pre-fix the worker calls plain INSERT
# and trips the unique constraint identically. With the fix the row
# is overwritten and vacuum runs through to summary_finish_vacuum.
SQ "delete from vacuum_summary where tableoid = ${t2_oid};"
SQ "insert into vacuum_summary(pid, tableoid, start_time_epoch, done_time_epoch, duration)
    values (99999, ${t2_oid}, 0, 0, 0);"

log=$(mktemp)
pgcopydb clone --resume --notice 2>&1 | tee "${log}"

if grep -q "constraint failed" "${log}"; then
    echo "FAIL: --resume hit SQLite constraint on vacuum_summary"
    exit 1
fi

# Case 1: v.t1 must have been visited and skipped as "already done."
if ! grep -qE "Skipping vacuum analyze of v\.t1 \(${t1_oid}\), already done on a previous run" "${log}"; then
    echo "FAIL: vacuum worker did not skip v.t1"
    echo "      summary_lookup_vacuum may not be wired into vacuum_analyze_table_by_oid"
    exit 1
fi
echo "Case 1 OK: v.t1 vacuum skipped on --resume."

# Case 2: v.t2's in-flight row must have been overwritten and the table
# actually vacuumed, so done_time_epoch is now > 0 again.
final_done=$(SQ "select done_time_epoch from vacuum_summary where tableoid = ${t2_oid};")
if [ -z "${final_done}" ] || [ "${final_done}" = "0" ]; then
    echo "FAIL: v.t2 in-flight row not re-vacuumed (done_time_epoch='${final_done}')"
    exit 1
fi
echo "Case 2 OK: v.t2 in-flight row re-vacuumed (done_time_epoch=${final_done})."

# Tear down the snapshot holder.
kill -TERM ${SNAP_PID} 2>/dev/null || true
wait ${SNAP_PID} 2>/dev/null || true

echo "PASS: vacuum --resume idempotency verified"
