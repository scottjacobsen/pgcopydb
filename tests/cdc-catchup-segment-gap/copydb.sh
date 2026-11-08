#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# Regression test for catch-up when the first change received after the
# replication slot's consistent point was written to a later WAL segment
# than the one holding the start LSN. The SQL file that catch-up expects
# for the start LSN is then never written while the files after it exist.
# Catch-up used to conclude it had nothing to apply and exit, leaving every
# prefetched change unapplied on the target.
#
# See src/bin/pgcopydb/ld_apply.c:stream_apply_catchup.

SHAREDIR=/var/lib/postgres/.local/share/pgcopydb

# make sure source and target databases are ready
pgcopydb ping

# apply schema + initial data on the source (target will be restored by clone)
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/ddl.sql

# create replication slot + snapshot
coproc ( pgcopydb snapshot --follow --plugin test_decoding )

sleep 1

# force everything written after the slot's consistent point, including
# the first change the slot is going to stream, into a later WAL segment
# than the one holding the start LSN
psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_switch_wal()'

pgcopydb stream setup
pgcopydb clone

kill -TERM ${COPROC_PID}
wait ${COPROC_PID}

# produce CDC traffic on the source: INSERT, UPDATE
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql

# complete the segment holding the DML and mark the streaming end position
psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_switch_wal()'

lsn=`psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_current_wal_flush_lsn()'`

# prefetch captures changes from the replication slot and decodes them
pgcopydb stream prefetch --resume --endpos "${lsn}" --notice

# make sure the gap is really there: catchup starts at the replication
# origin position on the target, and there must be no SQL file for the
# segment holding it while SQL files for later segments exist
startpos=`psql -At -d ${PGCOPYDB_TARGET_PGURI} -c "select pg_replication_origin_progress('pgcopydb', true)"`
startwal=`psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c "select pg_walfile_name('${startpos}')"`

ls -l ${SHAREDIR}

test ! -f ${SHAREDIR}/${startwal}.sql
ls ${SHAREDIR}/0*.sql

# allow replaying/catching-up changes and apply them to the target.
# Without the fix, catchup logs that the start segment file does not exist
# yet and exits without applying the later files.
pgcopydb stream sentinel set apply
pgcopydb stream catchup --resume --endpos "${lsn}" --notice

# cleanup replication slot + origin
pgcopydb stream cleanup

# verify source and target match: the target must reflect every INSERT and
# UPDATE from dml.sql

sql="select id, status, amount from orders order by id"

psql -At -F '|' -d ${PGCOPYDB_SOURCE_PGURI} -c "${sql}" > /tmp/s.out
psql -At -F '|' -d ${PGCOPYDB_TARGET_PGURI} -c "${sql}" > /tmp/t.out

diff /tmp/s.out /tmp/t.out
