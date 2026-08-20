select cron.schedule(
  'ledger-backup-trigger',
  '5 11 * * *',  -- daily-report এর ৫ মিনিট পরে চলবে, যাতে সেদিনের stats আগে বসে যায়
  $$
  select net.http_post(
    url := 'https://ohwzmxwsphsfzudmlins.supabase.co/functions/v1/ledger-backup',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', 'parvezmosharafvu'
    )
  );
  $$
);
