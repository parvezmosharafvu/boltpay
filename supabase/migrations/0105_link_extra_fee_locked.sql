-- 0105: per-link "extra fee" (buyer markup), set once at creation and locked.
--   * All existing links reset to 0% (owner decision).
--   * Buyer markup = link cost_percent, else 0. No profile/global fallback.
--   * Creators can no longer change cost_percent after creation; only admins
--     (trigger + admin-only set_link_markup).
--   * link_markup_enabled turned on (owner approved).

-- Audit trail of the reset before changing anything.
create table if not exists link_cost_percent_backup_0105 (
  link_id uuid primary key, user_id uuid, cost_percent numeric, backed_up_at timestamptz default now());
alter table link_cost_percent_backup_0105 enable row level security;
revoke all on link_cost_percent_backup_0105 from public, anon, authenticated;
insert into link_cost_percent_backup_0105 (link_id, user_id, cost_percent)
  select id, user_id, cost_percent from payment_links where cost_percent is distinct from 0
  on conflict do nothing;

update payment_links set cost_percent = 0 where cost_percent is distinct from 0;
select record_audit('link.cost_percent_reset', 'payment_link', null,
  null, jsonb_build_object('rows', (select count(*) from link_cost_percent_backup_0105)), null);

insert into app_settings (key, value) values ('link_markup_enabled', 'true'::jsonb)
  on conflict (key) do update set value = 'true'::jsonb;

-- Lock: only admins (or system/service context with no auth.uid()) may change it.
create or replace function payment_links_lock_cost_percent()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.cost_percent is distinct from old.cost_percent
     and auth.uid() is not null and not is_admin() then
    raise exception 'The extra fee of a link is fixed after creation';
  end if;
  return new;
end $$;
drop trigger if exists payment_links_lock_cost_percent on payment_links;
create trigger payment_links_lock_cost_percent
  before update of cost_percent on payment_links
  for each row execute function payment_links_lock_cost_percent();

create or replace function set_link_markup(p_link_id uuid, p_percent numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
declare v_link payment_links%rowtype; v_pct numeric;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not is_admin() then raise exception 'The extra fee of a link is fixed after creation'; end if;
  select * into v_link from payment_links where id = p_link_id and deleted_at is null;
  if not found then raise exception 'Link not found'; end if;
  v_pct := coalesce(check_link_markup(p_percent), 0);
  update payment_links set cost_percent = v_pct
   where user_id = v_link.user_id and deleted_at is null
     and (id = v_link.id or (v_link.variant_group is not null and variant_group = v_link.variant_group));
  perform record_audit('link.cost_percent_changed', 'payment_link', v_link.id::text,
    jsonb_build_object('cost_percent', v_link.cost_percent), jsonb_build_object('cost_percent', v_pct), null);
  return v_pct;
end $$;
revoke all on function set_link_markup(uuid, numeric) from public, anon;
grant execute on function set_link_markup(uuid, numeric) to authenticated;

-- Checkout lookup: effective % is the link's own, else 0.
create or replace function system_lnd_link_for_invoice(p_slug text)
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
         coalesce(pl.cost_percent, 0),
         pl.min_usd, pl.max_usd, pl.quick_amounts, pl.note,
         pl.cost_percent, pr.cost_percent
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  where pl.slug = p_slug and pl.deleted_at is null and pr.account_status = 'active'
  limit 1;
$$;
revoke all on function system_lnd_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_lnd_link_for_invoice(text) to service_role;
