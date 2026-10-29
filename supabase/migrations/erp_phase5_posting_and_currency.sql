-- ERP phase 5: automatic journal templates, currency, locks, reversals.
--
-- Requires erp_phase1.sql (journals, journal_lines, accounts, fx_rates).
--
-- Spec page 9: users enter business documents; the software generates the
-- journal lines. The event decides which account goes on each side, so the
-- mapping lives in a table and not in app.js.

-- ======================== POSTING TEMPLATES ===========================

create table if not exists public.posting_templates (
  event       text primary key,
  label       text not null,
  path        text not null default 'common',
  debit_code  text not null references public.accounts(code),
  credit_code text not null references public.accounts(code),
  note        text not null default '',
  active      boolean not null default true
);

-- The thirteen events on spec page 9, in its order.
-- 'path' marks the three alternative purchase routes. The spec is explicit:
-- these are alternatives, and the same goods must not travel two of them.
insert into public.posting_templates (event, label, path, debit_code, credit_code, note) values
  ('supplier_advance',       'Supplier advance',                  'common',  '1400', '1110',
   'Money prepaid before any bill exists.'),
  ('goods_in_transit',       'Goods recognized while in transit', 'transit', '1310', '2100',
   'Ownership passed while the goods are travelling.'),
  ('receive_from_transit',   'Receive goods already in transit',  'transit', '1300', '1310',
   'Transit asset becomes warehouse stock.'),
  ('receive_before_invoice', 'Receive goods before invoice',      'accrual', '1300', '2110',
   'Goods counted in; the supplier bill has not arrived.'),
  ('match_invoice_receipt',  'Match later invoice to receipt',    'accrual', '2110', '2100',
   'Clears the accrual. Must not add stock a second time.'),
  ('landed_cost',            'Eligible freight / customs',        'common',  '1300', '2100',
   'Adds to stock cost. Recoverable tax is kept out of this.'),
  ('pay_supplier_bill',      'Pay supplier bill',                 'common',  '2100', '1110',
   'Exchange difference added as a third line when the rate moved.'),
  ('credit_sales_invoice',   'Credit sales invoice',              'common',  '1200', '4000',
   'Revenue and the customer debt, at the configured recognition event.'),
  ('delivery_cost',          'Post delivery cost',                'common',  '5000', '1300',
   'Releases stock cost as cost of goods sold.'),
  ('customer_collection',    'Customer collection',               'common',  '1110', '1200',
   'Money in. Not another sale.'),
  ('customer_advance',       'Customer advance',                  'common',  '1110', '2200',
   'Collected before it is applied to an invoice.'),
  ('apply_supplier_advance', 'Apply supplier advance',            'common',  '2100', '1400',
   'Uses prepaid money against a bill.'),
  ('apply_customer_advance', 'Apply customer advance',            'common',  '2200', '1200',
   'Uses money held on account against an invoice.')
on conflict (event) do nothing;

-- =========================== PERIOD LOCKS =============================
-- Once a month is closed, nothing may post into it (spec page 11).

create table if not exists public.period_locks (
  company_id     uuid primary key references public.companies(id),
  locked_through date,
  reason         text not null default '',
  updated_at     timestamptz not null default now(),
  updated_by     uuid references auth.users(id)
);

create or replace function public.assert_period_open(p_company uuid, p_date date)
returns void language plpgsql stable set search_path to '' as $fn$
declare
  lock_date date;
begin
  select l.locked_through into lock_date
    from public.period_locks l where l.company_id = p_company;

  if lock_date is not null and p_date <= lock_date then
    raise exception 'The books are closed through %. Nothing can post on %.',
      to_char(lock_date, 'DD Mon YYYY'), to_char(p_date, 'DD Mon YYYY');
  end if;
end;
$fn$;

-- ============================= CURRENCY ===============================
-- Rate is always base currency per 1 unit of foreign currency (page 10).
-- A posted rate is never recalculated; history is kept.

