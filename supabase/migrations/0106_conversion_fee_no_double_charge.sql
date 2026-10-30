-- 0106: owner decision. Old settled payments whose buyer already paid the
-- old 2.5% global markup (amount_settled > buyer_amount) must not also carry
-- the retroactive 0104 conversion fee. Restore their pre-0104 commission and
-- zero their fee snapshot so nothing re-applies it. Backup first; audited;
-- no history deleted. Idempotent.

create table if not exists conversion_fee_refund_0106 (
  payment_id uuid primary key, user_id uuid,
  amount_settled numeric, buyer_amount numeric,
  commission_before numeric, commission_after numeric,
  fee_pct_before numeric, net_before numeric, net_after numeric,
  applied_at timestamptz default now());
alter table conversion_fee_refund_0106 enable row level security;
revoke all on conversion_fee_refund_0106 from public, anon, authenticated;

create table if not exists conversion_fee_refund_balances_0106 (
  user_id uuid primary key, payments int, refunded_usd numeric,
  available_before numeric, available_after numeric, applied_at timestamptz default now());
alter table conversion_fee_refund_balances_0106 enable row level security;
revoke all on conversion_fee_refund_balances_0106 from public, anon, authenticated;

do $$
declare r record; v_before numeric; v_after numeric; n int; amt numeric;
begin
  for r in
    select distinct p.user_id
      from payments p join conversion_fee_backup_0104 b on b.payment_id = p.id
     where p.status = 'settled' and p.buyer_amount is not null
       and p.amount_settled > p.buyer_amount and p.conversion_fee_percent > 0
       and p.commission_usd > b.commission_usd
       and not exists (select 1 from conversion_fee_refund_0106 x where x.payment_id = p.id)
  loop
    select available into v_before from get_balance_for(r.user_id);

    insert into conversion_fee_refund_0106 (payment_id, user_id, amount_settled, buyer_amount,
           commission_before, commission_after, fee_pct_before, net_before, net_after)
    select p.id, p.user_id, p.amount_settled, p.buyer_amount, p.commission_usd, b.commission_usd,
           p.conversion_fee_percent, p.net_usd, p.amount_settled - b.commission_usd
      from payments p join conversion_fee_backup_0104 b on b.payment_id = p.id
     where p.user_id = r.user_id and p.status = 'settled' and p.buyer_amount is not null
       and p.amount_settled > p.buyer_amount and p.conversion_fee_percent > 0
       and p.commission_usd > b.commission_usd
    on conflict do nothing;

    update payments p
       set commission_usd = x.commission_after, conversion_fee_percent = 0
      from conversion_fee_refund_0106 x
     where x.payment_id = p.id and x.user_id = r.user_id and p.conversion_fee_percent > 0;
    get diagnostics n = row_count;

    select available into v_after from get_balance_for(r.user_id);
    select sum(commission_before - commission_after) into amt
      from conversion_fee_refund_0106 where user_id = r.user_id;
    insert into conversion_fee_refund_balances_0106 (user_id, payments, refunded_usd, available_before, available_after)
    values (r.user_id, n, amt, v_before, v_after)
    on conflict (user_id) do nothing;
    perform record_audit('conversion_fee.retro_refund_double', 'profile', r.user_id::text,
      jsonb_build_object('available', v_before), jsonb_build_object('available', v_after, 'payments', n, 'refunded_usd', amt),
      'Buyer already paid 2.5% markup; retro conversion fee removed (owner decision)');
  end loop;
end $$;

-- Recompute stored daily invoices for the affected days.
do $$
declare d date;
begin
  for d in select distinct (p.settled_at at time zone 'Asia/Dhaka')::date + k
             from payments p, generate_series(0, 1) k
            where p.settled_at is not null
              and p.id in (select payment_id from conversion_fee_refund_0106)
  loop
    perform generate_daily_invoices(d);
  end loop;
end $$;
