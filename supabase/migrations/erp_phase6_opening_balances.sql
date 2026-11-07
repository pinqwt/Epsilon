-- ERP phase 6, part 2 of 2: opening balances (2026-11-07).
--
-- Applied as:
--   erp_phase6_opening_balance_tables
--   erp_phase6_opening_deal_direction_cast
--   erp_phase6_post_opening_balance
--   erp_phase6_cancel_opening_balance
--   erp_phase6_opening_reports
--
-- Spec page 12, phase 6: "Import opening stock with costs and unpaid invoices.
-- Reconcile all opening balances and validate reports before launch."
-- Spec page 3: "Opening balance: do not type an unexplained number into the
-- master. Import unpaid opening invoices / credits with dates and currency,
-- and reconcile them to opening accounting balances."
--
-- So an opening balance is a DOCUMENT that posts a journal, not a number typed
-- onto a party or an item. That is why `parties` and `items` get no
-- opening_balance column here.
--
-- THE SYNTHETIC OPENING ORDER. Decided with the owner 2026-11-07. Everything
-- in this schema hangs off a `deals` row: `sales_invoices.deal_id` and
-- `supplier_invoices.deal_id` are both not-null, and `private.payment_plan()`
-- reads a payment's deal for its currency and party. A carried-over unpaid
-- invoice has no order behind it, so posting creates one hidden order per
-- account, `reference = 'OPENING'`, `status = 'legacy'` - legacy being exactly
-- right, since it means "predates the ledger". The opening invoices hang off
-- it, and in exchange every existing screen keeps working untouched: the aging
-- reports, the open-items views, the party statement, and collecting or paying
-- an opening invoice through the ordinary receipt / payment screens.
--
-- The two alternatives were rejected deliberately: a nullable deal_id would
-- leave opening invoices uncollectable until payment_plan was reworked, and a
-- ledger-only opening balance would keep the trial balance right but never
-- show an opening invoice in an aging report or let one be settled on its own.
--
-- WHY THERE IS NO POSTING TEMPLATE FOR THIS EVENT. The 18 rows in
-- `posting_templates` each map one event to one debit and one credit account,
-- which is what spec page 9 asks an accountant to validate. An opening entry
-- is not a pair: it debits stock, receivables and the bank and credits
-- payables, all against one contra. There is no pair to review, so a row would
-- misrepresent it. What the accountant reviews instead is account 3100 and the
-- opening document itself - which is why the document exists and carries its
-- own `OPN-` number.

-- ===================== THE CONTRA ACCOUNT ===========================
-- Opening entries balance against their own equity account rather than 3000,
-- so carried-over data stays separable from real equity for ever. "What did we
-- start with?" is then one query, not archaeology.

insert into public.accounts (code, name, kind, is_control, active)
values ('3100', 'Opening balance', 'equity', false, true)
on conflict (code) do nothing;

-- ========================= THE DOCUMENT =============================

create table if not exists public.opening_balances (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  doc_no        text,
  as_of         date not null default current_date,
  status        text not null default 'draft'
                  check (status in ('draft', 'posted', 'cancelled')),
  note          text not null default '',
  journal_id    uuid references public.journals(id),
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id),
  posted_at     timestamptz,
  posted_by     uuid references auth.users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid references auth.users(id),
  cancel_reason text not null default ''
);

create unique index if not exists opening_doc_no_uniq
  on public.opening_balances (company_id, doc_no) where doc_no is not null;

-- Opening data is imported ONCE. A second posted opening document would double
-- every carried-over balance, and "no transactions = zero balance" means there
-- is nothing to top up later: a correction is a cancellation and a re-import,
-- which is what cancel_opening_balance is for.
create unique index if not exists opening_once_per_company
  on public.opening_balances (company_id) where status = 'posted';

