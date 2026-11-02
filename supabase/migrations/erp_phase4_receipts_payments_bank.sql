-- ERP phase 4: customer receipts, supplier payments, receivables / payables
-- aging and bank balances (spec pages 8, 13, 14, 26).
--
-- Applied as four migrations:
--   erp_phase4_payment_lifecycle   -- columns, guards, RLS, the two views that count payments
--   erp_phase4_post_and_reverse    -- payment_plan, preview_payment, post_payment, reverse_payment
--   erp_phase4_aging_and_bank      -- ar_aging, ap_aging, supplier_open_items, advances, bank balances
--   erp_phase4_reversed_journals_stay_in_balances  -- PART 4: the fix the acceptance test caught
--
-- Decisions (2026-11-01, payment flow confirmed with the owner 2026-11-02):
--  * A payment stays scoped to one order (payments.deal_id is NOT NULL). A
--    receipt allocates across that order's sales invoices; a customer paying
--    several orders at once is several receipts.
--  * Existing payments stay 'legacy'. They were never journal-posted, so
--    promoting them would put bank movements in the ledger with no opening
--    balance under them (phase 6). A trigger forbids the promotion.
--  * **`payments.status` keeps its 'legacy' default and the existing Add
--    payment / Fully paid box is left alone.** It inserts without a status, so
--    every payment it writes is 'legacy' and stays out of the ledger, exactly
--    as today - `deal_summary` still counts it, so "left to pay" still drops
--    the moment it is recorded. Posting is the new Receivables / Payables
--    screens' job: they create a 'draft' and run preview -> post, which is the
--    flow spec page 26 draws ("Preview journal", "Post payment"). The insert
--    policy therefore admits BOTH 'legacy' and 'draft': narrowing it to
--    'draft' alone would make every payment the current app records fail RLS.
--  * A supplier payment posts as a SUPPLIER ADVANCE (Dr 1400 / Cr bank), not
--    against 2100: the purchase path books receipts to 2110 and nothing
--    credits 2100 until supplier invoice matching (PIN) exists, so there is
--    no posted bill to clear. Spec page 6 says the same: pay first, apply the
--    advance when the bill is matched. `apply_supplier_advance` (Dr 2100 /
--    Cr 1400) is already a posting template, waiting for phase 2.
--  * Money may only move through a bank account held in the company base
--    currency for now; foreign bank balances need revaluation (phase 6).
--  * The arithmetic lives in ONE place, `private.payment_plan()`. preview and
--    post both read it, so a previewed journal and a posted one cannot drift.
--    It deliberately does NOT allocate a document number - that would burn a
--    code every time a preview was opened and abandoned, the same reason
--    `peek_party_code()` exists alongside `next_party_code()`.

-- ============================ PART 1: LIFECYCLE ======================

alter table public.payments
  add column if not exists bank_amount    numeric check (bank_amount is null or bank_amount > 0),
  add column if not exists posted_at      timestamptz,
  add column if not exists posted_by      uuid references auth.users(id),
  add column if not exists reversed_at    timestamptz,
  add column if not exists reversed_by    uuid references auth.users(id),
  add column if not exists reverse_reason text;

create unique index if not exists payments_doc_no_uniq
  on public.payments (company_id, doc_no) where doc_no is not null;

-- Phase 3 left sales_invoice_id as a bare uuid; give it its key, and make an
-- allocation point at exactly one thing.
alter table public.payment_allocations
  add constraint payment_alloc_sales_invoice_fk
    foreign key (sales_invoice_id) references public.sales_invoices(id),
  add constraint payment_alloc_one_target
    check (num_nonnulls(invoice_id, deal_id, sales_invoice_id) = 1);

-- Spec page 8 defines the buckets once; keep one definition so every aging
-- view and the open-items views cannot disagree about what "31-60" means.
create or replace function public.age_bucket(p_due date)
returns text language sql stable set search_path to '' as $fn$
  select case
    when p_due is null              then 'not due'
    when p_due >= current_date      then 'not due'
    when current_date - p_due <= 30 then '1-30'
    when current_date - p_due <= 60 then '31-60'
    when current_date - p_due <= 90 then '61-90'
    else 'over 90'
  end;
