-- 0082: platform commission (owner decision, pt238u).
--
-- Customer prices do NOT change: the edge functions still charge
-- buyer_amount * (1 + cost_percent/100) exactly as before. What changes is
-- who keeps that extra. With the flag OFF (default) everything is identical
-- to today: commission_usd stays 0 and the creator nets amount_settled.
-- With it ON (globally, or for one profile via commission_enabled=true for
-- a test), the platform keeps the markup (or a flat per-payment fee) and the
-- creator nets the base amount.
--
-- Snapshot per payment: commission_percent (the markup actually charged,
-- derived from amount_requested/buyer_amount), commission_active (decided
-- at invoice creation), commission_usd and net_usd (fixed at settlement).
-- cost_percent is kept as the price source; it is shown as "commission %".

alter table payments add column if not exists commission_percent numeric(7,3);
alter table payments add column if not exists commission_active boolean not null default false;
alter table payments add column if not exists commission_flat_usd numeric(18,2);
alter table payments add column if not exists commission_usd numeric(18,2) not null default 0;
alter table payments add column if not exists net_usd numeric(18,8)
  generated always as (coalesce(amount_settled, 0) - commission_usd) stored;

alter table profiles add column if not exists commission_enabled boolean;          -- null = follow global flag
alter table profiles add column if not exists commission_type text not null default 'percent';
alter table profiles add column if not exists commission_flat_usd numeric(18,2) not null default 0;
alter table profiles drop constraint if exists profiles_commission_type_chk;
alter table profiles add constraint profiles_commission_type_chk check (commission_type in ('percent','flat'));
alter table profiles drop constraint if exists profiles_commission_flat_chk;
alter table profiles add constraint profiles_commission_flat_chk check (commission_flat_usd >= 0 and commission_flat_usd <= 1000);

insert into app_settings(key, value) values ('platform_commission_enabled', '{"enabled": false}')
on conflict (key) do nothing;

create or replace function payments_commission_snapshot()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_global boolean; v_prof profiles%rowtype;
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
  end if;
  return new;
end $$;
revoke all on function payments_commission_snapshot() from public, anon, authenticated;

drop trigger if exists payments_commission_snapshot on payments;
create trigger payments_commission_snapshot before insert or update of status, amount_settled on payments
  for each row execute function payments_commission_snapshot();

-- Creator earnings use net_usd (identical to amount_settled while commission_usd = 0).
CREATE OR REPLACE FUNCTION public.get_balance_for(p_user_id uuid)
 RETURNS TABLE(earned numeric, queued numeric, withdrawn numeric, available numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    e.earned,
    q.queued,
    w.withdrawn,
    round(e.earned - q.queued, 8) as available
  from
    (select coalesce(sum(net_usd), 0) as earned
     from payments
     where user_id = p_user_id and status = 'settled'
       -- Strictly under the threshold, matching every other filter in
       -- this feature. A no-op when the toggle is off: threshold is -1
       -- and amount_settled is never negative.
       and amount_settled >= small_payment_threshold())
    e,
    (select coalesce(sum(amount_requested), 0) as queued
     from withdrawals where user_id = p_user_id and status <> 'rejected') q,
    (select coalesce(sum(amount_after_fee), 0) as withdrawn
     from withdrawals where user_id = p_user_id and status = 'paid') w;
$function$;
CREATE OR REPLACE FUNCTION public.my_daily_settled(p_days integer DEFAULT 14)
 RETURNS TABLE(cycle_date date, cycle_start timestamp with time zone, cycle_end timestamp with time zone, settled numeric, payment_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    select gs::date as cycle_date
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.cycle_date,
      (d.cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  )
  select
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.net_usd), 0),
    count(p.id)
  from bounds b
  left join payments p
    on p.user_id = v_uid
   and p.status = 'settled'
   and not (p.amount_settled < v_hide_at)
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc;
end;
$function$;
CREATE OR REPLACE FUNCTION public.my_top_links(p_days integer DEFAULT 30)
 RETURNS TABLE(slug text, display_name text, payment_count bigint, settled_usd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pl.slug, pl.display_name, count(p.id), coalesce(sum(p.net_usd), 0)
  from payment_links pl
  join payments p on p.payment_link_id = pl.id and p.status = 'settled'
   and p.settled_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 90))
  where pl.user_id = auth.uid() and pl.deleted_at is null
  group by pl.slug, pl.display_name
  order by 4 desc
  limit 5;
$function$;
CREATE OR REPLACE FUNCTION public.my_overview_stats()
 RETURNS TABLE(today_settled numeric, month_settled numeric, paid_count bigint, expired_count bigint, failed_count bigint, success_rate numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      coalesce(sum(p.net_usd) filter (where p.status = 'settled' and p.created_at >= v_day and not (p.amount_settled < v_hide_at)), 0) as t,
      coalesce(sum(p.net_usd) filter (where p.status = 'settled' and p.created_at >= v_month and not (p.amount_settled < v_hide_at)), 0) as m,
      count(*) filter (where p.status = 'settled' and not (p.amount_settled < v_hide_at)) as pc,
      count(*) filter (where p.status = 'expired') as ec,
      count(*) filter (where p.status = 'invalid') as fc
    from payments p
    where p.user_id = v_uid
  )
  select s.t, s.m, s.pc, s.ec, s.fc,
    case when (s.pc + s.ec + s.fc) = 0 then null
         else round(100.0 * s.pc / (s.pc + s.ec + s.fc), 1) end
  from s;
end;
$function$;

-- Daily invoice fix: commission_usd used to be gross(buyer_amount) minus
-- settled, which can never be positive, so it was always 0. Gross is now
-- what customers paid, commission is the per-payment snapshot, net = gross - commission.
CREATE OR REPLACE FUNCTION public.generate_daily_invoices(p_cycle_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_start timestamptz := (p_cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka';
  v_end   timestamptz := v_start + interval '24 hours';
  v_n int;
begin
  insert into daily_invoices (user_id, cycle_date, cycle_start, cycle_end,
                              payment_count, gross_usd, commission_usd, net_usd)
  select p.user_id, p_cycle_date, v_start, v_end, count(*),
         round(sum(p.amount_settled), 2),
         round(sum(p.commission_usd), 2),
         round(sum(p.net_usd), 2)
  from payments p
  where p.status = 'settled' and p.settled_at >= v_start and p.settled_at < v_end
  group by p.user_id
  on conflict (user_id, cycle_date) do update
    set payment_count = excluded.payment_count, gross_usd = excluded.gross_usd,
        commission_usd = excluded.commission_usd, net_usd = excluded.net_usd,
        updated_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- Fallback fee when the setting row is missing: 2% to match the live default (was 3%).
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_default_fee numeric;
  v_default_links int;
begin
  select coalesce((value->>'percent')::numeric, 2.0) into v_default_fee
  from app_settings where key = 'default_withdrawal_fee_percent';
  select coalesce((value->>'count')::int, 5) into v_default_links
  from app_settings where key = 'default_max_payment_links';

  insert into public.profiles (id, email, display_name, withdrawal_fee_percent, max_payment_links,
                               phone, telegram_username, account_status)
  values (
    new.id, new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    coalesce(v_default_fee, 2.0), coalesce(v_default_links, 5),
    left(nullif(btrim(new.raw_user_meta_data->>'phone'), ''), 32),
    left(nullif(ltrim(btrim(new.raw_user_meta_data->>'telegram_username'), '@'), ''), 64),
    'pending'
  )
  on conflict (id) do nothing;
  return new;
end;
$function$;
