-- Withdrawal request key (0088). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
-- 0104: isolate from the conversion fee (own test: conversion_fee_regression.sql)
update app_settings set value = '0'::jsonb where key = 'conversion_fee_percent';
-- Inside the rolled-back transaction only: let auth.uid() see a test user.
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); pid uuid; k uuid := gen_random_uuid(); w withdrawals; n int; dup boolean := false;
begin
  insert into auth.users(id, email) values (u, 'rk-test@example.invalid');
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 100, 'new') returning id into pid;
  update payments set status='settled', amount_settled=100, settled_at=now() where id=pid;
  perform set_config('test.uid', u::text, true);
  w := request_withdrawal(10, 'lightning', 'x@example.com', k);
  assert w.request_key = k, 'key stored';
  begin
    w := request_withdrawal(10, 'lightning', 'x@example.com', k);
  exception when others then
    dup := sqlerrm = 'DUPLICATE_REQUEST';
  end;
  assert dup, 'repeat key must raise DUPLICATE_REQUEST';
  select count(*) into n from withdrawals where user_id = u;
  assert n = 1, format('expected one withdrawal, got %s', n);
  w := request_withdrawal(10, 'lightning', 'x@example.com', gen_random_uuid());
  w := request_withdrawal(10, 'lightning', 'x@example.com');
  select count(*) into n from withdrawals where user_id = u;
  assert n = 3, 'new key and unkeyed calls still work';
end $$;
rollback;
