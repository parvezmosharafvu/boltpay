-- 0095: drop the old engine's data (owner-approved).
-- Payment rows are KEPT: get_balance_for and every earnings/withdrawal
-- figure are derived from them. Only the old engine's own columns,
-- tables and logs go. A full export was taken before this ran.

-- 1. Functions that read the old columns, rewritten without them.
--    Return shapes change, so drop + create + re-grant.
drop function if exists public.admin_live_payments();
create function public.admin_live_payments()
 returns table(id uuid, lightning_invoice text, amount_requested numeric, status text,
   created_at timestamptz, expires_at timestamptz, customer_city text, customer_country text,
   creator_email text, creator_name text, link_slug text)
 language plpgsql security definer set search_path to 'public'
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.lightning_invoice, p.amount_requested, p.status,
    p.created_at, p.expires_at, p.customer_city, p.customer_country,
    pr.email, pr.display_name, pl.slug
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  where p.status in ('new', 'pending')
  order by p.created_at desc;
end; $$;

drop function if exists public.get_link_preview(text);
create function public.get_link_preview(p_slug text)
 returns table(display_name text, is_active boolean, og_image text)
 language sql stable security definer set search_path to 'public'
as $$
  select pl.display_name, pl.is_active, pl.og_image
  from payment_links pl
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;

drop function if exists public.admin_list_people();
create function public.admin_list_people()
 returns table(id uuid, email text, display_name text, role text, withdrawal_fee_percent numeric,
   max_payment_links integer, auto_withdraw_enabled boolean, cost_percent numeric,
   total_settled numeric, available_balance numeric, created_at timestamptz)
 language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.role,
    pr.withdrawal_fee_percent, pr.max_payment_links, pr.auto_withdraw_enabled,
    coalesce(pr.cost_percent, 0),
    coalesce((select sum(p.amount_settled) from payments p
              where p.user_id = pr.id and p.status = 'settled'), 0),
    coalesce((select b.available from get_balance_for(pr.id) b), 0),
    pr.created_at
  from profiles pr
  where pr.role in ('creator', 'moderator')
  order by pr.created_at desc;
end; $$;

