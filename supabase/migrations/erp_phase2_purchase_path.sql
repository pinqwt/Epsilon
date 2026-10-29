-- ERP phase 2: the purchase path as separate documents.
--
-- Requires erp_phase1 (companies, warehouses, items, item_costs, stock_moves,
-- journals, audit_log) and erp_phase5 (post_event, reverse_journal,
-- assert_period_open).
--
-- The point of this phase: a goods receipt records COUNTED quantities. Before
-- it, stock_levels worked arrivals out from money — qty * goods_value /
-- bill_total — so an order delivered in full but only part paid looked half
-- missing, and a prepaid order that never shipped looked delivered.

-- ========================== GOODS RECEIPTS ===========================

create table if not exists public.goods_receipts (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references public.companies(id),
  deal_id           uuid not null references public.deals(id),
  shipment_id       uuid references public.shipments(id),
  doc_no            text,
  warehouse_id      uuid not null references public.warehouses(id),
  received_on       date not null default current_date,
  inspection_status text not null default 'awaiting'
                      check (inspection_status in ('awaiting','approved','rejected')),
  status            text not null default 'draft'
                      check (status in ('draft','posted','cancelled')),
  note              text not null default '',
  file_path         text,
  file_name         text,
  file_size         bigint,
  created_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id),
  posted_at         timestamptz,
  posted_by         uuid references auth.users(id),
  cancelled_at      timestamptz,
  cancelled_by      uuid references auth.users(id),
  cancel_reason     text not null default ''
);

create index if not exists grn_deal_idx on public.goods_receipts (deal_id);

create table if not exists public.goods_receipt_lines (
  id           uuid primary key default gen_random_uuid(),
  receipt_id   uuid not null references public.goods_receipts(id) on delete cascade,
  deal_item_id uuid references public.deal_items(id),
  item_id      uuid references public.items(id),
  qty_expected numeric not null default 0 check (qty_expected >= 0),
  qty_received numeric not null default 0 check (qty_received >= 0),
  qty_accepted numeric not null default 0 check (qty_accepted >= 0),
  qty_damaged  numeric not null default 0 check (qty_damaged  >= 0),
  unit_cost    numeric not null default 0 check (unit_cost    >= 0),
  note         text not null default '',
  -- You cannot accept more than turned up.
  check (qty_accepted + qty_damaged <= qty_received)
);

create index if not exists grn_lines_receipt_idx on public.goods_receipt_lines (receipt_id);

-- =========================== LANDED COST =============================
-- Freight and customs belong in the cost of the goods (spec page 21):
-- 3,070 goods + 230 freight = 3,300 / 100 units = 33.000 each, not 30.70.

create table if not exists public.landed_costs (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id),
  deal_id      uuid not null references public.deals(id),
  receipt_id   uuid references public.goods_receipts(id),
  doc_no       text,
  basis        text not null default 'value'
                 check (basis in ('value','quantity')),
  status       text not null default 'draft'
                 check (status in ('draft','posted','cancelled')),
  allocated_on date not null default current_date,
  note         text not null default '',
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id),
  posted_at    timestamptz,
  posted_by    uuid references auth.users(id)
);

create table if not exists public.landed_cost_lines (
  id             uuid primary key default gen_random_uuid(),
  landed_cost_id uuid not null references public.landed_costs(id) on delete cascade,
  label          text not null,
  amount_base    numeric not null check (amount_base > 0),
  -- Recoverable tax is NOT part of stock cost (spec page 21).
  treatment      text not null default 'stock'
                   check (treatment in ('stock','expense','recoverable_tax'))
);

-- 'cancelled' is how a posted document is deleted: the row stays, its effect
-- is reversed, and it drops out of stock and money.
alter table public.deals drop constraint if exists deals_status_check;
alter table public.deals add constraint deals_status_check
  check (status in ('legacy','draft','approved','posted','reversed','cancelled'));

-- ================================ RLS ================================

alter table public.goods_receipts      enable row level security;
alter table public.goods_receipt_lines enable row level security;
alter table public.landed_costs        enable row level security;
alter table public.landed_cost_lines   enable row level security;

do $do$
declare t text;
begin
  foreach t in array array['goods_receipts','goods_receipt_lines',
                           'landed_costs','landed_cost_lines']
  loop
    execute format('drop policy if exists %I_read on public.%I', t, t);
    execute format(
      'create policy %I_read on public.%I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists %I_write on public.%I', t, t);
    execute format(
      'create policy %I_write on public.%I for all to authenticated '
      'using (private.can_edit()) with check (private.can_edit())', t, t);
  end loop;
