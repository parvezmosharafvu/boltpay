-- 0096 wiped daily_stats, so the health check's cron probe ("daily_stats
-- has never been written") started alerting even though daily-report runs
-- fine. Write the row daily-report itself would write for the last closed
-- 7pm-7pm cycle, from the same daily_totals_for_cycle() source (all zeros
-- after the fresh start — real numbers, not a placeholder). The health
-- check is left strict on purpose: if daily-report stops running, this
-- row ages past 36h and the alert fires again.
insert into daily_stats (stat_date, total_settled, total_admin_profit, total_withdrawn, payment_count, computed_at)
select c.d, coalesce(t.total_settled,0), coalesce(t.total_admin_profit,0), coalesce(t.total_withdrawn,0), coalesce(t.payment_count,0)::int, now()
from (select (((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date - 1) as d) c
left join lateral public.daily_totals_for_cycle(c.d) t on true
on conflict (stat_date) do update set
  total_settled = excluded.total_settled, total_admin_profit = excluded.total_admin_profit,
  total_withdrawn = excluded.total_withdrawn, payment_count = excluded.payment_count,
  computed_at = excluded.computed_at;