create table if not exists public.opening_balance_lines (
  id              uuid primary key default gen_random_uuid(),
  opening_id      uuid not null references public.opening_balances(id) on delete cascade,
  kind            text not null
                    check (kind in ('stock', 'customer_invoice',
                                    'supplier_invoice', 'bank')),
  label           text not null default '',
  -- kind = 'stock'
  item_id         uuid references public.items(id),
  warehouse_id    uuid references public.warehouses(id),
  qty             numeric check (qty is null or qty > 0),
  unit_cost       numeric check (unit_cost is null or unit_cost >= 0),
  -- kind = 'customer_invoice' / 'supplier_invoice'
  party_id        uuid references public.parties(id),
  their_ref       text not null default '',
  invoice_date    date,
  due_date        date,
  -- kind = 'bank'
  bank_account_id uuid references public.bank_accounts(id),
  -- the money, in whatever currency it is owed in
  currency        text,
  amount_foreign  numeric check (amount_foreign is null or amount_foreign > 0),
  fx_rate         numeric check (fx_rate is null or fx_rate > 0),
  -- filled at posting, so a cancellation can find what it created
  amount_base        numeric,
  created_deal_id    uuid references public.deals(id),
  created_invoice_id uuid,
  note            text not null default '',
  -- Each kind carries its own fields. Without these a stock line with no
  -- warehouse, or an invoice line with no party, would reach the posting
  -- function and fail there instead of at entry.
  constraint opening_stock_fields check (
    kind <> 'stock' or (item_id is not null and warehouse_id is not null
                        and qty is not null and unit_cost is not null)),
  constraint opening_invoice_fields check (
    kind not in ('customer_invoice', 'supplier_invoice')
    or (party_id is not null and amount_foreign is not null
        and invoice_date is not null)),
  constraint opening_bank_fields check (
    kind <> 'bank' or (bank_account_id is not null and amount_foreign is not null))
);

create index if not exists opening_lines_doc_idx
  on public.opening_balance_lines (opening_id);

-- An opening invoice is a real invoice row - that is what makes it collectable
-- - so it needs a flag saying it carries no revenue and no goods behind it.
alter table public.sales_invoices
  add column if not exists is_opening boolean not null default false;
alter table public.supplier_invoices
  add column if not exists is_opening boolean not null default false;

-- ============================== RLS =================================

alter table public.opening_balances      enable row level security;
alter table public.opening_balance_lines enable row level security;

drop policy if exists opening_balances_read on public.opening_balances;
create policy opening_balances_read on public.opening_balances
  for select to authenticated using (true);

drop policy if exists opening_lines_read on public.opening_balance_lines;
create policy opening_lines_read on public.opening_balance_lines
  for select to authenticated using (true);

-- Only a draft is writable from the client, as everywhere else in this schema.
-- Posting goes through post_opening_balance, which is owner-only.
drop policy if exists opening_balances_insert on public.opening_balances;
create policy opening_balances_insert on public.opening_balances
  for insert to authenticated
  with check (private.can_edit() and status = 'draft');

drop policy if exists opening_balances_update on public.opening_balances;
create policy opening_balances_update on public.opening_balances
  for update to authenticated
  using (private.can_edit() and status = 'draft')
  with check (private.can_edit() and status = 'draft');

drop policy if exists opening_balances_delete on public.opening_balances;
create policy opening_balances_delete on public.opening_balances
  for delete to authenticated
  using (private.can_edit() and status = 'draft');

drop policy if exists opening_lines_write on public.opening_balance_lines;
create policy opening_lines_write on public.opening_balance_lines
  for all to authenticated
  using (
    private.can_edit() and exists (
      select 1 from public.opening_balances o
       where o.id = opening_balance_lines.opening_id and o.status = 'draft')
  )
  with check (
    private.can_edit() and exists (
      select 1 from public.opening_balances o
       where o.id = opening_balance_lines.opening_id and o.status = 'draft')
  );

-- ================== THE SYNTHETIC OPENING ORDER =====================

create or replace function private.opening_deal(
  p_company uuid, p_party uuid, p_direction text, p_currency text, p_as_of date)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  did   uuid;
  pname text;
begin
  -- One per account per direction, reused across lines, so a customer with six
  -- opening invoices gets one hidden order, not six.
  --
  -- `deals.direction` is the enum `public.deal_direction`, so the text
  -- parameter has to be cast explicitly: comparing an enum column to a text
  -- VARIABLE has no operator (a bare literal would have been coerced, which is
  -- why the insert below needs no cast).
  select d.id into did
    from public.deals d
   where d.company_id = p_company
     and d.party_id = p_party
     and d.direction = p_direction::public.deal_direction
     and d.reference = 'OPENING'
     and d.deleted_at is null
   limit 1;
  if did is not null then
    return did;
  end if;

  select p.name into pname from public.parties p where p.id = p_party;

  insert into public.deals (direction, party, party_id, company_id,
                            currency, deal_date, reference, status)
  values (p_direction, coalesce(pname, 'Opening balance'), p_party, p_company,
          p_currency, p_as_of, 'OPENING', 'legacy')
  returning id into did;

  return did;
