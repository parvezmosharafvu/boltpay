-- BDT withdrawal pricing regression (0083). BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
set local session_replication_role = default;
do $$
declare u uuid := gen_random_uuid(); w withdrawals%rowtype;
begin
  insert into auth.users(id, email) values (u, 'bdt-test@example.invalid');
  update withdrawal_methods set enabled = true where code = 'bkash';
  update profiles set bdt_rate = 120 where id = u;
  alter table withdrawals disable trigger user;
  alter table withdrawals enable trigger withdrawal_payout_snapshot;
  insert into withdrawals(user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
    values (u, 10, 0, 10, 'bkash', '01700000000', 'pending') returning * into w;
  assert w.payout_currency = 'USD' and w.payout_rate = 1 and w.payout_amount = 10, 'flag off must stay USD';
  update app_settings set value = '{"enabled": true}' where key = 'withdrawal_bdt_pricing';
  insert into withdrawals(user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
    values (u, 10, 0, 10, 'bkash', '01700000000', 'pending') returning * into w;
  assert w.payout_currency = 'BDT' and w.payout_rate = 120 and w.payout_amount = 1200 and w.amount_after_fee = 10, 'BDT snapshot';
  insert into withdrawals(user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
    values (u, 10, 0, 10, 'usdt_bep20', '0xabc', 'pending') returning * into w;
  assert w.payout_currency = 'USD' and w.payout_amount = 10, 'USD method stays USD';
  -- 0084: no user rate and no global rate -> a BDT withdrawal is refused.
  update profiles set bdt_rate = null where id = u;
  update app_settings set value = '{"rate": null}' where key = 'bdt_rate';
  begin
    insert into withdrawals(user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
      values (u, 10, 0, 10, 'bkash', '01700000000', 'pending');
    raise exception 'expected refusal';
  exception when sqlstate 'P0001' then
    if sqlerrm not like 'BDT rate not set%' then raise; end if;
  end;
  -- Global fallback applies when the user has no rate.
  update app_settings set value = '{"rate": 118}' where key = 'bdt_rate';
  insert into withdrawals(user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
    values (u, 10, 0, 10, 'bkash', '01700000000', 'pending') returning * into w;
  assert w.payout_rate = 118 and w.payout_amount = 1180, 'global fallback';
end $$;
rollback;
