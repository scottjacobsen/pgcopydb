#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_SOURCE_STANDBY_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# make sure source and target databases are ready
pgcopydb ping

# sleep a bit so standby is caught up and streaming
sleep 5

# Load schema + data on the PRIMARY (standby is read-only).
grep -v "OWNER TO postgres" /usr/src/pagila/pagila-schema.sql > /tmp/pagila-schema.sql

psql -o /tmp/s.out -d "${PGCOPYDB_SOURCE_PGURI}" -1 -f /tmp/pagila-schema.sql
psql -o /tmp/d.out -d "${PGCOPYDB_SOURCE_PGURI}" -1 -f /usr/src/pagila/pagila-data.sql

# Give the standby a moment to replay the WAL for the DDL above.
sleep 5

# Point pgcopydb at the STANDBY: this is the case we want to make work.
# Today this is expected to fail fatally with:
#   "pgcopydb does not support operating on standby server
#    when --filters are used, as it needs to create temp tables"
pgcopydb clone --skip-ext-comments --notice \
         --source "${PGCOPYDB_SOURCE_STANDBY_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" \
         --filters /usr/src/pgcopydb/exclude.ini \
         --resume --not-consistent

pgcopydb compare schema \
         --source "${PGCOPYDB_SOURCE_STANDBY_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" \
         --filters /usr/src/pgcopydb/exclude.ini || true
