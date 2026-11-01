-- ERP phase 3: the sales path as separate documents.
--
-- Requires erp_phase1 (items, item_costs, stock_moves, journals, doc_sequences),
-- erp_phase5 (post_event, reverse_journal, assert_period_open) and the phase 2
-- conventions (draft-only client writes, cancel-not-delete).
--
-- Spec page 7: quotation -> sales order -> reservation -> delivery -> invoice,
-- plus customer returns. The three events that matter are kept apart, because
-- running them together is how stock and revenue drift:
--
--   APPROVE + RESERVE  promises goods. No stock leaves, no money is earned.
--   DELIVER            takes the goods out and releases their cost to COGS.
--   INVOICE            earns the revenue and creates the customer debt.
--
-- The sales order itself is an existing `deals` row with direction='receiving',
-- the mirror of the purchase order, per the extend-in-place decision.

-- ===================== QUANTITIES AND PARTY CODES =====================

-- Reserved is promised-but-still-here. item_costs.qty_reserved (phase 1) holds
-- the warehouse total; this holds each order's share, so releasing one order
-- cannot release another order's goods.
alter table public.deal_items
  add column if not exists qty_reserved numeric not null default 0;

-- Phase 4 allocates customer receipts to specific sales invoices.
alter table public.payment_allocations
  add column if not exists sales_invoice_id uuid;

-- Spec page 3: CUS-000001 / SUP-000001, never reusing a retired code.
create or replace function public.next_party_code(p_company uuid, p_kind text)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  pfx  text := case when p_kind = 'customer' then 'CUS-' else 'SUP-' end;
  seq  text := 'party_' || p_kind;
  n    int;
  code text;
begin
  if p_kind not in ('customer', 'supplier') then
    raise exception 'A party code is either customer or supplier, not "%".', p_kind;
  end if;

  insert into public.doc_sequences (company_id, doc_type, year, next_no)
  values (p_company, seq, 0, 1)
  on conflict (company_id, doc_type, year) do nothing;

  -- Walk past anything already taken: phase 1 handed SUP- codes to the
  -- accounts that existed without touching this counter.
  loop
    update public.doc_sequences
       set next_no = next_no + 1
     where company_id = p_company and doc_type = seq and year = 0
    returning next_no - 1 into n;

    code := pfx || lpad(n::text, 6, '0');
    exit when not exists (
      select 1 from public.parties
       where cus_code = code or sup_code = code);
  end loop;

  return code;
end;
$fn$;

-- ============================= DELIVERIES =============================
-- Spec page 23: posting the delivery removes the goods and releases their
-- stock cost. A sales invoice posted later must not remove them again.

create table if not exists public.deliveries (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies(id),
  deal_id        uuid not null references public.deals(id),
  doc_no         text,
  warehouse_id   uuid not null references public.warehouses(id),
  delivered_on   date not null default current_date,
  picking_status text not null default 'picking'
                   check (picking_status in ('picking', 'checked')),
  status         text not null default 'draft'
                   check (status in ('draft', 'posted', 'cancelled')),
  note           text not null default '',
  created_at     timestamptz not null default now(),
  created_by     uuid references auth.users(id),
  posted_at      timestamptz,
  posted_by      uuid references auth.users(id),
  cancelled_at   timestamptz,
  cancelled_by   uuid references auth.users(id),
  cancel_reason  text not null default ''
);

create index if not exists deliveries_deal_idx on public.deliveries (deal_id);

create table if not exists public.delivery_lines (
  id            uuid primary key default gen_random_uuid(),
  delivery_id   uuid not null references public.deliveries(id) on delete cascade,
  deal_item_id  uuid references public.deal_items(id),
  item_id       uuid references public.items(id),
  qty_ordered   numeric not null default 0 check (qty_ordered   >= 0),
  qty_picked    numeric not null default 0 check (qty_picked    >= 0),
  qty_delivered numeric not null default 0 check (qty_delivered >= 0),
  -- Filled in at posting from the weighted average and then kept, so
  -- cancelling puts the goods back at the cost they actually left on.
  unit_cost     numeric not null default 0 check (unit_cost >= 0),
  note          text not null default '',
  -- You cannot hand over more than was picked off the shelf.
  check (qty_delivered <= qty_picked)
);

create index if not exists delivery_lines_delivery_idx on public.delivery_lines (delivery_id);

-- =========================== SALES INVOICES ===========================
-- Spec page 24. Separate from the delivery because they can fall on
-- different dates, and separate from `invoices`, which holds the SUPPLIER
-- invoice files already attached to purchase orders.

