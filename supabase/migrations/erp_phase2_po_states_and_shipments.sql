-- ERP phase 2, the rest of it - part 1 of 2 (2026-11-05).
--
-- Applied as:
--   erp_phase2_doc_prefixes            (part 0, 2026-11-05)
--   erp_phase2_approve_purchase_order  (part 1, 2026-11-05)
--   erp_phase2_shipment_allocation     (part 2, 2026-11-07)
--
-- Part 2 of 2 is erp_phase2_supplier_invoicing_returns_advances.sql.
--
-- What phases 1-5 left unbuilt, from spec page 5 ("From supplier selection to
-- payment") and page 11 ("Draft -> approved -> posted -> reversed"):
--
--   1. A purchase order had no approved state. Spec page 17's screen has
--      "Save draft" and "Approve order", and approval is what records the
--      buying commitment and issues PO-2026-000001.
--   2. A shipment pointed at one order and remembered arrived quantities in a
--      jsonb blob. Spec page 5 step 2 wants PO quantities ALLOCATED to a
--      shipment, and the same page's rules require "one PO across several
--      shipments and several POs in one shipment" - a many-to-many link, which
--      a jsonb column on the shipment cannot express.
--
-- ONE PURCHASE PATH, NOT THREE. Spec page 9: "These are alternative posting
-- paths; do not post all of them for the same goods." `post_goods_receipt`
-- already hardcodes `receive_before_invoice`, so this company is on the
-- receipt-before-invoice (accrual) path, and part 2 of this phase follows it.
-- The `goods_in_transit` / `receive_from_transit` templates stay on file,
-- unused, for a company that later chooses that path.

-- ========================= PART 0: DOC PREFIXES =======================
-- 'supplier_invoice' -> PIN was already here, unused, from phase 1. The three
-- new document types get theirs now, plus OPN for phase 6's opening balances.

create or replace function public.doc_prefix(doc_type text)
returns text language sql immutable set search_path to '' as $fn$
  select case doc_type
    when 'purchase_order'      then 'PO'
    when 'shipment'            then 'SHP'
    when 'goods_receipt'       then 'GRN'
    when 'supplier_invoice'    then 'PIN'
    when 'supplier_return'     then 'SRN'
    when 'advance_application' then 'ADV'
    when 'landed_cost'         then 'LC'
    when 'sales_order'         then 'SO'
    when 'delivery'            then 'DN'
    when 'sales_invoice'       then 'INV'
    when 'customer_receipt'    then 'REC'
    when 'supplier_payment'    then 'PAY'
    when 'credit_note'         then 'CN'
    when 'fx_conversion'       then 'FX'
    when 'journal'             then 'JV'
    when 'opening_balance'     then 'OPN'
    else upper(substring(doc_type from 1 for 3))
  end
$fn$;

-- ================= PART 1: THE PURCHASE ORDER'S STATES ================
--
-- The mirror of approve_sales_order. No credit check - that one protects us
-- from a customer, and there is no equivalent exposure in buying - but the same
-- document-number-on-approval rule, so an approved order has a PO number and a
-- draft does not.

create or replace function public.approve_purchase_order(p_deal uuid)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  d     public.deals;
  docno text;
  value numeric;
  lines int;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to approve orders.';
  end if;

  select * into d from public.deals where id = p_deal and deleted_at is null;
  if not found then
    raise exception 'That order does not exist.';
  end if;
  if d.direction <> 'sending' then
    raise exception 'Only a purchase can be approved as a purchase order.';
  end if;
  if d.status not in ('draft', 'legacy') then
    raise exception 'This order is already %.', d.status;
  end if;
  if d.company_id is null then
    raise exception 'Link this order to the company before approving it.';
  end if;
  if d.party_id is null then
    raise exception 'Choose the supplier before approving the order.';
  end if;

  select count(*), coalesce(sum(di.amount), 0) * (1 - coalesce(d.discount_pct, 0) / 100.0)
    into lines, value
    from public.deal_items di where di.deal_id = p_deal;

  if lines = 0 then
    raise exception 'An order with no item lines is not a commitment to buy anything.';
  end if;

  docno := public.next_doc_no(d.company_id, 'purchase_order',
                              extract(year from d.deal_date)::int);

  update public.deals
     set doc_no = coalesce(doc_no, docno), doc_type = 'purchase_order',
         status = 'approved',
         approved_at = now(), approved_by = (select auth.uid())
   where id = p_deal;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deals', p_deal, 'approved', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'order_value', value, 'lines', lines));

  return docno;
end;
$fn$;

-- ============== PART 2: ALLOCATING PO LINES TO A SHIPMENT =============
--
-- `shipments.items` is a jsonb list of {key, model, qty} that the Record
-- shipment flow writes so a later shipment knows what is still outstanding. It
-- stays exactly as it is - that flow is untouched - but it cannot carry a
-- many-to-many link, and spec page 5 needs one: "Support one PO across several
-- shipments and several POs in one shipment."
--
-- So allocation gets its own table, keyed on the ORDER LINE. `shipments.deal_id`
-- stays not-null and keeps meaning "the order this shipment was raised
-- against", which is what the existing screens read; an allocation row may
-- point at a line on a DIFFERENT order, and that is how several POs ride in one
-- shipment.

alter table public.shipments
  add column if not exists arrival_estimate date,
  add column if not exists transit_status   text not null default 'in_transit';

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'shipments_transit_status_check') then
    alter table public.shipments add constraint shipments_transit_status_check
      check (transit_status in ('in_transit','arrived','closed','cancelled'));
  end if;
