-- 0117: Cashout in display dollars + per-creator fee system removed + buyer default.
-- Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); pid uuid; r payments%rowtype; c record; j jsonb; w withdrawals; bad boolean;
begin
  assert conversion_fee_mode() = 'buyer', 'fee mode default buyer';
  assert not exists (select 1 from app_settings where key = 'platform_commission_enabled'), 'global commission flag removed';
  update app_settings set value = '2.5'::jsonb where key = 'conversion_fee_percent';
  insert into auth.users(id, email) values (u, 'cd-test@example.invalid');
  assert (select withdrawal_fee_percent from profiles where id = u) = 0, 'new user withdraw fee = global default 0';
  assert coalesce((select cost_percent from profiles where id = u), 0) = 0, 'new user cost 0';

  -- the old per-profile flag no longer does anything
  update profiles set commission_enabled = true, commission_type = 'flat', commission_flat_usd = 5 where id = u;
  -- buyer mode, base 100 + 27% extra fee: buyer pays 130.18, creator keeps 127, sees 100
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status,
                       conversion_fee_mode, conversion_fee_percent, buyer_fee_percent, buyer_fee_usd)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour',
            100, 130.18, 'new', 'buyer', 0, 2.5, 3.18) returning id into pid;
  update payments set status='settled', amount_settled=130.18, settled_at=now() where id=pid;
  select * into r from payments where id=pid;
  assert r.commission_active = false and r.commission_usd = 3.18 and r.net_usd = 127 and r.display_net_usd = 100,
    format('settle net=%s fee=%s disp=%s', r.net_usd, r.commission_usd, r.display_net_usd);

  -- retired setters
  perform set_config('test.uid', u::text, true);
  bad := false; begin perform set_my_cost_percent(5); exception when others then bad := true; end;
  assert bad, 'set_my_cost_percent removed';
  bad := false; begin perform admin_update_creator_fee(u, 5); exception when others then bad := true; end;
  assert bad, 'admin_update_creator_fee removed';
  bad := false; begin perform admin_set_cost_percent(u, 5); exception when others then bad := true; end;
  assert bad, 'admin_set_cost_percent removed';

  -- Cashout shows display figures only
  select * into c from get_my_cashout();
  assert c.available = 100, format('display available %s', c.available);
  update app_settings set value = '2'::jsonb where key = 'withdraw_fee_percent';
  update app_settings set value = '0.5'::jsonb where key = 'withdraw_fee_fixed_usd';

  -- display 50 -> real 63.50; real fee 1.77 -> display fee 1.39, receive 48.61
  j := request_withdrawal_display(50, false, 'lightning', 'x@example.com');
  select * into w from withdrawals where id = (j->>'id')::uuid;
  assert w.amount_requested = 63.5 and w.fee_usd = 1.77 and w.amount_after_fee = 61.73 and w.display_amount = 50,
    format('real row %s %s %s', w.amount_requested, w.fee_usd, w.amount_after_fee);
  assert (j->>'display_amount')::numeric = 50 and (j->>'display_fee')::numeric = 1.39 and (j->>'display_receive')::numeric = 48.61,
    format('display reply %s', j);
  assert (select available from get_my_cashout()) = 50, 'display available after';

  -- more than the display available is refused (server checks)
  bad := false; begin perform request_withdrawal_display(50.01, false, 'lightning', 'x@example.com'); exception when others then bad := true; end;
  assert bad, 'over display available refused';
  bad := false; begin perform request_withdrawal_display(4, false, 'lightning', 'x@example.com'); exception when others then bad := true; end;
  assert bad, 'min $5 display';

  -- withdraw all takes the exact real remainder
  j := request_withdrawal_display(null, true, 'usdt_bep20', '0x' || repeat('a', 40));
  select * into w from withdrawals where id = (j->>'id')::uuid;
  assert w.amount_requested = 63.5 and w.display_amount = 50, format('all %s', w.amount_requested);
  assert (select available from get_balance_for(u)) = 0, 'real balance emptied';
  assert (select available from get_my_cashout()) = 0, 'display balance emptied';
end $$;
rollback;