create table if not exists public.sales_invoices (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  deal_id       uuid not null references public.deals(id),
  delivery_id   uuid references public.deliveries(id),
  party_id      uuid references public.parties(id),
  doc_no        text,
  invoice_date  date not null default current_date,
  due_date      date,
  currency      text not null default 'KWD',
  fx_rate       numeric check (fx_rate is null or fx_rate > 0),
  -- Present but zero and unconfigured, per the recorded assumption: a tax
  -- setup has to be approved for the company before launch (spec page 1).
  tax_amount    numeric not null default 0 check (tax_amount >= 0),
  status        text not null default 'draft'
                  check (status in ('draft', 'posted', 'cancelled')),
  note          text not null default '',
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id),
  posted_at     timestamptz,
  posted_by     uuid references auth.users(id),
  cancelled_at  timestamptz,
  cancelled_by  uuid references auth.users(id),
  cancel_reason text not null default ''
);

create index if not exists sales_invoices_deal_idx  on public.sales_invoices (deal_id);
create index if not exists sales_invoices_party_idx on public.sales_invoices (party_id);

create table if not exists public.sales_invoice_lines (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.sales_invoices(id) on delete cascade,
  deal_item_id uuid references public.deal_items(id),
  item_id      uuid references public.items(id),
  description  text not null default '',
  qty          numeric not null check (qty > 0),
  unit_price   numeric not null default 0 check (unit_price >= 0),
  discount     numeric not null default 0 check (discount >= 0)
);

create index if not exists sales_invoice_lines_invoice_idx
  on public.sales_invoice_lines (invoice_id);

-- ===================== RETURNS AND CREDIT NOTES =======================
-- Spec page 27: a valid customer return reduces sales and receivable, and
-- restores accepted goods at the appropriate original cost. Goods that come
-- back broken are credited but not put back on the shelf, so restock is a
-- decision per line rather than per document.

create table if not exists public.credit_notes (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  deal_id       uuid not null references public.deals(id),
  invoice_id    uuid references public.sales_invoices(id),
  party_id      uuid references public.parties(id),
  warehouse_id  uuid not null references public.warehouses(id),
  doc_no        text,
  note_date     date not null default current_date,
  currency      text not null default 'KWD',
  fx_rate       numeric check (fx_rate is null or fx_rate > 0),
  reason        text not null default '',
  status        text not null default 'draft'
                  check (status in ('draft', 'posted', 'cancelled')),
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id),
  posted_at     timestamptz,
  posted_by     uuid references auth.users(id)
);

create index if not exists credit_notes_deal_idx on public.credit_notes (deal_id);

create table if not exists public.credit_note_lines (
  id             uuid primary key default gen_random_uuid(),
  credit_note_id uuid not null references public.credit_notes(id) on delete cascade,
  deal_item_id   uuid references public.deal_items(id),
  item_id        uuid references public.items(id),
  qty            numeric not null check (qty > 0),
  unit_price     numeric not null default 0 check (unit_price >= 0),
  unit_cost      numeric not null default 0 check (unit_cost  >= 0),
  -- Accepted back onto the shelf, or credited but written off.
  restock        boolean not null default true
);

create index if not exists credit_note_lines_note_idx
  on public.credit_note_lines (credit_note_id);

-- ======================== POSTING TEMPLATES ===========================
-- Spec page 9 lists thirteen events and then says plainly that returns need
-- their own approved templates. These are those two, and like the other
-- thirteen they are rows an accountant can review, not account codes buried
-- in app.js.

insert into public.posting_templates (event, label, path, debit_code, credit_code, note)
values
  ('sales_credit_note', 'Customer return / credit note', 'common', '4000', '1200',
   'Reverses the sale and what the customer owes. The goods move separately.'),
  ('return_to_stock', 'Return accepted back into stock', 'common', '1300', '5000',
   'Puts accepted goods back at their original cost and unwinds that COGS.')
on conflict (event) do nothing;

-- ================================ RLS =================================
-- Read for any signed-in user; writes only while the document is a draft --
-- the rule established in erp_phase2_only_drafts_are_editable.sql. A posted
-- document moves on only through the security-definer functions below.

alter table public.deliveries          enable row level security;
alter table public.delivery_lines      enable row level security;
alter table public.sales_invoices      enable row level security;
alter table public.sales_invoice_lines enable row level security;
alter table public.credit_notes        enable row level security;
alter table public.credit_note_lines   enable row level security;

