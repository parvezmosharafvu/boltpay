-- BDT withdrawal pricing regression (0083). BEGIN/ROLLBACK.
\set ON_ERROR_STOP on
begin;
set local session_replication_role = default;
do $$
declare u uuid := gen_random_uuid(); w withdrawals%rowtype;
begin
  insert into auth.users(id, email) values (u, 'bdt-test@example.invalid');
  update withdrawal_methods set enabled = true where code = 'bkash';
  update profiles set sell_rate = 120 where id = u;
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
end $$;
rollback;