end;
$fn$;

-- ========================== POSTING =================================

create or replace function public.post_opening_balance(p_opening uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  ob     public.opening_balances;
  base   text;
  dec    int;
  docno  text;
  jdoc   text;
  jid    uuid;
  ln     int := 0;
  r      record;
  amt    numeric;
  rt     numeric;
  net_dr numeric := 0;   -- running net debit; account 3100 balances it
  did    uuid;
  iid    uuid;
  lid    uuid;
  oldq   numeric;
  olda   numeric;
  bcode  text;
  bcur   text;
begin
  -- Owner only. Every later report is measured from this figure, and the
  -- one-posted-document-per-company index means there is no second chance
  -- without an explicit cancellation.
  if not private.is_owner() then
    raise exception
      'Only the owner can post an opening balance: it is the figure every later report is measured from.';
  end if;

  select * into ob from public.opening_balances where id = p_opening for update;
  if ob.id is null then
    raise exception 'That opening balance does not exist.';
  end if;
  if ob.status <> 'draft' then
    raise exception 'This opening balance is already %.', ob.status;
  end if;

  select c.base_currency into base from public.companies c where c.id = ob.company_id;
  if base is null then
    raise exception 'Unknown company.';
  end if;
  dec := public.currency_decimals(base);
  perform public.assert_period_open(ob.company_id, ob.as_of);

  if not exists (select 1 from public.opening_balance_lines
                  where opening_id = p_opening) then
    raise exception 'This opening balance has no lines, so there is nothing to carry over.';
  end if;

  docno := public.next_doc_no(ob.company_id, 'opening_balance',
                              extract(year from ob.as_of)::int);
  jdoc  := public.next_doc_no(ob.company_id, 'journal',
                              extract(year from ob.as_of)::int);

  insert into public.journals (company_id, doc_no, event, source_table, source_id,
                               entry_date, base_currency, status, reason, created_by)
  values (ob.company_id, jdoc, 'opening_balance', 'opening_balances', p_opening,
          ob.as_of, base, 'draft', coalesce(ob.note, ''), (select auth.uid()))
  returning id into jid;

  -- ------------------------- opening stock --------------------------
  -- Blended into the weighted average the same way a goods receipt is, so the
  -- first real receipt after launch averages against it correctly.
  for r in select * from public.opening_balance_lines
            where opening_id = p_opening and kind = 'stock' order by id loop

    amt := round(r.qty * r.unit_cost, dec);

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on,
                                    journal_id, created_by)
    values (r.item_id, r.warehouse_id, r.qty, r.unit_cost,
            'opening_balances', p_opening, ob.as_of, jid, (select auth.uid()));

    insert into public.item_costs (item_id, warehouse_id, qty_on_hand, avg_cost)
    values (r.item_id, r.warehouse_id, 0, 0)
    on conflict (item_id, warehouse_id) do nothing;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = r.item_id and warehouse_id = r.warehouse_id
       for update;

    update public.item_costs
       set qty_on_hand = oldq + r.qty,
           avg_cost    = case when oldq + r.qty = 0 then 0
                         else round((oldq * olda + r.qty * r.unit_cost)
                                    / (oldq + r.qty), 6) end,
           updated_at  = now()
     where item_id = r.item_id and warehouse_id = r.warehouse_id;

    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code,
                                      item_id, warehouse_id, debit, credit, memo)
    values (jid, ln, '1300', r.item_id, r.warehouse_id, amt, 0,
            'Opening stock'
            || case when btrim(r.label) <> '' then ' - ' || btrim(r.label) else '' end);
    net_dr := net_dr + amt;

    update public.opening_balance_lines set amount_base = amt where id = r.id;
  end loop;

  -- --------------------- opening customer invoices -------------------
  for r in select * from public.opening_balance_lines
            where opening_id = p_opening and kind = 'customer_invoice' order by id loop

    rt := coalesce(r.fx_rate,
                   case when upper(coalesce(r.currency, base)) = base then 1
                        else public.fx_rate_for(upper(r.currency), r.invoice_date, base) end);
    amt := public.to_base(r.amount_foreign, rt, base);

    did := private.opening_deal(ob.company_id, r.party_id, 'receiving',
                                upper(coalesce(r.currency, base)), ob.as_of);

    insert into public.sales_invoices (company_id, deal_id, party_id, doc_no,
                                       invoice_date, due_date, currency, fx_rate,
                                       tax_amount, status, is_opening, note,
                                       created_by, posted_at, posted_by)
    values (ob.company_id, did, r.party_id,
            public.next_doc_no(ob.company_id, 'sales_invoice',
                               extract(year from r.invoice_date)::int),
            r.invoice_date, coalesce(r.due_date, r.invoice_date),
            upper(coalesce(r.currency, base)), rt, 0, 'posted', true,
            'Opening unpaid invoice '
            || coalesce(nullif(btrim(r.their_ref), ''), '(no reference)'),
            (select auth.uid()), now(), (select auth.uid()))
    returning id into iid;

    -- customer_open_items derives the invoice amount from its LINES, so an
    -- opening invoice with no line would read as zero outstanding and never
    -- appear in the aging report. One line carrying the whole amount.
    insert into public.sales_invoice_lines (invoice_id, qty, unit_price,
                                            discount, description)
    values (iid, 1, r.amount_foreign, 0,
            'Opening balance carried over'
            || case when btrim(r.their_ref) <> ''
                    then ' - ' || btrim(r.their_ref) else '' end);

    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code, party_id,
                                      debit, credit, foreign_currency,
                                      foreign_amount, fx_rate, memo)
    values (jid, ln, '1200', r.party_id, amt, 0,
            nullif(upper(coalesce(r.currency, base)), base), r.amount_foreign, rt,
            'Opening customer balance');
    net_dr := net_dr + amt;

    update public.opening_balance_lines
       set amount_base = amt, created_deal_id = did, created_invoice_id = iid
     where id = r.id;
  end loop;

  -- --------------------- opening supplier invoices -------------------
  for r in select * from public.opening_balance_lines
            where opening_id = p_opening and kind = 'supplier_invoice' order by id loop

    rt := coalesce(r.fx_rate,
                   case when upper(coalesce(r.currency, base)) = base then 1
                        else public.fx_rate_for(upper(r.currency), r.invoice_date, base) end);
    amt := public.to_base(r.amount_foreign, rt, base);

    did := private.opening_deal(ob.company_id, r.party_id, 'sending',
                                upper(coalesce(r.currency, base)), ob.as_of);

    -- supplier_invoice_lines.deal_item_id is not-null by design: a bill line
    -- with no order line has nothing to match against. An opening bill has
    -- nothing to match either, so it gets a line on its own hidden order.
    insert into public.deal_items (deal_id, description, qty, unit_price, position)
    values (did, 'Opening balance carried over', 1, r.amount_foreign,
            coalesce((select max(di.position) + 1 from public.deal_items di
                       where di.deal_id = did), 1))
    returning id into lid;

    insert into public.supplier_invoices (company_id, deal_id, party_id, doc_no,
                                          supplier_ref, invoice_date, due_date,
                                          currency, fx_rate, tax_amount, is_final,
                                          status, is_opening, note,
                                          base_value, accrual_cleared, cost_difference,
                                          created_by, posted_at, posted_by)
    values (ob.company_id, did, r.party_id,
            public.next_doc_no(ob.company_id, 'supplier_invoice',
                               extract(year from r.invoice_date)::int),
            btrim(r.their_ref), r.invoice_date,
            coalesce(r.due_date, r.invoice_date),
            upper(coalesce(r.currency, base)), rt, 0, true, 'posted', true,
            'Opening unpaid bill', amt, 0, 0,
            (select auth.uid()), now(), (select auth.uid()))
    returning id into iid;

    insert into public.supplier_invoice_lines (invoice_id, deal_item_id, qty,
                                               unit_price, discount, note)
    values (iid, lid, 1, r.amount_foreign, 0, 'Opening balance carried over');

    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code, party_id,
                                      debit, credit, foreign_currency,
                                      foreign_amount, fx_rate, memo)
    values (jid, ln, '2100', r.party_id, 0, amt,
            nullif(upper(coalesce(r.currency, base)), base), r.amount_foreign, rt,
            'Opening supplier balance');
    net_dr := net_dr - amt;

    update public.opening_balance_lines
       set amount_base = amt, created_deal_id = did, created_invoice_id = iid
     where id = r.id;
  end loop;

  -- -------------------------- opening bank ---------------------------
  for r in select * from public.opening_balance_lines
            where opening_id = p_opening and kind = 'bank' order by id loop

    select b.gl_code, b.currency into bcode, bcur
      from public.bank_accounts b
     where b.id = r.bank_account_id and b.active;
    if bcode is null then
      raise exception 'That bank account is missing, inactive, or has no ledger account on it.';
    end if;
    -- The same restriction payment_plan enforces: a foreign bank balance needs
    -- period-end revaluation, which this phase does not build.
    if bcur <> base then
      raise exception
        'Opening bank balances must be held in %, not % - a foreign bank balance needs revaluation first.',
        base, bcur;
    end if;

    amt := round(r.amount_foreign, dec);

    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code,
                                      debit, credit, memo)
    values (jid, ln, bcode, amt, 0,
            'Opening bank balance'
            || case when btrim(r.label) <> '' then ' - ' || btrim(r.label) else '' end);
    net_dr := net_dr + amt;

    update public.opening_balance_lines set amount_base = amt where id = r.id;
  end loop;

  -- ------------------------- the contra line -------------------------
  if net_dr = 0 then
    raise exception
      'The opening lines net to zero against the contra account, so there is no opening position to post.';
  end if;

  ln := ln + 1;
  if net_dr > 0 then
    insert into public.journal_lines (journal_id, line_no, account_code,
                                      debit, credit, memo)
    values (jid, ln, '3100', 0, net_dr, 'Opening balance ' || docno);
  else
    insert into public.journal_lines (journal_id, line_no, account_code,
                                      debit, credit, memo)
    values (jid, ln, '3100', -net_dr, 0, 'Opening balance ' || docno);
  end if;

  -- Flipping to posted is what fires the debit-equals-credit trigger, so a
  -- one-sided opening entry is refused by the database, not by this function.
  update public.journals set status = 'posted' where id = jid;

  update public.opening_balances
     set doc_no = docno, status = 'posted', journal_id = jid,
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_opening;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('opening_balances', p_opening, 'posted', (select auth.uid()), ob.note,
          jsonb_build_object('doc_no', docno, 'journal', jid, 'journal_no', jdoc,
                             'as_of', ob.as_of, 'net_debit', net_dr,
                             'lines', ln));

  return jid;