do $do$
declare t text;
begin
  -- Headers: insert, update and delete only while status = 'draft'.
  foreach t in array array['deliveries', 'sales_invoices', 'credit_notes']
  loop
    execute format('drop policy if exists %I_read   on public.%I', t, t);
    execute format('drop policy if exists %I_write  on public.%I', t, t);
    execute format('drop policy if exists %I_insert on public.%I', t, t);
    execute format('drop policy if exists %I_update on public.%I', t, t);
    execute format('drop policy if exists %I_delete on public.%I', t, t);

    execute format(
      'create policy %I_read on public.%I for select to authenticated using (true)',
      t, t);
    execute format(
      'create policy %I_insert on public.%I for insert to authenticated '
      'with check (private.can_edit() and status = %L)', t, t, 'draft');
    execute format(
      'create policy %I_update on public.%I for update to authenticated '
      'using (private.can_edit() and status = %L) '
      'with check (private.can_edit() and status = %L)', t, t, 'draft', 'draft');
    execute format(
      'create policy %I_delete on public.%I for delete to authenticated '
      'using (private.can_edit() and status = %L)', t, t, 'draft');
  end loop;
end
$do$;

do $do$
declare r record;
begin
  -- Lines: writable only while their parent header is still a draft.
  for r in select * from (values
      ('delivery_lines',      'delivery_id',    'deliveries'),
      ('sales_invoice_lines', 'invoice_id',     'sales_invoices'),
      ('credit_note_lines',   'credit_note_id', 'credit_notes')
    ) as v(tbl, fk, parent)
  loop
    execute format('drop policy if exists %I_read  on public.%I', r.tbl, r.tbl);
    execute format('drop policy if exists %I_write on public.%I', r.tbl, r.tbl);

    execute format(
      'create policy %I_read on public.%I for select to authenticated using (true)',
      r.tbl, r.tbl);
    execute format(
      'create policy %I_write on public.%I for all to authenticated '
      'using (private.can_edit() and exists (select 1 from public.%I p '
      'where p.id = public.%I.%I and p.status = %L)) '
      'with check (private.can_edit() and exists (select 1 from public.%I p '
      'where p.id = public.%I.%I and p.status = %L))',
      r.tbl, r.tbl, r.parent, r.tbl, r.fk, 'draft',
                    r.parent, r.tbl, r.fk, 'draft');
  end loop;
end
$do$;

-- ===================== APPROVE AND RESERVE ============================
-- Spec page 22: approval and reservation create neither revenue nor a stock
-- movement. All they do is promise goods, and refuse to promise the same
-- ones twice.

create or replace function public.approve_sales_order(p_deal uuid)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  d     public.deals;
  p     public.parties;
  docno text;
  value numeric;
  owing numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to approve orders.';
  end if;

  select * into d from public.deals where id = p_deal and deleted_at is null;
  if not found then
    raise exception 'That order does not exist.';
  end if;
  if d.direction <> 'receiving' then
    raise exception 'Only a sale can be approved as a sales order.';
  end if;
  if d.status not in ('draft', 'legacy') then
    raise exception 'This order is already %.', d.status;
  end if;
  if d.company_id is null then
    raise exception 'Link this order to the company before approving it.';
  end if;

  select coalesce(sum(di.amount), 0) * (1 - coalesce(d.discount_pct, 0) / 100.0)
    into value
    from public.deal_items di where di.deal_id = p_deal;

  -- Credit check (spec page 7 step 2): what they already owe, plus this.
  if d.party_id is not null then
    select * into p from public.parties where id = d.party_id;
    if p.credit_limit > 0 then
      select coalesce(sum(o.outstanding), 0) into owing
        from public.customer_open_items o where o.party_id = d.party_id;

      if owing + value > p.credit_limit then
        raise exception
          'Credit limit: % already owes %, this order adds % and the limit is %.',
          p.name, round(owing, 3), round(value, 3), p.credit_limit;
      end if;
    end if;
  end if;

  docno := public.next_doc_no(d.company_id, 'sales_order',
                              extract(year from d.deal_date)::int);

  update public.deals
     set doc_no = coalesce(doc_no, docno), doc_type = 'sales_order',
         status = 'approved',
         approved_at = now(), approved_by = (select auth.uid())
   where id = p_deal;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deals', p_deal, 'approved', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'order_value', value));

  return docno;
end;
$fn$;