end
$do$;

-- ======================= POST A GOODS RECEIPT ========================
-- Four things at once, or none of them: counted stock in, the weighted
-- average cost updated, the journal written (Dr Inventory / Cr Receipt
-- accrual), and the order's received quantities advanced.

create or replace function public.post_goods_receipt(p_receipt uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  r      public.goods_receipts;
  base   text;
  docno  text;
  total  numeric := 0;
  jid    uuid;
  ln     record;
  oldq   numeric;
  olda   numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;

  select * into r from public.goods_receipts where id = p_receipt;
  if not found then
    raise exception 'That goods receipt does not exist.';
  end if;
  if r.status <> 'draft' then
    raise exception 'This receipt is already %. Only a draft can be posted.', r.status;
  end if;
  if r.inspection_status <> 'approved' then
    raise exception 'Approve the inspection before posting the receipt.';
  end if;

  select c.base_currency into base from public.companies c where c.id = r.company_id;
  perform public.assert_period_open(r.company_id, r.received_on);

  if not exists (select 1 from public.goods_receipt_lines l
                  where l.receipt_id = p_receipt and l.qty_accepted > 0) then
    raise exception 'Nothing was accepted on this receipt, so there is nothing to post.';
  end if;

  docno := public.next_doc_no(r.company_id, 'goods_receipt',
                              extract(year from r.received_on)::int);

  for ln in select l.*, coalesce(l.item_id, di.item_id) as use_item
              from public.goods_receipt_lines l
              left join public.deal_items di on di.id = l.deal_item_id
             where l.receipt_id = p_receipt and l.qty_accepted > 0 loop

    if ln.use_item is null then
      raise exception 'A receipt line has no item on file. Link it to an item first.';
    end if;

    total := total + round(ln.qty_accepted * ln.unit_cost, public.currency_decimals(base));

    -- Only ACCEPTED goods become sellable stock. Damaged ones do not.
    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, r.warehouse_id, ln.qty_accepted, ln.unit_cost,
            'goods_receipts', p_receipt, r.received_on, (select auth.uid()));

    -- Weighted average: blend the new arrival into what is already held.
    insert into public.item_costs (item_id, warehouse_id, qty_on_hand, avg_cost)
    values (ln.use_item, r.warehouse_id, 0, 0)
    on conflict (item_id, warehouse_id) do nothing;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = r.warehouse_id
       for update;

    update public.item_costs
       set qty_on_hand = oldq + ln.qty_accepted,
           avg_cost    = case when oldq + ln.qty_accepted = 0 then 0
                         else round((oldq * olda + ln.qty_accepted * ln.unit_cost)
                                    / (oldq + ln.qty_accepted), 6) end,
           updated_at  = now()
     where item_id = ln.use_item and warehouse_id = r.warehouse_id;

    -- Advance the order line. Counted, not inferred from money.
    if ln.deal_item_id is not null then
      update public.deal_items
         set qty_received = qty_received + ln.qty_received,
             qty_accepted = qty_accepted + ln.qty_accepted,
             qty_damaged  = qty_damaged  + ln.qty_damaged,
             unit_cost    = ln.unit_cost
       where id = ln.deal_item_id;
    end if;
  end loop;

  if total <= 0 then
    raise exception 'The accepted goods have no cost, so the receipt cannot be valued.';
  end if;

  jid := public.post_event(
    p_company => r.company_id, p_event => 'receive_before_invoice',
    p_source_table => 'goods_receipts', p_source_id => p_receipt,
    p_amount => total, p_currency => base, p_entry_date => r.received_on,
    p_warehouse => r.warehouse_id,
    p_memo => 'Goods receipt ' || docno);

  update public.stock_moves set journal_id = jid
   where source_table = 'goods_receipts' and source_id = p_receipt and journal_id is null;

  update public.goods_receipts
     set doc_no = docno, status = 'posted',
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_receipt;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('goods_receipts', p_receipt, 'posted', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'stock_value', total, 'journal', jid));

  return jid;
end;
$fn$;

-- ====================== DELETE A POSTED RECEIPT ======================
-- The row stays and is marked cancelled, its stock comes back out, the
-- weighted average is unwound and its journal is reversed. From the user's
-- side this is "delete"; underneath it is a correction with a trace, so
-- money cannot quietly vanish.
--
-- Deleting a draft needs can_edit. Cancelling a POSTED receipt reverses a
-- journal, and reverse_journal() is owner-only, so the check has to match or
-- staff would fail halfway through with stock already taken out.

