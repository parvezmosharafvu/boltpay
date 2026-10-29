-- ============================================================
-- Boltpay — 0068: Schedule the LND checkout watcher
-- ============================================================
-- Every minute, POST lnd-watcher (x-cron-secret) — but ONLY when there is
-- something to watch: the checkout flag is on, or an LND invoice is still
-- open from before it was switched off. With the flag off (the default
-- from 0067) and no open LND rows the job is a no-op SELECT and makes no
-- HTTP call, so scheduling it changes nothing today.
--
-- Same Vault secrets and unschedule-first pattern as 0045. Skips with a
-- NOTICE (never fails) if pg_cron / pg_net / Vault secrets are missing.
--
-- Rollback:
--   select cron.unschedule('boltpay-lnd-watcher')
--   where exists (select 1 from cron.job where jobname = 'boltpay-lnd-watcher');
-- ============================================================

do $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — skipping lnd-watcher schedule.';
    return;
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not installed — skipping lnd-watcher schedule.';
    return;
  end if;

  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'boltpay_functions_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'boltpay_cron_secret';

  if v_url is null or v_secret is null then
    raise notice 'Vault secrets boltpay_functions_url / boltpay_cron_secret are missing — skipping schedule.';
    return;
  end if;

  perform cron.unschedule('boltpay-lnd-watcher')
  where exists (select 1 from cron.job where jobname = 'boltpay-lnd-watcher');

  perform cron.schedule(
    'boltpay-lnd-watcher',
    '* * * * *',
    format(
      $job$
      select net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', %L
        ),
        timeout_milliseconds := 55000
      )
      where exists (select 1 from app_settings
                    where key = 'lnd_checkout_enabled' and value = 'true'::jsonb)
         or exists (select 1 from payments
                    where backend = 'lnd' and status in ('new', 'pending'));
      $job$,
      v_url || '/functions/v1/lnd-watcher',
      v_secret
    )
  );

  raise notice 'Scheduled boltpay-lnd-watcher every minute (gated on flag / open LND invoices).';
end $$;
