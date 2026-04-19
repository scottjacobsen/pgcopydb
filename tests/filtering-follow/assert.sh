#! /bin/bash

#
# Assertions for the filtering-follow test.
#
# Arguments:
#   $1  path to captured clone --follow log
#   $2  exit code of the clone --follow process
#   $3  1 if clone was still alive when copydb.sh sent SIGTERM, 0 otherwise
#

set -x

CLONE_LOG=${1:-/tmp/clone-follow.log}
CLONE_EXIT=${2:-0}
PRE_SIGTERM_ALIVE=${3:-0}

failures=0

assert_count () {
    local label=$1
    local table=$2
    local expected=$3

    local actual
    actual=$(psql -At -d "${PGCOPYDB_TARGET_PGURI}" \
                  -c "select count(*) from ${table}")

    if [ "${actual}" != "${expected}" ]
    then
        echo "FAIL ${label}: ${table} expected ${expected} rows, got ${actual}"
        failures=$((failures + 1))
    else
        echo "PASS ${label}: ${table} has ${actual} row(s)"
    fi
}

# 0. If clone --follow was dead BEFORE we sent SIGTERM, the follow
#    subprocess tree crashed mid-stream — that is exactly the filter
#    bug from issue #624. A non-zero exit after SIGTERM is acceptable
#    because we explicitly terminated the process group.
if [ "${PRE_SIGTERM_ALIVE}" -ne 1 ]
then
    echo "FAIL clone-alive: pgcopydb clone --follow died before SIGTERM (exit=${CLONE_EXIT})"
    failures=$((failures + 1))
else
    echo "PASS clone-alive: pgcopydb clone --follow was still running at SIGTERM"
fi

# 1. The captured log must not contain the `relation ... does not
#    exist` error. That's the direct symptom of issue #624.
if grep -Eq 'ERROR:[[:space:]]+relation .* does not exist' "${CLONE_LOG}"
then
    echo "FAIL clone-log: follow stream tried to apply DML for a filtered table"
    grep -E 'ERROR:' "${CLONE_LOG}" | head -20
    failures=$((failures + 1))
else
    echo "PASS clone-log: no 'relation does not exist' error in follow log"
fi

# 1b. The log must also not contain the `not in our catalogs` crash
#    that test_decoding emits when it meets a table the local catalog
#    has no record of (ultimately issue #624 again, seen in the wild
#    on partman.part_config and similar unmapped extension tables).
if grep -Eq 'which is not in our catalogs' "${CLONE_LOG}"
then
    echo "FAIL clone-log: transform crashed on an unmapped catalog table"
    grep -E 'which is not in our catalogs' "${CLONE_LOG}" | head -5
    failures=$((failures + 1))
else
    echo "PASS clone-log: no 'not in our catalogs' crash in follow log"
fi

# 2. unfiltered_table must receive both the seed row (initial COPY) and
#    the two rows inserted during the follow phase: 1 + 2 = 3 rows.
assert_count "unfiltered" "public.unfiltered_table" 3

# 3. data_filtered_table is in [exclude-table-data] so DDL is copied
#    but neither the seed row (initial COPY) nor the DML inserts should
#    be present on the target. The relation must exist.
exists=$(psql -At -d "${PGCOPYDB_TARGET_PGURI}" \
              -c "select to_regclass('public.data_filtered_table')")

if [ -z "${exists}" ]
then
    echo "FAIL data_filtered: public.data_filtered_table should exist on target"
    failures=$((failures + 1))
else
    assert_count "data_filtered" "public.data_filtered_table" 0
fi

# 4. filtered_table is in [exclude-table] so neither DDL nor DML
#    should land on the target. The relation must not exist.
exists=$(psql -At -d "${PGCOPYDB_TARGET_PGURI}" \
              -c "select to_regclass('public.filtered_table')")

if [ -n "${exists}" ]
then
    echo "FAIL filtered: public.filtered_table should NOT exist on target"
    failures=$((failures + 1))
else
    echo "PASS filtered: public.filtered_table is absent from target"
fi

if [ "${failures}" -ne 0 ]
then
    echo "assert.sh: ${failures} failure(s)"
    exit 1
fi

echo "assert.sh: all assertions passed"