create or replace function public.fx_rate_for(p_currency text, p_date date, p_base text default 'KWD')
returns numeric language plpgsql stable set search_path to '' as $fn$
declare
  r numeric;
begin
  if upper(coalesce(p_currency, p_base)) = upper(p_base) then
    return 1;
  end if;

  select f.rate into r
    from public.fx_rates f
   where upper(f.currency) = upper(p_currency)
     and f.rate_date <= p_date
   order by f.rate_date desc
   limit 1;

  if r is null then
    raise exception 'No exchange rate on file for % on or before %. Enter the rate first.',
      upper(p_currency), to_char(p_date, 'DD Mon YYYY');
  end if;
  return r;
end;
$fn$;

-- Base value, rounded to the base currency's own precision. KWD has three
-- decimals, so "zero left" keeps meaning exactly zero.
create or replace function public.to_base(p_amount numeric, p_rate numeric, p_base text default 'KWD')
returns numeric language sql immutable set search_path to '' as $fn$
  select round(coalesce(p_amount, 0) * coalesce(p_rate, 1), public.currency_decimals(p_base))
$fn$;

-- ========================= THE POSTING ACTION =========================
-- Spec page 11: validate -> commit -> link, saved together, rolled back
-- whole on failure. A plpgsql function is already one transaction, so a
-- raise anywhere below undoes every effect.

create or replace function public.post_event(
  p_company      uuid,
  p_event        text,
  p_source_table text,
  p_source_id    uuid,
  p_amount       numeric,
  p_currency     text default null,
  p_entry_date   date default null,
  p_rate         numeric default null,
  p_party        uuid default null,
  p_item         uuid default null,
  p_warehouse    uuid default null,
  p_memo         text default ''
) returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  tpl    public.posting_templates;
  base   text;
  edate  date := coalesce(p_entry_date, current_date);
  cur    text;
  rate   numeric;
  val    numeric;
  jid    uuid;
  docno  text;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;

  select c.base_currency into base from public.companies c where c.id = p_company;
  if base is null then
    raise exception 'Unknown company.';
  end if;

  select * into tpl from public.posting_templates t
   where t.event = p_event and t.active;
  if not found then
    raise exception 'There is no approved posting template for the event "%".', p_event;
  end if;

  perform public.assert_period_open(p_company, edate);

  cur  := upper(coalesce(nullif(btrim(p_currency), ''), base));
  rate := coalesce(p_rate, public.fx_rate_for(cur, edate, base));
  val  := public.to_base(p_amount, rate, base);

  if val <= 0 then
    raise exception 'A posting needs an amount above zero (got %).', val;
  end if;

  docno := public.next_doc_no(p_company, 'journal', extract(year from edate)::int);

  insert into public.journals (
    company_id, doc_no, event, source_table, source_id,
    entry_date, base_currency, status, reason, created_by)
  values (
    p_company, docno, p_event, p_source_table, p_source_id,
    edate, base, 'draft', coalesce(p_memo, ''), (select auth.uid()))
  returning id into jid;

  insert into public.journal_lines (
    journal_id, line_no, account_code, party_id, item_id, warehouse_id,
    debit, credit, foreign_currency, foreign_amount, fx_rate, memo)
  values
    (jid, 1, tpl.debit_code,  p_party, p_item, p_warehouse,
     val, 0, nullif(cur, base), case when cur <> base then p_amount end,
     nullif(rate, 1), tpl.label),
    (jid, 2, tpl.credit_code, p_party, p_item, p_warehouse,
     0, val, nullif(cur, base), case when cur <> base then p_amount end,
     nullif(rate, 1), tpl.label);

  -- The balance trigger checks debit = credit here and refuses otherwise.
  update public.journals set status = 'posted' where id = jid;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('journals', jid, 'posted', (select auth.uid()), coalesce(p_memo, ''),
          jsonb_build_object('event', p_event, 'doc_no', docno,
                             'base_value', val, 'currency', cur, 'rate', rate));

  return jid;
end;
$fn$;

