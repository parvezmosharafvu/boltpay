-- 0108: pre-0105 payments carried the old 2.5% buyer markup. 0106 removed the
-- retro creator fee on 14 settled ones but left the markup with the creator,
-- so they netted MORE than the base (e.g. d457ac08: base $140, paid $143.50,
-- net $143.50) and the platform collected no fee. Treat that markup as the
-- buyer-paid conversion fee (mode 'buyer'): creator nets the base, the
-- platform keeps the markup once. Unsettled pre-0105 rows (which also had a
-- creator fee snapshot on top of the markup) get the same treatment so their
-- estimates read correctly. Backup first, audited, idempotent, no deletes.

create table if not exists conversion_fee_markup_fix_0108 (
  payment_id uuid primary key, user_id uuid, status text,
  buyer_amount numeric, amount_requested numeric, amount_settled numeric,
  mode_before text, fee_pct_before numeric, buyer_fee_pct_before numeric, buyer_fee_usd_before numeric,
  commission_before numeric, net_before numeric, applied_at timestamptz default now());
alter table conversion_fee_markup_fix_0108 enable row level security;
revoke all on conversion_fee_markup_fix_0108 from public, anon, authenticated;

create table if not exists conversion_fee_markup_fix_balances_0108 (
  user_id uuid primary key, payments int, available_before numeric, available_after numeric,
  applied_at timestamptz default now());
alter table conversion_fee_markup_fix_balances_0108 enable row level security;
revoke all on conversion_fee_markup_fix_balances_0108 from public, anon, authenticated;

do $$
declare r record; v_before numeric; v_after numeric; n int;
begin
  for r in
    select distinct p.user_id from payments p
     where p.conversion_fee_mode = 'creator' and p.buyer_amount > 0
       and coalesce(p.buyer_fee_usd, 0) = 0
       and not exists (select 1 from conversion_fee_markup_fix_0108 x where x.payment_id = p.id)
       and ((p.status = 'settled' and exists (select 1 from conversion_fee_refund_0106 z where z.payment_id = p.id)
             and p.amount_settled > p.buyer_amount)
         or (p.status <> 'settled' and p.amount_requested > p.buyer_amount
             and p.created_at < '2026-10-30 20:59:25+00'))
  loop
    select available into v_before from get_balance_for(r.user_id);
    insert into conversion_fee_markup_fix_0108 (payment_id, user_id, status, buyer_amount, amount_requested,
           amount_settled, mode_before, fee_pct_before, buyer_fee_pct_before, buyer_fee_usd_before,
           commission_before, net_before)
    select p.id, p.user_id, p.status, p.buyer_amount, p.amount_requested, p.amount_settled,
           p.conversion_fee_mode, p.conversion_fee_percent, p.buyer_fee_percent, p.buyer_fee_usd,
           p.commission_usd, p.net_usd
      from payments p
     where p.user_id = r.user_id and p.conversion_fee_mode = 'creator' and p.buyer_amount > 0
       and coalesce(p.buyer_fee_usd, 0) = 0
       and ((p.status = 'settled' and exists (select 1 from conversion_fee_refund_0106 z where z.payment_id = p.id)
             and p.amount_settled > p.buyer_amount)
         or (p.status <> 'settled' and p.amount_requested > p.buyer_amount
             and p.created_at < '2026-10-30 20:59:25+00'))
    on conflict do nothing;

    update payments p
       set conversion_fee_mode = 'buyer', conversion_fee_percent = 0,
           buyer_fee_usd = round(coalesce(p.amount_settled, p.amount_requested) - p.buyer_amount, 2),
           buyer_fee_percent = round((coalesce(p.amount_settled, p.amount_requested) / p.buyer_amount - 1) * 100, 3),
           commission_usd = case when p.status = 'settled'
                                 then round(p.amount_settled - p.buyer_amount, 2) else p.commission_usd end
      from conversion_fee_markup_fix_0108 x
     where x.payment_id = p.id and x.user_id = r.user_id and p.conversion_fee_mode = 'creator';
    get diagnostics n = row_count;

    select available into v_after from get_balance_for(r.user_id);
    insert into conversion_fee_markup_fix_balances_0108 (user_id, payments, available_before, available_after)
    values (r.user_id, n, v_before, v_after) on conflict (user_id) do nothing;
    perform record_audit('conversion_fee.markup_as_fee', 'profile', r.user_id::text,
      jsonb_build_object('available', v_before), jsonb_build_object('available', v_after, 'payments', n),
      'Old 2.5% buyer markup counted once as the buyer-paid conversion fee; creator nets base (fixes 0106)');
  end loop;
end $$;

create or replace function public.get_my_payments(p_limit integer default 60, p_offset integer default 0, p_search text default null, p_status text default null)
 returns table(id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
   created_at timestamptz, settled_at timestamptz, expires_at timestamptz, customer_city text,
   customer_country text, link_slug text, link_name text, lightning_invoice text,
   marked_at timestamptz, marked_by_name text, marked_by_self boolean, mark_note text, total_count bigint,
   fee_percent numeric, fee_usd numeric, net_amount numeric)
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 60), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_hide_at numeric := small_payment_threshold();
  v_show_buyer boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_show_buyer := should_show_buyer_amount(v_uid);
  if v_status is not null
     and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;
  return query
  with filtered as (
    select p.*
    from payments p
    left join payment_links pl on pl.id = p.payment_link_id
    where p.user_id = v_uid
      and (v_status is null or p.status = v_status)
      and not (p.status = 'settled' and p.amount_settled < v_hide_at)
      and (v_search is null
        or p.id::text ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%')
  )
  select f.id,
    case when v_show_buyer then coalesce(f.buyer_amount, f.amount_requested) else f.amount_requested end,
    case when f.amount_settled is null then null
         when v_show_buyer then coalesce(f.buyer_amount, f.amount_settled)
         else f.amount_settled end,
    f.status, f.method, f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    pl.slug, pl.display_name,
    f.lightning_invoice, f.marked_at, mb.display_name, f.marked_by = v_uid, f.mark_note,
    count(*) over () as total_count,
    -- 0108: fee_percent/fee_usd are the TOTAL conversion fee (buyer part +
    -- creator part), so "paid/invoice = net_amount + fee_usd" always holds.
    coalesce(f.conversion_fee_percent, 0) + coalesce(f.buyer_fee_percent, 0),
    case when f.status = 'settled' and f.amount_settled is not null
         then f.commission_usd
         else coalesce(f.buyer_fee_usd, 0)
              + round((coalesce(f.amount_requested, 0) - coalesce(f.buyer_fee_usd, 0)) * coalesce(f.conversion_fee_percent, 0) / 100, 2) end,
    case when f.status = 'settled' and f.amount_settled is not null then round(f.net_usd, 2)
         else round(coalesce(f.amount_requested, 0) - coalesce(f.buyer_fee_usd, 0)
                    - round((coalesce(f.amount_requested, 0) - coalesce(f.buyer_fee_usd, 0)) * coalesce(f.conversion_fee_percent, 0) / 100, 2), 2) end
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function public.get_my_payments(integer, integer, text, text) from public, anon;
grant execute on function public.get_my_payments(integer, integer, text, text) to authenticated, service_role;
