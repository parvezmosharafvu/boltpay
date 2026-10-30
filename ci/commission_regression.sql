-- Platform commission regression (0082). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
-- 0104: isolate from the conversion fee (own test: conversion_fee_regression.sql)
update app_settings set value = '0'::jsonb where key = 'conversion_fee_percent';
do $$
declare u uuid := gen_random_uuid(); l uuid; pid uuid; r payments%rowtype;
begin
  insert into auth.users(id, email) values (u, 'comm-test@example.invalid');
  update profiles set cost_percent = 10 where id = u;
  -- flag OFF: creator keeps everything, identical to before
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 110, 'new') returning id into pid;
  update payments set status='settled', amount_settled=110, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.commission_active = false and r.commission_usd = 0 and r.net_usd = 110, 'flag off must not change earnings';
  assert r.commission_percent = 10, 'snapshot pct';
  -- per-profile ON: platform keeps the markup, creator nets base
  update profiles set commission_enabled = true where id = u;
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 110, 'new') returning id into pid;
  update payments set status='settled', amount_settled=110, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.amount_requested = 110, 'customer price unchanged';
  assert r.commission_usd = 10 and r.net_usd = 100, format('pct commission wrong: %s', r.commission_usd);
  -- flat
  update profiles set commission_type='flat', commission_flat_usd=1.5 where id = u;
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 20, 22, 'new') returning id into pid;
  update payments set status='settled', amount_settled=22, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.commission_usd = 1.5 and r.net_usd = 20.5, 'flat commission';
  -- daily invoice now carries commission
  perform generate_daily_invoices((now() at time zone 'Asia/Dhaka')::date);
end $$;
select gross_usd, commission_usd, net_usd from daily_invoices
 where user_id = (select id from auth.users where email='comm-test@example.invalid');
rollback;
