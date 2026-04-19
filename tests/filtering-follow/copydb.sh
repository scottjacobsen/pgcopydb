#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# make sure source and target databases are ready
pgcopydb ping

# set up the test schema on the source database
psql -d "${PGCOPYDB_SOURCE_PGURI}" -1 -f /usr/src/pgcopydb/schema.sql

CLONE_LOG=/tmp/clone-follow.log

# Start clone --follow in the background and capture its output so
# assert.sh can inspect it. Without the fix, the follow subprocess
# crashes on the first INSERT that touches a filtered table because
# the target does not have that table.
pgcopydb clone \
    --follow \
    --filters /usr/src/pgcopydb/exclude.ini \
    --plugin test_decoding \
    --slot-name pgcopydb_filterfollow \
    > "${CLONE_LOG}" 2>&1 &
CLONE_PID=$!

# Wait for the initial COPY + pre/post-data restore to finish and for
# the sentinel to enable `apply`. 15s is conservative for the tiny
# schema; the pagila-based fixtures all complete in <500ms.
sleep 15

if ! kill -0 "${CLONE_PID}" 2>/dev/null
then
    echo "FAIL: clone --follow exited before DML injection"
    wait "${CLONE_PID}" || true
    exit 1
fi

# Inject DML on the source. Every write flows through the replication
# slot. Without the fix, the INSERT into public.filtered_table will
# cause the follow apply subprocess to error with
# `ERROR: relation "public.filtered_table" does not exist`.
psql -d "${PGCOPYDB_SOURCE_PGURI}" -f /usr/src/pgcopydb/dml.sql

# Give the follow stream time to process and for the error (if any)
# to propagate up to the main clone process. If the bug is present
# the process will have died by now; record the state pre-SIGTERM so
# assert.sh can tell the difference between a crash and our SIGTERM.
sleep 30

PRE_SIGTERM_ALIVE=0
if kill -0 "${CLONE_PID}" 2>/dev/null
then
    PRE_SIGTERM_ALIVE=1
    kill -TERM -- "-${CLONE_PID}" 2>/dev/null || kill -TERM "${CLONE_PID}"
fi

# Collect the exit code for telemetry only — the real bug signature is
# in the log (assert.sh greps for it).
set +e
wait "${CLONE_PID}"
CLONE_EXIT=$?
set -e

echo "clone --follow exited with code ${CLONE_EXIT} (pre-SIGTERM alive: ${PRE_SIGTERM_ALIVE})"

# Dump the log so CI output includes it even on success.
echo "===== clone --follow log ====="
cat "${CLONE_LOG}"
echo "===== end log ====="

/usr/src/pgcopydb/assert.sh "${CLONE_LOG}" "${CLONE_EXIT}" "${PRE_SIGTERM_ALIVE}"
