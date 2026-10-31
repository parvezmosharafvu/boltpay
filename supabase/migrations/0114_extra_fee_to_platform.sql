-- 0114: the platform keeps the per-link extra fee (owner, t333s1702:
-- "Platform keeps the extra fee; credit the creator only $100").
-- On settle a creator is credited ONLY the base link amount, minus the creator
-- part of the conversion fee (creator/split modes), which is now a % of the
-- base, not of base + extra fee. The extra fee always counts as platform
-- revenue (commission_usd -> admin_fee_stats.fee_earned), whether or not the
-- old platform_commission flag is on. Flat commission (if enabled) is added on
-- top. Only the settle transition is re-priced, so already-settled rows never
-- change. Example, buyer mode: base 100, +27% = 127, +2.5% = 130.18 paid;
-- creator net 100, platform 30.18.
-- Prod check at apply time: no settled payment carries a real extra fee (the
-- 14 settled rows with commission_percent > 0 were reclassified by 0108 and
-- have amount_settled - buyer_fee_usd = buyer_amount), so no backfill.

create or replace function payments_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_global boolean; v_prof profiles%rowtype; v_fee numeric; v_bfee numeric;
        v_rest numeric; v_markup numeric; v_flat numeric;
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
    if coalesce(new.buyer_amount, 0) > 0 and coalesce(new.amount_requested, 0) - new.buyer_fee_usd > 0 then
      new.commission_percent := round(greatest((new.amount_requested - new.buyer_fee_usd) / new.buyer_amount - 1, 0) * 100, 3);
    end if;
    new.commission_usd := 0;
  end if;
  -- Fixed once, when the payment settles. Never re-priced afterwards.
  if new.status = 'settled' and new.amount_settled is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'settled'
          or old.amount_settled is distinct from new.amount_settled) then
    v_bfee   := least(coalesce(new.buyer_fee_usd, 0), new.amount_settled);
    v_rest   := new.amount_settled - v_bfee;                       -- base + extra fee
    v_markup := round(v_rest * coalesce(new.commission_percent, 0)
                      / (100 + coalesce(new.commission_percent, 0)), 2); -- extra fee -> platform
    v_fee    := round((v_rest - v_markup) * coalesce(new.conversion_fee_percent, 0) / 100, 2); -- on base
    v_flat   := case when new.commission_active and new.commission_flat_usd is not null
                     then new.commission_flat_usd else 0 end;
    new.commission_usd := least(v_bfee + v_markup + v_fee + v_flat, new.amount_settled);
  end if;
  return new;
end $$;
revoke all on function payments_commission_snapshot() from public, anon, authenticated;

-- Pre-settle estimate of what the creator will be credited (same math as settle).
create or replace function est_creator_net(p_base numeric, p_req numeric, p_bfee numeric, p_pct numeric)
returns numeric language sql immutable set search_path = public as $$
  select round(b - round(b * coalesce(p_pct, 0) / 100, 2), 2)
  from (select case when coalesce(p_base, 0) > 0
                    then least(p_base, greatest(coalesce(p_req, 0) - coalesce(p_bfee, 0), 0))
                    else greatest(coalesce(p_req, 0) - coalesce(p_bfee, 0), 0) end b) s;
$$;
revoke all on function est_creator_net(numeric, numeric, numeric, numeric) from public, anon;
grant execute on function est_creator_net(numeric, numeric, numeric, numeric) to authenticated, service_role;

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
    -- 0114: fee_usd = everything the platform keeps (buyer fee + link extra
    -- fee + creator part of the conversion fee); net = base - creator part.
    case when f.status = 'settled' and f.amount_settled is not null then f.commission_usd
         else round(coalesce(f.amount_requested, 0) - est_creator_net(f.buyer_amount, f.amount_requested,
                      f.buyer_fee_usd, f.conversion_fee_percent), 2) end,
    case when f.status = 'settled' and f.amount_settled is not null then round(f.net_usd, 2)
         else est_creator_net(f.buyer_amount, f.amount_requested, f.buyer_fee_usd, f.conversion_fee_percent) end
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function public.get_my_payments(integer, integer, text, text) from public, anon;
grant execute on function public.get_my_payments(integer, integer, text, text) to authenticated, service_role;
