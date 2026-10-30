-- Daily run report (0090). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
-- 0104: isolate from the conversion fee (own test: conversion_fee_regression.sql)
update app_settings set value = '0'::jsonb where key = 'conversion_fee_percent';
create or replace function auth.uid() returns uuid language sql stable as $f$ select nullif(current_setting('test.uid', true), '')::uuid $f$;
do $$
declare a uuid := gen_random_uuid(); u uuid := gen_random_uuid(); pid uuid; r1 jsonb; r2 jsonb;
  d date := ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date - 1;
  t timestamptz := (d::text || ' 20:00')::timestamp at time zone 'Asia/Dhaka';
begin
  insert into auth.users(id, email) values (a, 'run-admin@example.invalid'), (u, 'run-user@example.invalid');
  update profiles set role = 'admin' where id = a;
  perform set_config('test.uid', a::text, true);
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 40, 40, 'new') returning id into pid;
  update payments set status='settled', amount_settled=40, settled_at=t where id=pid;
  r1 := admin_run_daily_invoices_report(d);
  assert exists (select 1 from jsonb_array_elements(r1->'invoiced') e where (e->>'userId')::uuid = u), format('first run invoices user: %s', r1);
  r2 := admin_run_daily_invoices_report(d);
  assert not exists (select 1 from jsonb_array_elements(r2->'invoiced') e where (e->>'userId')::uuid = u), 'second run must not re-invoice';
  assert (r2->>'alreadyDone')::int >= 1, 'second run counts already done';
  update payments set confirmation='held' where id=pid;
  perform generate_daily_invoices(d);
  perform set_config('test.uid', u::text, true);
  begin
    perform admin_run_daily_invoices_report(d);
    raise exception 'non-admin ran it';
  exception when others then
    assert sqlerrm = 'Not authorized', sqlerrm;
  end;
end $$;
rollback;
