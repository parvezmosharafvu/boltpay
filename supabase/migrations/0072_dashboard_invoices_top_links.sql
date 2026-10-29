-- PR-E: creator dashboard invoices, 30-day chart data and top links.
create or replace function my_daily_invoices(p_days int default 30)
returns table (cycle_date date, payment_count int, gross_usd numeric, commission_usd numeric, net_usd numeric)
language sql security definer stable set search_path = public
as $$
  select di.cycle_date, di.payment_count, di.gross_usd, di.commission_usd, di.net_usd
  from daily_invoices di
  where di.user_id = auth.uid()
    and di.cycle_date >= current_date - least(greatest(coalesce(p_days, 30), 1), 90)
  order by di.cycle_date desc;
$$;
revoke all on function my_daily_invoices(int) from public, anon;
grant execute on function my_daily_invoices(int) to authenticated;

create or replace function my_top_links(p_days int default 30)
returns table (slug text, display_name text, payment_count bigint, settled_usd numeric)
language sql security definer stable set search_path = public
as $$
  select pl.slug, pl.display_name, count(p.id), coalesce(sum(p.amount_settled), 0)
  from payment_links pl
  join payments p on p.payment_link_id = pl.id and p.status = 'settled'
   and p.settled_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 30), 1), 90))
  where pl.user_id = auth.uid() and pl.deleted_at is null
  group by pl.slug, pl.display_name
  order by 4 desc
  limit 5;
$$;
revoke all on function my_top_links(int) from public, anon;
grant execute on function my_top_links(int) to authenticated;
