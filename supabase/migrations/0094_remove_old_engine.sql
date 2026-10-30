-- Remove the old checkout engine's database code. Tables and columns that
-- hold payment history are kept untouched (owner decides separately).

-- New links and payments are Lightning (LND) by default.
alter table payment_links alter column checkout_backend set default 'lnd';
alter table payments alter column backend set default 'lnd';

-- Old shop-routing code.
drop trigger if exists trg_guard_link_shop_updates on payment_links;
drop function if exists guard_link_shop_updates();
drop function if exists admin_customer_shop_lock(uuid);
drop function if exists admin_delete_shop(uuid);
drop function if exists admin_list_shops();
drop function if exists admin_lock_creator_shop(uuid, boolean, uuid);
drop function if exists admin_set_link_shop(uuid, uuid);
drop function if exists admin_upsert_shop(uuid, text, text, numeric, text, boolean, boolean, integer);
drop function if exists set_link_shop(uuid, uuid);
drop function if exists system_link_for_invoice(text);
drop function if exists link_cost_for_slug(text);

-- Link creation no longer picks a shop.
drop function if exists create_link_variants(text, text[], uuid);
create function create_link_variants(p_display_name text, p_styles text[])
returns table (slug text, style text, created boolean)
language plpgsql security definer set search_path = public
as $function$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_group uuid := gen_random_uuid();
  v_name text;
  v_style text;
  v_slug text;
  v_seen text[] := '{}';
  v_any boolean := false;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_name := title_case_name(p_display_name);
  if v_name = '' then raise exception 'Please enter a name for the link'; end if;
  if length(v_name) > 60 then raise exception 'Name is too long'; end if;
  if slug_from_name(v_name, 'kebab') = '' then
    raise exception 'Name must contain letters or numbers';
  end if;
  if p_styles is null or array_length(p_styles, 1) is null then
    raise exception 'Pick at least one link style';
  end if;
  foreach v_style in array p_styles loop
    if v_style not in ('kebab','pascal','lower','title-kebab') then
      raise exception 'Unknown link style: %', v_style;
    end if;
    v_slug := slug_from_name(v_name, v_style);
    if v_slug = '' or v_slug = any(v_seen) then continue; end if;
    v_seen := v_seen || v_slug;
    if exists (select 1 from payment_links pl where pl.slug = v_slug) then
      return query select v_slug, v_style, false;
      continue;
    end if;
    insert into payment_links (user_id, slug, display_name, slug_style,
                               variant_group, is_active, checkout_backend)
    values (v_uid, v_slug, v_name, v_style, v_group, true, 'lnd');
    v_any := true;
    return query select v_slug, v_style, true;
  end loop;
  if not v_any then raise exception 'Those links already exist'; end if;
end;
$function$;
revoke all on function create_link_variants(text, text[]) from public, anon;
grant execute on function create_link_variants(text, text[]) to authenticated;

-- Admin CSV: payment hash instead of the old invoice id.
drop function if exists admin_payments_export(int);
create function admin_payments_export(p_days int default 30)
returns table (invoice_id uuid, payment_hash text, bolt11 text, customer text, email text,
               link text, status text, confirmation text, amount_usd numeric,
               created_at timestamptz, paid_at timestamptz)
language plpgsql stable security definer set search_path = public
as $function$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select p.id, p.lnd_r_hash::text, p.bolt11::text, p.customer_name::text, pr.email::text,
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

-- Retired slug name no longer reserved.
create or replace function validate_link_slug()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.slug := trim(new.slug);
  if new.slug !~ '^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$' then
    raise exception 'Link name must be 4-50 characters: letters, numbers and hyphens only';
  end if;
  if lower(new.slug) in (
    'index','login','register','dashboard','admin','404','config','theme',
    'assets','favicon','api','u','static','public',
    'well-known','robots','sitemap','moderator','expired'
  ) then
    raise exception 'That link name is reserved';
  end if;
  return new;
end;
$$;

-- The old-engine reconciliation job is retired with its function.
do $$ begin
  if to_regprocedure('cron.unschedule(text)') is not null
     and exists (select 1 from cron.job where jobname = 'boltpay-reconcile') then
    perform cron.unschedule('boltpay-reconcile');
  end if;
end $$;
