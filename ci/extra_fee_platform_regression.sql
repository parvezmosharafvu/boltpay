-- 0114: the platform keeps the link extra fee; creator is credited only the
-- base (minus the creator part of the conversion fee). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); pid uuid; r payments%rowtype; g record; s record;
        m text; tot numeric; bfee numeric; bpct numeric; cpct numeric; net numeric; onchain boolean;
        exp_fee numeric := 0; exp_net numeric := 0; old_pid uuid; old_net numeric;
begin
  insert into auth.users(id, email) values (u, 'xf-test@example.invalid'), (a, 'xf-admin@example.invalid');
  update profiles set account_status = 'active' where id = u;
  update profiles set role = 'admin' where id = a;
  perform set_config('test.uid', a::text, true);
  perform admin_set_customer_markup(2.5);
  -- an already-settled row is never re-priced by later updates
  delete from payments where status = 'settled';
  -- base 100, extra fee 27% -> 127 (fee base G). buyer: 127*2.5% = 3.18 -> 130.18
  for m, tot, bfee, bpct, cpct, net in values
      ('buyer',  130.18::numeric, 3.18::numeric, 2.5::numeric, 0::numeric,  100::numeric),
      ('creator',127,             0,             0,            2.5,         97.5),
      ('split',  128.59,          1.59,          1.25,         1.25,        98.75) loop
    foreach onchain in array array[false, true] loop
      insert into payments(id, user_id, backend, lnd_r_hash, btc_address, amount_sats, expires_at, buyer_amount,
                           amount_requested, status, conversion_fee_mode, conversion_fee_percent, buyer_fee_percent, buyer_fee_usd)
        values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 'bc1qtest', 1000,
                now()+interval '1 hour', 100, tot, 'new', m, cpct, bpct, bfee)
        returning id into pid;
      select * into r from payments where id = pid;
      assert r.commission_percent = 27, format('%s markup pct %s', m, r.commission_percent);
      perform set_config('test.uid', u::text, true);
      select * into g from get_my_payments(50, 0, null, null) where id = pid;
      assert g.net_amount = net and g.fee_usd = tot - net, format('%s estimate net=%s fee=%s', m, g.net_amount, g.fee_usd);
      perform set_config('test.uid', a::text, true);
      if onchain then
        assert system_settle_onchain_payment(pid, repeat('a',64), 1000), 'onchain settle';
      else
        assert system_settle_lnd_payment((select lnd_r_hash from payments where id=pid), 1000000), 'ln settle';
      end if;
      select * into r from payments where id = pid;
      assert r.amount_settled = tot and r.net_usd = net and r.commission_usd = tot - net,
        format('%s onchain=%s settled=%s net=%s fee=%s', m, onchain, r.amount_settled, r.net_usd, r.commission_usd);
      perform set_config('test.uid', u::text, true);
      select * into g from get_my_payments(50, 0, null, null) where id = pid;
      assert g.net_amount = net and g.fee_usd = tot - net, format('%s settled list', m);
      perform set_config('test.uid', a::text, true);
      exp_fee := exp_fee + (tot - net); exp_net := exp_net + net;
      old_pid := pid; old_net := r.net_usd;
    end loop;
  end loop;
  -- the headline case: $100 + 27% + 2.5% buyer = $130.18; platform 30.18
  assert exp_fee = 2 * (30.18 + 29.5 + 29.84), format('fee total %s', exp_fee);
  select * into s from admin_fee_stats();
  assert s.fee_earned = exp_fee and s.creator_net = exp_net, format('fee stats %s %s', s.fee_earned, s.creator_net);
  assert (select earned from get_balance_for(u)) = exp_net, 'balance = base nets';
  -- no extra fee: unchanged from 0107 (buyer 102.50 -> 100; creator 100 -> 97.50)
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status,
                       conversion_fee_mode, conversion_fee_percent, buyer_fee_percent, buyer_fee_usd)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 102.5, 'new',
            'buyer', 0, 2.5, 2.5) returning id into pid;
  update payments set status='settled', amount_settled=102.5, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.net_usd = 100 and r.commission_usd = 2.5, 'no-markup buyer unchanged';
  -- settled rows are not re-priced by unrelated updates
  update payments set mark_note = 'x' where id = old_pid;
  assert (select net_usd from payments where id = old_pid) = old_net, 'settled row stable';
  raise notice 'extra fee to platform regression OK';
end $$;
rollback;
