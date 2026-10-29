-- ============================================================
-- Boltpay — 0076: cron jobs read the cron secret from Vault at run time
-- ============================================================
-- 0048 (health), 0068 (lnd-watcher) and the reconcile schedule baked the
-- value of Vault boltpay_cron_secret into cron.job.command when they were
-- scheduled. That copies the secret into a readable table and means a
-- rotation silently breaks the jobs. Reschedule all three to look the
-- secret up from vault.decrypted_secrets on every run, like
-- daily-report-trigger. Schedules, URLs, timeouts and gates are unchanged.
--
-- Skips with a NOTICE (never fails) if pg_cron / pg_net / Vault are missing.
-- Rollback: re-run 0048 / 0068 / the reconcile schedule.
-- ============================================================

do $$
declare
  v_url text;
  v_hdr constant text := $h$jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                            where name = 'boltpay_cron_secret')
        )$h$;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron / pg_net not installed — skipping.';
    return;
  end if;

  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'boltpay_functions_url';
  if v_url is null then
    raise notice 'Vault secret boltpay_functions_url is missing — skipping.';
    return;
  end if;

  perform cron.unschedule('boltpay-health')
  where exists (select 1 from cron.job where jobname = 'boltpay-health');
  perform cron.schedule('boltpay-health', '*/15 * * * *', format($job$
      select net.http_post(
        url     := %L,
        headers := %s,
        timeout_milliseconds := 30000
      );
      $job$, v_url || '/functions/v1/health', v_hdr));

  perform cron.unschedule('boltpay-reconcile')
  where exists (select 1 from cron.job where jobname = 'boltpay-reconcile');
  perform cron.schedule('boltpay-reconcile', '10 4 * * *', format($job$
      select net.http_post(
        url     := %L,
        headers := %s,
        timeout_milliseconds := 120000
      );
      $job$, v_url || '/functions/v1/reconcile?days=1', v_hdr));

  perform cron.unschedule('boltpay-lnd-watcher')
  where exists (select 1 from cron.job where jobname = 'boltpay-lnd-watcher');
  perform cron.schedule('boltpay-lnd-watcher', '* * * * *', format($job$
      select net.http_post(
        url     := %L,
        headers := %s,
        timeout_milliseconds := 55000
      )
      where exists (select 1 from app_settings
                    where key = 'lnd_checkout_enabled' and value = 'true'::jsonb)
         or exists (select 1 from payments
                    where backend = 'lnd' and status in ('new', 'pending'));
      $job$, v_url || '/functions/v1/lnd-watcher', v_hdr));

  raise notice 'Rescheduled health, reconcile, lnd-watcher to read boltpay_cron_secret from Vault.';
end $$;