create or replace function public.cancel_goods_receipt(p_receipt uuid, p_reason text)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  r    public.goods_receipts;
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
    raise exception 'Say why this receipt is being cancelled.';
  end if;

  select * into r from public.goods_receipts where id = p_receipt;
  if not found then
    raise exception 'That goods receipt does not exist.';
  end if;
  if r.status = 'cancelled' then
    return;
  end if;

  -- A draft never affected anything, so it can simply go.
  if r.status = 'draft' then
    delete from public.goods_receipts where id = p_receipt;
    insert into public.audit_log (table_name, row_id, action, actor, reason)
    values ('goods_receipts', p_receipt, 'deleted', (select auth.uid()), btrim(p_reason));
    return;
  end if;

  if not private.is_owner() then
    raise exception 'This receipt is posted. Only the owner can cancel it.';
  end if;

  perform public.assert_period_open(r.company_id, current_date);

  for ln in select l.*, coalesce(l.item_id, di.item_id) as use_item
              from public.goods_receipt_lines l
              left join public.deal_items di on di.id = l.deal_item_id
             where l.receipt_id = p_receipt and l.qty_accepted > 0 loop

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = r.warehouse_id
       for update;

    -- Has anything we received already been sold on? Taking the stock back
    -- out would push it negative, so that sale has to be undone first.
    newq := coalesce(oldq, 0) - ln.qty_accepted;
    if newq < 0 then
      raise exception
        'Cannot cancel: only % of % units are still on hand, the rest has moved on. Undo that first.',
        coalesce(oldq, 0), ln.qty_accepted;
    end if;

    insert into public.stock_moves (item_id, warehouse_id, qty, unit_cost,
                                    source_table, source_id, moved_on, created_by)
    values (ln.use_item, r.warehouse_id, -ln.qty_accepted, ln.unit_cost,
            'goods_receipts_cancel', p_receipt, current_date, (select auth.uid()));

    -- Unwind the blend: remove this arrival's value at its own cost.
    update public.item_costs
       set qty_on_hand = newq,
           avg_cost    = case when newq = 0 then 0
                         else round((oldq * olda - ln.qty_accepted * ln.unit_cost)
                                    / newq, 6) end,
           updated_at  = now()
     where item_id = ln.use_item and warehouse_id = r.warehouse_id;

    if ln.deal_item_id is not null then
      update public.deal_items
         set qty_received = greatest(qty_received - ln.qty_received, 0),
             qty_accepted = greatest(qty_accepted - ln.qty_accepted, 0),
             qty_damaged  = greatest(qty_damaged  - ln.qty_damaged,  0)
       where id = ln.deal_item_id;
    end if;
  end loop;

  select id into j from public.journals
   where source_table = 'goods_receipts' and source_id = p_receipt
     and status = 'posted' limit 1;
  if j is not null then
    perform public.reverse_journal(j, 'Receipt cancelled: ' || btrim(p_reason));
  end if;

  update public.goods_receipts
     set status = 'cancelled', cancelled_at = now(),
         cancelled_by = (select auth.uid()), cancel_reason = btrim(p_reason)
   where id = p_receipt;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('goods_receipts', p_receipt, 'cancelled', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('reversed_journal', j));
end;
$fn$;

-- ======================== ALLOCATE LANDED COST =======================

