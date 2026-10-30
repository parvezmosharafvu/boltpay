-- Item 12: admin CSV export of payments (read-only).
create or replace function admin_payments_export(p_days int default 30)
returns table (invoice_id uuid, btcpay_invoice text, bolt11 text, customer text, email text,
               link text, status text, confirmation text, amount_usd numeric,
               created_at timestamptz, paid_at timestamptz)
language plpgsql stable security definer set search_path = public
as $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.btcpay_invoice_id::text, p.bolt11::text, p.customer_name::text, pr.email::text,
         pl.slug::text, p.status::text, p.confirmation::text,
         coalesce(p.amount_settled, p.amount_requested)::numeric,
         p.created_at, coalesce(p.paid_at, p.settled_at)
  from payments p
  left join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  where p.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 366)))
  order by p.created_at desc
  limit 50000;
end $function$;
revoke all on function admin_payments_export(int) from public, anon;
grant execute on function admin_payments_export(int) to authenticated;
