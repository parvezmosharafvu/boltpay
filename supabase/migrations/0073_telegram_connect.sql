-- PR-F: creators connect their own Telegram and get a message per settled payment.
-- Flow: dashboard asks for a one-time code -> user sends "/start CODE" to the
-- bot -> telegram-webhook stores the chat id. Only the server can set the chat id.
alter table profiles add column if not exists telegram_chat_id bigint;
alter table profiles add column if not exists telegram_link_code text;
alter table profiles add column if not exists telegram_link_expires_at timestamptz;
create unique index if not exists profiles_telegram_link_code_idx on profiles(telegram_link_code) where telegram_link_code is not null;

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
  or new.telegram_chat_id           is distinct from old.telegram_chat_id
  or new.telegram_link_code         is distinct from old.telegram_link_code
  or new.telegram_link_expires_at   is distinct from old.telegram_link_expires_at
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end;

$$;

insert into app_settings (key, value)
select 'telegram_bot_username', 'null'::jsonb
where not exists (select 1 from app_settings where key = 'telegram_bot_username');

create or replace function my_telegram_status()
returns table (connected boolean, bot_username text)
language sql security definer stable set search_path = public
as $$
  select (select telegram_chat_id is not null from profiles where id = auth.uid()),
         (select value #>> '{}' from app_settings where key = 'telegram_bot_username');
$$;
revoke all on function my_telegram_status() from public, anon;
grant execute on function my_telegram_status() to authenticated;

create or replace function my_telegram_link_code()
returns text language plpgsql security definer set search_path = public
as $$
declare v_code text := upper(substr(md5(gen_random_uuid()::text), 1, 8));
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  update profiles set telegram_link_code = v_code,
                      telegram_link_expires_at = now() + interval '15 minutes'
   where id = auth.uid();
  return v_code;
end $$;
revoke all on function my_telegram_link_code() from public, anon;
grant execute on function my_telegram_link_code() to authenticated;

create or replace function my_telegram_disconnect()
returns void language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  update profiles set telegram_chat_id = null, telegram_link_code = null, telegram_link_expires_at = null
   where id = auth.uid();
end $$;
revoke all on function my_telegram_disconnect() from public, anon;
grant execute on function my_telegram_disconnect() to authenticated;

-- Called by telegram-webhook (service_role) with the code the user sent.
create or replace function system_telegram_link(p_code text, p_chat_id bigint)
returns boolean language plpgsql security definer set search_path = public
as $$
begin
  update profiles set telegram_chat_id = p_chat_id, telegram_link_code = null, telegram_link_expires_at = null
   where telegram_link_code = upper(btrim(p_code)) and telegram_link_expires_at > now();
  return found;
end $$;
revoke all on function system_telegram_link(text, bigint) from public, anon, authenticated;
grant execute on function system_telegram_link(text, bigint) to service_role;
