---
--- pgcopydb tests/cdc-catchup-segment-gap/ddl.sql
---
--- A small table with a primary key and a few seed rows that exist before
--- the clone snapshot. The CDC traffic in dml.sql is what must reach the
--- target after a catch-up that starts in a WAL segment with no SQL file.
---

begin;

create table orders
(
    id     bigserial primary key,
    status text      not null,
    amount integer   not null
);

commit;

insert into orders (status, amount)
select 'initial', i * 10 from generate_series(1, 5) as g(i);
