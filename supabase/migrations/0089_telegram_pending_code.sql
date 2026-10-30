-- 0089: Telegram link status with the pending code and its expiry, so the
-- dashboard can show a countdown and poll until the chat is linked.
create or replace function my_telegram_info()
returns table (connected boolean, bot_username text, pending_code text, pending_expires_at timestamptz)
language sql security definer stable set search_path = public
as $$
  select p.telegram_chat_id is not null,
         (select value #>> '{}' from app_settings where key = 'telegram_bot_username'),
         case when p.telegram_link_expires_at > now() then p.telegram_link_code end,
         case when p.telegram_link_expires_at > now() then p.telegram_link_expires_at end
  from profiles p where p.id = auth.uid();
$$;
revoke all on function my_telegram_info() from public, anon;
grant execute on function my_telegram_info() to authenticated;
