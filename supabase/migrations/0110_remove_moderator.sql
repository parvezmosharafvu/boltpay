-- 0110: remove the moderator (staff) system entirely.
-- Moderators are demoted to creators (accounts, links and payments kept).
-- Backups: moderator_removal_backup_0110 (profiles + moderator_assignments).
create table if not exists moderator_removal_backup_0110 (
  kind text not null, data jsonb not null, backed_up_at timestamptz not null default now());
alter table moderator_removal_backup_0110 enable row level security;
revoke all on moderator_removal_backup_0110 from anon, authenticated;
insert into moderator_removal_backup_0110(kind, data)
  select 'profile', to_jsonb(p) from profiles p where p.role = 'moderator';
insert into moderator_removal_backup_0110(kind, data)
  select 'assignment', to_jsonb(a) from moderator_assignments a;

insert into audit_log(actor_email, action, subject_type, subject_id, old_value, new_value, note)
  select 'system', 'staff.moderator_removed', 'profile', p.id::text,
         jsonb_build_object('role', 'moderator',
           'assigned_creators', (select count(*) from moderator_assignments a where a.moderator_id = p.id)),
         jsonb_build_object('role', 'creator'), 'Moderator system removed (0110)'
  from profiles p where p.role = 'moderator';
update profiles set role = 'creator' where role = 'moderator';

-- Shared admin functions: drop the moderator branches.
create or replace function admin_list_payments(p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_search text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, amount_requested numeric, amount_settled numeric, status text, method text, created_at timestamp with time zone, settled_at timestamp with time zone, expires_at timestamp with time zone, customer_city text, customer_country text, creator_id uuid, creator_email text, creator_name text, link_slug text, lightning_invoice text, marked_at timestamp with time zone, marked_by_name text, mark_note text, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  with filtered as (
    select p.*
    from payments p
    join profiles pr on pr.id = p.user_id
    left join payment_links pl on pl.id = p.payment_link_id
    where true
      and (v_search is null
        or p.id::text ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pr.email ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%')
  )
  select f.id,
    case when should_show_buyer_amount(f.user_id) then coalesce(f.buyer_amount, f.amount_requested) else f.amount_requested end,
    case when f.amount_settled is null then null
         when should_show_buyer_amount(f.user_id) then coalesce(f.buyer_amount, f.amount_settled)
         else f.amount_settled end,
    f.status, f.method, f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    f.user_id, pr.email, pr.display_name, pl.slug,
    f.lightning_invoice, f.marked_at, mb.display_name, f.mark_note,
    count(*) over () as total_count
  from filtered f
  join profiles pr on pr.id = f.user_id
  left join payment_links pl on pl.id = f.payment_link_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $function$;

create or replace function admin_payment_meta(p_ids uuid[])
 RETURNS TABLE(id uuid, confirmation text, confirmation_note text, device_id text, device_payments bigint, device_creators bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.confirmation, p.confirmation_note, p.device_id::text,
         (select count(*) from payments d where p.device_id is not null and d.device_id = p.device_id),
         (select count(distinct d.user_id) from payments d where p.device_id is not null and d.device_id = p.device_id)
  from payments p
  where p.id = any(p_ids) and true;
end; $function$;

create or replace function admin_payments_by_device(p_device_id text, p_limit integer DEFAULT 50)
 RETURNS TABLE(id uuid, created_at timestamp with time zone, status text, amount_requested numeric, creator_email text, link_slug text, confirmation text, customer_city text, customer_country text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.created_at, p.status, p.amount_requested, pr.email, pl.slug,
         p.confirmation, p.customer_city, p.customer_country
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  where p.device_id::text = p_device_id and true
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit,50),1),200);
end; $function$;

create or replace function admin_list_people()
 RETURNS TABLE(id uuid, email text, display_name text, role text, withdrawal_fee_percent numeric, max_payment_links integer, auto_withdraw_enabled boolean, cost_percent numeric, total_settled numeric, available_balance numeric, created_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.role,
    pr.withdrawal_fee_percent, pr.max_payment_links, pr.auto_withdraw_enabled,
    coalesce(pr.cost_percent, 0),
    coalesce((select sum(p.net_usd) from payments p
              where p.user_id = pr.id and p.status = 'settled'), 0),
    coalesce((select b.available from get_balance_for(pr.id) b), 0),
    pr.created_at
  from profiles pr
  where pr.role = 'creator'
  order by pr.created_at desc;
end; $function$;

create or replace function set_my_cost_percent(p_percent numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_role text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select role into v_role from profiles where id = v_uid;
  if v_role is distinct from 'creator' then
    raise exception 'Not authorized';
  end if;

  if p_percent is null or p_percent < 0 then
    raise exception 'Cost must be 0 or more';
  end if;

  -- Matches the column's typo guard, with a message that explains what
  -- the limit is for rather than implying a policy the admin set.
  if p_percent > 1000 then
    raise exception 'That looks like a typo — the maximum markup is 1000%%';
  end if;

  update profiles set cost_percent = round(p_percent, 3) where id = v_uid;
  return round(p_percent, 3);
end;
$function$;

create or replace function admin_set_role(p_user_id uuid, p_role text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admin_count int; v_old text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_role not in ('creator', 'admin') then
    raise exception 'Unknown role';
  end if;

  if p_role <> 'admin' then
    select count(*) into v_admin_count from profiles
     where role = 'admin' and id <> p_user_id;
    if v_admin_count = 0 then
      raise exception 'This is the only admin account — promote someone else first';
    end if;
  end if;

  select role into v_old from profiles where id = p_user_id;
  update profiles set role = p_role where id = p_user_id;


  perform record_audit(
    'staff.role_changed', 'profile', p_user_id::text,
    jsonb_build_object('role', v_old),
    jsonb_build_object('role', p_role)
  );
end; $function$;

create or replace function public.mark_payment(p_payment_id uuid, p_note text default null)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_owner uuid; v_status text;
begin
  select user_id, status into v_owner, v_status from payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if not (v_owner = auth.uid() or is_admin()) then raise exception 'Not authorized'; end if;
  if v_status <> 'settled' then raise exception 'Only settled payments can be marked'; end if;
  update payments set marked_at = now(), marked_by = auth.uid(),
         mark_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_payment_id;
end; $function$;

create or replace function public.unmark_payment(p_payment_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare v_owner uuid;
begin
  select user_id into v_owner from payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if not (v_owner = auth.uid() or is_admin()) then raise exception 'Not authorized'; end if;
  update payments set marked_at = null, marked_by = null, mark_note = null where id = p_payment_id;
end; $function$;

-- Moderator-only objects.
drop function if exists staff_global_stats(timestamptz, timestamptz);
drop function if exists staff_customer_totals();
drop function if exists staff_daily_settled(integer);
drop function if exists staff_list_payments(integer, integer, text, text, text);
drop function if exists staff_customer_directory();
drop function if exists admin_assign_creator(uuid, uuid, boolean);
drop function if exists admin_list_staff();
drop function if exists handles_creator(uuid);
drop function if exists is_moderator();
drop table if exists moderator_assignments;

alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role = any (array['creator'::text, 'admin'::text]));