-- Reserved stock is still physically here, so it never touches qty_on_hand.
-- It only stops the same unit being promised to a second customer.
create or replace function public.reserve_sales_order(p_deal uuid)
returns numeric language plpgsql security definer set search_path to '' as $fn$
declare
  d     public.deals;
  wh    uuid;
  ln    record;
  need  numeric;
  avail numeric;
  done  numeric := 0;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to reserve stock.';
  end if;

  select * into d from public.deals where id = p_deal and deleted_at is null;
  if not found then
    raise exception 'That order does not exist.';
  end if;
  if d.direction <> 'receiving' then
    raise exception 'Only a sale reserves stock.';
  end if;
  if d.status <> 'approved' then
    raise exception 'Approve the order before reserving stock for it.';
  end if;

  wh := coalesce(d.warehouse_id,
                 (select w.id from public.warehouses w
                   where w.company_id = d.company_id order by w.code limit 1));
  if wh is null then
    raise exception 'This company has no warehouse to reserve from.';
  end if;

  for ln in select di.* from public.deal_items di
             where di.deal_id = p_deal and di.item_id is not null
             order by di.id loop

    -- What is still promised but neither delivered nor already held.
    need := ln.qty - ln.qty_delivered - ln.qty_reserved;
    if need <= 0 then
      continue;
    end if;

    insert into public.item_costs (item_id, warehouse_id, qty_on_hand, avg_cost)
    values (ln.item_id, wh, 0, 0)
    on conflict (item_id, warehouse_id) do nothing;

    select qty_on_hand - qty_reserved into avail
      from public.item_costs
     where item_id = ln.item_id and warehouse_id = wh
       for update;

    if coalesce(avail, 0) < need then
      raise exception
        'Only % of % units are free to promise -- the rest are on hand but already reserved.',
        greatest(coalesce(avail, 0), 0), need;
    end if;

    update public.item_costs
       set qty_reserved = qty_reserved + need, updated_at = now()
     where item_id = ln.item_id and warehouse_id = wh;

    update public.deal_items
       set qty_reserved = qty_reserved + need,
           warehouse_id = coalesce(warehouse_id, wh)
     where id = ln.id;

    done := done + need;
  end loop;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deals', p_deal, 'reserved', (select auth.uid()), '',
          jsonb_build_object('qty_reserved', done, 'warehouse', wh));

  return done;
end;
$fn$;

-- Releasing a reservation is not a stock movement either: the goods never
-- went anywhere. Each order gives back exactly its own share.
create or replace function public.release_sales_order(p_deal uuid)
returns numeric language plpgsql security definer set search_path to '' as $fn$
declare
  d    public.deals;
  ln   record;
  wh   uuid;
  done numeric := 0;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to release stock.';
  end if;

  select * into d from public.deals where id = p_deal;
  if not found then
    raise exception 'That order does not exist.';
  end if;

  for ln in select di.* from public.deal_items di
             where di.deal_id = p_deal and di.qty_reserved > 0 loop

    wh := coalesce(ln.warehouse_id, d.warehouse_id);
    if wh is not null and ln.item_id is not null then
      update public.item_costs
         set qty_reserved = greatest(qty_reserved - ln.qty_reserved, 0),
             updated_at   = now()
       where item_id = ln.item_id and warehouse_id = wh;
    end if;

    done := done + ln.qty_reserved;
    update public.deal_items set qty_reserved = 0 where id = ln.id;
  end loop;

  return done;
end;
$fn$;

-- ========================== POST A DELIVERY ===========================
-- Spec page 23. Three things together or none: the goods leave, their cost
-- is released to cost of sales, and the order's delivered quantities move.

