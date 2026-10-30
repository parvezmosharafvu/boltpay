-- Fee-mode audit (0109): every mode, Lightning + on-chain settle, public invoice
-- amount and admin fee stats. Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); pid uuid; r payments%rowtype;
        m text; tot numeric; bfee numeric; cpct numeric; net numeric; onchain boolean; inv record; s record;
        exp_fee numeric := 0; exp_net numeric := 0;
begin
  insert into auth.users(id, email) values (u, 'fa-test@example.invalid'), (a, 'fa-admin@example.invalid');
  update profiles set account_status = 'active' where id = u;
  update profiles set role = 'admin' where id = a;
  perform set_config('test.uid', a::text, true);
  perform admin_set_customer_markup(2.5);
  delete from payments where status = 'settled';
  for m, tot, bfee, cpct, net in values ('creator',100::numeric,0::numeric,2.5::numeric,97.5::numeric),
                                         ('buyer',102.5,2.5,0,100), ('split',101.25,1.25,1.25,98.75) loop
    foreach onchain in array array[false, true] loop
      insert into payments(id, user_id, backend, lnd_r_hash, btc_address, amount_sats, expires_at, buyer_amount,
                           amount_requested, status, conversion_fee_mode, conversion_fee_percent, buyer_fee_percent, buyer_fee_usd)
        values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 'bc1qtest', 1000,
                now()+interval '1 hour', 100, tot, 'new', m, cpct, (case when m='creator' then 0 when m='buyer' then 2.5 else 1.25 end), bfee)
        returning id into pid;
      select * into inv from get_invoice_public(pid);
      assert inv.amount_requested = tot, format('%s public invoice shows %s, want %s', m, inv.amount_requested, tot);
      if onchain then
        assert system_settle_onchain_payment(pid, repeat('a',64), 1000), 'onchain settle';
      else
        assert system_settle_lnd_payment((select lnd_r_hash from payments where id=pid), 1000000), 'ln settle';
      end if;
      select * into r from payments where id = pid;
      assert r.amount_settled = tot and r.net_usd = net and r.commission_usd = tot - net,
        format('%s onchain=%s settled=%s net=%s fee=%s', m, onchain, r.amount_settled, r.net_usd, r.commission_usd);
      select * into inv from get_invoice_public(pid);
      assert inv.amount_settled = tot, format('%s public settled %s', m, inv.amount_settled);
      exp_fee := exp_fee + (tot - net); exp_net := exp_net + net;
    end loop;
  end loop;
  select * into s from admin_fee_stats();
  assert s.fee_earned = exp_fee and s.creator_net = exp_net and s.buyer_fees = 2*(2.5+1.25),
    format('fee stats %s %s %s', s.fee_earned, s.creator_net, s.buyer_fees);
  perform set_config('test.uid', u::text, true);
  begin perform admin_fee_stats(); raise exception 'non-admin allowed';
  exception when others then if sqlerrm = 'non-admin allowed' then raise; end if; end;
  raise notice 'fee audit regression OK';
end $$;
rollback;