-- Shows the lines an event would produce, without writing anything.
-- Backs the journal preview screen on spec page 29.
create or replace function public.preview_event(
  p_company    uuid,
  p_event      text,
  p_amount     numeric,
  p_currency   text default null,
  p_entry_date date default null,
  p_rate       numeric default null
) returns table (account_code text, account_name text, debit numeric, credit numeric)
language plpgsql stable security definer set search_path to '' as $fn$
declare
  tpl   public.posting_templates;
  base  text;
  edate date := coalesce(p_entry_date, current_date);
  rate  numeric;
  val   numeric;
begin
  select c.base_currency into base from public.companies c where c.id = p_company;
  select * into tpl from public.posting_templates t where t.event = p_event and t.active;
  if not found then
    raise exception 'There is no approved posting template for the event "%".', p_event;
  end if;

  rate := coalesce(p_rate, public.fx_rate_for(
            upper(coalesce(nullif(btrim(p_currency), ''), base)), edate, base));
  val  := public.to_base(p_amount, rate, base);

  return query
    select a.code, a.name, val, 0::numeric from public.accounts a where a.code = tpl.debit_code
    union all
    select a.code, a.name, 0::numeric, val from public.accounts a where a.code = tpl.credit_code;
end;
$fn$;

-- ==================== SETTLEMENT WITH EXCHANGE DIFF ===================
-- Spec page 26: a USD 10,000 bill carried at KWD 3,070 settled with
-- KWD 3,100 from the bank is fully paid, and the KWD 30 is exchange loss,
-- not an unpaid remainder. Three lines, so it needs its own function.

create or replace function public.post_settlement(
  p_company      uuid,
  p_side         text,              -- 'supplier' | 'customer'
  p_source_table text,
  p_source_id    uuid,
  p_book_base    numeric,           -- what the debt is carried at
  p_bank_base    numeric,           -- what actually moved through the bank
  p_party        uuid,
  p_entry_date   date default null,
  p_bank_code    text default '1110',
  p_foreign_cur  text default null,
  p_foreign_amt  numeric default null,
  p_rate         numeric default null,
  p_memo         text default ''
) returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  base       text;
  edate      date := coalesce(p_entry_date, current_date);
  dec        int;
  book       numeric;
  bank       numeric;
  diff       numeric;
  party_code text;
  jid        uuid;
  docno      text;
  ev         text;
  ln         int := 0;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to post.';
  end if;
  if p_side not in ('supplier', 'customer') then
    raise exception 'Settlement side must be supplier or customer, not "%".', p_side;
  end if;

  select c.base_currency into base from public.companies c where c.id = p_company;
  if base is null then
    raise exception 'Unknown company.';
  end if;

  perform public.assert_period_open(p_company, edate);

  dec  := public.currency_decimals(base);
  book := round(coalesce(p_book_base, 0), dec);
  bank := round(coalesce(p_bank_base, 0), dec);
  if book <= 0 or bank <= 0 then
    raise exception 'A settlement needs both a book value and a bank amount above zero.';
  end if;

  party_code := case p_side when 'supplier' then '2100' else '1200' end;
  ev         := case p_side when 'supplier' then 'pay_supplier_bill' else 'customer_collection' end;
  docno      := public.next_doc_no(p_company, 'journal', extract(year from edate)::int);

  insert into public.journals (
    company_id, doc_no, event, source_table, source_id,
    entry_date, base_currency, status, reason, created_by)
  values (
    p_company, docno, ev, p_source_table, p_source_id,
    edate, base, 'draft', coalesce(p_memo, ''), (select auth.uid()))
  returning id into jid;

  if p_side = 'supplier' then
    -- Clear the payable at book value; bank gives up what it actually paid.
    diff := bank - book;                       -- positive = exchange loss
    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code, party_id,
      debit, credit, foreign_currency, foreign_amount, fx_rate, memo)
    values (jid, ln, party_code, p_party, book, 0,
            p_foreign_cur, p_foreign_amt, p_rate, 'Supplier payable cleared');

    if diff > 0 then
      ln := ln + 1;
      insert into public.journal_lines (journal_id, line_no, account_code, debit, credit, memo)
      values (jid, ln, '6100', diff, 0, 'Exchange loss on settlement');
    end if;

    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code, debit, credit, memo)
    values (jid, ln, p_bank_code, 0, bank, 'Paid from bank');

    if diff < 0 then
      ln := ln + 1;
      insert into public.journal_lines (journal_id, line_no, account_code, debit, credit, memo)
      values (jid, ln, '6100', 0, -diff, 'Exchange gain on settlement');
    end if;
  else
    -- Collect from the customer; clear the receivable at book value.
    diff := book - bank;                       -- positive = exchange loss
    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code, debit, credit, memo)
    values (jid, ln, p_bank_code, bank, 0, 'Collected into bank');

    if diff > 0 then
      ln := ln + 1;
      insert into public.journal_lines (journal_id, line_no, account_code, debit, credit, memo)
      values (jid, ln, '6100', diff, 0, 'Exchange loss on collection');
    end if;

    ln := ln + 1;
    insert into public.journal_lines (journal_id, line_no, account_code, party_id,
      debit, credit, foreign_currency, foreign_amount, fx_rate, memo)
    values (jid, ln, party_code, p_party, 0, book,
            p_foreign_cur, p_foreign_amt, p_rate, 'Customer receivable cleared');

    if diff < 0 then
      ln := ln + 1;
      insert into public.journal_lines (journal_id, line_no, account_code, debit, credit, memo)
      values (jid, ln, '6100', 0, -diff, 'Exchange gain on collection');
    end if;
  end if;

  update public.journals set status = 'posted' where id = jid;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('journals', jid, 'posted', (select auth.uid()), coalesce(p_memo, ''),
          jsonb_build_object('event', ev, 'doc_no', docno, 'book_base', book,
                             'bank_base', bank, 'exchange_difference', diff));

  return jid;
