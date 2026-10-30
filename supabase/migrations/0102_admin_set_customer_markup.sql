-- 0102: owner pt304u. Admin can change the global customer markup %
-- (lnd_customer_markup_percent, 0100) from the Settings tab.
--   * admins only (is_admin()), range 0-50, two decimals
--   * every change is written to the audit log (old -> new)
--   * lnd-create-invoice reads the key on each request, so the new % applies
--     to the next invoice; existing invoices keep their charged amount.
-- Rollback: drop function admin_set_customer_markup(numeric);
create or replace function admin_set_customer_markup(p_percent numeric)
returns numeric language plpgsql security definer set search_path = public
as $$
declare v_old jsonb; v_new numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent is null or p_percent < 0 or p_percent > 50 then
    raise exception 'Fee must be between 0 and 50 percent';
  end if;
  v_new := round(p_percent, 2);
  select value into v_old from app_settings where key = 'lnd_customer_markup_percent';
  insert into app_settings(key, value) values ('lnd_customer_markup_percent', to_jsonb(v_new))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  perform record_audit('customer_markup', 'app_settings', 'lnd_customer_markup_percent',
    v_old, to_jsonb(v_new), null);
  return v_new;
end $$;
revoke all on function admin_set_customer_markup(numeric) from public, anon;
grant execute on function admin_set_customer_markup(numeric) to authenticated;
