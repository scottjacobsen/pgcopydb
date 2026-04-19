--
-- DML run against the source during the follow phase. Each statement is its
-- own transaction so a failure on one of them does not prevent the others
-- from being inspected on the target.
--
-- Without the fix:
--   * the INSERT into public.filtered_table produces a replication stream
--     event that the follow subprocess tries to apply against the target,
--     which does not have that table; the apply fails with
--     `ERROR: relation "public.filtered_table" does not exist` and the
--     clone --follow process exits non-zero.
--   * the INSERT into public.data_filtered_table succeeds but is applied
--     against the target even though exclude-table-data is set, so the
--     target ends up with data that should have been filtered.
--
-- With the fix both events are suppressed at the prefetch stage and the
-- target only sees the unfiltered_table change.
--

insert into public.unfiltered_table (val) values ('u-follow-1'), ('u-follow-2');

insert into public.filtered_table (val) values ('f-follow-1'), ('f-follow-2');

insert into public.data_filtered_table (val) values ('d-follow-1'), ('d-follow-2');