create or replace function public.post_delivery(p_delivery uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  d     public.deliveries;
  base  text;
  docno text;
  total numeric := 0;
  jid   uuid;
  ln    record;
  oldq  numeric;
  olda  numeric;
  rel   numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;

  select * into d from public.deliveries where id = p_delivery;
  if not found then
    raise exception 'That delivery note does not exist.';
  end if;
  if d.status <> 'draft' then
    raise exception 'This delivery is already %. Only a draft can be posted.', d.status;
  end if;
  if d.picking_status <> 'checked' then
    raise exception 'Confirm the picking check before posting the delivery.';
  end if;

  select c.base_currency into base from public.companies c where c.id = d.company_id;
  perform public.assert_period_open(d.company_id, d.delivered_on);

  if not exists (select 1 from public.delivery_lines l
                  where l.delivery_id = p_delivery and l.qty_delivered > 0) then
    raise exception 'Nothing was delivered on this note, so there is nothing to post.';
  end if;

  docno := public.next_doc_no(d.company_id, 'delivery',
                              extract(year from d.delivered_on)::int);

  for ln in select l.*, coalesce(l.item_id, di.item_id) as use_item
              from public.delivery_lines l
              left join public.deal_items di on di.id = l.deal_item_id
             where l.delivery_id = p_delivery and l.qty_delivered > 0
             order by l.id loop

    if ln.use_item is null then
      raise exception 'A delivery line has no item on file. Link it to an item first.';
    end if;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = d.warehouse_id
       for update;

    if oldq is null then
      raise exception 'That item has never been in this warehouse, so none can leave it.';
    end if;

    -- Negative stock is blocked, per the recorded assumption.
    if oldq < ln.qty_delivered then
      raise exception 'Only % of % units are on hand. Receive the rest before delivering.',
        oldq, ln.qty_delivered;
    end if;

    -- Weighted average: goods leave AT the running average, which is exactly
    -- why issuing them does not move it.
    total := total + round(ln.qty_delivered * olda, public.currency_decimals(base));
    update public.delivery_lines set unit_cost = olda where id = ln.id;

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, d.warehouse_id, -ln.qty_delivered, olda,
            'deliveries', p_delivery, d.delivered_on, (select auth.uid()));

    -- The goods have gone, so the promise over them is spent.
    rel := 0;
    if ln.deal_item_id is not null then
      select least(qty_reserved, ln.qty_delivered) into rel
        from public.deal_items where id = ln.deal_item_id;
      rel := coalesce(rel, 0);

      update public.deal_items
         set qty_delivered = qty_delivered + ln.qty_delivered,
             qty_reserved  = greatest(qty_reserved - rel, 0)
       where id = ln.deal_item_id;
    end if;

    update public.item_costs
       set qty_on_hand  = oldq - ln.qty_delivered,
           qty_reserved = greatest(qty_reserved - rel, 0),
           updated_at   = now()
     where item_id = ln.use_item and warehouse_id = d.warehouse_id;
  end loop;

  if total <= 0 then
    raise exception
      'The delivered goods have no cost on file, so nothing can be released to cost of sales.';
  end if;

  jid := public.post_event(
    p_company => d.company_id, p_event => 'delivery_cost',
    p_source_table => 'deliveries', p_source_id => p_delivery,
    p_amount => total, p_currency => base, p_entry_date => d.delivered_on,
    p_warehouse => d.warehouse_id,
    p_memo => 'Delivery ' || docno);

  update public.stock_moves set journal_id = jid
   where source_table = 'deliveries' and source_id = p_delivery and journal_id is null;

  update public.deliveries
     set doc_no = docno, status = 'posted',
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_delivery;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deliveries', p_delivery, 'posted', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'cost_released', total, 'journal', jid));

  return jid;
end;
$fn$;

-- ======================= DELETE A POSTED DELIVERY =====================
-- The mirror of cancel_goods_receipt: the row stays, the goods come back at
-- the cost they left on, and the journal is reversed.

