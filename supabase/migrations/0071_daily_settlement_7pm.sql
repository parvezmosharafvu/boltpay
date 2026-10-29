-- PR-D: daily settlement moves from 5pm to 7pm Dhaka, plus daily invoices.
-- The four cycle functions below are the live definitions with only the
-- cutoff changed (17:00 -> 19:00).

CREATE OR REPLACE FUNCTION public.admin_daily_settled(p_days integer DEFAULT 14)
 RETURNS TABLE(cycle_date date, cycle_start timestamp with time zone, cycle_end timestamp with time zone, settled numeric, payment_count bigint, admin_profit numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  -- Same 19-hour shift as staff_daily_settled(): the Dhaka calendar date
  -- on which the 7pm cycle containing "now" began.
  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date;

  return query
  with days as (
    select gs::date as d
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.d as cycle_date,
      (d.d::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.d::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  ),
  settled_per_cycle as (
    select
      b.cycle_date, b.cycle_start, b.cycle_end,
      coalesce(sum(p.amount_settled), 0) as settled,
      count(p.id) as payment_count
    from bounds b
    left join payments p
      on p.status = 'settled'
     and p.settled_at >= b.cycle_start
     and p.settled_at <  b.cycle_end
    group by b.cycle_date, b.cycle_start, b.cycle_end
  ),
  -- Real fee revenue, matching admin_global_stats() exactly. Attributed
  -- by processed_at - when the payout actually went out - rather than by
  -- when the underlying payments settled.
  profit_per_cycle as (
    select
      b.cycle_date,
      coalesce(sum(w.amount_requested - w.amount_after_fee), 0) as admin_profit
    from bounds b
    left join withdrawals w
      on w.status = 'paid'
     and w.processed_at >= b.cycle_start
     and w.processed_at <  b.cycle_end
    group by b.cycle_date
  )
  select
    s.cycle_date, s.cycle_start, s.cycle_end,
    s.settled, s.payment_count,
    round(pr.admin_profit, 4)
  from settled_per_cycle s
  join profit_per_cycle pr on pr.cycle_date = s.cycle_date
  order by s.cycle_date desc;
end;
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
    coalesce(sum(p.amount_settled), 0),
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

CREATE OR REPLACE FUNCTION public.staff_daily_settled(p_days integer DEFAULT 14)
 RETURNS TABLE(creator_id uuid, creator_name text, creator_email text, cycle_date date, cycle_start timestamp with time zone, cycle_end timestamp with time zone, settled numeric, payment_count bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

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
  ),
  mine as (
    select pr.id, pr.display_name, pr.email
    from profiles pr
    where pr.role = 'creator' and handles_creator(pr.id)
  )
  select
    m.id, m.display_name, m.email,
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.amount_settled), 0),
    count(p.id)
  from mine m
  cross join bounds b
  left join payments p
    on p.user_id = m.id
   and p.status = 'settled'
   and not (p.amount_settled < v_hide_at)
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by m.id, m.display_name, m.email, b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc, m.display_name;
end;
$function$;

