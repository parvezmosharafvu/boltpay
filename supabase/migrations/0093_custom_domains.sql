-- ============================================================
-- Boltpay — 0093: custom (white-label) domains per user
-- ============================================================
-- Same model as paycashapp.site: an admin adds a user's own hostname,
-- it is provisioned as a Cloudflare for SaaS custom hostname, polled
-- until active, and then serves only that user's links with the
-- user's brand on login and pay pages.
--
-- Everything is behind app_settings.custom_domains_enabled (default
-- false). With the flag off no row of kind 'custom' can become active,
-- and existing platform domains behave exactly as before.

alter table site_domains add column if not exists kind text not null default 'platform';
alter table site_domains drop constraint if exists site_domains_kind_check;
alter table site_domains add constraint site_domains_kind_check check (kind in ('platform','custom'));
alter table site_domains add column if not exists owner_id uuid references profiles(id) on delete set null;
alter table site_domains add column if not exists brand_name text;
alter table site_domains add column if not exists status text not null default 'active';
alter table site_domains drop constraint if exists site_domains_status_check;
alter table site_domains add constraint site_domains_status_check
  check (status in ('pending','provisioning','active','failed','disabled','removed'));
alter table site_domains add column if not exists cf_hostname_id text;
alter table site_domains add column if not exists ssl_status text;
alter table site_domains add column if not exists verification jsonb;
alter table site_domains add column if not exists last_error text;
alter table site_domains add column if not exists last_checked_at timestamptz;
alter table site_domains add column if not exists activated_at timestamptz;
alter table site_domains drop constraint if exists site_domains_custom_owner_check;
alter table site_domains add constraint site_domains_custom_owner_check
  check (kind = 'platform' or owner_id is not null or status = 'removed');
create index if not exists idx_site_domains_owner on site_domains(owner_id) where owner_id is not null;

insert into app_settings (key, value)
select 'custom_domains_enabled', 'false'::jsonb
where not exists (select 1 from app_settings where key = 'custom_domains_enabled');

-- Public read: platform domains only. A custom domain is visible to its
-- owner and admins; anyone else resolves it through domain_info().
drop policy if exists "domains public read" on site_domains;
create policy "domains public read"
on site_domains for select
using (kind = 'platform' or owner_id = auth.uid() or is_admin());

-- Branding for the current host (login / register / pay pages).
create or replace function domain_info(p_host text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'hostname', d.hostname,
    'kind', d.kind,
    'brand_name', coalesce(nullif(d.brand_name, ''), p.display_name),
    'white_label', true)
  from site_domains d
  left join profiles p on p.id = d.owner_id
  where lower(d.hostname) = lower(trim(p_host))
    and d.kind = 'custom' and d.is_active and d.status = 'active'
  limit 1;
$$;
revoke all on function domain_info(text) from public;
grant execute on function domain_info(text) to anon, authenticated;

-- Worker check: may this host serve this slug? Platform/unknown hosts:
-- always true (unchanged). Active custom host: only its owner's links.
create or replace function custom_domain_allows_slug(p_host text, p_slug text)
returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when d.id is null then true
    else exists (select 1 from payment_links l
                 where lower(l.slug) = lower(p_slug) and l.user_id = d.owner_id)
  end
  from (select 1) x
  left join site_domains d
    on lower(d.hostname) = lower(trim(p_host)) and d.kind = 'custom' and d.is_active;
$$;
revoke all on function custom_domain_allows_slug(text, text) from public;
grant execute on function custom_domain_allows_slug(text, text) to anon, authenticated;

drop function if exists admin_list_domains();
create or replace function admin_list_domains()
returns table (
  id uuid, hostname text, purpose text, theme text,
  is_active boolean, is_primary_site boolean, sort_order int,
  kind text, status text, ssl_status text, owner_id uuid, owner_email text,
  brand_name text, verification jsonb, last_error text,
  last_checked_at timestamptz, activated_at timestamptz
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select d.id, d.hostname, d.purpose, d.theme, d.is_active, d.is_primary_site, d.sort_order,
         d.kind, d.status, d.ssl_status, d.owner_id, p.email::text,
         d.brand_name, d.verification, d.last_error, d.last_checked_at, d.activated_at
  from site_domains d left join profiles p on p.id = d.owner_id
  where d.status <> 'removed'
  order by d.kind, d.sort_order, d.hostname;
end; $$;
revoke all on function admin_list_domains() from public;
grant execute on function admin_list_domains() to authenticated;
