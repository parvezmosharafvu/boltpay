-- ============================================================
-- Boltpay — 0067: LND checkout backend (schema + flags, all OFF)
-- ============================================================
-- Adds what a second invoice backend (the merchant's own LND node,
-- invoices with no route hints) needs, without changing anything the
-- existing BTCPay flow reads or writes:
--
--   * payments.backend            'btcpay' (default, every existing row)
--                                 or 'lnd'
--   * payments.lnd_r_hash         hex payment hash, unique, the LND key
--   * payments.bolt11 / amount_sats / btc_usd_rate / customer_name /
--     device_id / paid_at          LND-only details
--   * payment_links.checkout_backend  per-link switch, default 'btcpay'
--   * payment_events               page analytics (view, pay-click, ...)
--   * app_settings flags           lnd_checkout_enabled = false,
--                                  lnd_onchain_fallback = false,
--                                  lnd_pay_min_usd 10, lnd_pay_max_usd 1000,
--                                  lnd_invoice_expiry_sec 3600
--   * system_settle_lnd_payment()  idempotent settle, service_role only
--   * system_expire_lnd_payment()  new -> expired, service_role only
--
-- The LND path is used only when lnd_checkout_enabled is true AND the
-- link's checkout_backend is 'lnd'. With the defaults below nothing
-- changes for any existing link or payment.
--
-- Rollback (nothing else depends on these until the flag is turned on):
--   see the block at the end of this file.
-- ============================================================

-- ---------- payments ----------
alter table payments add column if not exists backend text not null default 'btcpay';
alter table payments drop constraint if exists payments_backend_check;
alter table payments add constraint payments_backend_check check (backend in ('btcpay','lnd'));

alter table payments add column if not exists lnd_r_hash    text;
alter table payments add column if not exists bolt11        text;
alter table payments add column if not exists btc_address   text;
alter table payments add column if not exists amount_sats   bigint;
alter table payments add column if not exists btc_usd_rate  numeric(18,2);
alter table payments add column if not exists customer_name text;
alter table payments add column if not exists device_id     text;
alter table payments add column if not exists paid_at       timestamptz;

alter table payments drop constraint if exists payments_lnd_r_hash_format;
alter table payments add constraint payments_lnd_r_hash_format
  check (lnd_r_hash is null or lnd_r_hash ~ '^[0-9a-f]{64}$');

-- An LND row must carry its hash and sats; a BTCPay row must not claim
-- an LND hash. Keeps the two backends from ever being confused.
alter table payments drop constraint if exists payments_backend_fields;
alter table payments add constraint payments_backend_fields check (
  (backend = 'btcpay' and lnd_r_hash is null)
  or (backend = 'lnd' and lnd_r_hash is not null and amount_sats is not null and amount_sats > 0)
);

alter table payments drop constraint if exists payments_customer_name_len;
alter table payments add constraint payments_customer_name_len
  check (customer_name is null or length(customer_name) <= 64);
alter table payments drop constraint if exists payments_device_id_len;
alter table payments add constraint payments_device_id_len
  check (device_id is null or length(device_id) <= 64);

create unique index if not exists idx_payments_lnd_r_hash on payments(lnd_r_hash) where lnd_r_hash is not null;
-- The watcher scans open LND invoices; keep that cheap.
create index if not exists idx_payments_lnd_open on payments(expires_at)
  where backend = 'lnd' and status in ('new','pending');

-- ---------- payment_links ----------
alter table payment_links add column if not exists checkout_backend text not null default 'btcpay';
alter table payment_links drop constraint if exists payment_links_checkout_backend_check;
alter table payment_links add constraint payment_links_checkout_backend_check
  check (checkout_backend in ('btcpay','lnd'));

-- ---------- payment_events ----------
create table if not exists payment_events (
  id          bigint generated always as identity primary key,
  payment_id  uuid not null references payments(id) on delete cascade,
  event       text not null check (event in ('view','pay-click','paid-observed','btc-fallback')),
  device_id   text check (device_id is null or length(device_id) <= 64),
  ua          text check (ua is null or length(ua) <= 256),
  created_at  timestamptz not null default now()
);
create index if not exists idx_payment_events_payment on payment_events(payment_id);

