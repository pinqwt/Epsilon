-- ERP phase 2, the rest of it - part 2 of 2 (2026-11-05).
--
-- Applied as (all 2026-11-07):
--   erp_phase2_supplier_invoice_tables      (part 0 + part 1 tables and RLS)
--   erp_phase2_supplier_invoice_matching    (part 1 functions)
--   erp_phase2_supplier_returns             (part 2)
--   erp_phase2_advance_application          (part 3 + part 4)
--   erp_phase2_payables_read_matched_bills  (parts 5-7)
--
-- Part 1 of 2 is erp_phase2_po_states_and_shipments.sql, which this needs for
-- the SRN / ADV document prefixes.
--
-- THE HOLE THIS CLOSES. `post_goods_receipt` credits 2110 (receipt accrual) and
-- nothing ever cleared it, because there was no supplier bill. So:
--   * 2110 grew without limit and the trial balance carried a liability that
--     would never be settled;
--   * `supplier_open_items` could not read a payable, so it read the purchase
--     ORDER instead and flagged `bill_source = 'order'` as the warning;
--   * a supplier payment could not be allocated to anything, so
--     `preview_payment` / `post_payment` refused allocation outright and posted
--     every supplier payment as an advance on 1400.
-- All three are fixed here. The `bill_source` column stays, because an order
-- with no bill against it yet still has to appear on Payables - it just now
-- reads 'invoice' for the rows that have a matched bill behind them.
--
-- WHY A BILL NEVER ADDS STOCK AGAIN. Spec page 20: "Use the appropriate receipt
-- / transit accounting path so matching the invoice does not add stock a second
-- time." The goods already came in at the receipt, debiting 1300 and crediting
-- 2110. The bill therefore clears 2110 and credits 2100; it moves no goods and
-- touches no quantity. The only way a bill changes the cost of stock is when it
-- DISAGREES with the accrual, and that difference is a price variance, which
-- spec page 9 requires to have its own approved template.

-- ====================== PART 0: THE THREE TEMPLATES ===================
-- Spec page 9: "Tax, returns, shortages and price differences need separate
-- approved templates." These are those, in the same reviewable table as the
-- other fifteen, because an accountant validates the event-to-account mapping
-- with `select * from posting_templates` before real posting begins.

insert into public.posting_templates (event, label, path, debit_code, credit_code, note) values
  ('invoice_price_difference', 'Supplier invoice above the receipt accrual', 'accrual',
   '1300', '2100',
   'The bill came in higher than the goods were accrued at. The excess is part of what the stock cost, so it is added to inventory and blended into the weighted average on the units still held.'),
  ('invoice_price_credit',     'Supplier invoice below the receipt accrual', 'accrual',
   '2110', '1300',
   'A final bill lower than the accrual: the residual accrual is cleared against stock cost, because the goods turned out to cost less than they were received at.'),
  ('supplier_return',          'Return goods to the supplier',              'common',
   '2100', '1300',
   'Goods go back: stock leaves at the cost it arrived at and the payable drops by the same value. A cash refund is a separate bank transaction.')
on conflict (event) do nothing;

-- ===================== PART 1: THE SUPPLIER INVOICE ==================

create table if not exists public.supplier_invoices (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  -- One bill matches one purchase order, the mirror of a payment being scoped
  -- to one order. A supplier billing two orders on one sheet is two PINs; that
  -- keeps the accrual arithmetic answerable per order instead of pooling it.
  deal_id       uuid not null references public.deals(id),
  party_id      uuid references public.parties(id),
  doc_no        text,
  -- Spec page 20 shows both numbers: ours (PIN-2026-000001) and theirs.
  supplier_ref  text not null default '',
  invoice_date  date not null default current_date,
  due_date      date,
  currency      text not null default 'KWD',
  fx_rate       numeric check (fx_rate is null or fx_rate > 0),
  tax_amount    numeric not null default 0 check (tax_amount >= 0),
  -- A final bill closes the accrual: any residual is written back against stock
  -- cost rather than left standing for a receipt that will never be billed.
  is_final      boolean not null default false,
  status        text not null default 'draft'
                  check (status in ('draft','posted','cancelled')),
  note          text not null default '',
  file_path     text,
  file_name     text,
  file_size     bigint,
  -- Filled at posting, so the split is on the record and not re-derived later.
  base_value      numeric,
  accrual_cleared numeric,
  cost_difference numeric,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id),
  posted_at     timestamptz,
  posted_by     uuid references auth.users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid references auth.users(id),
  cancel_reason text not null default ''
);

create index if not exists pin_deal_idx  on public.supplier_invoices (deal_id);
create index if not exists pin_party_idx on public.supplier_invoices (party_id);
create unique index if not exists pin_doc_no_uniq
  on public.supplier_invoices (company_id, doc_no) where doc_no is not null;

-- One supplier cannot send the same invoice number twice.
create unique index if not exists pin_supplier_ref_uniq
  on public.supplier_invoices (party_id, lower(btrim(supplier_ref)))
  where party_id is not null and btrim(supplier_ref) <> '' and status <> 'cancelled';

create table if not exists public.supplier_invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.supplier_invoices(id) on delete cascade,
  -- Required: a bill line that matches no order line has nothing to compare
  -- against, and a freight or clearance charge is a landed-cost sheet, not a
  -- line on the goods bill (spec page 21 keeps those apart).
  deal_item_id uuid not null references public.deal_items(id),
  item_id      uuid references public.items(id),
  qty          numeric not null check (qty > 0),
  unit_price   numeric not null check (unit_price >= 0),
  discount     numeric not null default 0 check (discount >= 0),
  note         text not null default ''
);

create index if not exists pin_lines_invoice_idx on public.supplier_invoice_lines (invoice_id);

-- ---------------- how much receipt accrual is still open --------------
--
-- Read from the LEDGER, not recomputed from documents, for two reasons: the
-- receipt's `unit_cost` is rewritten by post_landed_cost (so recomputing would
-- fold freight into the accrual, which landed cost credits to 2100, not 2110),
-- and the ledger is the thing the bill actually has to clear.
--
-- `status in ('posted','reversed')` is deliberate and is the mistake this
-- schema keeps re-making. A reversed journal stays in the ledger; its mirror,
-- which carries the same source but event '<event>_reversal', is what cancels
-- it. Filtering to 'posted' alone drops the original and leaves the mirror
-- standing, so a cancelled goods receipt would report NEGATIVE open accrual and
-- a bill against it would post as a price difference straight into stock.

create or replace function private.accrual_open(p_deal uuid)
returns numeric language sql stable security definer set search_path to '' as $fn$
  select coalesce(sum(l.credit - l.debit), 0)
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
   where l.account_code = '2110'
     and j.status in ('posted', 'reversed')
     and ( (j.source_table = 'goods_receipts'
            and j.source_id in (select g.id from public.goods_receipts g
                                 where g.deal_id = p_deal))
        or (j.source_table = 'supplier_invoices'
            and j.source_id in (select si.id from public.supplier_invoices si
                                 where si.deal_id = p_deal)) )
$fn$;


alter table public.supplier_invoices      enable row level security;
alter table public.supplier_invoice_lines enable row level security;

drop policy if exists supplier_invoices_read on public.supplier_invoices;
create policy supplier_invoices_read on public.supplier_invoices
  for select to authenticated using (true);

drop policy if exists supplier_invoice_lines_read on public.supplier_invoice_lines;
create policy supplier_invoice_lines_read on public.supplier_invoice_lines
  for select to authenticated using (true);

-- Only a draft is writable from the client. A posted bill moves on through
-- post_supplier_invoice / cancel_supplier_invoice, which are security definer.
drop policy if exists supplier_invoices_insert on public.supplier_invoices;
create policy supplier_invoices_insert on public.supplier_invoices
  for insert to authenticated
  with check (private.can_edit() and status = 'draft');

drop policy if exists supplier_invoices_update on public.supplier_invoices;
create policy supplier_invoices_update on public.supplier_invoices
  for update to authenticated
  using (private.can_edit() and status = 'draft')
  with check (private.can_edit() and status = 'draft');

