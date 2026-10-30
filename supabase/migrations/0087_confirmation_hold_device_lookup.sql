-- 0087: confirmation hold (gap 4) + admin device lookup (gap 5).
-- Additive only. Existing payments get confirmation = NULL, which the
-- balance treats exactly as before, so every current balance is unchanged.
alter table payments add column if not exists confirmation text
  check (confirmation in ('confirmed','held','rejected'));
alter table payments add column if not exists confirmation_note text;
alter table payments add column if not exists confirmation_by uuid references profiles(id);
alter table payments add column if not exists confirmation_at timestamptz;
create index if not exists payments_device_id_idx on payments(device_id) where device_id is not null;

-- Held / rejected settled payments do not count toward earned (so they
-- can't be withdrawn). NULL and 'confirmed' behave exactly as before.
create or replace function public.get_balance_for(p_user_id uuid)
 returns table(earned numeric, queued numeric, withdrawn numeric, available numeric)
 language sql stable security definer set search_path to 'public'
as $function$
  select e.earned, q.queued, w.withdrawn, round(e.earned - q.queued, 8) as available
  from
    (select coalesce(sum(net_usd), 0) as earned
     from payments
     where user_id = p_user_id and status = 'settled'
       and amount_settled >= small_payment_threshold()
       and (confirmation is null or confirmation = 'confirmed')) e,
    (select coalesce(sum(amount_requested), 0) as queued
     from withdrawals where user_id = p_user_id and status <> 'rejected') q,
    (select coalesce(sum(amount_after_fee), 0) as withdrawn
     from withdrawals where user_id = p_user_id and status = 'paid') w;
$function$;

create or replace function public.admin_set_payment_confirmation(
  p_payment_id uuid, p_confirmation text, p_note text default null)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
declare v_old text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_confirmation is not null and p_confirmation not in ('confirmed','held','rejected') then
    raise exception 'Invalid confirmation';
  end if;
  select confirmation into v_old from payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  update payments set confirmation = p_confirmation,
         confirmation_note = nullif(trim(coalesce(p_note,'')),''),
         confirmation_by = auth.uid(), confirmation_at = now()
   where id = p_payment_id;
  perform record_audit('payment.confirmation', 'payment', p_payment_id::text,
    jsonb_build_object('confirmation', v_old),
    jsonb_build_object('confirmation', p_confirmation, 'note', p_note));
end; $function$;

-- Per-row extras for the admin list: confirmation + device and how many
-- payments / creators that device has touched.
create or replace function public.admin_payment_meta(p_ids uuid[])
 returns table(id uuid, confirmation text, confirmation_note text, device_id text,
               device_payments bigint, device_creators bigint)
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.confirmation, p.confirmation_note, p.device_id::text,
         (select count(*) from payments d where p.device_id is not null and d.device_id = p.device_id),
         (select count(distinct d.user_id) from payments d where p.device_id is not null and d.device_id = p.device_id)
  from payments p
  where p.id = any(p_ids) and (is_admin() or handles_creator(p.user_id));
end; $function$;

create or replace function public.admin_payments_by_device(p_device_id text, p_limit int default 50)
 returns table(id uuid, created_at timestamptz, status text, amount_requested numeric,
               creator_email text, link_slug text, confirmation text,
               customer_city text, customer_country text)
 language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.created_at, p.status, p.amount_requested, pr.email, pl.slug,
         p.confirmation, p.customer_city, p.customer_country
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  where p.device_id::text = p_device_id and (is_admin() or handles_creator(p.user_id))
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit,50),1),200);
end; $function$;

revoke all on function public.admin_set_payment_confirmation(uuid,text,text) from public, anon;
revoke all on function public.admin_payment_meta(uuid[]) from public, anon;
revoke all on function public.admin_payments_by_device(text,int) from public, anon;
grant execute on function public.admin_set_payment_confirmation(uuid,text,text) to authenticated;
grant execute on function public.admin_payment_meta(uuid[]) to authenticated;
grant execute on function public.admin_payments_by_device(text,int) to authenticated;
