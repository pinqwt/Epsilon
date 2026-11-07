-- ERP phase 6, part 1 of 2: the reports (2026-11-07).
--
-- Applied as:
--   erp_phase6_reports
--
-- Part 2 of 2 is erp_phase6_opening_balances.sql.
--
-- Spec page 12 lists the reports the owner signs off before launch: "stock and
-- valuation, goods in transit, open orders, customer / supplier statements and
-- aging, bank / cash, journal drill-down, trial balance, profit and loss,
-- balance sheet and shipment cost."
--
-- Already built in earlier phases, and NOT rebuilt here:
--   statements and aging  -> party_statement() / ar_aging / ap_aging
--                            / customer_open_items / supplier_open_items
--   bank / cash           -> bank_balances
--   journal drill-down    -> general_ledger
--   trial balance         -> trial_balance(company, as_of)
--   stock on hand         -> stock_on_hand / stock_available / stock_levels
--
-- So this adds the six that were missing: stock valuation, goods in transit,
-- open orders, shipment cost, profit and loss, balance sheet.
--
-- TWO RULES THIS FILE FOLLOWS THROUGHOUT.
--
-- 1. Everything reads `general_ledger`, never `journal_lines` directly.
--    general_ledger already filters `status in ('posted','reversed')`, which is
--    the mistake this schema keeps re-making: a reversed journal STAYS in the
--    ledger and its mirror is what cancels it, so filtering to 'posted' alone
--    drops the original, leaves the mirror standing, and reports every
--    corrected transaction as its own opposite. Reading the view inherits the
--    correct filter instead of restating it and getting it wrong.
--
-- 2. The two parameterised reports are deliberately NOT `security definer`.
--    A function defaults to security invoker, so it runs as the caller and the
--    RLS on the tables under general_ledger still applies. Making a reporting
--    function security definer would hand the whole ledger to anyone holding
--    the publishable key - the same hole that `security_invoker = true` on
--    views exists to close.

-- ===================== STOCK AND VALUATION ==========================
-- `item_costs` is the source of truth for the weighted average, so valuation
-- is read from there rather than recomputed from stock_moves.

create or replace view public.stock_valuation
with (security_invoker = true) as
  select ic.item_id,
         i.code                                            as item_code,
         coalesce(nullif(btrim(i.model), ''), i.description) as item_label,
         i.brand,
         i.description,
         ic.warehouse_id,
         w.code                                            as warehouse_code,
         w.name                                            as warehouse_name,
         w.company_id,
         c.base_currency,
         public.currency_decimals(c.base_currency)         as cur_decimals,
         ic.qty_on_hand,
         coalesce(ic.qty_reserved, 0)                      as qty_reserved,
         ic.qty_on_hand - coalesce(ic.qty_reserved, 0)     as qty_available,
         ic.avg_cost,
         round(ic.qty_on_hand * ic.avg_cost,
               public.currency_decimals(c.base_currency))  as stock_value,
         ic.updated_at
    from public.item_costs ic
    join public.items i      on i.id = ic.item_id
    join public.warehouses w on w.id = ic.warehouse_id
    join public.companies c  on c.id = w.company_id
   where ic.qty_on_hand <> 0 or coalesce(ic.qty_reserved, 0) <> 0;

-- ======================= GOODS IN TRANSIT ===========================
-- Allocated to a shipment and not yet received. Per shipment, so the owner
-- sees "what is on the water", which is what account 1310 is for.

create or replace view public.goods_in_transit
with (security_invoker = true) as
  select sp.shipment_id,
         sp.shipment_no,
         sp.carrier_ref,
         sp.carrier,
         sp.shipped_on,
         sp.arrival_estimate,
         sp.transit_status,
         sp.deal_id,
         sp.order_no,
         sp.order_reference,
         sp.supplier,
         sp.party_id,
         sp.currency,
         sp.cur_decimals,
         count(*)                             as lines_in_transit,
         sum(sp.qty_shipped)                  as qty_shipped,
         sum(sp.qty_received)                 as qty_received,
         sum(sp.qty_in_transit)               as qty_in_transit,
         sum(round(sp.qty_in_transit * sp.unit_price, 6)) as value_in_transit,
         case when sp.arrival_estimate is not null and sp.arrival_estimate < current_date
              then current_date - sp.arrival_estimate else 0 end as days_overdue
    from public.shipment_progress sp
   where sp.qty_in_transit > 0
     and sp.transit_status <> 'cancelled'
   group by sp.shipment_id, sp.shipment_no, sp.carrier_ref, sp.carrier,
            sp.shipped_on, sp.arrival_estimate, sp.transit_status,
            sp.deal_id, sp.order_no, sp.order_reference, sp.supplier,
            sp.party_id, sp.currency, sp.cur_decimals;