drop policy if exists supplier_invoices_delete on public.supplier_invoices;
create policy supplier_invoices_delete on public.supplier_invoices
  for delete to authenticated
  using (private.can_edit() and status = 'draft');

drop policy if exists supplier_invoice_lines_write on public.supplier_invoice_lines;
create policy supplier_invoice_lines_write on public.supplier_invoice_lines
  for all to authenticated
  using (
    private.can_edit() and exists (
      select 1 from public.supplier_invoices si
       where si.id = supplier_invoice_lines.invoice_id and si.status = 'draft')
  )
  with check (
    private.can_edit() and exists (
      select 1 from public.supplier_invoices si
       where si.id = supplier_invoice_lines.invoice_id and si.status = 'draft')
  );

-- ------------------------- the match itself ---------------------------
-- Spec page 5 step 4: "Match supplier invoice to PO and goods receipt; check
-- quantity / price differences." This is that check, as a readable table rather
-- than a pass/fail, because the differences are the point: a short shipment and
-- an overcharge both show up here and both need a human decision.

create or replace function public.match_supplier_invoice(p_invoice uuid)
returns table (
  deal_item_id        uuid,
  item_label          text,
  description         text,
  qty_ordered         numeric,
  qty_received        numeric,
  qty_accepted        numeric,
  qty_invoiced_before numeric,
  qty_on_invoice      numeric,
  price_ordered       numeric,
  price_invoiced      numeric,
  line_amount         numeric,
  qty_variance        numeric,
  price_variance      numeric,
  verdict             text
) language sql stable security definer set search_path to '' as $fn$
  select l.deal_item_id,
         coalesce(nullif(btrim(di.model), ''), di.description),
         di.description,
         di.qty,
         di.qty_received,
         di.qty_accepted,
         di.qty_invoiced,
         l.qty,
         di.unit_price,
         l.unit_price,
         round(l.qty * l.unit_price - l.discount, 6),
         l.qty - di.qty_accepted,
         l.unit_price - di.unit_price,
         case
           when di.qty_accepted = 0          then 'nothing accepted yet'
           when l.qty > di.qty_accepted       then 'billed for more than was accepted'
           when l.qty < di.qty_accepted       then 'billed for less than was accepted'
           when l.unit_price > di.unit_price  then 'price above the order'
           when l.unit_price < di.unit_price  then 'price below the order'
           else 'matches'
         end
    from public.supplier_invoice_lines l
    join public.deal_items di on di.id = l.deal_item_id
   where l.invoice_id = p_invoice
   order by di.position, di.id
$fn$;

-- One place for a bill's arithmetic, read by both preview and post, the same
-- reason private.payment_plan exists: a previewed journal and a posted one
-- cannot drift. STABLE, and it issues no document number.
create or replace function private.invoice_plan(p_invoice uuid)
returns table (
  company_id    uuid,
  party_id      uuid,
  deal_id       uuid,
  base_currency text,
  cur_decimals  int,
  currency      text,
  rate          numeric,
  entry_date    date,
  gross_foreign numeric,
  base_value    numeric,
  accrual_open  numeric,
  clear_base    numeric,
  diff_base     numeric,
  credit_base   numeric
) language plpgsql stable security definer set search_path to '' as $fn$
declare
  inv   public.supplier_invoices;
  d     public.deals;
  base  text;
  dec   int;
  rt    numeric;
  net   numeric;
  gross numeric;
  val   numeric;
  opn   numeric;
  clr   numeric;
  dif   numeric;
  crd   numeric := 0;
begin
  select * into inv from public.supplier_invoices where id = p_invoice;
  if inv.id is null then
    raise exception 'That supplier invoice does not exist.';
  end if;

  select * into d from public.deals where id = inv.deal_id;
  if d.id is null or d.deleted_at is not null then
    raise exception 'The order this bill belongs to is gone.';
  end if;
  if d.direction <> 'sending' then
    raise exception 'A supplier invoice belongs to a purchase order, not a sale.';
  end if;

  select c.base_currency into base from public.companies c where c.id = inv.company_id;
  if base is null then
    raise exception 'Unknown company.';
  end if;
  dec := public.currency_decimals(base);

  select coalesce(sum(round(l.qty * l.unit_price - l.discount, 6)), 0) into net
    from public.supplier_invoice_lines l where l.invoice_id = p_invoice;
  if net <= 0 then
    raise exception 'This bill has no priced lines, so there is nothing to owe.';
  end if;

  gross := net + coalesce(inv.tax_amount, 0);
  rt    := coalesce(inv.fx_rate,
                    case when upper(inv.currency) = base then 1
                         else public.fx_rate_for(upper(inv.currency), inv.invoice_date, base) end);
  val   := public.to_base(gross, rt, base);

  opn := private.accrual_open(inv.deal_id);
  clr := least(val, greatest(opn, 0));
  dif := round(val - clr, dec);

  -- A final bill closes what is left of the accrual against stock cost.
  if inv.is_final and opn > clr then
    crd := round(opn - clr, dec);
  end if;

  return query select
    inv.company_id, coalesce(inv.party_id, d.party_id), inv.deal_id,
    base, dec, upper(inv.currency), rt, inv.invoice_date,
    gross, val, opn, round(clr, dec), dif, crd;
end;
$fn$;

create or replace function public.preview_supplier_invoice(p_invoice uuid)
returns table (account_code text, account_name text, debit numeric, credit numeric, memo text)
language plpgsql stable security definer set search_path to '' as $fn$
declare
  pl record;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to preview a supplier invoice.';
  end if;

  select * into pl from private.invoice_plan(p_invoice);

  if pl.clear_base > 0 then
    return query
      select '2110'::text, a.name, pl.clear_base, 0::numeric, 'Receipt accrual cleared'::text
        from public.accounts a where a.code = '2110';
  end if;
  if pl.diff_base > 0 then
    return query
      select '1300'::text, a.name, pl.diff_base, 0::numeric,
             'Billed above the accrual: added to stock cost'::text
        from public.accounts a where a.code = '1300';
  end if;
  if pl.clear_base + pl.diff_base > 0 then
    return query
      select '2100'::text, a.name, 0::numeric, pl.clear_base + pl.diff_base,
             'Supplier payable'::text
        from public.accounts a where a.code = '2100';
  end if;
  if pl.credit_base > 0 then
    return query
      select '2110'::text, a.name, pl.credit_base, 0::numeric,
             'Residual accrual closed by the final bill'::text
        from public.accounts a where a.code = '2110'
      union all
      select '1300'::text, a.name, 0::numeric, pl.credit_base,
             'Stock cost reduced: billed below the accrual'::text
        from public.accounts a where a.code = '1300';
  end if;
end;
$fn$;

-- Spreads a cost adjustment over the bill's lines and into the weighted
-- average, the same shape post_landed_cost uses: the charge lands on the units
-- still HELD, because the ones already sold carry the cost they left on and
-- spec page 6 is explicit that an old posted cost is never changed silently.
create or replace function private.blend_invoice_difference(
  p_invoice uuid, p_amount_base numeric, p_total_base numeric)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  d      public.deals;
  dec    int;
  base   text;
  ln     record;
  share  numeric;
  spread numeric := 0;
  lastwh uuid;
  lastit uuid;
  onhand numeric;