end;
$fn$;

-- ===================== BANK CURRENCY CONVERSION =======================
-- Spec page 28: moving your own money between your own currency accounts.
-- Not a purchase and not a sale.

create table if not exists public.fx_conversions (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id),
  doc_no       text,
  from_bank    uuid not null references public.bank_accounts(id),
  to_bank      uuid not null references public.bank_accounts(id),
  from_amount  numeric not null check (from_amount > 0),
  to_amount    numeric not null check (to_amount > 0),
  actual_rate  numeric not null check (actual_rate > 0),
  fees_base    numeric not null default 0 check (fees_base >= 0),
  converted_on date not null default current_date,
  status       text not null default 'draft'
                 check (status in ('draft','posted','reversed')),
  note         text not null default '',
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id),
  check (from_bank <> to_bank)
);

alter table public.fx_conversions enable row level security;

drop policy if exists fx_conv_read on public.fx_conversions;
create policy fx_conv_read on public.fx_conversions
  for select to authenticated using (true);

drop policy if exists fx_conv_write on public.fx_conversions;
create policy fx_conv_write on public.fx_conversions
  for all to authenticated
  using (private.can_edit()) with check (private.can_edit());

-- ========================= REVERSAL CONTROL ===========================
-- Spec page 11: posted records are never deleted or overwritten. A
-- correction is a new, linked, mirrored journal.

create or replace function public.reverse_journal(p_journal uuid, p_reason text)
returns uuid language plpgsql security definer set search_path to '' as $fn$
declare
  j     public.journals;
  jid   uuid;
  docno text;
