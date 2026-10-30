-- 0104: conversion fee (owner decision, 2026-10-31).
--
-- The 2.5% global "customer markup" becomes a creator-side CONVERSION FEE:
--   * buyers pay exactly the base amount (lnd_customer_markup_percent -> 0;
--     lnd-create-invoice no longer adds a global markup);
--   * app_settings.conversion_fee_percent (seeded from the old markup) is
--     snapshotted on every NEW payment (payments.conversion_fee_percent) and
--     at settlement added to commission_usd, so net_usd (= amount_settled -
--     commission_usd) — already used by balance, withdrawals, daily invoices
--     and overview — is the creator's net.
-- RETROACTIVE (owner update "old new all"): every existing payment without
-- a snapshot gets the current fee; settled ones have commission_usd raised
-- by round(amount_settled * fee / 100, 2). Nothing is deleted. Before it
-- runs, the touched rows are copied to conversion_fee_backup_0104 and every
-- creator's balance before/after goes to conversion_fee_balances_0104 and
-- the audit log. Creators with any non-rejected withdrawal are skipped.
-- Undo for one payment: restore commission_usd / conversion_fee_percent
-- from conversion_fee_backup_0104.
-- Creator-earnings readouts that still summed amount_settled now sum net_usd.
-- Platform volume (admin/staff global stats, daily settled charts) stays gross.
--
-- Rollback: set conversion_fee_percent to 0 (new payments); restore old
-- rows from conversion_fee_backup_0104.

insert into app_settings(key, value)
select 'conversion_fee_percent',
       coalesce((select value from app_settings where key = 'lnd_customer_markup_percent'), '2.5'::jsonb)
on conflict (key) do nothing;
update app_settings set value = '0'::jsonb, updated_at = now()
 where key = 'lnd_customer_markup_percent' and value is distinct from '0'::jsonb;

alter table payments add column if not exists conversion_fee_percent numeric(7,3);

