-- 0107: conversion fee modes (owner, pt318u).
--   creator (default) : buyer pays base (+ link extra fee); creator nets minus fee%.
--   buyer             : buyer total includes fee%; creator nets full base.
--   split             : fee% split 50/50 between buyer total and creator net.
-- Mode and split are snapshotted on each payment at creation, so changing
-- the mode never changes existing payments. Fee base G = base + link extra fee.
--   buyer_fee_usd = round(G * buyer% / 100, 2); buyer pays G + buyer_fee_usd.
--   creator fee   = round(G * creator% / 100, 2) at settle.

insert into app_settings (key, value) values ('conversion_fee_mode', '"creator"'::jsonb)
  on conflict (key) do nothing;

alter table payments add column if not exists conversion_fee_mode text;
alter table payments add column if not exists buyer_fee_percent numeric(7,3);
alter table payments add column if not exists buyer_fee_usd numeric(12,2);
-- Existing rows were all priced in creator mode.
update payments set conversion_fee_mode = 'creator', buyer_fee_percent = 0, buyer_fee_usd = 0
 where conversion_fee_mode is null;
alter table payments drop constraint if exists payments_conversion_fee_mode_chk;
alter table payments add constraint payments_conversion_fee_mode_chk
  check (conversion_fee_mode is null or conversion_fee_mode in ('creator','buyer','split'));

create or replace function conversion_fee_mode()
returns text language sql stable security definer set search_path = public
as $$
  select coalesce((select value #>> '{}' from app_settings where key = 'conversion_fee_mode'), 'creator');
$$;
revoke all on function conversion_fee_mode() from public, anon;
grant execute on function conversion_fee_mode() to authenticated, service_role;

-- Mode + split for display and for the checkout.
create or replace function conversion_fee_config()
returns table (mode text, fee_percent numeric, buyer_percent numeric, creator_percent numeric)
language sql stable security definer set search_path = public
as $$
  select m, f,
         case m when 'buyer' then f when 'split' then round(f / 2, 3) else 0 end,
         case m when 'buyer' then 0 when 'split' then f - round(f / 2, 3) else f end
  from (select conversion_fee_mode() m, conversion_fee_percent() f) s;
$$;
revoke all on function conversion_fee_config() from public, anon;
grant execute on function conversion_fee_config() to authenticated, service_role;

create or replace function admin_set_conversion_fee_mode(p_mode text)
returns text language plpgsql security definer set search_path = public
as $$
declare v_old text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_mode is null or p_mode not in ('creator','buyer','split') then
    raise exception 'Mode must be creator, buyer or split';
  end if;
  v_old := conversion_fee_mode();
  insert into app_settings(key, value) values ('conversion_fee_mode', to_jsonb(p_mode))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  perform record_audit('conversion_fee.mode', 'app_settings', 'conversion_fee_mode',
    to_jsonb(v_old), to_jsonb(p_mode), null);
  return p_mode;
end $$;
revoke all on function admin_set_conversion_fee_mode(text) from public, anon;
grant execute on function admin_set_conversion_fee_mode(text) to authenticated;

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
    coalesce(f.conversion_fee_percent, 0),
    -- 0107: fee_usd is the creator's part only; net + fee = creator gross.
    case when f.status = 'settled' and f.amount_settled is not null
         then f.commission_usd - least(coalesce(f.buyer_fee_usd, 0), f.amount_settled)
         else round((coalesce(f.amount_requested, 0) - coalesce(f.buyer_fee_usd, 0)) * coalesce(f.conversion_fee_percent, 0) / 100, 2) end,
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