begin
  if not private.is_owner() then
    raise exception 'Only the owner can reverse a posted journal.';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'A reversal needs a reason.';
  end if;

  select * into j from public.journals where id = p_journal;
  if not found then
    raise exception 'That journal does not exist.';
  end if;
  if j.status <> 'posted' then
    raise exception 'Only a posted journal can be reversed (this one is %).', j.status;
  end if;
  if exists (select 1 from public.journals r
              where r.reversal_of = p_journal and r.status = 'posted') then
    raise exception 'Journal % has already been reversed.', j.doc_no;
  end if;

  perform public.assert_period_open(j.company_id, current_date);

  docno := public.next_doc_no(j.company_id, 'journal', extract(year from current_date)::int);

  insert into public.journals (
    company_id, doc_no, event, source_table, source_id, entry_date,
    base_currency, status, reversal_of, reason, created_by)
  values (
    j.company_id, docno, j.event || '_reversal', j.source_table, j.source_id,
    current_date, j.base_currency, 'draft', j.id, btrim(p_reason), (select auth.uid()))
  returning id into jid;

  -- Same lines, sides swapped.
  insert into public.journal_lines (
    journal_id, line_no, account_code, party_id, item_id, warehouse_id,
    debit, credit, foreign_currency, foreign_amount, fx_rate, memo)
  select jid, l.line_no, l.account_code, l.party_id, l.item_id, l.warehouse_id,
         l.credit, l.debit, l.foreign_currency, l.foreign_amount, l.fx_rate,
         'Reversal of ' || j.doc_no
    from public.journal_lines l where l.journal_id = j.id;

  update public.journals set status = 'posted' where id = jid;

  -- The immutability trigger allows exactly this one transition.
  update public.journals set status = 'reversed' where id = j.id;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('journals', j.id, 'reversed', (select auth.uid()), btrim(p_reason),
          jsonb_build_object('original', j.doc_no, 'reversal', docno));

  return jid;
end;
$fn$;

-- ===================== PROOF THAT POSTING IS SOUND ====================
-- Not the phase 6 report pack. This is the one number that proves the
-- engine: across every posted journal, debit must equal credit.

-- A reversed journal STAYS in the ledger. Its linked reversal is what
-- cancels it, so the two net to zero. Filtering to status 'posted' alone
-- removed the original and left only the mirror standing, which showed the
-- opposite of the original transaction instead of nothing at all.
create or replace view public.general_ledger as
  select j.company_id, j.id as journal_id, j.doc_no, j.event, j.entry_date,
         j.status, j.base_currency, j.source_table, j.source_id,
         l.line_no, l.account_code, a.name as account_name, a.kind as account_kind,
         l.party_id, p.name as party_name, l.item_id, l.warehouse_id,
         l.debit, l.credit, l.foreign_currency, l.foreign_amount, l.fx_rate, l.memo,
         j.reversal_of
    from public.journals j
    join public.journal_lines l on l.journal_id = j.id
    join public.accounts a on a.code = l.account_code
    left join public.parties p on p.id = l.party_id
   where j.status in ('posted', 'reversed');

create or replace function public.trial_balance(p_company uuid, p_as_of date default null)
returns table (account_code text, account_name text, account_kind text,
               debit numeric, credit numeric, balance numeric)
language sql stable set search_path to '' as $fn$
  select g.account_code, g.account_name, g.account_kind,
         sum(g.debit), sum(g.credit), sum(g.debit) - sum(g.credit)
    from public.general_ledger g
   where g.company_id = p_company
     and (p_as_of is null or g.entry_date <= p_as_of)
   group by g.account_code, g.account_name, g.account_kind
   order by g.account_code
$fn$;

-- ============================ RLS ON NEW ==============================

alter table public.posting_templates enable row level security;
alter table public.period_locks      enable row level security;

drop policy if exists tpl_read on public.posting_templates;
create policy tpl_read on public.posting_templates
  for select to authenticated using (true);

-- Changing a template re-routes every future journal, so owner only.
drop policy if exists tpl_write on public.posting_templates;
create policy tpl_write on public.posting_templates
  for all to authenticated
  using (private.is_owner()) with check (private.is_owner());

drop policy if exists locks_read on public.period_locks;
create policy locks_read on public.period_locks
  for select to authenticated using (true);

drop policy if exists locks_write on public.period_locks;
create policy locks_write on public.period_locks
  for all to authenticated
  using (private.is_owner()) with check (private.is_owner());
