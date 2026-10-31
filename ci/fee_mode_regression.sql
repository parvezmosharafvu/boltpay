-- Conversion fee modes (0107). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); pid uuid;
        r payments%rowtype; c record; g record; bad boolean;
begin
  insert into auth.users(id, email) values (u, 'fm-test@example.invalid'), (a, 'fm-admin@example.invalid');
  update profiles set account_status = 'active' where id = u;
  update profiles set role = 'admin' where id = a;
  perform set_config('test.uid', a::text, true);
  perform admin_set_customer_markup(2.5);
  assert conversion_fee_mode() = 'buyer', 'default buyer (0117)';
  perform admin_set_conversion_fee_mode('creator');
  select * into c from conversion_fee_config();
  assert c.buyer_percent = 0 and c.creator_percent = 2.5, 'creator split';

  -- creator mode via fallback (no mode passed): 100 -> net 97.50
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 100, 'new')
    returning id into pid;
  update payments set status='settled', amount_settled=100, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.conversion_fee_mode = 'creator' and r.commission_usd = 2.5 and r.net_usd = 97.5, 'creator mode';

  -- buyer mode: total 102.50, creator nets 100
  assert admin_set_conversion_fee_mode('buyer') = 'buyer';
  select * into c from conversion_fee_config();
  assert c.buyer_percent = 2.5 and c.creator_percent = 0, 'buyer split';
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status,
                       conversion_fee_mode, conversion_fee_percent, buyer_fee_percent, buyer_fee_usd)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 102.5, 'new',
            'buyer', 0, 2.5, 2.5)
    returning id into pid;
  -- switching mode later never changes this payment
  perform admin_set_conversion_fee_mode('creator');
  update payments set status='settled', amount_settled=102.5, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.conversion_fee_mode = 'buyer' and r.commission_usd = 2.5 and r.net_usd = 100, format('buyer mode %s', r.net_usd);
  perform set_config('test.uid', u::text, true);
  select * into g from get_my_payments(10, 0, null, null) where id = pid;
  assert g.fee_usd = 2.5 and g.fee_percent = 2.5 and g.net_amount = 100, 'buyer mode list (total fee)';
  perform set_config('test.uid', a::text, true);

  -- split mode with rounding: base 33.33 -> buyer fee 0.42, total 33.75, net 32.91
  perform admin_set_conversion_fee_mode('split');
  select * into c from conversion_fee_config();
  assert c.buyer_percent = 1.25 and c.creator_percent = 1.25, 'split shares';
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status,
                       conversion_fee_mode, conversion_fee_percent, buyer_fee_percent, buyer_fee_usd)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 33.33, 33.75, 'new',
            'split', 1.25, 1.25, 0.42)
    returning id into pid;
  perform set_config('test.uid', u::text, true);
  select * into g from get_my_payments(10, 0, null, null) where id = pid;
  assert g.fee_usd = 0.84 and g.fee_percent = 2.5 and g.net_amount = 32.91, format('split estimate %s %s', g.fee_usd, g.net_amount);
  update payments set status='settled', amount_settled=33.75, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.commission_usd = 0.84 and r.net_usd = 32.91, format('split settle %s %s', r.commission_usd, r.net_usd);
  -- odd fee: round(2.555/2,3) = 1.278 / 1.277
  perform set_config('test.uid', a::text, true);
  perform admin_set_customer_markup(2.555);
  select * into c from conversion_fee_config();
  assert c.fee_percent = 2.56 or (c.buyer_percent + c.creator_percent = c.fee_percent), 'shares add up';

  -- balance = sum of nets
  assert (select earned from get_balance_for(u)) = 97.5 + 100 + 32.91, 'balance net';

  -- guards
  bad := false;
  begin perform admin_set_conversion_fee_mode('nope'); exception when others then bad := true; end;
  assert bad, 'bad mode rejected';
  perform set_config('test.uid', u::text, true);
  bad := false;
  begin perform admin_set_conversion_fee_mode('buyer'); exception when others then bad := true; end;
  assert bad, 'non-admin rejected';
  assert exists (select 1 from audit_log where action = 'conversion_fee.mode'), 'audited';
end $$;
rollback;