$fn$;

-- Status can only move forward, and a legacy row never moves at all.
create or replace function private.payments_guard()
returns trigger language plpgsql set search_path to '' as $fn$
begin
  if old.status = 'legacy' and new.status <> 'legacy' then
    raise exception 'A legacy payment was never journal-posted and cannot be promoted. Record a new payment instead.';
  end if;
  if new.status = 'legacy' and old.status <> 'legacy' then
    raise exception 'A payment cannot be turned into a legacy one.';
  end if;
  if old.status = 'posted' and new.status not in ('posted', 'reversed') then
    raise exception 'A posted payment can only be reversed.';
  end if;
  if old.status = 'reversed' and new.status <> 'reversed' then
    raise exception 'A reversed payment stays reversed.';
  end if;
  return new;
end;
$fn$;

drop trigger if exists payments_guard on public.payments;
create trigger payments_guard before update on public.payments
  for each row execute function private.payments_guard();

-- Only an unposted payment is writable from the browser. 'legacy' is what the
-- existing Add payment box writes (the column default) and must keep working;
-- 'draft' is what the new receipts / payments screens create. A posted payment
-- moves on only through post_payment / reverse_payment, which are security
-- definer. An UPDATE that fails `using` affects zero rows rather than raising.
drop policy if exists payments_write on public.payments;

create policy payments_insert on public.payments
  for insert to authenticated
  with check (private.can_edit() and status in ('legacy', 'draft')
              and exists (select 1 from public.deals d where d.id = payments.deal_id));

create policy payments_update on public.payments
  for update to authenticated
  using      (private.can_edit() and status in ('legacy', 'draft')
              and exists (select 1 from public.deals d where d.id = payments.deal_id))
  with check (private.can_edit() and status in ('legacy', 'draft')
              and exists (select 1 from public.deals d where d.id = payments.deal_id));

create policy payments_delete on public.payments
  for delete to authenticated
  using (private.can_edit() and status in ('legacy', 'draft')
         and exists (select 1 from public.deals d where d.id = payments.deal_id));

drop policy if exists payment_allocations_write on public.payment_allocations;
create policy payment_allocations_write on public.payment_allocations
  for all to authenticated
  using (private.can_edit() and exists (
          select 1 from public.payments p where p.id = payment_allocations.payment_id and p.status = 'draft'))
  with check (private.can_edit() and exists (
          select 1 from public.payments p where p.id = payment_allocations.payment_id and p.status = 'draft'));

