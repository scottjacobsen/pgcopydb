---
--- pgcopydb tests/cdc-catchup-segment-gap/dml.sql
---
--- DML written after the replication slot's consistent point, and after a
--- pg_switch_wal() so that it lands in a later WAL segment than the one
--- holding the catch-up start LSN. Every row change here must be applied to
--- the target by `pgcopydb stream catchup`.
---

begin;

insert into orders (status, amount)
select 'cdc', i * 100 from generate_series(1, 5) as g(i);

update orders
   set status = 'initial-updated'
 where status = 'initial';

update orders
   set amount = amount + 1
 where status = 'cdc';

commit;