drop function if exists public.admin_list_payment_links();
create function public.admin_list_payment_links()
 returns table(id uuid, slug text, display_name text, is_active boolean, created_at timestamptz,
   owner_email text, owner_name text, total_earned numeric, payment_count bigint,
   cost_percent numeric, cost_is_override boolean)
 language plpgsql security definer set search_path to 'public'
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pl.id, pl.slug, pl.display_name, pl.is_active, pl.created_at,
    pr.email, pr.display_name,
    coalesce((select sum(p.amount_settled) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce((select count(*) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce(pl.cost_percent, pr.cost_percent, 0),
    pl.cost_percent is not null
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  where pl.deleted_at is null
  order by pl.created_at desc;
end; $$;

drop function if exists public.admin_list_payments(integer, integer, text);
create function public.admin_list_payments(p_limit integer default 100, p_offset integer default 0, p_search text default null)
 returns table(id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
   created_at timestamptz, settled_at timestamptz, expires_at timestamptz, customer_city text,
   customer_country text, creator_id uuid, creator_email text, creator_name text, link_slug text,
   lightning_invoice text, marked_at timestamptz, marked_by_name text, mark_note text, total_count bigint)
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;
  return query
  with filtered as (
    select p.*
    from payments p
    join profiles pr on pr.id = p.user_id
    left join payment_links pl on pl.id = p.payment_link_id
    where (is_admin() or handles_creator(p.user_id))
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
end; $$;

drop function if exists public.get_my_payments(integer, integer, text, text);
create function public.get_my_payments(p_limit integer default 60, p_offset integer default 0, p_search text default null, p_status text default null)
 returns table(id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
   created_at timestamptz, settled_at timestamptz, expires_at timestamptz, customer_city text,
   customer_country text, link_slug text, link_name text, lightning_invoice text,
   marked_at timestamptz, marked_by_name text, marked_by_self boolean, mark_note text, total_count bigint)
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 60), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_hide_at numeric := small_payment_threshold();
  v_show_buyer boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_show_buyer := should_show_buyer_amount(v_uid);
  if v_status is not null
     and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;
  return query
  with filtered as (
    select p.*
    from payments p
    left join payment_links pl on pl.id = p.payment_link_id
    where p.user_id = v_uid
      and (v_status is null or p.status = v_status)
      and not (p.status = 'settled' and p.amount_settled < v_hide_at)
      and (v_search is null
        or p.id::text ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%')
  )
  select f.id,
    case when v_show_buyer then coalesce(f.buyer_amount, f.amount_requested) else f.amount_requested end,
    case when f.amount_settled is null then null
         when v_show_buyer then coalesce(f.buyer_amount, f.amount_settled)
         else f.amount_settled end,
    f.status, f.method, f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    pl.slug, pl.display_name,
    f.lightning_invoice, f.marked_at, mb.display_name, f.marked_by = v_uid, f.mark_note,
    count(*) over () as total_count
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

drop function if exists public.staff_list_payments(integer, integer, text, text, text);
create function public.staff_list_payments(p_limit integer default 120, p_offset integer default 0, p_search text default null, p_status text default null, p_time text default null)
 returns table(id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
   created_at timestamptz, settled_at timestamptz, expires_at timestamptz, customer_city text,
   customer_country text, creator_id uuid, creator_email text, creator_name text, link_slug text,
   lightning_invoice text, marked_at timestamptz, marked_by_name text, mark_note text)
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 120), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_time text := lower(nullif(trim(coalesce(p_time, '')), ''));
  v_now timestamptz := now();
  v_start timestamptz := null;
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;
  if v_status is not null and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;
  if v_time = 'today' then v_start := date_trunc('day', v_now);
  elsif v_time = '7d' then v_start := v_now - interval '7 days';
  elsif v_time = '30d' then v_start := v_now - interval '30 days';
  elsif v_time is null or v_time = '' then v_start := null;
  else raise exception 'Invalid time filter';
  end if;
  return query
  select p.id,
    case when should_show_buyer_amount(p.user_id) then coalesce(p.buyer_amount, p.amount_requested) else p.amount_requested end,
    case when p.amount_settled is null then null
         when should_show_buyer_amount(p.user_id) then coalesce(p.buyer_amount, p.amount_settled)
         else p.amount_settled end,
    p.status, p.method, p.created_at, p.settled_at, p.expires_at,
    p.customer_city, p.customer_country, p.user_id, pr.email, pr.display_name, pl.slug,
    p.lightning_invoice, p.marked_at, mb.display_name, p.mark_note
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  left join profiles mb on mb.id = p.marked_by
  where (is_admin() or handles_creator(p.user_id))
    and not (p.status = 'settled' and p.amount_settled < v_hide_at)
    and (p_search is null or p_search = ''
      or p.id::text ilike '%' || p_search || '%'
      or p.lightning_invoice ilike '%' || p_search || '%'
      or pr.email ilike '%' || p_search || '%'
      or coalesce(pr.display_name, '') ilike '%' || p_search || '%'
      or coalesce(pl.slug, '') ilike '%' || p_search || '%')
    and (v_status is null or p.status = v_status)
    and (v_start is null or p.created_at >= v_start)
  order by p.created_at desc
  limit v_limit offset v_offset;
end; $$;

create or replace function public.lookup_payment_status(p_reference text)
 returns table(amount numeric, status text, created_at timestamptz, settled_at timestamptz)
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_ref text := trim(coalesce(p_reference, ''));
begin
  if length(v_ref) < 12 then
    raise exception 'Enter the full invoice ID or Lightning address';
  end if;
  return query
  select case when should_show_buyer_amount(p.user_id)
              then coalesce(p.buyer_amount, p.amount_settled, p.amount_requested)
              else coalesce(p.amount_settled, p.amount_requested) end,
    p.status, p.created_at, p.settled_at
  from payments p
  where p.id::text = v_ref or p.lightning_invoice = v_ref
  limit 1;
end; $$;

create or replace function public.admin_mark_payment(p_payment_id uuid, p_status text, p_amount_settled numeric default null)
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare
  v_payment payments;
  v_is_service_role boolean;
  v_max_allowed numeric;
begin
  v_is_service_role := coalesce(
    current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') = 'service_role';
  if not (is_admin() or v_is_service_role) then raise exception 'Not authorized'; end if;
  if p_status not in ('settled', 'expired', 'invalid') then raise exception 'Invalid status'; end if;
  select * into v_payment from payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_payment.status = 'settled' then raise exception 'This payment is already settled'; end if;
  if p_status = 'settled' then
    if p_amount_settled is not null and p_amount_settled <= 0 then
      raise exception 'Settled amount must be positive';
    end if;
    v_max_allowed := round(v_payment.amount_requested * 1.02, 2);
    if p_amount_settled is not null and p_amount_settled > v_max_allowed then
      raise exception
        'Settled amount $% exceeds the requested $% by more than 2%%. '
        'A genuine overpayment should be verified against the Lightning node directly.',
        p_amount_settled, v_payment.amount_requested;
    end if;
    update payments
      set status = 'settled', settled_at = now(),
          amount_settled = coalesce(p_amount_settled, amount_requested)
      where id = p_payment_id;
    perform record_audit(
      'payment.manually_settled', 'payment', p_payment_id::text,
      jsonb_build_object('status', v_payment.status),
      jsonb_build_object('status', 'settled',
                         'amount_settled', coalesce(p_amount_settled, v_payment.amount_requested),
                         'amount_requested', v_payment.amount_requested));
  else
    update payments set status = p_status where id = p_payment_id;
  end if;
end; $$;

create or replace function public.guard_withdrawal_updates()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if auth.uid() is null then
    return new;  -- service role / definer functions
  end if;
  if new.user_id          is distinct from old.user_id
  or new.amount_requested is distinct from old.amount_requested
  or new.fee_percent      is distinct from old.fee_percent
  or new.amount_after_fee is distinct from old.amount_after_fee
  or new.destination      is distinct from old.destination
  then
    raise exception 'Withdrawal amounts and destination cannot be edited';
  end if;
  -- A paid or processing withdrawal is final from any browser session.
  if old.status in ('paid', 'processing') and new.status is distinct from old.status then
    raise exception 'A paid or processing withdrawal cannot be reopened';
  end if;
  return new;
end; $$;

create or replace function public.guard_profile_updates()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;
  if new.id                         is distinct from old.id
  or new.email                      is distinct from old.email
  or new.role                       is distinct from old.role
  or new.withdrawal_fee_percent     is distinct from old.withdrawal_fee_percent
  or new.max_payment_links          is distinct from old.max_payment_links
  or new.auto_withdraw_enabled      is distinct from old.auto_withdraw_enabled
  or new.buy_rate                   is distinct from old.buy_rate
  or new.sell_rate                  is distinct from old.sell_rate
  or new.show_buyer_amount_override is distinct from old.show_buyer_amount_override
  or new.account_status             is distinct from old.account_status
  or new.telegram_chat_id           is distinct from old.telegram_chat_id
  or new.telegram_link_code         is distinct from old.telegram_link_code
  or new.telegram_link_expires_at   is distinct from old.telegram_link_expires_at
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end; $$;

revoke all on function public.admin_live_payments(), public.admin_list_people(),
  public.admin_list_payment_links(), public.admin_list_payments(integer, integer, text),
  public.get_my_payments(integer, integer, text, text),
  public.staff_list_payments(integer, integer, text, text, text),
  public.get_link_preview(text) from public;
grant execute on function public.admin_live_payments(), public.admin_list_people(),
  public.admin_list_payment_links(), public.admin_list_payments(integer, integer, text),
  public.get_my_payments(integer, integer, text, text),
  public.staff_list_payments(integer, integer, text, text, text),
  public.get_link_preview(text) to authenticated, service_role;
grant execute on function public.get_link_preview(text) to anon;

-- 2. Webhook log and its retention job.
do $$
begin
  if to_regprocedure('cron.unschedule(text)') is not null
     and exists (select 1 from cron.job where jobname = 'prune-webhook-events') then
    perform cron.unschedule('prune-webhook-events');
  end if;
end $$;
drop function if exists public.prune_webhook_events();
drop table if exists public.webhook_events;

-- 3. Old columns and the shops table.
alter table payment_links drop constraint if exists payment_links_shop_id_fkey;
alter table profiles drop constraint if exists profiles_forced_shop_id_fkey;
alter table payment_links drop column if exists shop_id;
alter table profiles drop column if exists forced_shop_id;
alter table profiles drop column if exists shop_locked;
alter table payments drop column if exists btcpay_invoice_id;
alter table payments drop column if exists btcpay_store_id;
alter table payments drop column if exists btcpay_api_key_env;
drop table if exists public.btcpay_shops;

-- 4. Links can only use LND. The 12 remaining old-backend links are all
--    deleted and inactive, so switching their label changes nothing.
update payment_links set checkout_backend = 'lnd' where checkout_backend <> 'lnd';
alter table payment_links drop constraint if exists payment_links_checkout_backend_check;
alter table payment_links add constraint payment_links_checkout_backend_check
  check (checkout_backend = 'lnd');