CREATE OR REPLACE FUNCTION public.daily_totals_for_cycle(p_cycle_date date)
 RETURNS TABLE(cycle_start timestamp with time zone, cycle_end timestamp with time zone, total_settled numeric, payment_count bigint, total_withdrawn numeric, total_admin_profit numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with b as (
    select
      (p_cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (p_cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka'
        + interval '24 hours' as cycle_end
  )
  select
    b.cycle_start,
    b.cycle_end,
    coalesce((
      select sum(p.amount_settled) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0),
    coalesce((
      select count(*) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0),
    coalesce((
      select sum(w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and w.processed_at >= b.cycle_start
        and w.processed_at <  b.cycle_end
    ), 0),
    -- Real fee revenue for this cycle, identical in definition to
    -- admin_global_stats() and admin_daily_settled().
    coalesce((
      select sum(w.amount_requested - w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and w.processed_at >= b.cycle_start
        and w.processed_at <  b.cycle_end
    ), 0)
  from b;
$function$;

-- One invoice per creator per cycle (7pm-7pm Dhaka, named after the start date).
-- gross = what buyers paid, net = what the creator gets, commission = gross - net.
create table if not exists daily_invoices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  cycle_date date not null,
  cycle_start timestamptz not null,
  cycle_end timestamptz not null,
  payment_count int not null default 0,
  gross_usd numeric(18,2) not null default 0,
  commission_usd numeric(18,2) not null default 0,
  net_usd numeric(18,2) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, cycle_date)
);
alter table daily_invoices enable row level security;
drop policy if exists "own daily invoices" on daily_invoices;
create policy "own daily invoices" on daily_invoices for select using (user_id = auth.uid() or is_admin());
revoke insert, update, delete on daily_invoices from anon, authenticated;

create or replace function generate_daily_invoices(p_cycle_date date)
returns int language plpgsql security definer set search_path = public
as $$
declare
  v_start timestamptz := (p_cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka';
  v_end   timestamptz := v_start + interval '24 hours';
  v_n int;
begin
  insert into daily_invoices (user_id, cycle_date, cycle_start, cycle_end,
                              payment_count, gross_usd, commission_usd, net_usd)
  select p.user_id, p_cycle_date, v_start, v_end, count(*),
         round(sum(coalesce(p.buyer_amount, p.amount_settled)), 2),
         round(sum(greatest(coalesce(p.buyer_amount, p.amount_settled) - p.amount_settled, 0)), 2),
         round(sum(p.amount_settled), 2)
  from payments p
  where p.status = 'settled' and p.settled_at >= v_start and p.settled_at < v_end
  group by p.user_id
  on conflict (user_id, cycle_date) do update
    set payment_count = excluded.payment_count, gross_usd = excluded.gross_usd,
        commission_usd = excluded.commission_usd, net_usd = excluded.net_usd,
        updated_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function generate_daily_invoices(date) from public, anon, authenticated;

-- Closes the cycle that just ended (and re-runs the one before, in case a run was missed).
create or replace function run_daily_invoices()
returns int language plpgsql security definer set search_path = public
as $$
declare v_last date := ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date - 1;
begin
  perform generate_daily_invoices(v_last - 1);
  return generate_daily_invoices(v_last);
end $$;
revoke all on function run_daily_invoices() from public, anon, authenticated;

-- Admin "Run now": also refreshes the cycle still in progress.
create or replace function admin_run_daily_invoices()
returns int language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  perform run_daily_invoices();
  return generate_daily_invoices(((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date);
end $$;
revoke all on function admin_run_daily_invoices() from public, anon;
grant execute on function admin_run_daily_invoices() to authenticated;

create or replace function admin_list_daily_invoices(p_days int default 14)
returns table (cycle_date date, user_id uuid, display_name text, email text,
               payment_count int, gross_usd numeric, commission_usd numeric, net_usd numeric)
language plpgsql security definer stable set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
    select di.cycle_date, di.user_id, pr.display_name, pr.email,
           di.payment_count, di.gross_usd, di.commission_usd, di.net_usd
    from daily_invoices di join profiles pr on pr.id = di.user_id
    where di.cycle_date >= current_date - least(greatest(coalesce(p_days,14),1),90)
    order by di.cycle_date desc, di.net_usd desc;
end $$;
revoke all on function admin_list_daily_invoices(int) from public, anon;
grant execute on function admin_list_daily_invoices(int) to authenticated;

-- 13:05 UTC = 19:05 Dhaka, just after the cycle closes.
do $$ begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed - skipping daily invoice schedule.';
    return;
  end if;
  perform cron.unschedule('boltpay-daily-invoices')
  where exists (select 1 from cron.job where jobname = 'boltpay-daily-invoices');
  perform cron.schedule('boltpay-daily-invoices', '5 13 * * *', 'select public.run_daily_invoices();');
end $$;

-- Backfill the last 14 closed cycles.
select generate_daily_invoices(d::date)
from generate_series(((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date - 14,
                     ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date, interval '1 day') d;
