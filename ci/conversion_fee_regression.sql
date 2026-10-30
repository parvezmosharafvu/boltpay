-- Conversion fee (0104). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); pid uuid; old_pid uuid;
        r payments%rowtype; b record; g record; bad boolean;
begin
  assert (select value from app_settings where key='lnd_customer_markup_percent') = '0'::jsonb, 'buyer markup removed';
  assert conversion_fee_percent() > 0, 'fee seeded from old markup';
  insert into auth.users(id, email) values (u, 'cf-test@example.invalid'), (a, 'cf-admin@example.invalid');
  update profiles set account_status = 'active' where id = u;
  update profiles set role = 'admin' where id = a;
  perform set_config('test.uid', a::text, true);
  assert admin_set_customer_markup(2.5) = 2.5, 'admin sets fee';
  assert conversion_fee_percent() = 2.5;

  -- a pre-0104 style row: null snapshot -> 0 fee, forward-only
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 100, 'new')
    returning id into old_pid;
  update payments set conversion_fee_percent = null where id = old_pid;
  update payments set status='settled', amount_settled=100, settled_at=now() where id=old_pid;
  select * into r from payments where id=old_pid;
  assert r.commission_usd = 0 and r.net_usd = 100, 'null snapshot = no fee';
  -- retro: backs up, applies current fee, records balances, idempotent
  assert system_apply_conversion_fee_retro() >= 1, 'retro applied';
  select * into r from payments where id=old_pid;
  assert r.commission_usd = 2.5 and r.net_usd = 97.5 and r.conversion_fee_percent = 2.5, 'retro fee';
  assert exists (select 1 from conversion_fee_backup_0104 where payment_id = old_pid and commission_usd = 0), 'backup';
  assert (select earned_before - earned_after from conversion_fee_balances_0104 where user_id = u) = 2.5, 'balances recorded';
  assert system_apply_conversion_fee_retro() = 0, 'idempotent';

  -- new payment: buyer pays base, creator nets base - 2.5%
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 100, 'new')
    returning id into pid;
  select * into r from payments where id=pid;
  assert r.conversion_fee_percent = 2.5, 'snapshot at insert';
  -- admin changes fee later: existing invoice keeps its snapshot
  perform admin_set_customer_markup(5);
  update payments set status='settled', amount_settled=100, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.commission_usd = 2.5 and r.net_usd = 97.5, format('fee wrong: %s', r.commission_usd);

  -- balance / totals use net
  select * into b from get_balance_for(u);
  assert b.earned = 195 and b.available = 195, format('balance %s', b.earned);
  perform set_config('test.uid', u::text, true);
  select * into g from get_my_payments(10, 0, null, null) where id = pid;
  assert g.fee_percent = 2.5 and g.fee_usd = 2.5 and g.net_amount = 97.5, 'list exposes fee';

  -- non-admin cannot change fee
  bad := false;
  begin perform admin_set_customer_markup(1); exception when others then bad := true; end;
  assert bad, 'non-admin rejected';
end $$;
rollback;