-- Written only by edge functions with the service role. No client role
-- reads or writes it directly.
alter table payment_events enable row level security;
revoke all on table payment_events from public, anon, authenticated;
grant all on table payment_events to service_role;

-- ---------- flags (all OFF / conservative) ----------
insert into app_settings (key, value) values
  ('lnd_checkout_enabled',   'false'::jsonb),
  ('lnd_onchain_fallback',   'false'::jsonb),
  ('lnd_pay_min_usd',        '10'::jsonb),
  ('lnd_pay_max_usd',        '1000'::jsonb),
  ('lnd_invoice_expiry_sec', '3600'::jsonb)
on conflict (key) do nothing;

-- ---------- link lookup for the LND path ----------
-- Separate from system_link_for_invoice so the BTCPay path's function
-- (and its grants) stays exactly as it is.
create or replace function system_lnd_link_for_invoice(p_slug text)
returns table (
  link_id uuid,
  user_id uuid,
  slug text,
  display_name text,
  is_active boolean,
  checkout_backend text,
  cost_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         pl.checkout_backend,
         coalesce(pl.cost_percent, pr.cost_percent, 0)
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;
revoke all on function system_lnd_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_lnd_link_for_invoice(text) to service_role;

-- ---------- settle ----------
-- Called by payment-status and lnd-watcher once LND reports SETTLED.
-- Idempotent: only new/pending LND rows move to settled, under a row
-- lock; a second call returns false and changes nothing. LND never
-- settles an underpaid invoice, but the paid amount is still checked.
-- amount_settled is the USD amount fixed when the invoice was created,
-- so balance, fee and withdrawal maths are identical to BTCPay rows.
create or replace function system_settle_lnd_payment(p_r_hash text, p_amt_paid_msat bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay payments;
begin
  select * into v_pay from payments
   where lnd_r_hash = lower(p_r_hash) and backend = 'lnd'
   for update;
  if not found then
    return false;
  end if;
  if v_pay.status not in ('new','pending') then
    return false;
  end if;
  if p_amt_paid_msat is null or p_amt_paid_msat < v_pay.amount_sats * 1000 then
    raise exception 'LND payment % underpaid: % msat < % sat', v_pay.id, p_amt_paid_msat, v_pay.amount_sats;
  end if;
  update payments
     set status = 'settled',
         amount_settled = amount_requested,
         settled_at = now(),
         paid_at = now()
   where id = v_pay.id;
  return true;
end;
$$;
revoke all on function system_settle_lnd_payment(text, bigint) from public, anon, authenticated;
grant execute on function system_settle_lnd_payment(text, bigint) to service_role;

-- ---------- expire ----------
create or replace function system_expire_lnd_payment(p_r_hash text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update payments set status = 'expired'
   where lnd_r_hash = lower(p_r_hash) and backend = 'lnd' and status = 'new';
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
revoke all on function system_expire_lnd_payment(text) from public, anon, authenticated;
grant execute on function system_expire_lnd_payment(text) to service_role;

-- ============================================================
-- Rollback (only while no row has backend = 'lnd'):
--   drop function if exists system_expire_lnd_payment(text);
--   drop function if exists system_settle_lnd_payment(text, bigint);
--   drop function if exists system_lnd_link_for_invoice(text);
--   drop table if exists payment_events;
--   delete from app_settings where key in ('lnd_checkout_enabled',
--     'lnd_onchain_fallback','lnd_pay_min_usd','lnd_pay_max_usd',
--     'lnd_invoice_expiry_sec');
--   alter table payment_links drop column if exists checkout_backend;
--   drop index if exists idx_payments_lnd_open;
--   drop index if exists idx_payments_lnd_r_hash;
--   alter table payments drop constraint if exists payments_backend_fields,
--     drop constraint if exists payments_lnd_r_hash_format,
--     drop constraint if exists payments_customer_name_len,
--     drop constraint if exists payments_device_id_len,
--     drop column if exists backend, drop column if exists lnd_r_hash,
--     drop column if exists bolt11, drop column if exists btc_address,
--     drop column if exists amount_sats, drop column if exists btc_usd_rate,
--     drop column if exists customer_name, drop column if exists device_id,
--     drop column if exists paid_at;
-- ============================================================
