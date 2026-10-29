-- PR-B: account approval, phone and Telegram at signup.
-- New signups start 'pending'; every existing account is set 'active' so
-- current creators keep access. Only admins can change the status.
alter table profiles add column if not exists phone text;
alter table profiles add column if not exists telegram_username text;
alter table profiles add column if not exists account_status text not null default 'active';
update profiles set account_status = 'active' where account_status is null;
alter table profiles alter column account_status set default 'pending';
do $$ begin
  alter table profiles add constraint profiles_account_status_chk
    check (account_status in ('pending','active','rejected'));
exception when duplicate_object then null; end $$;
alter table profiles drop constraint if exists profiles_contact_len_chk;
alter table profiles add constraint profiles_contact_len_chk
  check (coalesce(length(phone),0) <= 32 and coalesce(length(telegram_username),0) <= 64);

create or replace function guard_profile_updates()
returns trigger
language plpgsql
security definer
set search_path = public
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
  or new.shop_locked                is distinct from old.shop_locked
  or new.forced_shop_id              is distinct from old.forced_shop_id
  or new.show_buyer_amount_override is distinct from old.show_buyer_amount_override
  or new.account_status             is distinct from old.account_status
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end;

$$;

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_default_fee numeric;
  v_default_links int;
begin
  select coalesce((value->>'percent')::numeric, 3.0) into v_default_fee
  from app_settings where key = 'default_withdrawal_fee_percent';
  select coalesce((value->>'count')::int, 5) into v_default_links
  from app_settings where key = 'default_max_payment_links';

  insert into public.profiles (id, email, display_name, withdrawal_fee_percent, max_payment_links,
                               phone, telegram_username, account_status)
  values (
    new.id, new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    coalesce(v_default_fee, 3.0), coalesce(v_default_links, 5),
    left(nullif(btrim(new.raw_user_meta_data->>'phone'), ''), 32),
    left(nullif(ltrim(btrim(new.raw_user_meta_data->>'telegram_username'), '@'), ''), 64),
    'pending'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke all on function handle_new_user() from anon, authenticated;

-- Checkout only serves links whose owner is approved.
create or replace function system_lnd_link_for_invoice(p_slug text)
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
  where pl.slug = p_slug and pl.deleted_at is null and pr.account_status = 'active'
  limit 1;
$$;
revoke all on function system_lnd_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_lnd_link_for_invoice(text) to service_role;

create or replace function admin_list_accounts(p_status text default 'pending')
returns table (id uuid, email text, display_name text, phone text, telegram_username text,
               account_status text, created_at timestamptz)
language plpgsql security definer stable set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
    select p.id, p.email, p.display_name, p.phone, p.telegram_username, p.account_status, p.created_at
    from profiles p
    where p.role <> 'admin' and (p_status is null or p.account_status = p_status)
    order by p.created_at desc limit 500;
end $$;
revoke all on function admin_list_accounts(text) from public, anon;
grant execute on function admin_list_accounts(text) to authenticated;

create or replace function admin_set_account_status(p_user_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_status not in ('pending','active','rejected') then raise exception 'Bad status'; end if;
  update profiles set account_status = p_status where id = p_user_id and role <> 'admin';
  if not found then raise exception 'User not found'; end if;
end $$;
revoke all on function admin_set_account_status(uuid, text) from public, anon;
grant execute on function admin_set_account_status(uuid, text) to authenticated;