create or replace function public.post_landed_cost(p_lc uuid)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  lc      public.landed_costs;
  base    text;
  dec     int;
  addable numeric;
  docno   text;
  jid     uuid;
  denom   numeric;
  ln      record;
  share   numeric;
  spread  numeric := 0;
  lastid  uuid;
  oldq    numeric;
  olda    numeric;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;

  select * into lc from public.landed_costs where id = p_lc;
  if not found then
    raise exception 'That cost sheet does not exist.';
  end if;
  if lc.status <> 'draft' then
    raise exception 'This cost sheet is already %.', lc.status;
  end if;
  if lc.receipt_id is null then
    raise exception 'Point the cost sheet at the goods receipt it belongs to.';
  end if;
  if not exists (select 1 from public.goods_receipts g
                  where g.id = lc.receipt_id and g.status = 'posted') then
    raise exception 'Post the goods receipt before allocating costs to it.';
  end if;

  select c.base_currency into base from public.companies c where c.id = lc.company_id;
  dec := public.currency_decimals(base);
  perform public.assert_period_open(lc.company_id, lc.allocated_on);

  -- Only charges marked 'stock' change the cost of the goods.
  select coalesce(sum(amount_base), 0) into addable
    from public.landed_cost_lines where landed_cost_id = p_lc and treatment = 'stock';
  if addable <= 0 then
    raise exception 'No charges on this sheet add to stock cost.';
  end if;

  -- Split by purchase value, or by quantity if that is the chosen basis.
  if lc.basis = 'quantity' then
    select coalesce(sum(l.qty_accepted), 0) into denom
      from public.goods_receipt_lines l
     where l.receipt_id = lc.receipt_id and l.qty_accepted > 0;
  else
    select coalesce(sum(l.qty_accepted * l.unit_cost), 0) into denom
      from public.goods_receipt_lines l
     where l.receipt_id = lc.receipt_id and l.qty_accepted > 0;
  end if;

  if denom <= 0 then
    raise exception 'The receipt has nothing to spread these costs over.';
  end if;

  docno := public.next_doc_no(lc.company_id, 'landed_cost',
                              extract(year from lc.allocated_on)::int);

  for ln in select l.*, coalesce(l.item_id, di.item_id) as use_item,
                   g.warehouse_id
              from public.goods_receipt_lines l
              join public.goods_receipts g on g.id = l.receipt_id
              left join public.deal_items di on di.id = l.deal_item_id
             where l.receipt_id = lc.receipt_id and l.qty_accepted > 0
             order by l.id loop

    share := round(addable * (case when lc.basis = 'quantity'
                                   then ln.qty_accepted
                                   else ln.qty_accepted * ln.unit_cost end) / denom, dec);
    spread := spread + share;
    lastid := ln.id;

    update public.goods_receipt_lines
       set unit_cost = round(unit_cost + share / ln.qty_accepted, 6)
     where id = ln.id;

    select qty_on_hand, avg_cost into oldq, olda
      from public.item_costs
     where item_id = ln.use_item and warehouse_id = ln.warehouse_id
       for update;

    -- The charge lands on the stock still held, not on units already gone.
    if coalesce(oldq, 0) > 0 then
      update public.item_costs
         set avg_cost   = round(olda + share / oldq, 6),
             updated_at = now()
       where item_id = ln.use_item and warehouse_id = ln.warehouse_id;
    end if;
  end loop;

  -- Rounding crumbs go on the last line so the total lands exactly.
  if spread <> addable and lastid is not null then
    update public.goods_receipt_lines
       set unit_cost = round(unit_cost + (addable - spread) / nullif(qty_accepted, 0), 6)
     where id = lastid;
  end if;

  jid := public.post_event(
    p_company => lc.company_id, p_event => 'landed_cost',
    p_source_table => 'landed_costs', p_source_id => p_lc,
    p_amount => addable, p_currency => base, p_entry_date => lc.allocated_on,
    p_memo => 'Landed cost ' || docno);

  update public.landed_costs
     set doc_no = docno, status = 'posted',
         posted_at = now(), posted_by = (select auth.uid())
   where id = p_lc;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('landed_costs', p_lc, 'posted', (select auth.uid()), '',
          jsonb_build_object('doc_no', docno, 'added_to_stock', addable, 'journal', jid));

  return jid;
end;
$fn$;

-- ============================== VIEWS ================================

-- What has actually arrived, per order line. Counted quantities, so an
-- unpaid-but-delivered order no longer looks half missing. Backs the
-- "Arrived?" column on the Stock page.
create or replace view public.order_progress as
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
         end as arrival_state
    from public.deal_items di
    join public.deals d on d.id = di.deal_id
    left join public.items i on i.id = di.item_id
   where d.deleted_at is null
     and d.status <> 'cancelled';

-- Real stock, built from signed movements rather than estimated from money.
create or replace view public.stock_on_hand as
  select m.item_id,
         i.code  as item_code,
         i.brand,
         i.model,
         i.description,
         i.unit,
         i.stock_key,
         m.warehouse_id,
         w.code  as warehouse_code,
         sum(m.qty) as qty_on_hand,
         max(c.avg_cost) as avg_cost,
         round(sum(m.qty) * coalesce(max(c.avg_cost), 0), 3) as stock_value
    from public.stock_moves m
    join public.items i on i.id = m.item_id
    join public.warehouses w on w.id = m.warehouse_id
    left join public.item_costs c
           on c.item_id = m.item_id and c.warehouse_id = m.warehouse_id
   group by m.item_id, i.code, i.brand, i.model, i.description, i.unit,
            i.stock_key, m.warehouse_id, w.code
  having sum(m.qty) <> 0;
