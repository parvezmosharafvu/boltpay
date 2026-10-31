-- 0116: owner correction (supersedes 0114): the CREATOR keeps the link extra
-- fee. Ledger: net_usd = base + extra fee - creator conversion share, the
-- conversion share being a % of G = base + extra fee (the same base the
-- checkout uses for the buyer-paid part). Buyer mode, $100 @ 27%: buyer pays
-- 130.18, creator credited 127.00, platform 3.18. This restores the exact
-- pre-0114 trigger (0107), backed up in prod as fn_backup_0114 / fn_backup_0116.
-- Display rule: creators only ever see base amounts + "Luna 27%". The new
-- generated column display_net_usd = net_usd scaled by base / G (so
-- 127 -> 100, creator mode 123.82 -> 97.50, split 125.41 -> 98.75), and every
-- creator-facing RPC below reports it instead of net_usd. Withdrawals and
-- get_balance_for/get_my_totals keep using the real ledger.

create or replace function payments_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_global boolean; v_prof profiles%rowtype; v_fee numeric; v_bfee numeric;
begin
  if tg_op = 'INSERT' then
    select coalesce((value->>'enabled')::boolean, false) into v_global
      from app_settings where key = 'platform_commission_enabled';
    select * into v_prof from profiles where id = new.user_id;
    new.commission_active := coalesce(v_prof.commission_enabled, v_global, false);
    if coalesce(new.buyer_amount, 0) > 0 and coalesce(new.amount_requested, 0) > 0 then
      new.commission_percent := round(greatest(new.amount_requested / new.buyer_amount - 1, 0) * 100, 3);
    else
      new.commission_percent := 0;
    end if;
    if v_prof.commission_type = 'flat' then
      new.commission_flat_usd := v_prof.commission_flat_usd;
    end if;
    -- 0107: the checkout passes mode + split it priced the buyer with.
    -- Any other insert path falls back to 'creator' at the current fee.
    if new.conversion_fee_mode is null then
      new.conversion_fee_mode := 'creator';
      new.conversion_fee_percent := conversion_fee_percent();
      new.buyer_fee_percent := 0;
      new.buyer_fee_usd := 0;
    else
      if new.conversion_fee_mode not in ('creator','buyer','split') then
        raise exception 'bad conversion_fee_mode';
      end if;
      new.conversion_fee_percent := coalesce(new.conversion_fee_percent, 0);
      new.buyer_fee_percent := coalesce(new.buyer_fee_percent, 0);
      new.buyer_fee_usd := coalesce(new.buyer_fee_usd, 0);
    end if;
    -- link-markup commission % must not count the buyer-paid conversion fee
    if coalesce(new.buyer_amount, 0) > 0 and coalesce(new.amount_requested, 0) - new.buyer_fee_usd > 0 then
      new.commission_percent := round(greatest((new.amount_requested - new.buyer_fee_usd) / new.buyer_amount - 1, 0) * 100, 3);
    end if;
    new.commission_usd := 0;
  end if;
  -- Fixed once, when the payment settles. Never re-priced afterwards.
  if new.status = 'settled' and new.amount_settled is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'settled'
          or old.amount_settled is distinct from new.amount_settled) then
    if new.commission_active then
      if new.commission_flat_usd is not null then
        new.commission_usd := least(new.commission_flat_usd, new.amount_settled);
      else
        new.commission_usd := round(new.amount_settled * coalesce(new.commission_percent, 0)
                                    / (100 + coalesce(new.commission_percent, 0)), 2);
      end if;
    else
      new.commission_usd := 0;
    end if;
    -- Buyer-paid part of the fee goes to the platform as charged; the
    -- creator part is a % of what is left (base + link extra fee).
    v_bfee := least(coalesce(new.buyer_fee_usd, 0), new.amount_settled);
    if new.commission_active and new.commission_flat_usd is null then
      new.commission_usd := round((new.amount_settled - v_bfee) * coalesce(new.commission_percent, 0)
                                  / (100 + coalesce(new.commission_percent, 0)), 2);
    end if;
    v_fee := round((new.amount_settled - v_bfee) * coalesce(new.conversion_fee_percent, 0) / 100, 2);
    new.commission_usd := least(new.commission_usd + v_bfee + v_fee, new.amount_settled);
  end if;
  return new;
end $$;
revoke all on function payments_commission_snapshot() from public, anon, authenticated;

alter table payments add column if not exists display_net_usd numeric
  generated always as (
    case when coalesce(buyer_amount, 0) > 0 and amount_settled is not null
              and amount_settled - coalesce(buyer_fee_usd, 0) > buyer_amount
         then round((amount_settled - commission_usd) * buyer_amount / (amount_settled - coalesce(buyer_fee_usd, 0)), 2)
         else round(coalesce(amount_settled, 0) - commission_usd, 2) end) stored;

create or replace function public.get_my_display_totals()
returns table(earned numeric, available numeric, withdrawn numeric)
language plpgsql stable security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); b record; v_disp numeric; v_ratio numeric;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into b from get_balance_for(v_uid);
  select coalesce(sum(display_net_usd), 0) into v_disp from payments
   where user_id = v_uid and status = 'settled' and amount_settled >= small_payment_threshold()
     and (confirmation is null or confirmation = 'confirmed');
  v_ratio := case when b.earned > 0 then v_disp / b.earned else 1 end;
  return query select round(v_disp, 2), round(greatest(b.available, 0) * v_ratio, 2), round(b.withdrawn * v_ratio, 2);
