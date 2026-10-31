-- 0111: audit admin changes to checkout limits (additive).
-- Conversion fee, fee mode and markup range already write audit_log from
-- their SECURITY DEFINER RPCs. Checkout limits are saved by a direct
-- app_settings upsert, so they left no trace. This trigger records old/new
-- for those keys through the existing record_audit(). No values, policies
-- or calculations change.
create or replace function audit_checkout_limit_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and old.value is not distinct from new.value then
    return new;
  end if;
  perform record_audit('checkout_limit', 'app_settings', new.key,
    case when tg_op = 'UPDATE' then old.value else null end, new.value, null);
  return new;
end $$;
revoke all on function audit_checkout_limit_change() from public, anon, authenticated;

drop trigger if exists trg_audit_checkout_limits on app_settings;
create trigger trg_audit_checkout_limits
  after insert or update on app_settings
  for each row
  when (new.key in ('lnd_invoice_expiry_sec', 'lnd_pay_min_usd', 'lnd_pay_max_usd'))
  execute function audit_checkout_limit_change();
