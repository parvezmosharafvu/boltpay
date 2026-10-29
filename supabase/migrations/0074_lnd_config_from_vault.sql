-- 0074: LND connection settings from Supabase Vault.
--
-- Edge Function secrets could not be set on this project, so _shared/lnd.ts
-- falls back to two Vault secrets when LND_REST_URL / LND_INVOICE_MACAROON
-- env vars are missing:
--   lnd_rest_url          https base URL of the LND REST endpoint
--   lnd_invoice_macaroon  hex invoice-only macaroon
-- This migration creates only the reader; the secrets are added separately
-- (vault.create_secret) and never live in the repo.
--
-- system_lnd_config is SECURITY DEFINER and executable by service_role only.
-- Revert: drop function if exists public.system_lnd_config();

create or replace function public.system_lnd_config()
returns table (rest_url text, macaroon text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return query select
    (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'lnd_rest_url' limit 1),
    (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'lnd_invoice_macaroon' limit 1);
end;
$$;

revoke all on function public.system_lnd_config() from public, anon, authenticated;
grant execute on function public.system_lnd_config() to service_role;
