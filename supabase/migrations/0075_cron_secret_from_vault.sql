-- 0075: let Edge Functions read the pg_cron secret from Vault.
--
-- pg_cron sends x-cron-secret = Vault 'boltpay_cron_secret' (0045/0068).
-- Edge Function secrets cannot be set on this project, so lnd-watcher and
-- reconcile (_shared/cron.ts) also accept the Vault value, read through
-- this SECURITY DEFINER RPC, executable by service_role only.
-- Revert: drop function if exists public.system_cron_secret();

create or replace function public.system_cron_secret()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return (select s.decrypted_secret from vault.decrypted_secrets s
          where s.name = 'boltpay_cron_secret' limit 1);
end;
$$;

revoke all on function public.system_cron_secret() from public, anon, authenticated;
grant execute on function public.system_cron_secret() to service_role;