-- deal_summary counts a payment only while it stands: legacy rows and posted
-- ones. A draft has not happened yet and a reversed one no longer has.
create or replace view public.deal_summary
with (security_invoker = true) as
 with agg as (
   select d.id,
          d.currency,
          public.currency_decimals(d.currency) as cur_decimals,
          d.discount_pct,
          (select coalesce(sum(di.amount), 0::numeric) from public.deal_items di where di.deal_id = d.id) as subtotal_raw,
          (select count(*) from public.deal_items di where di.deal_id = d.id) as item_count,
          (select coalesce(sum(pm.amount), 0::numeric) from public.payments pm
            where pm.deal_id = d.id and pm.status in ('legacy', 'posted')) as paid_raw,
          (select coalesce(sum(pm.amount), 0::numeric) from public.payments pm
            where pm.deal_id = d.id and pm.is_down_payment and pm.status in ('legacy', 'posted')) as down_raw,
          (select count(*) from public.payments pm
            where pm.deal_id = d.id and pm.status in ('legacy', 'posted')) as payment_count,
          (select max(pm.paid_on) from public.payments pm
            where pm.deal_id = d.id and pm.status in ('legacy', 'posted')) as last_paid_on,
          (select count(*) from public.invoices iv where iv.deal_id = d.id) as invoice_count,
          inv.id as invoice_id,
          inv.invoice_no,
          inv.total as invoice_total,
          inv.uploaded_at as invoice_uploaded_at
     from public.deals d
     left join lateral (
       select iv.id, iv.invoice_no, iv.total, iv.uploaded_at
         from public.invoices iv
        where iv.deal_id = d.id
        order by iv.uploaded_at desc, iv.id desc
        limit 1) inv on true
 ), calc as (
   select a.id, a.currency, a.cur_decimals, a.discount_pct, a.subtotal_raw, a.item_count,
          a.paid_raw, a.down_raw, a.payment_count, a.last_paid_on, a.invoice_count,
          a.invoice_id, a.invoice_no, a.invoice_total, a.invoice_uploaded_at,
          round(a.subtotal_raw, a.cur_decimals) as subtotal,
          round(a.subtotal_raw * a.discount_pct / 100::numeric, a.cur_decimals) as discount_amount,
          round(a.subtotal_raw - a.subtotal_raw * a.discount_pct / 100::numeric, a.cur_decimals) as items_total,
          round(a.paid_raw, a.cur_decimals) as paid,
          round(a.down_raw, a.cur_decimals) as down_payment,
          case when a.invoice_id is null
               then round(a.subtotal_raw - a.subtotal_raw * a.discount_pct / 100::numeric, a.cur_decimals)
               else round(a.invoice_total, a.cur_decimals) end as bill_total
     from agg a
 )
 select id as deal_id, currency, cur_decimals, item_count, payment_count, invoice_count,
        last_paid_on, subtotal, discount_pct, discount_amount, items_total,
        invoice_id, invoice_no, invoice_uploaded_at,
        case when invoice_id is null then 'items'::text else 'invoice'::text end as bill_source,
        bill_total, paid, down_payment,
        bill_total - paid as amount_left,
        items_total - bill_total as items_vs_bill,
        case when bill_total > 0::numeric
             then least(100::numeric, greatest(0::numeric, round(paid * 100::numeric / bill_total, 1)))
             else 0::numeric end as percent_paid,
        case when (bill_total - paid) < 0::numeric then 'overpaid'::text
             when bill_total = 0::numeric and paid = 0::numeric then 'empty'::text
             when (bill_total - paid) = 0::numeric then 'covered'::text
             when paid = 0::numeric then 'unpaid'::text
             else 'partial'::text end as status
   from calc c;

-- An allocation reduces an invoice only once its receipt is posted.
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
         inv.amount - coalesce(al.allocated, 0) - coalesce(cr.credited, 0) as outstanding,
         public.age_bucket(si.due_date) as age_bucket
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
   where si.status = 'posted';

-- ====================== PART 2: POST AND REVERSE =====================

-- One place for a payment's arithmetic. preview_payment and post_payment both
-- read it, so what the owner is shown and what lands in the ledger are the same
-- numbers. STABLE on purpose: it issues no document number, because a preview
-- that burned a PAY- code would leave a permanent hole every time one was
-- opened and abandoned (see peek_party_code vs next_party_code).
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

  -- The allocated share carries the whole exchange difference, because it is
  -- the only part with a bill behind it to compare against. An advance has no
  -- bill, so its base value simply is the money that moved.
  alcb  := public.to_base(alc, rt, base);
  alcbk := case when alc >= pay.amount then bank
                else round(bank * alc / pay.amount, dec) end;

  return query select
    comp, case dl.direction when 'receiving' then 'customer' else 'supplier' end,
    base, dec, dl.currency, dl.party_id, pay.paid_on, bcode, rt,
    pay.amount, book, bank, alc, alcb, alcbk, round(bank - alcbk, dec);
end;
$fn$;