end;
$fn$;

-- ========================= CANCELLATION =============================
-- A correction to opening data is a cancellation and a re-import, because the
-- one-posted-document-per-company index leaves no way to top it up.
--
-- The created invoices are marked cancelled rather than deleted: the open-items
-- views all filter `status = 'posted'`, so cancelling removes them from every
-- balance while leaving the trail of what was imported. The hidden opening
-- orders stay too - they are excluded from the reports, and a re-import reuses
-- them.

create or replace function public.cancel_opening_balance(
  p_opening uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  ob   public.opening_balances;
  r    record;
  oldq numeric;
  olda numeric;
  newq numeric;
  n    int := 0;
begin
  if not private.is_owner() then
    raise exception 'Only the owner can cancel an opening balance.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why the opening balance is being cancelled.';
  end if;

  select * into ob from public.opening_balances where id = p_opening for update;
  if ob.id is null then
    raise exception 'That opening balance does not exist.';
  end if;
  if ob.status = 'cancelled' then
    return;
  end if;

  if ob.status = 'draft' then
    delete from public.opening_balances where id = p_opening;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('opening_balances', p_opening, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  perform public.assert_period_open(ob.company_id, current_date);

  -- Money collected or paid against an opening invoice would be left settling
  -- an invoice that no longer stands.
  if exists (
    select 1
      from public.opening_balance_lines l
      join public.payment_allocations a
        on a.sales_invoice_id = l.created_invoice_id
        or a.supplier_invoice_id = l.created_invoice_id
      join public.payments pm on pm.id = a.payment_id
     where l.opening_id = p_opening and pm.status = 'posted') then
    raise exception
      'A posted payment is allocated to one of these opening invoices. Reverse that payment first.';
  end if;

  -- Take the opening stock back out at the cost it came in at.
  for r in select * from public.opening_balance_lines
            where opening_id = p_opening and kind = 'stock' order by id loop

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = r.item_id and warehouse_id = r.warehouse_id
       for update;

    newq := coalesce(oldq, 0) - r.qty;
    if newq < 0 then
      raise exception
        'Opening stock for one of these items has already been sold or moved, so it cannot be taken back out. Reverse those movements first.';
    end if;

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (r.item_id, r.warehouse_id, -r.qty, r.unit_cost,
            'opening_balances_cancel', p_opening, current_date, (select auth.uid()));

    update public.item_costs
       set qty_on_hand = newq,
           avg_cost    = case when newq = 0 then 0
                         else greatest(round((oldq * olda - r.qty * r.unit_cost)
                                             / newq, 6), 0) end,
           updated_at  = now()
     where item_id = r.item_id and warehouse_id = r.warehouse_id;
  end loop;

  update public.sales_invoices si
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()),
         cancel_reason = 'Opening balance cancelled: ' || btrim(p_reason)
   where si.id in (select l.created_invoice_id from public.opening_balance_lines l
                    where l.opening_id = p_opening and l.kind = 'customer_invoice'
                      and l.created_invoice_id is not null);

  update public.supplier_invoices sv
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()),
         cancel_reason = 'Opening balance cancelled: ' || btrim(p_reason)
   where sv.id in (select l.created_invoice_id from public.opening_balance_lines l
                    where l.opening_id = p_opening and l.kind = 'supplier_invoice'
                      and l.created_invoice_id is not null);

  for r in select id from public.journals
            where source_table = 'opening_balances' and source_id = p_opening
              and status = 'posted' loop
    perform public.reverse_journal(r.id, 'Opening balance cancelled: ' || btrim(p_reason));
    n := n + 1;
  end loop;

  update public.opening_balances
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_opening;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('opening_balances', p_opening, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('doc_no', ob.doc_no, 'journals_reversed', n));
end;
$fn$;