create or replace function conversion_fee_percent()
returns numeric language sql stable security definer set search_path = public
as $$
  select coalesce((select (value #>> '{}')::numeric from app_settings where key = 'conversion_fee_percent'), 0);
$$;
revoke all on function conversion_fee_percent() from public, anon;
grant execute on function conversion_fee_percent() to authenticated, service_role;

-- Admin control (same RPC / UI as before, now the conversion fee).
create or replace function admin_set_customer_markup(p_percent numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
declare v_old jsonb; v_new numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent is null or p_percent < 0 or p_percent > 50 then
    raise exception 'Fee must be between 0 and 50 percent';
  end if;
  v_new := round(p_percent, 2);
  select value into v_old from app_settings where key = 'conversion_fee_percent';
  insert into app_settings(key, value) values ('conversion_fee_percent', to_jsonb(v_new))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  perform record_audit('conversion_fee', 'app_settings', 'conversion_fee_percent',
    v_old, to_jsonb(v_new), null);
  return v_new;
end $$;
revoke all on function admin_set_customer_markup(numeric) from public, anon;
grant execute on function admin_set_customer_markup(numeric) to authenticated;

create or replace function payments_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_global boolean; v_prof profiles%rowtype; v_fee numeric;
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
    new.conversion_fee_percent := conversion_fee_percent();
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
    v_fee := round(new.amount_settled * coalesce(new.conversion_fee_percent, 0) / 100, 2);
    new.commission_usd := least(new.commission_usd + v_fee, new.amount_settled);
  end if;
  return new;
end $$;
revoke all on function payments_commission_snapshot() from public, anon, authenticated;

-- Creator payment list: + fee_percent, fee_usd, net_amount.
drop function if exists public.get_my_payments(integer, integer, text, text);
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
    case when f.status = 'settled' and f.amount_settled is not null then f.commission_usd
         else round(coalesce(f.amount_requested, 0) * coalesce(f.conversion_fee_percent, 0) / 100, 2) end,
    case when f.status = 'settled' and f.amount_settled is not null then round(f.net_usd, 2)
         else round(coalesce(f.amount_requested, 0) * (1 - coalesce(f.conversion_fee_percent, 0) / 100), 2) end
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function public.get_my_payments(integer, integer, text, text) from public, anon;
grant execute on function public.get_my_payments(integer, integer, text, text) to authenticated, service_role;

-- Creator earnings readouts: net, not gross.
CREATE OR REPLACE FUNCTION public.admin_customer_directory()
 RETURNS TABLE(rn bigint, id uuid, email text, display_name text, total_earned numeric, total_withdrawn numeric, payment_count bigint, link_count bigint, max_links integer, auto_withdraw_enabled boolean, w_lightning text, w_binance text, w_usdt text, w_bkash text, w_nagad text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
                                                                                                                                    begin
                                                                                                                                      if not is_admin() then raise exception 'Not authorized'; end if;
                                                                                                                                        return query select row_number() over (order by coalesce(te.total_earned,0) desc) as rn,
                                                                                                                                            pr.id, pr.email, pr.display_name, coalesce(te.total_earned,0), coalesce(tw.total_withdrawn,0),
                                                                                                                                                coalesce(te.payment_count,0), coalesce(pl.link_count,0), coalesce(pr.max_payment_links, 5), coalesce(pr.auto_withdraw_enabled, false),
                                                                                                                                                    pr.wallet_lightning, pr.wallet_binance_id, pr.wallet_usdt_bep20, pr.wallet_bkash, pr.wallet_nagad
                                                                                                                                                      from profiles pr
                                                                                                                                                        left join (select user_id, sum(net_usd) as total_earned, count(*) as payment_count from payments where status = 'settled' group by user_id) te on te.user_id = pr.id
                                                                                                                                                          left join (select user_id, sum(amount_after_fee) as total_withdrawn from withdrawals where status = 'paid' group by user_id) tw on tw.user_id = pr.id
                                                                                                                                                            left join (select user_id, count(*) as link_count from payment_links group by user_id) pl on pl.user_id = pr.id
                                                                                                                                                              where pr.role = 'creator' order by rn;
                                                                                                                                                              end; $function$;

CREATE OR REPLACE FUNCTION public.admin_list_payment_links()
 RETURNS TABLE(id uuid, slug text, display_name text, is_active boolean, created_at timestamp with time zone, owner_email text, owner_name text, total_earned numeric, payment_count bigint, cost_percent numeric, cost_is_override boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pl.id, pl.slug, pl.display_name, pl.is_active, pl.created_at,
    pr.email, pr.display_name,
    coalesce((select sum(p.net_usd) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce((select count(*) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce(pl.cost_percent, pr.cost_percent, 0),
    pl.cost_percent is not null
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  where pl.deleted_at is null
  order by pl.created_at desc;
end; $function$;

CREATE OR REPLACE FUNCTION public.admin_list_people()
 RETURNS TABLE(id uuid, email text, display_name text, role text, withdrawal_fee_percent numeric, max_payment_links integer, auto_withdraw_enabled boolean, cost_percent numeric, total_settled numeric, available_balance numeric, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.role,
    pr.withdrawal_fee_percent, pr.max_payment_links, pr.auto_withdraw_enabled,
    coalesce(pr.cost_percent, 0),
    coalesce((select sum(p.net_usd) from payments p
              where p.user_id = pr.id and p.status = 'settled'), 0),
    coalesce((select b.available from get_balance_for(pr.id) b), 0),
    pr.created_at
  from profiles pr
  where pr.role in ('creator', 'moderator')
  order by pr.created_at desc;
end; $function$;

CREATE OR REPLACE FUNCTION public.get_my_insights()
 RETURNS TABLE(revenue_7d numeric, revenue_30d numeric, total_invoices bigint, paid_invoices bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_hide_at numeric := small_payment_threshold();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  return query
  select
    coalesce(sum(p.net_usd) filter (
      where p.status = 'settled' and p.amount_settled >= v_hide_at
        and p.settled_at >= now() - interval '7 days'
    ), 0),
    coalesce(sum(p.net_usd) filter (
      where p.status = 'settled' and p.amount_settled >= v_hide_at
        and p.settled_at >= now() - interval '30 days'
    ), 0),
    count(*) filter (
      where not (p.status = 'settled' and p.amount_settled < v_hide_at)
    ),
    count(*) filter (
      where p.status = 'settled' and p.amount_settled >= v_hide_at
    )
  from payments p
  where p.user_id = v_uid;
end;
$function$;

CREATE OR REPLACE FUNCTION public.staff_customer_directory()
 RETURNS TABLE(rn bigint, id uuid, email text, display_name text, total_earned numeric, total_withdrawn numeric, payment_count bigint, link_count bigint, max_links integer, auto_withdraw_enabled boolean, w_binance text, w_usdt text, w_bkash text, w_nagad text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;

  return query
  select
    row_number() over (order by coalesce(e.earned, 0) desc),
    pr.id, pr.email, pr.display_name,
    coalesce(e.earned, 0), coalesce(w.paid, 0),
    coalesce(e.cnt, 0), coalesce(l.cnt, 0), pr.max_payment_links,
    pr.auto_withdraw_enabled,
    pr.wallet_binance_id, pr.wallet_usdt_bep20, pr.wallet_bkash, pr.wallet_nagad
  from profiles pr
  left join lateral (
    select sum(p.net_usd) as earned, count(*) as cnt
    from payments p where p.user_id = pr.id and p.status = 'settled') e on true
  left join lateral (
    select sum(wd.amount_after_fee) as paid
    from withdrawals wd where wd.user_id = pr.id and wd.status = 'paid') w on true
  left join lateral (
    select count(*) as cnt from payment_links pl where pl.user_id = pr.id) l on true
  where pr.role = 'creator' and handles_creator(pr.id)
  order by coalesce(e.earned, 0) desc;
end; $function$;

CREATE OR REPLACE FUNCTION public.staff_customer_totals()
 RETURNS TABLE(creator_id uuid, email text, display_name text, settled numeric, pending numeric, expired numeric, withdrawn numeric, payment_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  return query
  select
    pr.id, pr.email, pr.display_name,
    coalesce(sum(p.net_usd) filter (
      where p.status = 'settled' and not (p.amount_settled < v_hide_at)
    ), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('new','pending')), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('expired','invalid')), 0),
    coalesce((select sum(w.amount_after_fee) from withdrawals w
              where w.user_id = pr.id and w.status = 'paid'), 0),
    count(p.id) filter (
      where p.status = 'settled' and not (p.amount_settled < v_hide_at)
    )
  from profiles pr
  left join payments p on p.user_id = pr.id
  where pr.role = 'creator' and handles_creator(pr.id)
  group by pr.id, pr.email, pr.display_name
  order by 4 desc;
end;
$function$;

-- Retroactive application (owner: "old new all").
create table if not exists conversion_fee_backup_0104 (
  payment_id uuid primary key, user_id uuid, status text, amount_settled numeric,
  commission_usd numeric, conversion_fee_percent numeric, net_usd numeric,
  backed_up_at timestamptz not null default now());
create table if not exists conversion_fee_balances_0104 (
  user_id uuid primary key, payments int, fee_usd numeric,
  earned_before numeric, available_before numeric,
  earned_after numeric, available_after numeric, skipped boolean not null default false,
  applied_at timestamptz not null default now());
alter table conversion_fee_backup_0104 enable row level security;
alter table conversion_fee_balances_0104 enable row level security;
revoke all on conversion_fee_backup_0104, conversion_fee_balances_0104 from public, anon, authenticated;

create or replace function system_apply_conversion_fee_retro()
returns int language plpgsql security definer set search_path = public
as $$
declare v_pct numeric := conversion_fee_percent(); u record; b record; v_n int; v_fee numeric; v_total int := 0;
begin
  for u in select distinct p.user_id from payments p where p.conversion_fee_percent is null loop
    select * into b from get_balance_for(u.user_id);
    if exists (select 1 from withdrawals w where w.user_id = u.user_id and w.status <> 'rejected') then
      insert into conversion_fee_balances_0104(user_id, payments, fee_usd, earned_before, available_before,
                                               earned_after, available_after, skipped)
        values (u.user_id, 0, 0, b.earned, b.available, b.earned, b.available, true)
        on conflict (user_id) do nothing;
      continue;
    end if;
    insert into conversion_fee_backup_0104(payment_id, user_id, status, amount_settled, commission_usd, conversion_fee_percent, net_usd)
      select id, user_id, status, amount_settled, commission_usd, conversion_fee_percent, net_usd
        from payments where user_id = u.user_id and conversion_fee_percent is null
      on conflict (payment_id) do nothing;
    select count(*) filter (where status = 'settled' and amount_settled is not null),
           coalesce(sum(round(amount_settled * v_pct / 100, 2)) filter (where status = 'settled' and amount_settled is not null), 0)
      into v_n, v_fee
      from payments where user_id = u.user_id and conversion_fee_percent is null;
    -- Direct column update: the snapshot trigger only fires on status/amount_settled.
    update payments
       set conversion_fee_percent = v_pct,
           commission_usd = case when status = 'settled' and amount_settled is not null
             then least(commission_usd + round(amount_settled * v_pct / 100, 2), amount_settled)
             else commission_usd end
     where user_id = u.user_id and conversion_fee_percent is null;
    insert into conversion_fee_balances_0104(user_id, payments, fee_usd, earned_before, available_before, earned_after, available_after)
      select u.user_id, v_n, v_fee, b.earned, b.available, a.earned, a.available from get_balance_for(u.user_id) a
      on conflict (user_id) do nothing;
    perform record_audit('conversion_fee.retro', 'profile', u.user_id::text,
      jsonb_build_object('earned', b.earned, 'available', b.available),
      (select jsonb_build_object('earned', a.earned, 'available', a.available, 'fee_usd', v_fee,
                                 'payments', v_n, 'percent', v_pct) from get_balance_for(u.user_id) a), null);
    v_total := v_total + v_n;
  end loop;
  return v_total;
end $$;
revoke all on function system_apply_conversion_fee_retro() from public, anon, authenticated;

select system_apply_conversion_fee_retro();

-- Stored daily invoices for the affected days: recompute from net_usd.
do $$
declare d date;
begin
  for d in select distinct (p.settled_at at time zone 'Asia/Dhaka')::date + k
             from payments p, generate_series(0, 1) k
            where p.status = 'settled' and p.settled_at is not null
              and p.id in (select payment_id from conversion_fee_backup_0104)
  loop
    perform generate_daily_invoices(d);
  end loop;
end $$;
