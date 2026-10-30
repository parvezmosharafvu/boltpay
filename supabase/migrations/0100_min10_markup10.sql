-- 0100: owner decision pt297u.
--   * checkout minimum is $10 entered (code also floors it at 10; per-link
--     mins above 10 still apply, lower ones are lifted to 10)
--   * one global customer markup: +10% ($10 -> $11.00). lnd-create-invoice
--     now reads lnd_customer_markup_percent instead of the per-link
--     cost_percent. Creator earnings logic (0082) is unchanged.
-- Rollback: update app_settings set value='1'::jsonb where key='lnd_pay_min_usd';
--           delete from app_settings where key='lnd_customer_markup_percent';
insert into app_settings(key, value) values ('lnd_pay_min_usd', '10'::jsonb)
on conflict (key) do update set value = '10'::jsonb, updated_at = now();
insert into app_settings(key, value) values ('lnd_customer_markup_percent', '10'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();