-- ============ KEEP THE HIDDEN ORDERS OUT OF OPEN ORDERS =============
-- The synthetic opening orders carry a deal_item on the supplier side, so
-- without this they would show up as orders with goods still to come. They are
-- not orders and nothing is coming; the opening BILL is what is outstanding,
-- and supplier_open_items already reports that through its invoice branch.

create or replace view public.open_orders
with (security_invoker = true) as
  select d.id            as deal_id,
         d.doc_no,
         d.direction,
         d.reference,
         d.party,
         d.party_id,
         d.status,
         d.deal_date,
         s.currency,
         s.cur_decimals,
         s.bill_total,
         s.paid,
         s.amount_left,
         count(op.deal_item_id)      as lines,
         sum(op.qty_ordered)         as qty_ordered,
         sum(op.qty_accepted)        as qty_settled,
         sum(op.qty_outstanding)     as qty_outstanding,
         sum(round(op.qty_outstanding * op.unit_price, 6)) as value_outstanding,
         case when d.direction = 'sending' then 'purchase' else 'sale' end as side
    from public.deals d
    join public.deal_summary s    on s.deal_id = d.id
    join public.order_progress op on op.deal_id = d.id
   where d.deleted_at is null
     and d.status <> 'cancelled'
     and coalesce(d.reference, '') <> 'OPENING'
   group by d.id, d.doc_no, d.direction, d.reference, d.party, d.party_id,
            d.status, d.deal_date, s.currency, s.cur_decimals,
            s.bill_total, s.paid, s.amount_left
  having sum(op.qty_outstanding) > 0 or s.amount_left > 0;

-- ===================== WHAT WAS CARRIED OVER ========================
-- Spec page 12: "Reconcile all opening balances." This is that reconciliation
-- - the imported figures grouped the way the ledger holds them.

create or replace view public.opening_balance_summary
with (security_invoker = true) as
  select o.id            as opening_id,
         o.company_id,
         o.doc_no,
         o.as_of,
         o.status,
         o.journal_id,
         l.kind,
         case l.kind
           when 'stock'            then '1300'
           when 'customer_invoice' then '1200'
           when 'supplier_invoice' then '2100'
           else 'bank'
         end as account_code,
         count(*)                               as lines,
         sum(l.amount_base)                     as imported_base,
         c.base_currency,
         public.currency_decimals(c.base_currency) as cur_decimals
    from public.opening_balances o
    join public.opening_balance_lines l on l.opening_id = o.id
    join public.companies c on c.id = o.company_id
   group by o.id, o.company_id, o.doc_no, o.as_of, o.status, o.journal_id,
            l.kind, c.base_currency;
