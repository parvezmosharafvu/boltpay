-- 0109: fee-mode audit fixes.
-- get_invoice_public returned buyer_amount (the base, pre buyer-fee) for some
-- creators; the invoice actually charges amount_requested. Always return the
-- amount the buyer pays/paid.
create or replace function get_invoice_public(p_payment_id uuid)
returns table(id uuid, amount_requested numeric, amount_settled numeric, method text, status text,
              expires_at timestamptz, merchant_name text, link_slug text, lightning_invoice text)
language sql stable security definer set search_path to 'public' as $$
  select p.id, p.amount_requested, p.amount_settled, p.method::text, p.status::text, p.expires_at,
         pr.display_name::text, pl.slug::text, p.lightning_invoice::text
  from payments p
  left join payment_links pl on pl.id = p.payment_link_id
  left join profiles pr on pr.id = p.user_id
  where p.id = p_payment_id;
$$;

-- Admin "Fee earned" card: conversion/link fees kept by the platform and the
-- creators' net, over the same settled rows as admin_global_stats().total_settled.
create or replace function admin_fee_stats(p_start timestamptz default null, p_end timestamptz default null)
returns table(fee_earned numeric, buyer_fees numeric, creator_net numeric)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select coalesce(sum(p.commission_usd), 0), coalesce(sum(p.buyer_fee_usd), 0), coalesce(sum(p.net_usd), 0)
  from payments p
  where p.status = 'settled'
    and (p_start is null or p.settled_at >= p_start)
    and (p_end   is null or p.settled_at <= p_end);
end $$;
revoke all on function public.admin_fee_stats(timestamptz, timestamptz) from public, anon;
grant execute on function public.admin_fee_stats(timestamptz, timestamptz) to authenticated;
