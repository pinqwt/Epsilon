-- Applied as three migrations (2026-10-29):
--   erp_phase2_receipts_only_drafts_editable
--   erp_phase2_receipt_lines_only_drafts_editable
--   erp_phase2_landed_costs_only_drafts_editable
--
-- A posted document must not be editable or deletable from the browser.
--
-- The phase 2 tables each carried a single `for all using (can_edit())` policy,
-- so anyone with edit rights could DELETE a POSTED goods receipt straight from
-- the client. The row and its lines would go, but its stock_moves (a loose
-- source_table/source_id reference, not a foreign key), its blended item_costs
-- average and its posted journal would all stay behind -- stock and the ledger
-- claiming goods with no document under them, and cancel_goods_receipt() left
-- unable to ever undo it.
--
-- This is the rule the journals already enforce: once posted, a document only
-- moves on through the functions. Those are security definer, so they still
-- perform every legitimate transition (post, cancel, reverse). What is
-- withdrawn here is only the client's ability to go around them.
--
-- Note that an UPDATE whose row fails the `using` clause affects zero rows
-- rather than raising, so a posted receipt simply does not respond to an edit.

-- ---------------------------- goods receipts ----------------------------
drop policy if exists goods_receipts_write on public.goods_receipts;

create policy goods_receipts_insert on public.goods_receipts
  for insert to authenticated
  with check (private.can_edit() and status = 'draft');

create policy goods_receipts_update on public.goods_receipts
  for update to authenticated
  using (private.can_edit() and status = 'draft')
  with check (private.can_edit() and status = 'draft');

create policy goods_receipts_delete on public.goods_receipts
  for delete to authenticated
  using (private.can_edit() and status = 'draft');

-- ------------------------- goods receipt lines --------------------------
drop policy if exists goods_receipt_lines_write on public.goods_receipt_lines;

create policy goods_receipt_lines_write on public.goods_receipt_lines
  for all to authenticated
  using (
    private.can_edit() and exists (
      select 1 from public.goods_receipts r
       where r.id = goods_receipt_lines.receipt_id and r.status = 'draft')
  )
  with check (
    private.can_edit() and exists (
      select 1 from public.goods_receipts r
       where r.id = goods_receipt_lines.receipt_id and r.status = 'draft')
  );

-- ----------------------------- landed costs -----------------------------
drop policy if exists landed_costs_write on public.landed_costs;

create policy landed_costs_insert on public.landed_costs
  for insert to authenticated
  with check (private.can_edit() and status = 'draft');

create policy landed_costs_update on public.landed_costs
  for update to authenticated
  using (private.can_edit() and status = 'draft')
  with check (private.can_edit() and status = 'draft');

create policy landed_costs_delete on public.landed_costs
  for delete to authenticated
  using (private.can_edit() and status = 'draft');

drop policy if exists landed_cost_lines_write on public.landed_cost_lines;

create policy landed_cost_lines_write on public.landed_cost_lines
  for all to authenticated
  using (
    private.can_edit() and exists (
      select 1 from public.landed_costs c
       where c.id = landed_cost_lines.landed_cost_id and c.status = 'draft')
  )
  with check (
    private.can_edit() and exists (
      select 1 from public.landed_costs c
       where c.id = landed_cost_lines.landed_cost_id and c.status = 'draft')
  );
