-- Audit fix: two internal functions were callable by anyone via /rest/v1/rpc.
--  * prune_webhook_events(): a maintenance job (pg_cron runs it as postgres).
--    Its 0033 revoke was lost when the function was recreated later.
--  * link_cost_for_slug(text): exposed the internal cost % of any link.
--    Nothing in the pages, edge functions or SQL calls it any more.
-- service_role and postgres keep access.
revoke execute on function public.prune_webhook_events() from public, anon, authenticated;
revoke execute on function public.link_cost_for_slug(text) from public, anon, authenticated;