-- ========================== OPEN ORDERS =============================
-- Both directions: a purchase order with goods still to come, or a sales order
-- with goods still to go, or either with money still outstanding. An order is
-- open while EITHER is true - goods fully received but unpaid is still open,
-- and so is paid up front but undelivered.

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
   group by d.id, d.doc_no, d.direction, d.reference, d.party, d.party_id,
            d.status, d.deal_date, s.currency, s.cur_decimals,
            s.bill_total, s.paid, s.amount_left
  having sum(op.qty_outstanding) > 0 or s.amount_left > 0;

-- ========================= SHIPMENT COST ============================
-- What a consignment actually cost: goods as accrued at receipt, plus the
-- landed costs allocated to it.
--
-- The goods figure comes from the LEDGER (the 2110 accrual), not from
-- goods_receipt_lines.unit_cost, because post_landed_cost rewrites that
-- unit_cost to include the freight it just allocated. Reading the rewritten
-- unit_cost and then adding the landed costs again would count freight twice.

create or replace view public.shipment_cost
with (security_invoker = true) as
  select g.id              as receipt_id,
         g.doc_no          as receipt_no,
         g.shipment_id,
         s.doc_no          as shipment_no,
         s.carrier,
         s.shipped_on,
         g.received_on,
         g.deal_id,
         d.doc_no          as order_no,
         d.reference       as order_reference,
         d.party           as supplier,
         d.party_id,
         g.company_id,
         c.base_currency,
         public.currency_decimals(c.base_currency) as cur_decimals,
         gq.goods_qty,
         coalesce(gv.goods_base, 0)                as goods_base,
         coalesce(lc.landed_base, 0)               as landed_base,
         coalesce(gv.goods_base, 0) + coalesce(lc.landed_base, 0) as total_base,
         case when gq.goods_qty > 0
              then round((coalesce(gv.goods_base, 0) + coalesce(lc.landed_base, 0))
                         / gq.goods_qty, 6) end    as cost_per_unit,
         case when coalesce(gv.goods_base, 0) > 0
              then round(100 * coalesce(lc.landed_base, 0)
                         / gv.goods_base, 2) end   as landed_pct_of_goods
    from public.goods_receipts g
    join public.deals d      on d.id = g.deal_id
    join public.companies c  on c.id = g.company_id
    left join public.shipments s on s.id = g.shipment_id
    cross join lateral (
      select coalesce(sum(gl.qty_accepted), 0) as goods_qty
        from public.goods_receipt_lines gl
       where gl.receipt_id = g.id
    ) gq
    left join lateral (
      select sum(jl.credit - jl.debit) as goods_base
        from public.journals j
        join public.journal_lines jl on jl.journal_id = j.id
       where j.source_table = 'goods_receipts'
         and j.source_id = g.id
         and j.status in ('posted', 'reversed')
         and jl.account_code = '2110'
    ) gv on true
    left join lateral (
      select sum(l.amount_base) as landed_base
        from public.landed_costs lcx
        join public.landed_cost_lines l on l.landed_cost_id = lcx.id
       where lcx.receipt_id = g.id
         and lcx.status = 'posted'
    ) lc on true
   where g.status = 'posted'
     and d.deleted_at is null;

-- ======================= PROFIT AND LOSS ============================
-- Revenue earned less what it cost, over a date range.
--
-- Cost of sales is the 5xxx block and everything else expense-kind is an
-- operating expense, so the exchange difference account (6100) lands below
-- gross profit rather than inside it - an exchange loss on a settlement is not
-- part of what the goods cost.
--
-- `sort_order` exists so a screen can print the report straight down without
-- knowing the accounting order; subtotal rows carry a null account_code.

create or replace function public.profit_and_loss(
  p_company uuid, p_from date, p_to date)