end
$do$;

create table if not exists public.shipment_allocations (
  id           uuid primary key default gen_random_uuid(),
  shipment_id  uuid not null references public.shipments(id) on delete cascade,
  deal_item_id uuid not null references public.deal_items(id) on delete cascade,
  qty_shipped  numeric not null check (qty_shipped > 0),
  note         text not null default '',
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id),
  unique (shipment_id, deal_item_id)
);

create index if not exists shipment_alloc_shipment_idx
  on public.shipment_allocations (shipment_id);
create index if not exists shipment_alloc_line_idx
  on public.shipment_allocations (deal_item_id);

alter table public.shipment_allocations enable row level security;

drop policy if exists shipment_alloc_read on public.shipment_allocations;
create policy shipment_alloc_read on public.shipment_allocations
  for select to authenticated using (true);

-- Written only through allocate_shipment(), which is what enforces "you cannot
-- ship more than was ordered". A direct client write would go around that, so
-- the client is not given one: the policy admits the owner only, while
-- allocate_shipment is security definer and asks for can_edit.
drop policy if exists shipment_alloc_write on public.shipment_allocations;
create policy shipment_alloc_write on public.shipment_allocations
  for all to authenticated
  using (private.is_owner()) with check (private.is_owner());

-- Replaces a shipment's whole allocation in one go: p_rows is
-- [{"deal_item_id": "...", "qty": 10}, ...]. Replacing rather than adding is
-- deliberate - the screen shows the full list, so saving it should leave
-- exactly what is on screen, and a dropped line must give its quantity back.
create or replace function public.allocate_shipment(p_shipment uuid, p_rows jsonb)
returns int language plpgsql security definer set search_path to '' as $fn$
declare
  sh      public.shipments;
  touched uuid[];
  r       record;
  n       int := 0;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change a shipment.';
  end if;

  select * into sh from public.shipments where id = p_shipment;
  if not found then
    raise exception 'That shipment does not exist.';
  end if;
  if jsonb_typeof(coalesce(p_rows, 'null'::jsonb)) <> 'array' then
    raise exception 'Allocations must be a list of {deal_item_id, qty}.';
  end if;

  -- Lines LOSING an allocation need their qty_shipped recomputed too, so keep
  -- the union of what was allocated and what is being allocated now.
  select coalesce(array_agg(distinct deal_item_id), array[]::uuid[]) into touched
    from public.shipment_allocations where shipment_id = p_shipment;

  delete from public.shipment_allocations where shipment_id = p_shipment;

  for r in select (e->>'deal_item_id')::uuid as line_id,
                  round((e->>'qty')::numeric, 6) as qty
             from jsonb_array_elements(p_rows) e loop

    if r.line_id is null then
      raise exception 'An allocation row has no order line on it.';
    end if;
    -- A zero row means "do not ship this line": a removal, not an error.
    if r.qty is null or r.qty <= 0 then
      continue;
    end if;

    if not exists (select 1
                     from public.deal_items di
                     join public.deals d on d.id = di.deal_id
                    where di.id = r.line_id
                      and d.deleted_at is null
                      and d.status <> 'cancelled'
                      and d.direction = 'sending') then
      raise exception 'That order line is not on a live purchase order.';
    end if;

    insert into public.shipment_allocations (shipment_id, deal_item_id, qty_shipped, created_by)
    values (p_shipment, r.line_id, r.qty, (select auth.uid()));

    touched := touched || r.line_id;
    n := n + 1;
  end loop;

  -- One order line cannot be shipped more than it was ordered, counting every
  -- shipment it appears on - that is the whole point of allocating.
  for r in select di.id, di.qty, di.model, di.description,
                  coalesce(sum(a.qty_shipped), 0) as shipped
             from public.deal_items di
             left join public.shipment_allocations a on a.deal_item_id = di.id
            where di.id = any(touched)
            group by di.id, di.qty, di.model, di.description loop

    if r.shipped > r.qty then
      raise exception
        'Order line "%" has % ordered but % allocated across shipments.',
        coalesce(nullif(btrim(r.model), ''), r.description), r.qty, r.shipped;
    end if;

    update public.deal_items set qty_shipped = r.shipped where id = r.id;
  end loop;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('shipments', p_shipment, 'allocated', (select auth.uid()), '',
          jsonb_build_object('lines', n));

  return n;
