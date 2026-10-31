-- Withdraw fee (0115). Runs inside BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
update app_settings set value = '0'::jsonb where key = 'conversion_fee_percent';
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select nullif(current_setting('test.uid', true), '')::uuid $fn$;
do $$
declare u uuid := gen_random_uuid(); pid uuid; w withdrawals; n0 int; n1 int; bad boolean;
  avail0 numeric; avail1 numeric; fee numeric;
begin
  -- defaults: 0 % and $0, existing rows default fee 0
  assert (select percent from get_withdraw_fee()) = 0, 'default percent 0';
  assert (select fixed_usd from get_withdraw_fee()) = 0, 'default fixed 0';

  insert into auth.users(id, email) values (u, 'wf-test@example.invalid');
  insert into payments(id, user_id, backend, lnd_r_hash, amount_sats, expires_at, buyer_amount, amount_requested, status)
    values (gen_random_uuid(), u, 'lnd', md5(random()::text)||md5(random()::text), 1000, now()+interval '1 hour', 100, 100, 'new') returning id into pid;
  update payments set status='settled', amount_settled=100, settled_at=now() where id=pid;
  perform set_config('test.uid', u::text, true);

  -- fee 0: unchanged behaviour
  w := request_withdrawal(10, 'lightning', 'x@example.com');
  assert w.fee_usd = 0 and w.amount_after_fee = 10 and w.fee_percent = 0 and w.fee_fixed_usd = 0, 'zero fee';

  -- set 5 % + $1 (audited: two rows)
  select count(*) into n0 from audit_log where action = 'withdraw_fee';
  update app_settings set value = '5'::jsonb where key = 'withdraw_fee_percent';
  update app_settings set value = '1'::jsonb where key = 'withdraw_fee_fixed_usd';
  update app_settings set value = '1'::jsonb where key = 'withdraw_fee_fixed_usd'; -- no-op, not audited
  select count(*) into n1 from audit_log where action = 'withdraw_fee';
  assert n1 - n0 = 2, format('expected 2 audit rows, got %s', n1 - n0);
  assert exists (select 1 from audit_log where action='withdraw_fee' and subject_id='withdraw_fee_percent'
    and old_value = '0'::jsonb and new_value = '5'::jsonb), 'old/new recorded';

  select available into avail0 from get_balance_for(u);
  w := request_withdrawal(20, 'usdt_bep20', '0xabc');
  assert w.fee_percent = 5 and w.fee_fixed_usd = 1, 'snapshot settings';
  assert w.fee_usd = 2.00, format('fee 20*5%%+1 = 2, got %s', w.fee_usd);
  assert w.amount_after_fee = 18.00, 'creator receives amount minus fee';
  assert w.payout_amount = 18.00, 'payout snapshot uses amount after fee';
  select available into avail1 from get_balance_for(u);
  assert avail0 - avail1 = 20, 'balance drops by full amount';

  -- percent only, rounding
  update app_settings set value = '0'::jsonb where key = 'withdraw_fee_fixed_usd';
  update app_settings set value = '2.5'::jsonb where key = 'withdraw_fee_percent';
  w := request_withdrawal(7.77, 'usdt_bep20', '0xabc');
  assert w.fee_usd = 0.19 and w.amount_after_fee = 7.58, format('rounding, got %s', w.fee_usd);

  -- fixed only, fee >= amount rejected
  update app_settings set value = '0'::jsonb where key = 'withdraw_fee_percent';
  update app_settings set value = '6'::jsonb where key = 'withdraw_fee_fixed_usd';
  bad := false;
  begin w := request_withdrawal(6, 'usdt_bep20', '0xabc');
  exception when others then bad := sqlerrm like 'Withdraw fee%'; end;
  assert bad, 'fee equal to amount must be rejected';
  bad := false;
  begin w := request_withdrawal(5, 'usdt_bep20', '0xabc');
  exception when others then bad := sqlerrm like 'Withdraw fee%'; end;
  assert bad, 'fee above amount must be rejected';
  w := request_withdrawal(6.01, 'usdt_bep20', '0xabc');
  assert w.amount_after_fee = 0.01, 'just above fee is allowed';

  -- range guard
  bad := false;
  begin update app_settings set value = '50.01'::jsonb where key = 'withdraw_fee_percent';
  exception when others then bad := true; end;
  assert bad, 'percent > 50 rejected';
  bad := false;
  begin update app_settings set value = '-1'::jsonb where key = 'withdraw_fee_fixed_usd';
  exception when others then bad := true; end;
  assert bad, 'negative fixed rejected';
  bad := false;
  begin perform admin_set_withdraw_fee(1, 1);
  exception when others then bad := sqlerrm = 'Not authorized'; end;
  assert bad, 'non-admin cannot set';

  -- browser session cannot edit the snapshot
  bad := false;
  begin update withdrawals set fee_usd = 0 where id = w.id;
  exception when others then bad := true; end;
  assert bad, 'fee snapshot is immutable from a session';

  -- revenue: only paid withdrawals' fee_usd
  perform set_config('test.uid', '', true);
  update withdrawals set status = 'paid' where user_id = u and fee_usd > 0;
  select sum(fee_usd) into fee from withdrawals where user_id = u and status = 'paid';
  assert fee = 2.00 + 0.19 + 6.00, format('fee total %s', fee);
  raise notice 'withdraw fee regression OK';
end $$;
rollback;
