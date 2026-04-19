--
-- Schema for the filtering-follow test.
--
-- Three tables that exercise the filtering behaviour of clone --follow:
--
--   unfiltered_table     - should be fully replicated (data + DML).
--   filtered_table       - listed in [exclude-table]; target must not have
--                          this table and the follow stream must not try
--                          to apply DML against it.
--   data_filtered_table  - listed in [exclude-table-data]; the target DOES
--                          get the schema (DDL), but the initial COPY and
--                          subsequent DML from the follow stream must
--                          not populate it.
--
-- All tables are given REPLICA IDENTITY FULL so that UPDATE/DELETE changes
-- flow through the logical decoding plugin even without primary keys.
--

drop table if exists public.unfiltered_table;
drop table if exists public.filtered_table;
drop table if exists public.data_filtered_table;

create table public.unfiltered_table (
    id serial primary key,
    val text not null
);
alter table public.unfiltered_table replica identity full;

create table public.filtered_table (
    id serial primary key,
    val text not null
);
alter table public.filtered_table replica identity full;

create table public.data_filtered_table (
    id serial primary key,
    val text not null
);
alter table public.data_filtered_table replica identity full;

-- seed one row in each table so the initial COPY also has something to skip
insert into public.unfiltered_table (val) values ('seed-u');
insert into public.filtered_table (val) values ('seed-f');
insert into public.data_filtered_table (val) values ('seed-d');
