-- PR-A: per-link amount options (min, max, quick amounts, note).
-- NULL means "use the global lnd_pay_min_usd / lnd_pay_max_usd".
alter table payment_links add column if not exists min_usd numeric(12,2);
alter table payment_links add column if not exists max_usd numeric(12,2);
alter table payment_links add column if not exists quick_amounts numeric(12,2)[] not null default '{}';
alter table payment_links add column if not exists note text;

do $$ begin
  alter table payment_links add constraint payment_links_amount_opts_chk check (
    (min_usd is null or min_usd > 0)
    and (max_usd is null or max_usd > 0)
    and (min_usd is null or max_usd is null or min_usd <= max_usd)
    and coalesce(array_length(quick_amounts, 1), 0) <= 6
    and (note is null or length(note) <= 200)
  );
exception when duplicate_object then null; end $$;

-- Return type changes, so drop first (avoids 42P13).
drop function if exists system_lnd_link_for_invoice(text);
create function system_lnd_link_for_invoice(p_slug text)
returns table (
  link_id uuid, user_id uuid, slug text, display_name text, is_active boolean,
  checkout_backend text, cost_percent numeric,
  min_usd numeric, max_usd numeric, quick_amounts numeric[], note text
)
language sql security definer stable set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         pl.checkout_backend,
         coalesce(pl.cost_percent, pr.cost_percent, 0),
         pl.min_usd, pl.max_usd, pl.quick_amounts, pl.note
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;
revoke all on function system_lnd_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_lnd_link_for_invoice(text) to service_role;

-- Owner-only setter for the creator dashboard.
create or replace function set_link_amount_options(
  p_link_id uuid, p_min numeric, p_max numeric, p_quick numeric[], p_note text
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_quick is not null and exists (select 1 from unnest(p_quick) q where q is null or q <= 0) then
    raise exception 'Quick amounts must be positive';
  end if;
  update payment_links
     set min_usd = p_min, max_usd = p_max,
         quick_amounts = coalesce(p_quick, '{}'),
         note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_link_id and user_id = v_uid and deleted_at is null;
  if not found then raise exception 'Link not found'; end if;
end $$;
revoke all on function set_link_amount_options(uuid, numeric, numeric, numeric[], text) from public, anon;
grant execute on function set_link_amount_options(uuid, numeric, numeric, numeric[], text) to authenticated;