end $$;
revoke all on function public.get_my_display_totals() from public, anon;
grant execute on function public.get_my_display_totals() to authenticated, service_role;

create or replace function public.my_daily_settled(p_days integer default 14)
 returns table(cycle_date date, cycle_start timestamptz, cycle_end timestamptz, settled numeric, payment_count bigint)
 language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid();
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
  v_hide_at numeric := small_payment_threshold();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date;
  return query
  with days as (
    select gs::date as cycle_date from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ), bounds as (
    select d.cycle_date,
      (d.cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  )
  select b.cycle_date, b.cycle_start, b.cycle_end, coalesce(sum(p.display_net_usd), 0), count(p.id)
  from bounds b
  left join payments p on p.user_id = v_uid and p.status = 'settled' and not (p.amount_settled < v_hide_at)
   and p.settled_at >= b.cycle_start and p.settled_at < b.cycle_end
  group by b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc;
end; $$;

create or replace function public.my_overview_stats()
 returns table(today_settled numeric, month_settled numeric, paid_count bigint, expired_count bigint, failed_count bigint, success_rate numeric)
 language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid();
  v_hide_at numeric := small_payment_threshold();
  v_day timestamptz := date_trunc('day', now() at time zone 'Asia/Dhaka') at time zone 'Asia/Dhaka';
  v_month timestamptz := date_trunc('month', now() at time zone 'Asia/Dhaka') at time zone 'Asia/Dhaka';
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  return query
  with s as (
    select
      coalesce(sum(p.display_net_usd) filter (where p.status = 'settled' and p.created_at >= v_day and not (p.amount_settled < v_hide_at)), 0) as t,
      coalesce(sum(p.display_net_usd) filter (where p.status = 'settled' and p.created_at >= v_month and not (p.amount_settled < v_hide_at)), 0) as m,
      count(*) filter (where p.status = 'settled' and not (p.amount_settled < v_hide_at)) as pc,
      count(*) filter (where p.status = 'expired') as ec,
      count(*) filter (where p.status = 'invalid') as fc
    from payments p where p.user_id = v_uid
  )
  select s.t, s.m, s.pc, s.ec, s.fc,
    case when (s.pc + s.ec + s.fc) = 0 then null else round(100.0 * s.pc / (s.pc + s.ec + s.fc), 1) end
  from s;
end; $$;

create or replace function public.my_top_links(p_days integer default 30)
 returns table(slug text, display_name text, payment_count bigint, settled_usd numeric)
 language sql stable security definer set search_path to 'public' as $$
  select pl.slug, pl.display_name, count(p.id), coalesce(sum(p.display_net_usd), 0)
  from payment_links pl
  join payments p on p.payment_link_id = pl.id and p.status = 'settled'
   and p.settled_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 90))
  where pl.user_id = auth.uid() and pl.deleted_at is null
  group by pl.slug, pl.display_name
  order by 4 desc
  limit 5;
$$;

-- daily_invoices stays the real ledger; the creator view shows display net.
create or replace function public.my_daily_invoices(p_days integer default 30)
 returns table(cycle_date date, payment_count integer, gross_usd numeric, commission_usd numeric, net_usd numeric)
 language sql stable security definer set search_path to 'public' as $$
  select di.cycle_date, di.payment_count, x.base, round(x.base - x.net, 2), x.net
  from daily_invoices di
  cross join lateral (
    select coalesce(sum(coalesce(nullif(p.buyer_amount, 0), p.amount_settled - coalesce(p.buyer_fee_usd, 0))), 0) base,
           coalesce(sum(p.display_net_usd), 0) net
    from payments p
    where p.user_id = di.user_id and p.status = 'settled'
      and p.settled_at >= di.cycle_start and p.settled_at < di.cycle_end
      and not (p.amount_settled < small_payment_threshold())) x
  where di.user_id = auth.uid()
    and di.cycle_date >= current_date - least(greatest(coalesce(p_days, 30), 1), 90)
  order by di.cycle_date desc;
$$;

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
        coalesce(f.conversion_fee_percent, 0) + coalesce(f.buyer_fee_percent, 0),
    -- 0116: display-only. net_amount = base minus the creator's conversion
    -- share (never base + extra fee); fee_usd = paid - net_amount (hidden in UI).
    case when f.status = 'settled' and f.amount_settled is not null then round(f.amount_settled - f.display_net_usd, 2)
         else round(coalesce(f.amount_requested, 0) - est_creator_net(f.buyer_amount, f.amount_requested,
                      f.buyer_fee_usd, f.conversion_fee_percent), 2) end,
    case when f.status = 'settled' and f.amount_settled is not null then f.display_net_usd
         else est_creator_net(f.buyer_amount, f.amount_requested, f.buyer_fee_usd, f.conversion_fee_percent) end
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function public.get_my_payments(integer, integer, text, text) from public, anon;
grant execute on function public.get_my_payments(integer, integer, text, text) to authenticated, service_role;