-- What posting would do, without doing it (spec page 26's "Preview journal").
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
    if pl.alloc_foreign > 0 then
      raise exception 'A supplier payment cannot be allocated yet: supplier invoice matching (PIN) is phase 2. Post it as an advance and apply it when the bill is matched.';
    end if;
    return query
      select '1400'::text, a.name, pl.bank_base, 0::numeric, 'Supplier advance'::text
        from public.accounts a where a.code = '1400'
      union all
      select pl.bank_code, a.name, 0::numeric, pl.bank_base, 'Paid from bank'::text
        from public.accounts a where a.code = pl.bank_code;
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

-- Post a draft payment. Returns the journal id (the settlement one when a
-- receipt both clears invoices and leaves an advance).
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

  if pl.side = 'supplier' then
    if pl.alloc_foreign > 0 then
      raise exception 'A supplier payment cannot be allocated yet: supplier invoice matching (PIN) is phase 2. Post it as an advance and apply it when the bill is matched.';
    end if;
    jid := public.post_event(
             p_company      => pl.company_id,
             p_event        => 'supplier_advance',
             p_source_table => 'payments',
             p_source_id    => p_payment,
             p_amount       => pl.bank_base,
             p_currency     => pl.base_currency,
             p_entry_date   => pl.entry_date,
             p_rate         => 1,
             p_party        => pl.party_id,
             p_item         => null,
             p_warehouse    => null,
             p_memo         => coalesce(nullif(p_memo, ''), 'Supplier payment ' || docno));
  else
    if pl.alloc_foreign > 0 then
      jid := public.post_settlement(
               pl.company_id, 'customer', 'payments', p_payment,
               pl.alloc_book_base, pl.alloc_bank_base, pl.party_id,
               pl.entry_date, pl.bank_code,
               case when pl.deal_currency = pl.base_currency then null else pl.deal_currency end,
               case when pl.deal_currency = pl.base_currency then null else pl.alloc_foreign end,
               case when pl.deal_currency = pl.base_currency then null else pl.rate end,
               coalesce(nullif(p_memo, ''), 'Customer receipt ' || docno));
    end if;

    if pl.advance_base > 0 then
      jadv := public.post_event(
                p_company      => pl.company_id,
                p_event        => 'customer_advance',
                p_source_table => 'payments',
                p_source_id    => p_payment,
                p_amount       => pl.advance_base,
                p_currency     => pl.base_currency,
                p_entry_date   => pl.entry_date,
                p_rate         => 1,
                p_party        => pl.party_id,
                p_item         => null,
                p_warehouse    => null,
                p_memo         => coalesce(nullif(p_memo, ''), 'Customer advance ' || docno));
      jid := coalesce(jid, jadv);
    end if;
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

-- Reversal is the owner's call, and goes through reverse_journal so the mirror
-- entry and the 'reversed' status are the engine's work, not a second opinion.
create or replace function public.reverse_payment(p_payment uuid, p_reason text)
returns int
language plpgsql security definer set search_path to '' as $fn$
declare
  pay public.payments;
  j   record;
  n   int := 0;
begin
  if not private.is_owner() then
    raise exception 'Only the owner can reverse a posted payment.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reversal needs a reason.';
  end if;

  select * into pay from public.payments where id = p_payment for update;
  if pay.id is null then
    raise exception 'Payment not found.';
  end if;
  if pay.status <> 'posted' then
    raise exception 'Only a posted payment can be reversed; this one is %.', pay.status;
  end if;

  for j in select id from public.journals
            where source_table = 'payments' and source_id = p_payment
              and status = 'posted'
            order by doc_no
  loop
    perform public.reverse_journal(j.id, p_reason);
    n := n + 1;
  end loop;

  if n = 0 then
    raise exception 'That payment is marked posted but has no posted journal behind it. Tell the owner before going further.';
  end if;

  update public.payments
     set status         = 'reversed',
         reversed_at    = now(),
         reversed_by    = (select auth.uid()),
         reverse_reason = p_reason
   where id = p_payment;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('payments', p_payment, 'reversed', (select auth.uid()), p_reason,
          jsonb_build_object('journals_reversed', n, 'doc_no', pay.doc_no));

  return n;
end;
$fn$;

-- ===================== PART 3: AGING AND BANK ========================

-- Spec page 8: "Show advances separately." An advance is money held with no
-- bill behind it yet, so it is a ledger balance, not an open item.
create or replace view public.customer_advances
with (security_invoker = true) as
  select l.party_id,
         p.name as party_name,
         p.cus_code,
         j.company_id,
         sum(l.credit - l.debit) as advance_base
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id and j.status = 'posted'
    join public.parties p on p.id = l.party_id
   where l.account_code = '2200'
   group by l.party_id, p.name, p.cus_code, j.company_id
  having sum(l.credit - l.debit) <> 0;

create or replace view public.supplier_advances
with (security_invoker = true) as
  select l.party_id,
         p.name as party_name,
         p.sup_code,
         p.supplier_no,
         j.company_id,
         sum(l.debit - l.credit) as advance_base
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id and j.status = 'posted'
    join public.parties p on p.id = l.party_id
   where l.account_code = '1400'
   group by l.party_id, p.name, p.sup_code, p.supplier_no, j.company_id
  having sum(l.debit - l.credit) <> 0;

-- Spec page 8's aging bands, per customer, over posted sales invoices.
create or replace view public.ar_aging
with (security_invoker = true) as
  select oi.party_id,
         oi.party_name,
         oi.cus_code,
         oi.currency,
         oi.cur_decimals,
         count(*) as open_invoices,
         sum(case when oi.age_bucket = 'not due' then oi.outstanding else 0 end) as not_due,
         sum(case when oi.age_bucket = '1-30'    then oi.outstanding else 0 end) as overdue_1_30,
         sum(case when oi.age_bucket = '31-60'   then oi.outstanding else 0 end) as overdue_31_60,
         sum(case when oi.age_bucket = '61-90'   then oi.outstanding else 0 end) as overdue_61_90,
         sum(case when oi.age_bucket = 'over 90' then oi.outstanding else 0 end) as overdue_over_90,
         sum(oi.outstanding) as total_outstanding
    from public.customer_open_items oi
   where oi.outstanding > 0
   group by oi.party_id, oi.party_name, oi.cus_code, oi.currency, oi.cur_decimals;

-- The payable side has no matched supplier bill yet: supplier invoice matching
-- (PIN) is the unfinished part of phase 2. Until it lands, what we owe is read
-- from the purchase ORDER - deal_summary's bill against what has been paid -
-- and the due date is the invoice date plus the supplier's terms. When PIN
-- exists this view switches to those bills, and the shape here is what it has
-- to keep. Treat 'bill_source' as the warning: 'order' means no posted payable
-- stands behind the figure.
create or replace view public.supplier_open_items
with (security_invoker = true) as
  select d.id as deal_id,
         d.doc_no,
         d.party_id,
         p.name as party_name,
         p.sup_code,
         p.supplier_no,
         s.invoice_no,
         s.invoice_uploaded_at::date as invoice_date,
         case when p.payment_terms_days is not null and s.invoice_uploaded_at is not null
              then (s.invoice_uploaded_at::date + p.payment_terms_days)
              else null end as due_date,
         s.currency,
         s.cur_decimals,
         s.bill_total as amount,
         s.paid,
         s.amount_left as outstanding,
         'order'::text as bill_source,
         public.age_bucket(
           case when p.payment_terms_days is not null and s.invoice_uploaded_at is not null
                then (s.invoice_uploaded_at::date + p.payment_terms_days)
                else null end) as age_bucket
    from public.deals d
    join public.deal_summary s on s.deal_id = d.id
    left join public.parties p on p.id = d.party_id
   where d.direction = 'sending'
     and d.deleted_at is null
     and s.amount_left > 0;

create or replace view public.ap_aging
with (security_invoker = true) as
  select oi.party_id,
         oi.party_name,
         oi.sup_code,
         oi.supplier_no,
         oi.currency,
         oi.cur_decimals,
         count(*) as open_bills,
         sum(case when oi.age_bucket = 'not due' then oi.outstanding else 0 end) as not_due,
         sum(case when oi.age_bucket = '1-30'    then oi.outstanding else 0 end) as overdue_1_30,
         sum(case when oi.age_bucket = '31-60'   then oi.outstanding else 0 end) as overdue_31_60,
         sum(case when oi.age_bucket = '61-90'   then oi.outstanding else 0 end) as overdue_61_90,
         sum(case when oi.age_bucket = 'over 90' then oi.outstanding else 0 end) as overdue_over_90,
         sum(oi.outstanding) as total_outstanding
    from public.supplier_open_items oi
   group by oi.party_id, oi.party_name, oi.sup_code, oi.supplier_no,
            oi.currency, oi.cur_decimals;

-- Spec page 13's "Bank and currency" figure: what the ledger says each bank
-- account holds. Posted journals only, so a draft never moves a balance.
create or replace view public.bank_balances
with (security_invoker = true) as
  select b.id as bank_account_id,
         b.company_id,
         b.code,
         b.name,
         b.currency,
         b.gl_code,
         t.balance_base,
         t.movements
    from public.bank_accounts b
    cross join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as balance_base,
             count(*) as movements
        from public.journal_lines l
        join public.journals j on j.id = l.journal_id
       where j.status = 'posted'
         and j.company_id = b.company_id
         and l.account_code = b.gl_code
    ) t
   where b.active;