begin
  if coalesce(p_amount_base, 0) = 0 or coalesce(p_total_base, 0) = 0 then
    return;
  end if;

  select dl.* into d
    from public.deals dl
    join public.supplier_invoices si on si.deal_id = dl.id
   where si.id = p_invoice;

  select c.base_currency into base from public.companies c where c.id = d.company_id;
  dec := public.currency_decimals(base);

  for ln in
    select l.id,
           coalesce(l.item_id, di.item_id) as use_item,
           coalesce(
             (select g.warehouse_id
                from public.goods_receipt_lines gl
                join public.goods_receipts g on g.id = gl.receipt_id
               where gl.deal_item_id = l.deal_item_id and g.status = 'posted'
               order by g.received_on desc, g.posted_at desc limit 1),
             d.warehouse_id) as use_wh,
           round(l.qty * l.unit_price - l.discount, 6) as line_net
      from public.supplier_invoice_lines l
      join public.deal_items di on di.id = l.deal_item_id
     where l.invoice_id = p_invoice
     order by l.id
  loop
    if ln.use_item is null or ln.use_wh is null then
      continue;
    end if;

    share  := round(p_amount_base * ln.line_net / p_total_base, dec);
    spread := spread + share;
    lastit := ln.use_item;
    lastwh := ln.use_wh;

    select qty_on_hand into onhand
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = ln.use_wh
       for update;

    if coalesce(onhand, 0) > 0 then
      update public.item_costs
         set avg_cost   = greatest(round(avg_cost + share / onhand, 6), 0),
             updated_at = now()
       where item_id = ln.use_item and warehouse_id = ln.use_wh;
    end if;
  end loop;

  -- Rounding crumbs go on the last line so the total lands exactly, as in
  -- post_landed_cost.
  if spread <> p_amount_base and lastit is not null then
    select qty_on_hand into onhand
      from public.item_costs
     where item_id = lastit and warehouse_id = lastwh for update;
    if coalesce(onhand, 0) > 0 then
      update public.item_costs
         set avg_cost   = greatest(round(avg_cost + (p_amount_base - spread) / onhand, 6), 0),
             updated_at = now()
       where item_id = lastit and warehouse_id = lastwh;
    end if;
  end if;
end;
$fn$;

create or replace function public.post_supplier_invoice(p_invoice uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  inv   public.supplier_invoices;
  pl    record;
  docno text;
  jid   uuid;
  jdif  uuid;
  jcrd  uuid;
  ln    record;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post a supplier invoice.';
  end if;

  select * into inv from public.supplier_invoices where id = p_invoice for update;
  if inv.id is null then
    raise exception 'That supplier invoice does not exist.';
  end if;
  if inv.status <> 'draft' then
    raise exception 'This bill is already %. Only a draft can be posted.', inv.status;
  end if;

  -- This company is on the receipt-before-invoice path (spec page 9), so the
  -- bill clears an accrual that a receipt put there. With no posted receipt
  -- there is no accrual, and posting would have to debit stock for goods that
  -- have not arrived - which is the transit path, a different set of templates.
  if not exists (select 1 from public.goods_receipts g
                  where g.deal_id = inv.deal_id and g.status = 'posted') then
    raise exception
      'Post the goods receipt first. This company books a bill against the receipt accrual, so a bill with no receipt behind it would value goods that have not arrived.';
  end if;

  select * into pl from private.invoice_plan(p_invoice);
  perform public.assert_period_open(pl.company_id, pl.entry_date);

  if pl.clear_base <= 0 then
    raise exception
      'Everything received on this order has already been billed. Extra charges on these goods belong on a landed-cost sheet, not on a second supplier invoice.';
  end if;

  docno := public.next_doc_no(pl.company_id, 'supplier_invoice',
                              extract(year from pl.entry_date)::int);

  -- Posted in BASE currency on purpose. The bill's base value has to split
  -- exactly between the accrual it clears and the price difference, and
  -- splitting a foreign amount proportionally would re-round and drift. The
  -- original currency, rate and foreign total stay on the supplier_invoices
  -- row, which is what supplier_open_items and the aging reports read. This is
  -- the same choice post_payment makes for its advance leg.
  jid := public.post_event(
           p_company      => pl.company_id,
           p_event        => 'match_invoice_receipt',
           p_source_table => 'supplier_invoices',
           p_source_id    => p_invoice,
           p_amount       => pl.clear_base,
           p_currency     => pl.base_currency,
           p_entry_date   => pl.entry_date,
           p_rate         => 1,
           p_party        => pl.party_id,
           p_item         => null,
           p_warehouse    => null,
           p_memo         => 'Supplier invoice ' || docno ||
                             case when btrim(inv.supplier_ref) <> ''
                                  then ' (' || btrim(inv.supplier_ref) || ')' else '' end);

  if pl.diff_base > 0 then
    jdif := public.post_event(
              p_company      => pl.company_id,
              p_event        => 'invoice_price_difference',
              p_source_table => 'supplier_invoices',
              p_source_id    => p_invoice,
              p_amount       => pl.diff_base,
              p_currency     => pl.base_currency,
              p_entry_date   => pl.entry_date,
              p_rate         => 1,
              p_party        => pl.party_id,
              p_item         => null,
              p_warehouse    => null,
              p_memo         => 'Billed above the accrual on ' || docno);
    perform private.blend_invoice_difference(p_invoice, pl.diff_base, pl.base_value);
  end if;

  if pl.credit_base > 0 then
    jcrd := public.post_event(
              p_company      => pl.company_id,
              p_event        => 'invoice_price_credit',
              p_source_table => 'supplier_invoices',
              p_source_id    => p_invoice,
              p_amount       => pl.credit_base,
              p_currency     => pl.base_currency,
              p_entry_date   => pl.entry_date,
              p_rate         => 1,
              p_party        => pl.party_id,
              p_item         => null,
              p_warehouse    => null,
              p_memo         => 'Final bill below the accrual on ' || docno);
    perform private.blend_invoice_difference(p_invoice, -pl.credit_base, pl.base_value);
  end if;

  -- The bill moves no goods, so only the invoiced quantity advances.
  for ln in select l.deal_item_id, l.qty from public.supplier_invoice_lines l
             where l.invoice_id = p_invoice loop
    update public.deal_items
       set qty_invoiced = qty_invoiced + ln.qty
     where id = ln.deal_item_id;
  end loop;

  update public.supplier_invoices
     set doc_no          = docno,
         status          = 'posted',
         party_id        = coalesce(party_id, pl.party_id),
         due_date        = coalesce(due_date,
                             pl.entry_date + coalesce(
                               (select p.payment_terms_days from public.parties p
                                 where p.id = pl.party_id), 0)),
         base_value      = pl.base_value,
         accrual_cleared = pl.clear_base,
         cost_difference = pl.diff_base - pl.credit_base,
         posted_at       = now(),
         posted_by       = (select auth.uid())
   where id = p_invoice;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('supplier_invoices', p_invoice, 'posted', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'supplier_ref', inv.supplier_ref,
                             'base_value', pl.base_value,
                             'accrual_cleared', pl.clear_base,
                             'price_difference', pl.diff_base,
                             'accrual_credit', pl.credit_base,
                             'journal', jid, 'difference_journal', jdif,
                             'credit_journal', jcrd));

  return jid;
end;
$fn$;