end;
$fn$;

-- Spec page 18's "Create receipt": open a draft GRN already filled in with what
-- the shipment says is coming and has not arrived yet, so the warehouse counts
-- against the right expectation instead of retyping it.
create or replace function public.receipt_from_shipment(
  p_shipment uuid, p_warehouse uuid default null)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  sh  public.shipments;
  d   public.deals;
  wh  uuid;
  rid uuid;
  n   int := 0;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to record a receipt.';
  end if;

  select * into sh from public.shipments where id = p_shipment;
  if not found then
    raise exception 'That shipment does not exist.';
  end if;

  select * into d from public.deals where id = sh.deal_id;
  if d.company_id is null then
    raise exception 'Link the order to the company before receiving against it.';
  end if;

  wh := coalesce(p_warehouse, d.warehouse_id,
                 (select w.id from public.warehouses w
                   where w.company_id = d.company_id and w.active
                   order by w.code limit 1));
  if wh is null then
    raise exception 'There is no warehouse to receive these goods into.';
  end if;

  insert into public.goods_receipts (company_id, deal_id, shipment_id, warehouse_id,
                                     received_on, status, created_by)
  values (d.company_id, sh.deal_id, p_shipment, wh, current_date, 'draft',
          (select auth.uid()))
  returning id into rid;

  -- Expected = allocated to this shipment, less what earlier receipts already
  -- counted in. A partial arrival leaves the rest pending (spec page 5 step 3).
  insert into public.goods_receipt_lines (receipt_id, deal_item_id, item_id,
                                          qty_expected, unit_cost)
  select rid, a.deal_item_id, di.item_id,
         greatest(a.qty_shipped - di.qty_received, 0),
         case when di.unit_cost > 0 then di.unit_cost else di.unit_price end
    from public.shipment_allocations a
    join public.deal_items di on di.id = a.deal_item_id
   where a.shipment_id = p_shipment
     and greatest(a.qty_shipped - di.qty_received, 0) > 0;

  select count(*) into n from public.goods_receipt_lines where receipt_id = rid;
  if n = 0 then
    delete from public.goods_receipts where id = rid;
    raise exception 'Everything allocated to this shipment has already been received.';
  end if;

  return rid;
end;
$fn$;

-- Spec page 18's grid: ordered, shipped, received, per PO line per shipment.
create or replace view public.shipment_progress
with (security_invoker = true) as
  select a.id              as allocation_id,
         a.shipment_id,
         s.doc_no          as shipment_no,
         s.receipt_id      as carrier_ref,
         s.carrier,
         s.shipped_on,
         s.arrival_estimate,
         s.transit_status,
         di.deal_id,
         d.doc_no          as order_no,
         d.reference       as order_reference,
         d.party           as supplier,
         d.party_id,
         a.deal_item_id,
         di.item_id,
         coalesce(nullif(btrim(di.model), ''), di.description) as item_label,
         di.description,
         di.qty            as qty_ordered,
         a.qty_shipped,
         di.qty_received,
         di.qty_accepted,
         greatest(a.qty_shipped - di.qty_received, 0) as qty_in_transit,
         di.unit_price,
         d.currency,
         public.currency_decimals(d.currency) as cur_decimals
    from public.shipment_allocations a
    join public.shipments s   on s.id  = a.shipment_id
    join public.deal_items di on di.id = a.deal_item_id
    join public.deals d       on d.id  = di.deal_id
   where d.deleted_at is null;
