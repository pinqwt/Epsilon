-- Applied as: erp_views_security_invoker (2026-10-29)
--
-- RLS is the whole security boundary here: the browser holds only the
-- publishable key, which is public in CONFIG. A view without security_invoker
-- reads its base tables with the view OWNER's rights, so it bypasses RLS
-- completely -- the policies on the table underneath never run.
--
-- The six original billing views (deal_list, deal_summary, deal_settlement,
-- account_entries, party_account, stock_levels) all set this. The four views
-- added by the ERP work did not. Measured as the anon role, holding nothing
-- but the publishable key and no login at all:
--
--   order_progress   19 rows returned   <- live leak of every purchase line
--   general_ledger    0 rows returned   <- only because no journal has posted
--   stock_on_hand     0 rows returned   <- only because no receipt exists
--   activity_log      0 rows returned   <- only because the trail is empty
--   deal_list           refused         <- what the others should have done
--
-- Three of the four read empty today, so the leak was invisible; the general
-- ledger would have gone public the moment the first journal posted.
alter view public.activity_log    set (security_invoker = true);
alter view public.general_ledger  set (security_invoker = true);
alter view public.order_progress  set (security_invoker = true);
alter view public.stock_on_hand   set (security_invoker = true);