create or replace function public.cancel_supplier_invoice(p_invoice uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  inv public.supplier_invoices;
  j   record;
  ln  record;
  n   int := 0;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change this.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this bill is being cancelled.';
  end if;

  select * into inv from public.supplier_invoices where id = p_invoice for update;
  if inv.id is null then
    raise exception 'That supplier invoice does not exist.';
  end if;
  if inv.status = 'cancelled' then
    return;
  end if;

  if inv.status = 'draft' then
    delete from public.supplier_invoices where id = p_invoice;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('supplier_invoices', p_invoice, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  if not private.is_owner() then
    raise exception 'This bill is posted. Only the owner can cancel it.';
  end if;

  -- Money already settled against it would be left pointing at nothing.
  if exists (select 1 from public.payment_allocations a
              join public.payments pm on pm.id = a.payment_id
             where a.supplier_invoice_id = p_invoice and pm.status = 'posted') then
    raise exception
      'A posted payment is allocated to this bill. Reverse the payment first, or it would be left settling a bill that no longer exists.';
  end if;
  if exists (select 1 from public.advance_applications aa
              where aa.supplier_invoice_id = p_invoice and aa.status = 'posted') then
    raise exception
      'A posted advance application points at this bill. Cancel that first.';
  end if;

  perform public.assert_period_open(inv.company_id, current_date);

  for j in select id from public.journals
            where source_table = 'supplier_invoices' and source_id = p_invoice
              and status = 'posted'
            order by doc_no loop
    perform public.reverse_journal(j.id, 'Supplier invoice cancelled: ' || btrim(p_reason));
    n := n + 1;
  end loop;

  -- Take the cost blend back out. Like post_landed_cost's own blend, this is
  -- exact only while the stock is still on hand; units already sold carry the
  -- cost they left on, which spec page 6 says must not be rewritten.
  if coalesce(inv.cost_difference, 0) <> 0 then
    perform private.blend_invoice_difference(
              p_invoice, -inv.cost_difference, inv.base_value);
  end if;

  for ln in select l.deal_item_id, l.qty from public.supplier_invoice_lines l
             where l.invoice_id = p_invoice loop
    update public.deal_items
       set qty_invoiced = greatest(qty_invoiced - ln.qty, 0)
     where id = ln.deal_item_id;
  end loop;

  update public.supplier_invoices
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_invoice;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('supplier_invoices', p_invoice, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('journals_reversed', n, 'doc_no', inv.doc_no));
end;
$fn$;

-- ====================== PART 2: RETURN TO SUPPLIER ====================
--
-- Spec page 5: "select original receipt -> return accepted quantity -> reduce
-- stock cost -> obtain supplier credit -> reduce payable or create a supplier
-- credit / refund balance. A refund is a separate bank transaction."
--
-- Goods leave at the cost they ARRIVED at - the receipt line's unit_cost - and
-- the weighted average is unwound the same way cancel_goods_receipt unwinds it,
-- because a return is the same movement: this consignment going back out.

create table if not exists public.supplier_returns (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  deal_id       uuid not null references public.deals(id),
  party_id      uuid references public.parties(id),
  receipt_id    uuid not null references public.goods_receipts(id),
  doc_no        text,
  returned_on   date not null default current_date,
  -- 'credit' leaves the value sitting against the supplier as a debit balance
  -- on 2100, ready for the next bill. 'refund' posts identically; the money
  -- coming back is a separate bank transaction, recorded as a payment.
  settlement    text not null default 'credit'
                  check (settlement in ('credit','refund')),
  status        text not null default 'draft'
                  check (status in ('draft','posted','cancelled')),
  reason        text not null default '',
  note          text not null default '',
  base_value    numeric,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id),
  posted_at     timestamptz,
  posted_by     uuid references auth.users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid references auth.users(id),
  cancel_reason text not null default ''
);

create index if not exists srn_deal_idx    on public.supplier_returns (deal_id);
create index if not exists srn_receipt_idx on public.supplier_returns (receipt_id);

create table if not exists public.supplier_return_lines (
  id              uuid primary key default gen_random_uuid(),
  return_id       uuid not null references public.supplier_returns(id) on delete cascade,
  receipt_line_id uuid not null references public.goods_receipt_lines(id),
  deal_item_id    uuid references public.deal_items(id),
  item_id         uuid references public.items(id),
  qty             numeric not null check (qty > 0),
  unit_cost       numeric not null default 0 check (unit_cost >= 0),
  note            text not null default ''
);

create index if not exists srn_lines_return_idx on public.supplier_return_lines (return_id);

alter table public.supplier_returns      enable row level security;
alter table public.supplier_return_lines enable row level security;

drop policy if exists supplier_returns_read on public.supplier_returns;
create policy supplier_returns_read on public.supplier_returns
  for select to authenticated using (true);

drop policy if exists supplier_return_lines_read on public.supplier_return_lines;
create policy supplier_return_lines_read on public.supplier_return_lines
  for select to authenticated using (true);

drop policy if exists supplier_returns_insert on public.supplier_returns;
create policy supplier_returns_insert on public.supplier_returns
  for insert to authenticated
  with check (private.can_edit() and status = 'draft');

drop policy if exists supplier_returns_update on public.supplier_returns;
create policy supplier_returns_update on public.supplier_returns
  for update to authenticated
  using (private.can_edit() and status = 'draft')
  with check (private.can_edit() and status = 'draft');

drop policy if exists supplier_returns_delete on public.supplier_returns;
create policy supplier_returns_delete on public.supplier_returns
  for delete to authenticated
  using (private.can_edit() and status = 'draft');

drop policy if exists supplier_return_lines_write on public.supplier_return_lines;
create policy supplier_return_lines_write on public.supplier_return_lines
  for all to authenticated
  using (
    private.can_edit() and exists (
      select 1 from public.supplier_returns r
       where r.id = supplier_return_lines.return_id and r.status = 'draft')
  )
  with check (
    private.can_edit() and exists (
      select 1 from public.supplier_returns r
       where r.id = supplier_return_lines.return_id and r.status = 'draft')
  );

create or replace function public.post_supplier_return(p_return uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  r        public.supplier_returns;
  g        public.goods_receipts;
  base     text;
  dec      int;
  docno    text;
  total    numeric := 0;
  jid      uuid;
  ln       record;
  returned numeric;
  oldq     numeric;
  olda     numeric;
  newq     numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post a return.';
  end if;

  select * into r from public.supplier_returns where id = p_return for update;
  if r.id is null then
    raise exception 'That return does not exist.';
  end if;
  if r.status <> 'draft' then
    raise exception 'This return is already %. Only a draft can be posted.', r.status;
  end if;

  select * into g from public.goods_receipts where id = r.receipt_id;
  if g.id is null or g.status <> 'posted' then
    raise exception 'A return has to come off a POSTED goods receipt: that is where the cost the goods arrived at is recorded.';
  end if;

  select c.base_currency into base from public.companies c where c.id = r.company_id;
  dec := public.currency_decimals(base);
  perform public.assert_period_open(r.company_id, r.returned_on);

  if not exists (select 1 from public.supplier_return_lines l
                  where l.return_id = p_return and l.qty > 0) then
    raise exception 'This return has no quantities on it.';
  end if;

  docno := public.next_doc_no(r.company_id, 'supplier_return',
                              extract(year from r.returned_on)::int);

  for ln in
    select l.*,
           coalesce(l.item_id, gl.item_id, di.item_id) as use_item,
           coalesce(nullif(l.unit_cost, 0), gl.unit_cost) as use_cost,
           gl.qty_accepted,
           coalesce(nullif(btrim(di.model), ''), di.description, '') as label
      from public.supplier_return_lines l
      join public.goods_receipt_lines gl on gl.id = l.receipt_line_id
      left join public.deal_items di on di.id = coalesce(l.deal_item_id, gl.deal_item_id)
     where l.return_id = p_return and l.qty > 0
     order by l.id
  loop
    if ln.use_item is null then
      raise exception 'A return line has no item on file.';
    end if;

    -- You cannot send back more than was accepted, counting earlier returns.
    select coalesce(sum(l2.qty), 0) into returned
      from public.supplier_return_lines l2
      join public.supplier_returns r2 on r2.id = l2.return_id
     where l2.receipt_line_id = ln.receipt_line_id
       and r2.status = 'posted';

    if ln.qty + returned > ln.qty_accepted then
      raise exception
        'Return line "%": % were accepted, % already went back, so % cannot be returned.',
        ln.label, ln.qty_accepted, returned, ln.qty;
    end if;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = g.warehouse_id
       for update;

    newq := coalesce(oldq, 0) - ln.qty;
    if newq < 0 then
      raise exception
        'Return line "%": only % units are still on hand, so % cannot go back to the supplier. Undo the sale first.',
        ln.label, coalesce(oldq, 0), ln.qty;
    end if;

    total := total + round(ln.qty * ln.use_cost, dec);

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, g.warehouse_id, -ln.qty, ln.use_cost,
            'supplier_returns', p_return, r.returned_on, (select auth.uid()));

    -- Unwind the blend at the cost this consignment came in at, exactly as
    -- cancel_goods_receipt does, so the remaining average is undisturbed.
    update public.item_costs
       set qty_on_hand = newq,
           avg_cost    = case when newq = 0 then 0
                         else greatest(round((oldq * olda - ln.qty * ln.use_cost) / newq, 6), 0)
                         end,
           updated_at  = now()
     where item_id = ln.use_item and warehouse_id = g.warehouse_id;

    if ln.deal_item_id is not null then
      update public.deal_items
         set qty_accepted = greatest(qty_accepted - ln.qty, 0)
       where id = ln.deal_item_id;
    end if;

    update public.supplier_return_lines
       set unit_cost = ln.use_cost, item_id = coalesce(item_id, ln.use_item)
     where id = ln.id;
  end loop;

  if total <= 0 then
    raise exception 'The returned goods have no cost on them, so there is nothing to credit.';
  end if;

  jid := public.post_event(
           p_company      => r.company_id,
           p_event        => 'supplier_return',
           p_source_table => 'supplier_returns',
           p_source_id    => p_return,
           p_amount       => total,
           p_currency     => base,
           p_entry_date   => r.returned_on,
           p_rate         => 1,
           p_party        => coalesce(r.party_id,
                               (select d.party_id from public.deals d where d.id = r.deal_id)),
           p_item         => null,
           p_warehouse    => g.warehouse_id,
           p_memo         => 'Return to supplier ' || docno);

  update public.stock_moves set journal_id = jid
   where source_table = 'supplier_returns' and source_id = p_return and journal_id is null;

  update public.supplier_returns
     set doc_no = docno, status = 'posted', base_value = total,
         party_id = coalesce(party_id,
                      (select d.party_id from public.deals d where d.id = r.deal_id)),
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_return;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('supplier_returns', p_return, 'posted', (select auth.uid()), r.reason,
          jsonb_build_object('doc_no', docno, 'credit_value', total,
                             'settlement', r.settlement, 'journal', jid));

  return jid;
end;
$fn$;

create or replace function public.cancel_supplier_return(p_return uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  r    public.supplier_returns;
  g    public.goods_receipts;
  j    uuid;
  ln   record;
  oldq numeric;
  olda numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change this.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this return is being cancelled.';
  end if;

  select * into r from public.supplier_returns where id = p_return for update;
  if r.id is null then
    raise exception 'That return does not exist.';
  end if;
  if r.status = 'cancelled' then
    return;
  end if;

  if r.status = 'draft' then
    delete from public.supplier_returns where id = p_return;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('supplier_returns', p_return, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  if not private.is_owner() then
    raise exception 'This return is posted. Only the owner can cancel it.';
  end if;

  select * into g from public.goods_receipts where id = r.receipt_id;
  perform public.assert_period_open(r.company_id, current_date);

  -- The goods come back on the shelf at the cost they left on.
  for ln in select l.*, coalesce(l.item_id, gl.item_id) as use_item
              from public.supplier_return_lines l
              join public.goods_receipt_lines gl on gl.id = l.receipt_line_id
             where l.return_id = p_return and l.qty > 0 loop

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, g.warehouse_id, ln.qty, ln.unit_cost,
            'supplier_returns_cancel', p_return, current_date, (select auth.uid()));

    insert into public.item_costs (item_id, warehouse_id, qty_on_hand, avg_cost)
    values (ln.use_item, g.warehouse_id, 0, 0)
    on conflict (item_id, warehouse_id) do nothing;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = g.warehouse_id for update;

    update public.item_costs
       set qty_on_hand = oldq + ln.qty,
           avg_cost    = case when oldq + ln.qty = 0 then 0
                         else round((oldq * olda + ln.qty * ln.unit_cost)
                                    / (oldq + ln.qty), 6) end,
           updated_at  = now()
     where item_id = ln.use_item and warehouse_id = g.warehouse_id;

    if ln.deal_item_id is not null then
      update public.deal_items
         set qty_accepted = qty_accepted + ln.qty
       where id = ln.deal_item_id;
    end if;
  end loop;

  select id into j from public.journals
   where source_table = 'supplier_returns' and source_id = p_return
     and status = 'posted' limit 1;
  if j is not null then
    perform public.reverse_journal(j, 'Return cancelled: ' || btrim(p_reason));
  end if;

  update public.supplier_returns
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_return;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('supplier_returns', p_return, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('reversed_journal', j, 'doc_no', r.doc_no));
end;
$fn$;

-- =================== PART 3: APPLYING AN ADVANCE ======================
--
-- `apply_supplier_advance` (Dr 2100 / Cr 1400) and `apply_customer_advance`
-- (Dr 2200 / Cr 1200) have been approved templates since phase 5 with nothing
-- calling them, because on the supplier side there was no bill to apply an
-- advance TO. Spec page 5 step 5 is explicit: "allocate advance / payment".
--
-- It gets its own document rather than being a flag on the payment, for a
-- structural reason: `journals_source_event_uq` means one (source_table,
-- source_id, event) posts once, so hanging the event off the party row would
-- let each party apply an advance exactly once, ever.

create table if not exists public.advance_applications (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid not null references public.companies(id),
  party_id            uuid not null references public.parties(id),
  side                text not null check (side in ('customer','supplier')),
  doc_no              text,
  amount_base         numeric not null check (amount_base > 0),
  applied_on          date not null default current_date,
  supplier_invoice_id uuid references public.supplier_invoices(id),
  sales_invoice_id    uuid references public.sales_invoices(id),
  status              text not null default 'draft'
                        check (status in ('draft','posted','cancelled')),
  note                text not null default '',
  created_at          timestamptz not null default now(),
  created_by          uuid references auth.users(id),
  posted_at           timestamptz,
  posted_by           uuid references auth.users(id),
  cancelled_at        timestamptz,
  cancelled_by        uuid references auth.users(id),
  cancel_reason       text not null default '',
  -- A supplier application points at a supplier bill or at nothing; the same
  -- for the customer side. It can never point at both, nor at the wrong side.
  check (num_nonnulls(supplier_invoice_id, sales_invoice_id) <= 1),
  check (side <> 'customer' or supplier_invoice_id is null),
  check (side <> 'supplier' or sales_invoice_id is null)
);

create index if not exists adv_app_party_idx on public.advance_applications (party_id);
create unique index if not exists adv_app_doc_no_uniq
  on public.advance_applications (company_id, doc_no) where doc_no is not null;

alter table public.advance_applications enable row level security;

drop policy if exists advance_applications_read on public.advance_applications;
create policy advance_applications_read on public.advance_applications
  for select to authenticated using (true);

drop policy if exists advance_applications_insert on public.advance_applications;
create policy advance_applications_insert on public.advance_applications
  for insert to authenticated
  with check (private.can_edit() and status = 'draft');

drop policy if exists advance_applications_update on public.advance_applications;
create policy advance_applications_update on public.advance_applications
  for update to authenticated
  using (private.can_edit() and status = 'draft')
  with check (private.can_edit() and status = 'draft');

drop policy if exists advance_applications_delete on public.advance_applications;
create policy advance_applications_delete on public.advance_applications
  for delete to authenticated
  using (private.can_edit() and status = 'draft');

-- What a party is holding on account, read straight from the ledger so it
-- cannot disagree with the customer_advances / supplier_advances views.
-- 'posted','reversed' again: the mirror of a reversed advance is what cancels
-- it, and dropping the original would report the advance as its own opposite.
create or replace function private.advance_held(p_party uuid, p_side text)
returns numeric language sql stable security definer set search_path to '' as $fn$
  select coalesce(sum(case when p_side = 'supplier' then l.debit - l.credit
                                                    else l.credit - l.debit end), 0)
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where l.party_id = p_party
     and j.status in ('posted', 'reversed')
     and l.account_code = case when p_side = 'supplier' then '1400' else '2200' end
$fn$;

create or replace function public.post_advance_application(p_app uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  aa    public.advance_applications;
  base  text;
  dec   int;
  held  numeric;
  owed  numeric;
  docno text;
  jid   uuid;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to apply an advance.';
  end if;

  select * into aa from public.advance_applications where id = p_app for update;
  if aa.id is null then
    raise exception 'That advance application does not exist.';
  end if;
  if aa.status <> 'draft' then
    raise exception 'This application is already %.', aa.status;
  end if;

  select c.base_currency into base from public.companies c where c.id = aa.company_id;
  dec := public.currency_decimals(base);
  perform public.assert_period_open(aa.company_id, aa.applied_on);

  held := private.advance_held(aa.party_id, aa.side);
  if round(aa.amount_base, dec) > round(held, dec) then
    raise exception
      'Only % is held on account for this party, so % cannot be applied.',
      round(held, dec), round(aa.amount_base, dec);
  end if;

  -- An advance cannot clear more than the bill it is pointed at still owes.
  if aa.supplier_invoice_id is not null then
    select oi.outstanding into owed
      from public.supplier_open_items oi
     where oi.supplier_invoice_id = aa.supplier_invoice_id;
    if owed is null then
      raise exception 'That supplier bill is not open, so there is nothing to apply the advance to.';
    end if;
    if round(aa.amount_base, dec) > round(owed, dec) then
      raise exception 'That bill has only % left to pay.', round(owed, dec);
    end if;
  elsif aa.sales_invoice_id is not null then
    select oi.outstanding into owed
      from public.customer_open_items oi
     where oi.sales_invoice_id = aa.sales_invoice_id;
    if owed is null then
      raise exception 'That sales invoice is not open, so there is nothing to apply the advance to.';
    end if;
    if round(aa.amount_base, dec) > round(owed, dec) then
      raise exception 'That invoice has only % left to collect.', round(owed, dec);
    end if;
  end if;

  docno := public.next_doc_no(aa.company_id, 'advance_application',
                              extract(year from aa.applied_on)::int);

  jid := public.post_event(
           p_company      => aa.company_id,
           p_event        => case aa.side when 'supplier' then 'apply_supplier_advance'
                                          else 'apply_customer_advance' end,
           p_source_table => 'advance_applications',
           p_source_id    => p_app,
           p_amount       => aa.amount_base,
           p_currency     => base,
           p_entry_date   => aa.applied_on,
           p_rate         => 1,
           p_party        => aa.party_id,
           p_item         => null,
           p_warehouse    => null,
           p_memo         => 'Advance applied ' || docno);

  update public.advance_applications
     set doc_no = docno, status = 'posted',
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_app;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('advance_applications', p_app, 'posted', (select auth.uid()), aa.note,
          jsonb_build_object('doc_no', docno, 'side', aa.side,
                             'amount_base', aa.amount_base, 'journal', jid));

  return jid;
end;
$fn$;

create or replace function public.cancel_advance_application(p_app uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  aa public.advance_applications;
  j  uuid;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change this.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this application is being cancelled.';
  end if;

  select * into aa from public.advance_applications where id = p_app for update;
  if aa.id is null then
    raise exception 'That advance application does not exist.';
  end if;
  if aa.status = 'cancelled' then
    return;
  end if;

  if aa.status = 'draft' then
    delete from public.advance_applications where id = p_app;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('advance_applications', p_app, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  if not private.is_owner() then
    raise exception 'This application is posted. Only the owner can cancel it.';
  end if;

  select id into j from public.journals
   where source_table = 'advance_applications' and source_id = p_app
     and status = 'posted' limit 1;
  if j is not null then
    perform public.reverse_journal(j, 'Advance application cancelled: ' || btrim(p_reason));
  end if;

  update public.advance_applications
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_app;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('advance_applications', p_app, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('reversed_journal', j, 'doc_no', aa.doc_no));
end;
$fn$;

-- ============ PART 4: A SUPPLIER PAYMENT CAN NOW BE ALLOCATED =========

alter table public.payment_allocations
  add column if not exists supplier_invoice_id uuid references public.supplier_invoices(id);

alter table public.payment_allocations drop constraint if exists payment_alloc_one_target;
alter table public.payment_allocations add constraint payment_alloc_one_target
  check (num_nonnulls(invoice_id, deal_id, sales_invoice_id, supplier_invoice_id) = 1);

create index if not exists payment_alloc_pin_idx
  on public.payment_allocations (supplier_invoice_id) where supplier_invoice_id is not null;

-- ================== PART 5: WHAT WE OWE, FROM THE BILL ================
--
-- `supplier_open_items` read the purchase ORDER because there was no bill. Now
-- there is, so it reads the bill - and keeps reading the order for any order
-- that has no posted bill yet, because those are still real commitments the
-- owner has to see on Payables, and because the live data is entirely of that
-- kind. `bill_source` says which: 'invoice' means a posted payable stands
-- behind the figure, 'order' means it does not. The two sets cannot overlap: an
-- order appears as an order row only while no posted PIN names it.

drop view if exists public.ap_aging;
drop view if exists public.supplier_open_items;

create view public.supplier_open_items
with (security_invoker = true) as
  -- Matched bills.
  select si.id                       as supplier_invoice_id,
         si.deal_id,
         si.doc_no,
         si.party_id,
         p.name                      as party_name,
         p.sup_code,
         p.supplier_no,
         nullif(btrim(si.supplier_ref), '') as invoice_no,
         si.invoice_date,
         coalesce(si.due_date,
                  si.invoice_date + coalesce(p.payment_terms_days, 0)) as due_date,
         si.currency,
         public.currency_decimals(si.currency) as cur_decimals,
         si.base_value               as amount,
         coalesce(al.allocated, 0)   as paid,
         coalesce(rt.returned, 0)    as credited,
         coalesce(ad.applied, 0)     as advanced,
         si.base_value
           - coalesce(al.allocated, 0)
           - coalesce(rt.returned, 0)
           - coalesce(ad.applied, 0) as outstanding,
         'invoice'::text             as bill_source,
         public.age_bucket(coalesce(si.due_date,
                  si.invoice_date + coalesce(p.payment_terms_days, 0))) as age_bucket
    from public.supplier_invoices si
    left join public.parties p on p.id = si.party_id
    left join lateral (
      select sum(a.amount) as allocated
        from public.payment_allocations a
        join public.payments pm on pm.id = a.payment_id and pm.status = 'posted'
       where a.supplier_invoice_id = si.id
    ) al on true
    left join lateral (
      -- A return credits the supplier, so it reduces what is owed on the
      -- order's bill. Returns are receipt-scoped, not invoice-scoped, so they
      -- land on the order's bill; with one bill per order - the rule this
      -- schema keeps - that is the same thing.
      select sum(r.base_value) as returned
        from public.supplier_returns r
       where r.deal_id = si.deal_id and r.status = 'posted'
    ) rt on true
    left join lateral (
      select sum(aa.amount_base) as applied
        from public.advance_applications aa
       where aa.supplier_invoice_id = si.id and aa.status = 'posted'
    ) ad on true
   where si.status = 'posted'
     and si.base_value
         - coalesce(al.allocated, 0)
         - coalesce(rt.returned, 0)
         - coalesce(ad.applied, 0) > 0

  union all

  -- Orders with no matched bill yet: a commitment, not a posted payable.
  select null::uuid                  as supplier_invoice_id,
         d.id                        as deal_id,
         d.doc_no,
         d.party_id,
         p.name                      as party_name,
         p.sup_code,
         p.supplier_no,
         s.invoice_no,
         s.invoice_uploaded_at::date as invoice_date,
         case when p.payment_terms_days is not null and s.invoice_uploaded_at is not null
              then (s.invoice_uploaded_at::date + p.payment_terms_days)
              else null end          as due_date,
         s.currency,
         s.cur_decimals,
         s.bill_total                as amount,
         s.paid,
         0::numeric                  as credited,
         0::numeric                  as advanced,
         s.amount_left               as outstanding,
         'order'::text               as bill_source,
         public.age_bucket(
           case when p.payment_terms_days is not null and s.invoice_uploaded_at is not null
                then (s.invoice_uploaded_at::date + p.payment_terms_days)
                else null end)       as age_bucket
    from public.deals d
    join public.deal_summary s on s.deal_id = d.id
    left join public.parties p on p.id = d.party_id
   where d.direction = 'sending'
     and d.deleted_at is null
     and s.amount_left > 0
     and not exists (select 1 from public.supplier_invoices si
                      where si.deal_id = d.id and si.status = 'posted');

create view public.ap_aging
with (security_invoker = true) as
  select oi.party_id,
         oi.party_name,
         oi.sup_code,
         oi.supplier_no,
         oi.currency,
         oi.cur_decimals,
         count(*)                                         as open_bills,
         count(*) filter (where oi.bill_source = 'order') as unmatched_orders,
         sum(case when oi.age_bucket = 'not due' then oi.outstanding else 0 end) as not_due,
         sum(case when oi.age_bucket = '1-30'    then oi.outstanding else 0 end) as overdue_1_30,
         sum(case when oi.age_bucket = '31-60'   then oi.outstanding else 0 end) as overdue_31_60,
         sum(case when oi.age_bucket = '61-90'   then oi.outstanding else 0 end) as overdue_61_90,
         sum(case when oi.age_bucket = 'over 90' then oi.outstanding else 0 end) as overdue_over_90,
         sum(oi.outstanding) as total_outstanding
    from public.supplier_open_items oi
   group by oi.party_id, oi.party_name, oi.sup_code, oi.supplier_no,
            oi.currency, oi.cur_decimals;

-- An applied customer advance clears a receivable, so the invoice it was
-- applied to owes that much less. `advanced` is appended at the END of the
-- column list on purpose: create-or-replace can add columns there but cannot
-- reorder or rename the ones already in use.
create or replace view public.customer_open_items
with (security_invoker = true) as
  select si.id as sales_invoice_id,
         si.doc_no,
         si.deal_id,
         si.party_id,
         p.name as party_name,
         p.cus_code,
         si.invoice_date,
         si.due_date,
         si.currency,
         public.currency_decimals(si.currency) as cur_decimals,
         inv.amount,
         coalesce(al.allocated, 0) as allocated,
         coalesce(cr.credited, 0) as credited,
         inv.amount - coalesce(al.allocated, 0) - coalesce(cr.credited, 0)
                    - coalesce(ad.applied, 0) as outstanding,
         public.age_bucket(si.due_date) as age_bucket,
         coalesce(ad.applied, 0) as advanced
    from public.sales_invoices si
    join public.parties p on p.id = si.party_id
    cross join lateral (
      select coalesce(sum(l.qty * l.unit_price - l.discount), 0)
               + coalesce(si.tax_amount, 0) as amount
        from public.sales_invoice_lines l where l.invoice_id = si.id
    ) inv
    left join lateral (
      select sum(a.amount) as allocated
        from public.payment_allocations a
        join public.payments pm on pm.id = a.payment_id and pm.status = 'posted'
       where a.sales_invoice_id = si.id
    ) al on true
    left join lateral (
      select sum(l.qty * l.unit_price) as credited
        from public.credit_notes cn
        join public.credit_note_lines l on l.credit_note_id = cn.id
       where cn.invoice_id = si.id and cn.status = 'posted'
    ) cr on true
    left join lateral (
      select sum(aa.amount_base) as applied
        from public.advance_applications aa
       where aa.sales_invoice_id = si.id and aa.status = 'posted'
    ) ad on true
   where si.status = 'posted';

-- ============== PART 6: PAYMENTS STOP REFUSING ALLOCATION =============
--
-- payment_plan's arithmetic does not change - an allocated share and an advance
-- share, with the exchange difference sitting on the allocated share, because
-- that is the only part with a bill behind it. What changes is that the
-- supplier side no longer refuses, and that an allocation now has to point at a
-- posted bill on the payment's own order. That check belongs here, in the one
-- place both preview and post read, so the two cannot disagree about it.

create or replace function private.payment_plan(p_payment uuid)
returns table (
  company_id       uuid,
  side             text,
  base_currency    text,
  cur_decimals     int,
  deal_currency    text,
  party_id         uuid,
  entry_date       date,
  bank_code        text,
  rate             numeric,
  amount_foreign   numeric,
  book_base        numeric,
  bank_base        numeric,
  alloc_foreign    numeric,
  alloc_book_base  numeric,
  alloc_bank_base  numeric,
  advance_base     numeric
)
language plpgsql stable security definer set search_path to '' as $fn$
declare
  pay   public.payments;
  dl    public.deals;
  comp  uuid;
  base  text;
  dec   int;
  bcode text;
  bcur  text;
  rt    numeric;
  book  numeric;
  bank  numeric;
  alc   numeric;
  alcb  numeric;
  alcbk numeric;
  sd    text;
  bad   int;
begin
  select * into pay from public.payments where id = p_payment;
  if pay.id is null then
    raise exception 'Payment not found.';
  end if;

  select * into dl from public.deals where id = pay.deal_id;
  if dl.id is null then
    raise exception 'The payment is not attached to an order.';
  end if;

  comp := coalesce(pay.company_id, dl.company_id);
  if comp is null then
    raise exception 'The payment has no company, so there is no ledger to post it to.';
  end if;

  select c.base_currency into base from public.companies c where c.id = comp;
  if base is null then
    raise exception 'Unknown company.';
  end if;
  dec := public.currency_decimals(base);
  sd  := case dl.direction when 'receiving' then 'customer' else 'supplier' end;

  if pay.bank_account_id is null then
    raise exception 'Choose the bank account the money moved through before posting.';
  end if;
  select b.gl_code, b.currency into bcode, bcur
    from public.bank_accounts b
   where b.id = pay.bank_account_id and b.active;
  if bcode is null then
    raise exception 'That bank account is missing, inactive, or has no ledger account on it.';
  end if;
  if bcur <> base then
    raise exception 'Money can only move through a bank account held in %, not % - a foreign bank balance needs revaluation (phase 6).', base, bcur;
  end if;

  -- An order already in base currency needs no rate; otherwise the rate on the
  -- payment wins, and fx_rate_for raises rather than assuming 1:1.
  if dl.currency = base then
    rt := 1;
  else
    rt := coalesce(pay.fx_rate,
                   public.fx_rate_for(dl.currency, coalesce(pay.rate_date, pay.paid_on), base));
  end if;

  book := public.to_base(pay.amount, rt, base);
  bank := round(coalesce(pay.bank_amount, book), dec);
  if book <= 0 then
    raise exception 'A payment needs an amount above zero.';
  end if;
  if bank <= 0 then
    raise exception 'The bank amount must be above zero.';
  end if;

  select coalesce(sum(a.amount), 0) into alc
    from public.payment_allocations a where a.payment_id = p_payment;
  if alc > pay.amount then
    raise exception 'Allocations (%) exceed the payment amount (%).', alc, pay.amount;
  end if;

  -- An allocation has to name a posted bill on this order. Otherwise the
  -- settlement would clear a payable or receivable that was never posted.
  if alc > 0 then
    if sd = 'supplier' then
      select count(*) into bad
        from public.payment_allocations a
        left join public.supplier_invoices si
               on si.id = a.supplier_invoice_id and si.status = 'posted'
                  and si.deal_id = pay.deal_id
       where a.payment_id = p_payment and si.id is null;
      if bad > 0 then
        raise exception
          'A supplier payment can only be allocated to a posted supplier invoice (PIN) on the same order. % of its allocations do not name one.', bad;
      end if;
    else
      select count(*) into bad
        from public.payment_allocations a
        left join public.sales_invoices sv
               on sv.id = a.sales_invoice_id and sv.status = 'posted'
                  and sv.deal_id = pay.deal_id
       where a.payment_id = p_payment and sv.id is null;
      if bad > 0 then
        raise exception
          'A customer receipt can only be allocated to a posted sales invoice on the same order. % of its allocations do not name one.', bad;
      end if;
    end if;
  end if;

  -- The allocated share carries the whole exchange difference, because it is
  -- the only part with a bill behind it to compare against. An advance has no
  -- bill, so its base value simply is the money that moved.
  alcb  := public.to_base(alc, rt, base);
  alcbk := case when alc >= pay.amount then bank
                else round(bank * alc / pay.amount, dec) end;

  return query select
    comp, sd, base, dec, dl.currency, dl.party_id, pay.paid_on, bcode, rt,
    pay.amount, book, bank, alc, alcb, alcbk, round(bank - alcbk, dec);
end;
$fn$;

create or replace function public.preview_payment(p_payment uuid)
returns table (account_code text, account_name text, debit numeric, credit numeric, memo text)
language plpgsql stable security definer set search_path to '' as $fn$
declare
  pl   record;
  diff numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to preview a payment.';
  end if;

  select * into pl from private.payment_plan(p_payment);

  if pl.side = 'supplier' then
    -- The allocated share clears the payable at what the bill is carried at;
    -- the bank gives up what it actually paid, and the gap is the exchange
    -- result. Nothing else in a payment carries that difference.
    if pl.alloc_foreign > 0 then
      diff := pl.alloc_bank_base - pl.alloc_book_base;
      return query
        select '2100'::text, a.name, pl.alloc_book_base, 0::numeric,
               'Supplier payable cleared'::text
          from public.accounts a where a.code = '2100';
      if diff > 0 then
        return query select '6100'::text, a.name, diff, 0::numeric,
               'Exchange loss on settlement'::text
          from public.accounts a where a.code = '6100';
      end if;
      return query
        select pl.bank_code, a.name, 0::numeric, pl.alloc_bank_base, 'Paid from bank'::text
          from public.accounts a where a.code = pl.bank_code;
      if diff < 0 then
        return query select '6100'::text, a.name, 0::numeric, -diff,
               'Exchange gain on settlement'::text
          from public.accounts a where a.code = '6100';
      end if;
    end if;

    if pl.advance_base > 0 then
      return query
        select '1400'::text, a.name, pl.advance_base, 0::numeric, 'Supplier advance'::text
          from public.accounts a where a.code = '1400'
        union all
        select pl.bank_code, a.name, 0::numeric, pl.advance_base, 'Paid from bank'::text
          from public.accounts a where a.code = pl.bank_code;
    end if;
    return;
  end if;

  -- Customer side: the allocated share clears receivables, the rest is an
  -- advance, and the exchange difference sits with the allocated share.
  if pl.alloc_foreign > 0 then
    diff := pl.alloc_book_base - pl.alloc_bank_base;
    return query
      select pl.bank_code, a.name, pl.alloc_bank_base, 0::numeric, 'Collected into bank'::text
        from public.accounts a where a.code = pl.bank_code;
    if diff > 0 then
      return query select '6100'::text, a.name, diff, 0::numeric, 'Exchange loss on collection'::text
        from public.accounts a where a.code = '6100';
    end if;
    return query
      select '1200'::text, a.name, 0::numeric, pl.alloc_book_base, 'Customer receivable cleared'::text
        from public.accounts a where a.code = '1200';
    if diff < 0 then
      return query select '6100'::text, a.name, 0::numeric, -diff, 'Exchange gain on collection'::text
        from public.accounts a where a.code = '6100';
    end if;
  end if;

  if pl.advance_base > 0 then
    return query
      select pl.bank_code, a.name, pl.advance_base, 0::numeric, 'Collected into bank'::text
        from public.accounts a where a.code = pl.bank_code
      union all
      select '2200'::text, a.name, 0::numeric, pl.advance_base, 'Customer advance'::text
        from public.accounts a where a.code = '2200';
  end if;
end;
$fn$;

create or replace function public.post_payment(p_payment uuid, p_memo text default '')
returns uuid
language plpgsql security definer set search_path to '' as $fn$
declare
  pay   public.payments;
  pl    record;
  docno text;
  jid   uuid;
  jadv  uuid;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post a payment.';
  end if;

  select * into pay from public.payments where id = p_payment for update;
  if pay.id is null then
    raise exception 'Payment not found.';
  end if;
  if pay.status = 'legacy' then
    raise exception 'This payment predates the ledger and cannot be posted. Record it on the receipts screen instead.';
  end if;
  if pay.status <> 'draft' then
    raise exception 'Only a draft payment can be posted; this one is %.', pay.status;
  end if;

  select * into pl from private.payment_plan(p_payment);
  perform public.assert_period_open(pl.company_id, pl.entry_date);

  docno := coalesce(pay.doc_no,
                    public.next_doc_no(pl.company_id, 'payment',
                                       extract(year from pl.entry_date)::int));

  -- Both sides now behave the same way: an allocated share settles a posted
  -- bill through post_settlement, which is what carries the exchange
  -- difference, and anything unallocated is an advance.
  if pl.alloc_foreign > 0 then
    jid := public.post_settlement(
             pl.company_id, pl.side, 'payments', p_payment,
             pl.alloc_book_base, pl.alloc_bank_base, pl.party_id,
             pl.entry_date, pl.bank_code,
             case when pl.deal_currency = pl.base_currency then null else pl.deal_currency end,
             case when pl.deal_currency = pl.base_currency then null else pl.alloc_foreign end,
             case when pl.deal_currency = pl.base_currency then null else pl.rate end,
             coalesce(nullif(p_memo, ''),
                      case pl.side when 'supplier' then 'Supplier payment '
                                   else 'Customer receipt ' end || docno));
  end if;

  if pl.advance_base > 0 then
    jadv := public.post_event(
              p_company      => pl.company_id,
              p_event        => case pl.side when 'supplier' then 'supplier_advance'
                                             else 'customer_advance' end,
              p_source_table => 'payments',
              p_source_id    => p_payment,
              p_amount       => pl.advance_base,
              p_currency     => pl.base_currency,
              p_entry_date   => pl.entry_date,
              p_rate         => 1,
              p_party        => pl.party_id,
              p_item         => null,
              p_warehouse    => null,
              p_memo         => coalesce(nullif(p_memo, ''),
                                  case pl.side when 'supplier' then 'Supplier advance '
                                               else 'Customer advance ' end || docno));
    jid := coalesce(jid, jadv);
  end if;

  if jid is null then
    raise exception 'Nothing to post: the payment has neither an allocated share nor an advance.';
  end if;

  update public.payments
     set status    = 'posted',
         doc_no    = docno,
         posted_at = now(),
         posted_by = (select auth.uid())
   where id = p_payment;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('payments', p_payment, 'posted', (select auth.uid()), coalesce(p_memo, ''),
          jsonb_build_object('doc_no', docno, 'side', pl.side,
                             'book_base', pl.book_base, 'bank_base', pl.bank_base,
                             'allocated_base', pl.alloc_book_base,
                             'advance_base', pl.advance_base,
                             'journal', jid, 'advance_journal', jadv));

  return jid;
end;
$fn$;

-- ============= PART 7: ORDER PROGRESS LEARNS TWO MORE NUMBERS =========
-- Spec page 17: "Shipped, received and invoiced quantities are tracked
-- separately." Appended at the end of the column list, for the same
-- create-or-replace reason as customer_open_items above.

create or replace view public.order_progress
with (security_invoker = true) as
  select di.id            as deal_item_id,
         di.deal_id,
         d.direction,
         d.reference,
         d.party,
         d.party_id,
         d.status         as deal_status,
         di.item_id,
         i.code           as item_code,
         coalesce(nullif(btrim(di.model), ''), di.description) as item_label,
         di.brand,
         di.description,
         di.qty           as qty_ordered,
         di.qty_received,
         di.qty_accepted,
         di.qty_damaged,
         greatest(di.qty - di.qty_accepted, 0) as qty_outstanding,
         di.unit_price,
         di.unit_cost,
         d.currency,
         public.currency_decimals(d.currency) as cur_decimals,
         case
           when di.qty_accepted = 0 and di.qty_received = 0 then 'not arrived'
           when di.qty_accepted >= di.qty                   then 'arrived'
           when di.qty_damaged > 0 and di.qty_accepted = 0   then 'arrived damaged'
           else 'partly arrived'
         end as arrival_state,
         di.qty_shipped,
         di.qty_invoiced,
         greatest(di.qty_accepted - di.qty_invoiced, 0) as qty_uninvoiced
    from public.deal_items di
    join public.deals d on d.id = di.deal_id
    left join public.items i on i.id = di.item_id
   where d.deleted_at is null
     and d.status <> 'cancelled';
