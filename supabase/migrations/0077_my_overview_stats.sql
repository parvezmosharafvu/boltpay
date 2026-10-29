-- 0077: Overview stat cards matching the reference dashboard
-- (Today, This month, Success rate, Paid/Expired/Failed counts).
-- Days and months are cut on Asia/Dhaka calendar boundaries.
create or replace function my_overview_stats()
returns table (
  today_settled numeric,
  month_settled numeric,
  paid_count bigint,
  expired_count bigint,
  failed_count bigint,
  success_rate numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
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
      coalesce(sum(p.amount_settled) filter (where p.status = 'settled' and p.created_at >= v_day and not (p.amount_settled < v_hide_at)), 0) as t,
      coalesce(sum(p.amount_settled) filter (where p.status = 'settled' and p.created_at >= v_month and not (p.amount_settled < v_hide_at)), 0) as m,
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
$$;
revoke all on function my_overview_stats() from public, anon;
grant execute on function my_overview_stats() to authenticated;
