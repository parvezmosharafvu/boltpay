// Rename this file to config.js and fill in your real project values.
// The anon key is safe to expose in the browser — it's designed to be
// public. Real protection lives in RLS policies and SECURITY DEFINER
// functions in supabase/migrations/. Never put the service role key
// or any BTCPay secret in this file.

window.SUPABASE_URL = 'SUPABASE_URL;
const SUPABASE_ANON_KEY = 'SUPABASE_ANON_KEY;

window.supabaseClient = window.supabase.createClient(window.SUPABASE_URL, SUPABASE_ANON_KEY);
