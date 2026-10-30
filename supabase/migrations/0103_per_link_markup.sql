-- 0103: per-link markup (owner pt314u).
--
-- A creator sets the markup % on each link (whole variant group) when
-- creating it and can edit it later, inside an admin-set min/max range.
-- Resolution at checkout, ONLY when app_settings.link_markup_enabled = true:
--   link cost_percent (clamped to range)
--   -> profile cost_percent when > 0 (clamped to range)
--   -> global lnd_customer_markup_percent
-- With the flag OFF (default) checkout is exactly as before: global only.
-- Null link % always falls back, so existing links are unaffected.
--
-- Rollback: set link_markup_enabled=false (instant). Full: drop the new
-- functions, recreate create_link_variants(text,text[]) from 0094 and
-- system_lnd_link_for_invoice from 0070.

insert into app_settings(key, value) values
  ('link_markup_enabled', 'false'::jsonb),
  ('link_markup_min_percent', '0'::jsonb),
  ('link_markup_max_percent', '50'::jsonb)
on conflict (key) do nothing;

create or replace function link_markup_range(out min_pct numeric, out max_pct numeric)
language sql stable security definer set search_path = public
as $$
  select coalesce((select (value #>> '{}')::numeric from app_settings where key = 'link_markup_min_percent'), 0),
         coalesce((select (value #>> '{}')::numeric from app_settings where key = 'link_markup_max_percent'), 50);
$$;
revoke all on function link_markup_range() from public, anon;
grant execute on function link_markup_range() to authenticated, service_role;

create or replace function check_link_markup(p_percent numeric)
returns numeric language plpgsql stable security definer set search_path = public
as $$
declare r record;
begin
  if p_percent is null then return null; end if;
  select * into r from link_markup_range();
  if p_percent < r.min_pct or p_percent > r.max_pct then
    raise exception 'Markup must be between % and % percent', r.min_pct, r.max_pct;
  end if;
  return round(p_percent, 2);
end $$;
revoke all on function check_link_markup(numeric) from public, anon;

create or replace function admin_set_link_markup_range(p_min numeric, p_max numeric)
returns void language plpgsql security definer set search_path = public
as $$
declare v_old jsonb;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_min is null or p_max is null or p_min < 0 or p_max > 100 or p_min > p_max then
    raise exception 'Range must be 0-100 with min <= max';
  end if;
  select jsonb_build_object('min', min_pct, 'max', max_pct) into v_old from link_markup_range();
  insert into app_settings(key, value) values
    ('link_markup_min_percent', to_jsonb(round(p_min, 2))),
    ('link_markup_max_percent', to_jsonb(round(p_max, 2)))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  perform record_audit('link_markup_range', 'app_settings', 'link_markup_range',
    v_old, jsonb_build_object('min', round(p_min, 2), 'max', round(p_max, 2)), null);
end $$;
revoke all on function admin_set_link_markup_range(numeric, numeric) from public, anon;
grant execute on function admin_set_link_markup_range(numeric, numeric) to authenticated;

create or replace function admin_set_link_markup_enabled(p_enabled boolean)
returns boolean language plpgsql security definer set search_path = public
as $$
declare v_old jsonb;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_enabled is null then raise exception 'Missing value'; end if;
  select value into v_old from app_settings where key = 'link_markup_enabled';
  insert into app_settings(key, value) values ('link_markup_enabled', to_jsonb(p_enabled))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  perform record_audit('link_markup_enabled', 'app_settings', 'link_markup_enabled',
    v_old, to_jsonb(p_enabled), null);
  return p_enabled;
end $$;
revoke all on function admin_set_link_markup_enabled(boolean) from public, anon;
grant execute on function admin_set_link_markup_enabled(boolean) to authenticated;

-- Link creation: optional markup % for the whole new group.
drop function if exists create_link_variants(text, text[]);
create function create_link_variants(p_display_name text, p_styles text[], p_cost_percent numeric default null)
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
  v_pct numeric;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_pct := check_link_markup(p_cost_percent);
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
                               variant_group, is_active, checkout_backend, cost_percent)
    values (v_uid, v_slug, v_name, v_style, v_group, true, 'lnd', v_pct);
    v_any := true;
    return query select v_slug, v_style, true;
  end loop;
  if not v_any then raise exception 'Those links already exist'; end if;
end;
$function$;
revoke all on function create_link_variants(text, text[], numeric) from public, anon;
grant execute on function create_link_variants(text, text[], numeric) to authenticated;

-- Owner edits the markup of a link; applies to its whole variant group.
-- p_percent null = clear (fall back to profile / global).
create or replace function set_link_markup(p_link_id uuid, p_percent numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_link payment_links%rowtype; v_pct numeric;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_link from payment_links where id = p_link_id and deleted_at is null;
  if not found or v_link.user_id <> v_uid then raise exception 'Link not found'; end if;
  v_pct := check_link_markup(p_percent);
  update payment_links set cost_percent = v_pct
   where user_id = v_uid and deleted_at is null
     and (id = v_link.id or (v_link.variant_group is not null and variant_group = v_link.variant_group));
  perform record_audit('link.cost_percent_changed', 'payment_link', v_link.id::text,
    jsonb_build_object('cost_percent', v_link.cost_percent), jsonb_build_object('cost_percent', v_pct), null);
  return v_pct;
end $$;
revoke all on function set_link_markup(uuid, numeric) from public, anon;
grant execute on function set_link_markup(uuid, numeric) to authenticated;

-- Checkout lookup: expose link and profile % separately.
drop function if exists system_lnd_link_for_invoice(text);
create function system_lnd_link_for_invoice(p_slug text)
returns table (
  link_id uuid, user_id uuid, slug text, display_name text, is_active boolean,
  checkout_backend text, cost_percent numeric,
  min_usd numeric, max_usd numeric, quick_amounts numeric[], note text,
  link_cost_percent numeric, profile_cost_percent numeric
)
language sql security definer stable set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         pl.checkout_backend,
         coalesce(pl.cost_percent, pr.cost_percent, 0),
         pl.min_usd, pl.max_usd, pl.quick_amounts, pl.note,
         pl.cost_percent, pr.cost_percent
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  where pl.slug = p_slug and pl.deleted_at is null and pr.account_status = 'active'
  limit 1;
$$;
revoke all on function system_lnd_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_lnd_link_for_invoice(text) to service_role;