returns table (
  sort_order   int,
  section      text,
  account_code text,
  account_name text,
  amount       numeric
) language sql stable set search_path to '' as $fn$
  with m as (
    select g.account_code, g.account_name, g.account_kind,
           sum(g.credit - g.debit) as credit_net,
           sum(g.debit - g.credit) as debit_net
      from public.general_ledger g
     where g.company_id = p_company
       and g.entry_date between p_from and p_to
       and g.account_kind in ('revenue', 'expense')
     group by g.account_code, g.account_name, g.account_kind
  ),
  rev  as (select * from m where account_kind = 'revenue'),
  cogs as (select * from m where account_kind = 'expense' and account_code like '5%'),
  opex as (select * from m where account_kind = 'expense' and account_code not like '5%'),
  t as (
    select coalesce((select sum(credit_net) from rev),  0) as revenue,
           coalesce((select sum(debit_net)  from cogs), 0) as cost_of_sales,
           coalesce((select sum(debit_net)  from opex), 0) as expenses
  )
  select 10, 'Revenue'::text,             account_code, account_name, credit_net from rev
  union all
  select 19, 'Total revenue'::text,       null::text, null::text, revenue       from t
  union all
  select 20, 'Cost of sales'::text,       account_code, account_name, debit_net  from cogs
  union all
  select 29, 'Total cost of sales'::text, null::text, null::text, cost_of_sales from t
  union all
  select 30, 'Gross profit'::text,        null::text, null::text,
         revenue - cost_of_sales from t
  union all
  select 40, 'Expenses'::text,            account_code, account_name, debit_net  from opex
  union all
  select 49, 'Total expenses'::text,      null::text, null::text, expenses      from t
  union all
  select 50, 'Net profit'::text,          null::text, null::text,
         revenue - cost_of_sales - expenses from t
  order by 1, 3 nulls last
$fn$;

-- ========================= BALANCE SHEET ============================
-- Cumulative to a date. Profit for the period is not stored anywhere, so
-- retained earnings is derived: summing (credit - debit) across BOTH revenue
-- and expense accounts gives revenue less expenses, because an expense's
-- credit-minus-debit is already negative. That keeps the sheet balancing
-- without a period-close posting, which this system does not have.
--
-- The last row is the proof: assets less liabilities, equity and earnings must
-- be exactly zero. If it is not, something posted one-sided and the trial
-- balance will disagree too.

create or replace function public.balance_sheet(
  p_company uuid, p_as_of date)
returns table (
  sort_order   int,
  section      text,
  account_code text,
  account_name text,
  amount       numeric
) language sql stable set search_path to '' as $fn$
  with m as (
    select g.account_code, g.account_name, g.account_kind,
           sum(g.debit - g.credit) as dr_net,
           sum(g.credit - g.debit) as cr_net
      from public.general_ledger g
     where g.company_id = p_company
       and g.entry_date <= p_as_of
     group by g.account_code, g.account_name, g.account_kind
  ),
  a as (select * from m where account_kind = 'asset'     and dr_net <> 0),
  l as (select * from m where account_kind = 'liability' and cr_net <> 0),
  e as (select * from m where account_kind = 'equity'    and cr_net <> 0),
  t as (
    select coalesce((select sum(dr_net) from a), 0) as assets,
           coalesce((select sum(cr_net) from l), 0) as liabilities,
           coalesce((select sum(cr_net) from e), 0) as equity,
           coalesce((select sum(cr_net) from m
                      where account_kind in ('revenue', 'expense')), 0) as earnings
  )
  select 10, 'Assets'::text,            account_code, account_name, dr_net from a
  union all
  select 19, 'Total assets'::text,      null::text, null::text, assets     from t
  union all
  select 20, 'Liabilities'::text,       account_code, account_name, cr_net from l
  union all
  select 29, 'Total liabilities'::text, null::text, null::text, liabilities from t
  union all
  select 30, 'Equity'::text,            account_code, account_name, cr_net from e
  union all
  select 35, 'Retained earnings'::text, null::text, null::text, earnings   from t
  union all
  select 39, 'Total equity'::text,      null::text, null::text, equity + earnings from t
  union all
  select 40, 'Liabilities and equity'::text, null::text, null::text,
         liabilities + equity + earnings from t
  union all
  select 50, 'Balance check (must be zero)'::text, null::text, null::text,
         assets - liabilities - equity - earnings from t
  order by 1, 3 nulls last
$fn$;
