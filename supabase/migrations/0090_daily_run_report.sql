-- Item 10: the daily invoice run now reports what it did, like
-- {invoiced[], zeroEarnings, alreadyDone, errors[]}. Held or rejected payments
-- are left off invoices, the same as get_balance_for leaves them out of balances.
-- The run only writes daily_invoices (a report table), never balances.
create or replace function generate_daily_invoices(p_cycle_date date)
returns int language plpgsql security definer set search_path = public
as $function$
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
    and coalesce(p.confirmation, 'confirmed') not in ('held', 'rejected')
  group by p.user_id
  on conflict (user_id, cycle_date) do update
    set payment_count = excluded.payment_count, gross_usd = excluded.gross_usd,
        commission_usd = excluded.commission_usd, net_usd = excluded.net_usd,
        updated_at = now()
    where (daily_invoices.payment_count, daily_invoices.gross_usd, daily_invoices.commission_usd, daily_invoices.net_usd)
      is distinct from (excluded.payment_count, excluded.gross_usd, excluded.commission_usd, excluded.net_usd);
  get diagnostics v_n = row_count;
  return v_n;
end $function$;
revoke all on function generate_daily_invoices(date) from public, anon, authenticated;

-- Closes one cycle and says what happened to each creator.
-- invoiced: rows created or corrected; alreadyDone: rows already right;
-- zeroEarnings: creators with no settled payment in the cycle.
create or replace function admin_run_daily_invoices_report(p_cycle_date date default null)
returns jsonb language plpgsql security definer set search_path = public
as $function$
declare
  v_cycle date := coalesce(p_cycle_date, ((now() at time zone 'Asia/Dhaka') - interval '19 hours')::date - 1);
  v_start timestamptz := (v_cycle::text || ' 19:00')::timestamp at time zone 'Asia/Dhaka';
  v_end timestamptz := v_start + interval '24 hours';
  v_invoiced jsonb := '[]'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_done int := 0;
  v_zero int;
  r record;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  for r in
    select p.user_id, count(*) n, round(sum(p.amount_settled), 2) g,
           round(sum(p.commission_usd), 2) c, round(sum(p.net_usd), 2) net
    from payments p
    where p.status = 'settled' and p.settled_at >= v_start and p.settled_at < v_end
      and coalesce(p.confirmation, 'confirmed') not in ('held', 'rejected')
    group by p.user_id
  loop
    begin
      if exists (select 1 from daily_invoices d where d.user_id = r.user_id and d.cycle_date = v_cycle
                 and (d.payment_count, d.gross_usd, d.commission_usd, d.net_usd) = (r.n, r.g, r.c, r.net)) then
        v_done := v_done + 1;
      else
        insert into daily_invoices (user_id, cycle_date, cycle_start, cycle_end, payment_count, gross_usd, commission_usd, net_usd)
        values (r.user_id, v_cycle, v_start, v_end, r.n, r.g, r.c, r.net)
        on conflict (user_id, cycle_date) do update
          set payment_count = excluded.payment_count, gross_usd = excluded.gross_usd,
              commission_usd = excluded.commission_usd, net_usd = excluded.net_usd, updated_at = now();
        v_invoiced := v_invoiced || jsonb_build_object('userId', r.user_id,
          'userName', (select coalesce(nullif(display_name, ''), email) from profiles where id = r.user_id),
          'payments', r.n, 'grossUSD', r.g, 'commissionUSD', r.c, 'netUSD', r.net);
      end if;
    exception when others then
      v_errors := v_errors || jsonb_build_object('userId', r.user_id, 'error', sqlerrm);
    end;
  end loop;
  select count(*) into v_zero from profiles pr
   where coalesce(pr.role, '') <> 'admin'
     and not exists (select 1 from payments p where p.user_id = pr.id and p.status = 'settled'
                     and p.settled_at >= v_start and p.settled_at < v_end
                     and coalesce(p.confirmation, 'confirmed') not in ('held', 'rejected'));
  -- Also refresh the cycle before (in case a run was missed) and the one in progress.
  perform generate_daily_invoices(v_cycle - 1);
  perform generate_daily_invoices(v_cycle + 1);
  return jsonb_build_object('cycleDate', v_cycle, 'invoiced', v_invoiced, 'zeroEarnings', v_zero,
                            'alreadyDone', v_done, 'errors', v_errors);
end $function$;
revoke all on function admin_run_daily_invoices_report(date) from public, anon;
grant execute on function admin_run_daily_invoices_report(date) to authenticated;
