-- 0121: Admin drill-down for the same 7pm-to-7pm Dhaka settlement cycle
-- used by admin_daily_settled. Read-only; never uses or modifies balances.
-- Includes historical/deleted payment links and all settled payments,
-- so the sum of link totals reconciles to the daily settled history.
create or replace function admin_daily_settled_link_details(p_cycle_date date)
returns table (
  link_id uuid,
  slug text,
  link_name text,
  payment_count bigint,
  total_settled numeric,
  payments jsonb
)
language plpgsql stable security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz;
  v_end timestamptz;
begin
  if not public.is_admin() then
    raise exception 'Not authorized';
  end if;
  if p_cycle_date is null then
    raise exception 'Cycle date required';
  end if;
  v_start := (p_cycle_date::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka';
  v_end := v_start + interval '24 hours';

  return query
  select
    p.payment_link_id as link_id,
    coalesce(pl.slug, '(unlinked)')::text as slug,
    coalesce(pl.display_name, pl.slug, '(unlinked payment)')::text as link_name,
    count(*)::bigint as payment_count,
    sum(p.amount_settled)::numeric as total_settled,
    jsonb_agg(
      jsonb_build_object('amount', p.amount_settled, 'settled_at', p.settled_at)
      order by p.settled_at desc, p.id
    ) as payments
  from public.payments p
  left join public.payment_links pl on pl.id = p.payment_link_id
  where p.status = 'settled'
    and p.settled_at >= v_start
    and p.settled_at < v_end
  group by p.payment_link_id, pl.slug, pl.display_name
  order by sum(p.amount_settled) desc, coalesce(pl.slug, '(unlinked)');
end;
$$;

revoke all on function public.admin_daily_settled_link_details(date) from public, anon;
grant execute on function public.admin_daily_settled_link_details(date) to authenticated;