-- ============ PART 4: A REVERSED JOURNAL STAYS IN A BALANCE ==========
--
-- The three views above were written filtering `j.status = 'posted'`, and the
-- phase 4 acceptance test caught it: after reverse_payment, supplier_advances
-- still reported a row. 'reversed' means corrected, not never happened, and
-- the linked mirror journal is what cancels it, so the pair must net to zero.
-- Filtering to 'posted' alone drops the original and leaves the mirror
-- standing, which reported a reversed KWD 400 advance as its own opposite.
-- This is the same bug as general_ledger on 2026-10-29 (fixed then by
-- erp_phase5_fix_reversed_journals_stay_in_ledger), reintroduced here in new
-- views and caught before it ever saw real data. Any future view that sums
-- journal_lines must filter `status in ('posted','reversed')`.

create or replace view public.customer_advances
with (security_invoker = true) as
  select l.party_id,
         p.name as party_name,
         p.cus_code,
         j.company_id,
         sum(l.credit - l.debit) as advance_base
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id and j.status in ('posted', 'reversed')
    join public.parties p on p.id = l.party_id
   where l.account_code = '2200'
   group by l.party_id, p.name, p.cus_code, j.company_id
  having sum(l.credit - l.debit) <> 0;

create or replace view public.supplier_advances
with (security_invoker = true) as
  select l.party_id,
         p.name as party_name,
         p.sup_code,
         p.supplier_no,
         j.company_id,
         sum(l.debit - l.credit) as advance_base
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id and j.status in ('posted', 'reversed')
    join public.parties p on p.id = l.party_id
   where l.account_code = '1400'
   group by l.party_id, p.name, p.sup_code, p.supplier_no, j.company_id
  having sum(l.debit - l.credit) <> 0;

create or replace view public.bank_balances
with (security_invoker = true) as
  select b.id as bank_account_id,
         b.company_id,
         b.code,
         b.name,
         b.currency,
         b.gl_code,
         t.balance_base,
         t.movements
    from public.bank_accounts b
    cross join lateral (
      select coalesce(sum(l.debit - l.credit), 0) as balance_base,
             count(*) as movements
        from public.journal_lines l
        join public.journals j on j.id = l.journal_id
       where j.status in ('posted', 'reversed')
         and j.company_id = b.company_id
         and l.account_code = b.gl_code
    ) t
   where b.active;