create or replace function public.cancel_delivery(p_delivery uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  d    public.deliveries;
  j    uuid;
  ln   record;
  oldq numeric;
  olda numeric;
  newq numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change this.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this delivery is being cancelled.';
  end if;

  select * into d from public.deliveries where id = p_delivery;
  if not found then
    raise exception 'That delivery note does not exist.';
  end if;
  if d.status = 'cancelled' then
    return;
  end if;

  -- A draft never moved anything, so it can simply go.
  if d.status = 'draft' then
    delete from public.deliveries where id = p_delivery;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('deliveries', p_delivery, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  if not private.is_owner() then
    raise exception 'This delivery is posted. Only the owner can cancel it.';
  end if;

  -- An invoice standing on this delivery would be left describing goods
  -- that never left the building.
  if exists (select 1 from public.sales_invoices si
              where si.delivery_id = p_delivery and si.status = 'posted') then
    raise exception
      'A posted sales invoice stands on this delivery. Credit that invoice first.';
  end if;

  perform public.assert_period_open(d.company_id, current_date);

  for ln in select l.*, coalesce(l.item_id, di.item_id) as use_item
              from public.delivery_lines l
              left join public.deal_items di on di.id = l.deal_item_id
             where l.delivery_id = p_delivery and l.qty_delivered > 0 loop

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = d.warehouse_id
       for update;

    newq := coalesce(oldq, 0) + ln.qty_delivered;

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, d.warehouse_id, ln.qty_delivered, ln.unit_cost,
            'deliveries_cancel', p_delivery, current_date, (select auth.uid()));

    -- Blend the returning goods back in at the cost they left on.
    update public.item_costs
       set qty_on_hand = newq,
           avg_cost    = case when newq = 0 then 0
                         else round((coalesce(oldq, 0) * coalesce(olda, 0)
                                     + ln.qty_delivered * ln.unit_cost) / newq, 6) end,
           updated_at  = now()
     where item_id = ln.use_item and warehouse_id = d.warehouse_id;

    if ln.deal_item_id is not null then
      update public.deal_items
         set qty_delivered = greatest(qty_delivered - ln.qty_delivered, 0)
       where id = ln.deal_item_id;
    end if;
  end loop;

  select id into j from public.journals
   where source_table = 'deliveries' and source_id = p_delivery
     and status = 'posted' limit 1;
  if j is not null then
    perform public.reverse_journal(j, 'Delivery cancelled: ' || btrim(p_reason));
  end if;

  update public.deliveries
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_delivery;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deliveries', p_delivery, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('reversed_journal', j));
end;
$fn$;

-- ======================= POST A SALES INVOICE =========================
-- Spec page 24: this earns the revenue and creates the debt. It moves no
-- goods -- the delivery already did that.

create or replace function public.post_sales_invoice(p_invoice uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  inv   public.sales_invoices;
  terms int := 0;
  docno text;
  net   numeric;
  total numeric;
  jid   uuid;
  ln    record;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;

  select * into inv from public.sales_invoices where id = p_invoice;
  if not found then
    raise exception 'That sales invoice does not exist.';
  end if;
  if inv.status <> 'draft' then
    raise exception 'This invoice is already %. Only a draft can be posted.', inv.status;
  end if;
  if inv.party_id is null then
    raise exception 'A sales invoice needs the customer it is addressed to.';
  end if;

  perform public.assert_period_open(inv.company_id, inv.invoice_date);

  select coalesce(sum(l.qty * l.unit_price - l.discount), 0) into net
    from public.sales_invoice_lines l where l.invoice_id = p_invoice;

  total := net + coalesce(inv.tax_amount, 0);
  if total <= 0 then
    raise exception 'This invoice adds up to nothing, so there is no sale to post.';
  end if;

  docno := public.next_doc_no(inv.company_id, 'sales_invoice',
                              extract(year from inv.invoice_date)::int);

  select coalesce(p.payment_terms_days, 0) into terms
    from public.parties p where p.id = inv.party_id;

  jid := public.post_event(
    p_company => inv.company_id, p_event => 'credit_sales_invoice',
    p_source_table => 'sales_invoices', p_source_id => p_invoice,
    p_amount => total, p_currency => inv.currency, p_entry_date => inv.invoice_date,
    p_rate => inv.fx_rate, p_party => inv.party_id,
    p_memo => 'Sales invoice ' || docno);

  -- Invoiced quantities are tracked apart from delivered ones (spec page 11).
  for ln in select l.* from public.sales_invoice_lines l
             where l.invoice_id = p_invoice and l.deal_item_id is not null loop
    update public.deal_items
       set qty_invoiced = qty_invoiced + ln.qty
     where id = ln.deal_item_id;
  end loop;

  update public.sales_invoices
     set doc_no = docno, status = 'posted',
         due_date = coalesce(due_date, inv.invoice_date + terms),
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_invoice;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('sales_invoices', p_invoice, 'posted', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'amount', total,
                             'currency', inv.currency, 'journal', jid));

  return jid;
end;
$fn$;

create or replace function public.cancel_sales_invoice(p_invoice uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  inv public.sales_invoices;
  j   uuid;
  ln  record;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change this.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this invoice is being cancelled.';
  end if;

  select * into inv from public.sales_invoices where id = p_invoice;
  if not found then
    raise exception 'That sales invoice does not exist.';
  end if;
  if inv.status = 'cancelled' then
    return;
  end if;

  if inv.status = 'draft' then
    delete from public.sales_invoices where id = p_invoice;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('sales_invoices', p_invoice, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  if not private.is_owner() then
    raise exception 'This invoice is posted. Only the owner can cancel it.';
  end if;

  perform public.assert_period_open(inv.company_id, current_date);

  for ln in select l.* from public.sales_invoice_lines l
             where l.invoice_id = p_invoice and l.deal_item_id is not null loop
    update public.deal_items
       set qty_invoiced = greatest(qty_invoiced - ln.qty, 0)
     where id = ln.deal_item_id;
  end loop;

  select id into j from public.journals
   where source_table = 'sales_invoices' and source_id = p_invoice
     and status = 'posted' limit 1;
  if j is not null then
    perform public.reverse_journal(j, 'Invoice cancelled: ' || btrim(p_reason));
  end if;

  update public.sales_invoices
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_invoice;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('sales_invoices', p_invoice, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('reversed_journal', j));
end;
$fn$;

-- ======================== POST A CREDIT NOTE ==========================
-- Spec page 27: money and goods move on separate tracks. The credit always
-- reduces the sale and the receivable; only accepted goods go back on the
-- shelf, so a note produces one journal or two.

create or replace function public.post_credit_note(p_note uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  cn     public.credit_notes;
  base   text;
  docno  text;
  credit numeric;
  cost   numeric := 0;
  jid    uuid;
  jstock uuid;
  ln     record;
  oldq   numeric;
  olda   numeric;
  newq   numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;

  select * into cn from public.credit_notes where id = p_note;
  if not found then
    raise exception 'That credit note does not exist.';
  end if;
  if cn.status <> 'draft' then
    raise exception 'This credit note is already %.', cn.status;
  end if;
  if cn.party_id is null then
    raise exception 'A credit note needs the customer it is issued to.';
  end if;

  select c.base_currency into base from public.companies c where c.id = cn.company_id;
  perform public.assert_period_open(cn.company_id, cn.note_date);

  select coalesce(sum(l.qty * l.unit_price), 0) into credit
    from public.credit_note_lines l where l.credit_note_id = p_note;
  if credit <= 0 then
    raise exception 'This credit note credits nothing.';
  end if;

  docno := public.next_doc_no(cn.company_id, 'credit_note',
                              extract(year from cn.note_date)::int);

  jid := public.post_event(
    p_company => cn.company_id, p_event => 'sales_credit_note',
    p_source_table => 'credit_notes', p_source_id => p_note,
    p_amount => credit, p_currency => cn.currency, p_entry_date => cn.note_date,
    p_rate => cn.fx_rate, p_party => cn.party_id,
    p_memo => 'Credit note ' || docno);

  -- Goods accepted back; rejected ones are credited but written off.
  for ln in select l.*, coalesce(l.item_id, di.item_id) as use_item
              from public.credit_note_lines l
              left join public.deal_items di on di.id = l.deal_item_id
             where l.credit_note_id = p_note and l.restock and l.qty > 0
             order by l.id loop

    if ln.use_item is null then
      raise exception 'A returned line has no item on file. Link it to an item first.';
    end if;

    insert into public.item_costs (item_id, warehouse_id, qty_on_hand, avg_cost)
    values (ln.use_item, cn.warehouse_id, 0, 0)
    on conflict (item_id, warehouse_id) do nothing;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = cn.warehouse_id
       for update;

    newq := coalesce(oldq, 0) + ln.qty;
    cost := cost + round(ln.qty * ln.unit_cost, public.currency_decimals(base));

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, cn.warehouse_id, ln.qty, ln.unit_cost,
            'credit_notes', p_note, cn.note_date, (select auth.uid()));

    update public.item_costs
       set qty_on_hand = newq,
           avg_cost    = case when newq = 0 then 0
                         else round((coalesce(oldq, 0) * coalesce(olda, 0)
                                     + ln.qty * ln.unit_cost) / newq, 6) end,
           updated_at  = now()
     where item_id = ln.use_item and warehouse_id = cn.warehouse_id;

    if ln.deal_item_id is not null then
      update public.deal_items
         set qty_delivered = greatest(qty_delivered - ln.qty, 0)
       where id = ln.deal_item_id;
    end if;
  end loop;

  if cost > 0 then
    jstock := public.post_event(
      p_company => cn.company_id, p_event => 'return_to_stock',
      p_source_table => 'credit_notes', p_source_id => p_note,
      p_amount => cost, p_currency => base, p_entry_date => cn.note_date,
      p_warehouse => cn.warehouse_id,
      p_memo => 'Return to stock ' || docno);

    update public.stock_moves set journal_id = jstock
     where source_table = 'credit_notes' and source_id = p_note and journal_id is null;
  end if;

  -- The credit reduces what was invoiced, restocked or not.
  for ln in select l.* from public.credit_note_lines l
             where l.credit_note_id = p_note and l.deal_item_id is not null loop
    update public.deal_items
       set qty_invoiced = greatest(qty_invoiced - ln.qty, 0)
     where id = ln.deal_item_id;
  end loop;

  update public.credit_notes
     set doc_no = docno, status = 'posted',
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_note;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('credit_notes', p_note, 'posted', (select auth.uid()), cn.reason,
          jsonb_build_object('doc_no', docno, 'credit', credit,
                             'stock_restored', cost,
                             'journal', jid, 'stock_journal', jstock));

  return jid;
end;
$fn$;

-- ============================== VIEWS =================================
-- Every view sets security_invoker, or it reads its base tables with the
-- view owner's rights, RLS never runs, and the whole table is readable by
-- anyone holding the publishable key.

-- On hand, promised, and what is genuinely free to sell (spec page 16).
create or replace view public.stock_available
with (security_invoker = true) as
  select c.item_id,
         i.code as item_code,
         i.brand,
         i.model,
         i.description,
         i.unit,
         i.stock_key,
         c.warehouse_id,
         w.code as warehouse_code,
         c.qty_on_hand,
         c.qty_reserved,
         greatest(c.qty_on_hand - c.qty_reserved, 0) as qty_available,
         c.avg_cost,
         round(c.qty_on_hand * c.avg_cost, 3) as stock_value
    from public.item_costs c
    join public.items i      on i.id = c.item_id
    join public.warehouses w on w.id = c.warehouse_id;

-- Posted sales invoices and what is still to collect, with the aging
-- buckets from spec page 8. Both a payment and a credit note reduce what is
-- owed: an early version subtracted only payments, so a credited invoice
-- still showed in full and the credit check above refused orders against
-- money the customer no longer owed. Spec page 8 is the test -- invoice 500,
-- collect 200, credit 50, remaining 250.
--
-- Dropped rather than replaced because `credited` lands before
-- `outstanding`, and create-or-replace cannot reorder a view's columns.
-- Phase 4 is what will start writing the allocations.
drop view if exists public.customer_open_items;

create view public.customer_open_items
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
         inv.amount - coalesce(al.allocated, 0) - coalesce(cr.credited, 0) as outstanding,
         case
           when si.due_date is null              then 'not due'
           when si.due_date >= current_date      then 'not due'
           when current_date - si.due_date <= 30 then '1-30'
           when current_date - si.due_date <= 60 then '31-60'
           when current_date - si.due_date <= 90 then '61-90'
           else 'over 90'
         end as age_bucket
    from public.sales_invoices si
    join public.parties p on p.id = si.party_id
    cross join lateral (
      select coalesce(sum(l.qty * l.unit_price - l.discount), 0)
               + coalesce(si.tax_amount, 0) as amount
        from public.sales_invoice_lines l where l.invoice_id = si.id
    ) inv
    left join lateral (
      select sum(a.amount) as allocated
        from public.payment_allocations a where a.sales_invoice_id = si.id
    ) al on true
    left join lateral (
      select sum(l.qty * l.unit_price) as credited
        from public.credit_notes cn
        join public.credit_note_lines l on l.credit_note_id = cn.id
       where cn.invoice_id = si.id and cn.status = 'posted'
    ) cr on true
   where si.status = 'posted';

-- Ordered / reserved / delivered / invoiced per order line: the sales-side
-- twin of order_progress, which follows the purchase side.
create or replace view public.sales_progress
with (security_invoker = true) as
  select di.id as deal_item_id,
         di.deal_id,
         d.reference,
         d.doc_no,
         d.party,
         d.party_id,
         d.status as order_status,
         d.deal_date,
         di.item_id,
         i.code as item_code,
         coalesce(nullif(btrim(di.model), ''), di.description) as item_label,
         di.brand,
         di.description,
         di.qty as qty_ordered,
         di.qty_reserved,
         di.qty_delivered,
         di.qty_invoiced,
         greatest(di.qty - di.qty_delivered, 0) as qty_to_deliver,
         greatest(di.qty_delivered - di.qty_invoiced, 0) as qty_to_invoice,
         di.unit_price,
         d.currency,
         public.currency_decimals(d.currency) as cur_decimals,
         case
           when di.qty_delivered = 0 and di.qty_reserved = 0 then 'not started'
           when di.qty_delivered = 0                         then 'reserved'
           when di.qty_delivered >= di.qty                   then 'delivered'
           else 'part delivered'
         end as fulfilment_state
    from public.deal_items di
    join public.deals d on d.id = di.deal_id
    left join public.items i on i.id = di.item_id
   where d.deleted_at is null
     and d.direction = 'receiving'
     and d.status <> 'cancelled';
