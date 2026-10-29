-- ERP phase 1: foundation + posting engine.
-- Extends the existing schema in place. Changes nothing in deal_list,
-- deal_summary, deal_settlement, account_entries, party_account or
-- stock_levels, so every current screen keeps working untouched.

-- ============================== COMPANY ==============================

create table if not exists public.companies (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  name          text not null check (btrim(name) <> ''),
  base_currency text not null default 'KWD',
  created_at    timestamptz not null default now()
);

create table if not exists public.warehouses (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  code       text not null,
  name       text not null check (btrim(name) <> ''),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, code)
);

-- ========================= CHART OF ACCOUNTS =========================
-- Categories, never one account per customer. Party detail lives in the
-- subledger (journal_lines.party_id), exactly as spec page 4 requires.

create table if not exists public.accounts (
  code       text primary key,
  name       text not null,
  kind       text not null check (kind in ('asset','liability','equity','revenue','expense')),
  is_control boolean not null default false,
  active     boolean not null default true
);

-- =============================== FX ===================================
-- Rate is always base currency per 1 unit of foreign currency (page 10).

create table if not exists public.fx_rates (
  id         uuid primary key default gen_random_uuid(),
  currency   text not null,
  rate_date  date not null,
  rate       numeric not null check (rate > 0),
  note       text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  unique (currency, rate_date)
);

create table if not exists public.bank_accounts (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  code       text not null,
  name       text not null,
  currency   text not null,
  gl_code    text references public.accounts(code),
  active     boolean not null default true,
  unique (company_id, code)
);

-- ============================ ITEM MASTER =============================
-- Weighted average costing: one running cost per item per warehouse.

create table if not exists public.items (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  brand       text not null default '',
  model       text not null default '',
  description text not null default '',
  unit        text not null default 'PCS',
  barcode     text not null default '',
  oem_alts    text[] not null default '{}',
  cost_method text not null default 'weighted_average'
                check (cost_method in ('weighted_average')),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id),
  stock_key   text generated always as
                (lower(nullif(btrim(coalesce(nullif(btrim(model), ''), description)), ''))) stored
);

create unique index if not exists items_stock_key_uq
  on public.items (stock_key) where stock_key is not null;

create table if not exists public.item_costs (
  item_id      uuid not null references public.items(id),
  warehouse_id uuid not null references public.warehouses(id),
  qty_on_hand  numeric not null default 0,
  qty_reserved numeric not null default 0,
  avg_cost     numeric not null default 0 check (avg_cost >= 0),
  updated_at   timestamptz not null default now(),
  primary key (item_id, warehouse_id)
);

-- ========================= DOCUMENT NUMBERING =========================

create table if not exists public.doc_sequences (
  company_id uuid not null references public.companies(id),
  doc_type   text not null,
  year       int  not null,
  next_no    int  not null default 1,
  primary key (company_id, doc_type, year)
);

create or replace function public.doc_prefix(doc_type text)
returns text language sql immutable set search_path to '' as $fn$
  select case doc_type
    when 'purchase_order'   then 'PO'
    when 'shipment'         then 'SHP'
    when 'goods_receipt'    then 'GRN'
    when 'supplier_invoice' then 'PIN'
    when 'landed_cost'      then 'LC'
    when 'sales_order'      then 'SO'
    when 'delivery'         then 'DN'
    when 'sales_invoice'    then 'INV'
    when 'customer_receipt' then 'REC'
    when 'supplier_payment' then 'PAY'
    when 'credit_note'      then 'CN'
    when 'fx_conversion'    then 'FX'
    when 'journal'          then 'JV'
    else upper(substring(doc_type from 1 for 3))
  end
$fn$;

-- Locks the sequence row, so two users clicking Approve cannot collide.
create or replace function public.next_doc_no(p_company uuid, p_doc_type text, p_year int default null)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  yr int := coalesce(p_year, extract(year from now())::int);
  n  int;
begin
  insert into public.doc_sequences (company_id, doc_type, year, next_no)
  values (p_company, p_doc_type, yr, 1)
  on conflict (company_id, doc_type, year) do nothing;

  update public.doc_sequences
     set next_no = next_no + 1
   where company_id = p_company and doc_type = p_doc_type and year = yr
  returning next_no - 1 into n;

  return public.doc_prefix(p_doc_type) || '-' || yr::text || '-' || lpad(n::text, 6, '0');
end;
$fn$;

-- =========================== POSTING ENGINE ===========================

create table if not exists public.journals (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  doc_no        text not null,
  event         text not null,
  source_table  text not null,
  source_id     uuid not null,
  entry_date    date not null default current_date,
  base_currency text not null default 'KWD',
  status        text not null default 'draft'
                  check (status in ('draft','posted','reversed')),
  reversal_of   uuid references public.journals(id),
  reason        text not null default '',
  posted_at     timestamptz,
  posted_by     uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id)
);

-- One business event posts once. A retry cannot double-post.
create unique index if not exists journals_source_event_uq
  on public.journals (source_table, source_id, event)
  where status = 'posted';

create table if not exists public.journal_lines (
  id               uuid primary key default gen_random_uuid(),
  journal_id       uuid not null references public.journals(id) on delete cascade,
  line_no          int  not null default 0,
  account_code     text not null references public.accounts(code),
  party_id         uuid references public.parties(id),
  item_id          uuid references public.items(id),
  warehouse_id     uuid references public.warehouses(id),
  debit            numeric not null default 0 check (debit  >= 0),
  credit           numeric not null default 0 check (credit >= 0),
  foreign_currency text,
  foreign_amount   numeric,
  fx_rate          numeric check (fx_rate is null or fx_rate > 0),
  memo             text not null default '',
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

create index if not exists journal_lines_journal_idx on public.journal_lines (journal_id);
create index if not exists journal_lines_party_idx   on public.journal_lines (party_id);
create index if not exists journal_lines_account_idx on public.journal_lines (account_code);

-- Debit total must equal credit total at the moment of posting (page 9).
create or replace function public.assert_journal_balanced()
returns trigger language plpgsql set search_path to '' as $fn$
declare
  d numeric;
  c numeric;
begin
  if new.status <> 'posted' or (tg_op = 'UPDATE' and old.status = 'posted') then
    return new;
  end if;

  select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0)
    into d, c
    from public.journal_lines l where l.journal_id = new.id;

  if d = 0 and c = 0 then
    raise exception 'Journal % has no lines to post.', new.doc_no;
  end if;
  if round(d, 6) <> round(c, 6) then
    raise exception 'Journal % is out of balance: debit % vs credit %.', new.doc_no, d, c;
  end if;

  new.posted_at := coalesce(new.posted_at, now());
  new.posted_by := coalesce(new.posted_by, (select auth.uid()));
  return new;
end;
$fn$;

drop trigger if exists journals_balanced on public.journals;
create trigger journals_balanced
  before insert or update on public.journals
  for each row execute function public.assert_journal_balanced();

-- A posted journal is history. Only the status may move to 'reversed'.
create or replace function public.protect_posted_journal()
returns trigger language plpgsql set search_path to '' as $fn$
begin
  if tg_op = 'DELETE' then
    if old.status = 'posted' then
      raise exception 'Posted journal % cannot be deleted. Post a reversal instead.', old.doc_no;
    end if;
    return old;
  end if;

  if old.status = 'posted' then
    if new.status = 'reversed' and new.id = old.id
       and new.doc_no = old.doc_no and new.source_id = old.source_id then
      return new;
    end if;
    raise exception 'Posted journal % cannot be changed. Post a reversal instead.', old.doc_no;
  end if;
  return new;
end;
$fn$;

drop trigger if exists journals_immutable on public.journals;
create trigger journals_immutable
  before update or delete on public.journals
  for each row execute function public.protect_posted_journal();

create or replace function public.protect_posted_lines()
returns trigger language plpgsql set search_path to '' as $fn$
declare
  st text;
begin
  select j.status into st from public.journals j
   where j.id = coalesce(new.journal_id, old.journal_id);
  if st = 'posted' then
    raise exception 'The lines of a posted journal cannot be changed.';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists journal_lines_immutable on public.journal_lines;
create trigger journal_lines_immutable
  before insert or update or delete on public.journal_lines
  for each row execute function public.protect_posted_lines();

-- ========================== STOCK MOVEMENTS ===========================
-- One signed movement per posting, carrying its own cost and source.

create table if not exists public.stock_moves (
  id           uuid primary key default gen_random_uuid(),
  journal_id   uuid references public.journals(id),
  item_id      uuid not null references public.items(id),
  warehouse_id uuid not null references public.warehouses(id),
  qty          numeric not null check (qty <> 0),
  unit_cost    numeric not null default 0 check (unit_cost >= 0),
  source_table text not null default '',
  source_id    uuid,
  moved_on     date not null default current_date,
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id)
);

create index if not exists stock_moves_item_idx on public.stock_moves (item_id, warehouse_id);

-- ============================ AUDIT TRAIL =============================

create table if not exists public.audit_log (
  id         bigserial primary key,
  table_name text not null,
  row_id     uuid,
  action     text not null,
  actor      uuid references auth.users(id),
  reason     text not null default '',
  detail     jsonb not null default '{}',
  at         timestamptz not null default now()
);

create index if not exists audit_log_row_idx on public.audit_log (table_name, row_id);

-- ===================== EXTEND THE EXISTING TABLES =====================
-- Every addition is nullable or defaulted, so no current query changes.

alter table public.parties
  add column if not exists cus_code           text,
  add column if not exists sup_code           text,
  add column if not exists country            text not null default '',
  add column if not exists tax_id             text not null default '',
  add column if not exists default_currency   text,
  add column if not exists payment_terms_days int not null default 0,
  add column if not exists credit_limit       numeric not null default 0,
  add column if not exists ar_code            text references public.accounts(code),
  add column if not exists ap_code            text references public.accounts(code),
  add column if not exists bank_verified      boolean not null default false,
  add column if not exists active             boolean not null default true;

create unique index if not exists parties_cus_code_uq on public.parties (cus_code) where cus_code is not null;
create unique index if not exists parties_sup_code_uq on public.parties (sup_code) where sup_code is not null;

alter table public.deals
  add column if not exists company_id   uuid references public.companies(id),
  add column if not exists warehouse_id uuid references public.warehouses(id),
  add column if not exists doc_type     text,
  add column if not exists doc_no       text,
  add column if not exists status       text not null default 'legacy'
    check (status in ('legacy','draft','approved','posted','reversed')),
  add column if not exists fx_rate      numeric check (fx_rate is null or fx_rate > 0),
  add column if not exists rate_date    date,
  add column if not exists approved_by  uuid references auth.users(id),
  add column if not exists approved_at  timestamptz,
  add column if not exists posted_by    uuid references auth.users(id),
  add column if not exists posted_at    timestamptz;

create unique index if not exists deals_doc_no_uq on public.deals (doc_no) where doc_no is not null;

-- Ordered / shipped / received / accepted / delivered / invoiced are tracked
-- separately, per spec page 11: counted quantities, not value fractions.
alter table public.deal_items
  add column if not exists item_id       uuid references public.items(id),
  add column if not exists warehouse_id  uuid references public.warehouses(id),
  add column if not exists qty_shipped   numeric not null default 0,
  add column if not exists qty_received  numeric not null default 0,
  add column if not exists qty_accepted  numeric not null default 0,
  add column if not exists qty_damaged   numeric not null default 0,
  add column if not exists qty_delivered numeric not null default 0,
  add column if not exists qty_invoiced  numeric not null default 0,
  add column if not exists unit_cost     numeric not null default 0;

alter table public.payments
  add column if not exists company_id      uuid references public.companies(id),
  add column if not exists bank_account_id uuid references public.bank_accounts(id),
  add column if not exists doc_no          text,
  add column if not exists fx_rate         numeric check (fx_rate is null or fx_rate > 0),
  add column if not exists rate_date       date,
  add column if not exists status          text not null default 'legacy'
    check (status in ('legacy','draft','posted','reversed'));

alter table public.shipments
  add column if not exists doc_no            text,
  add column if not exists qty_received      numeric not null default 0,
  add column if not exists qty_accepted      numeric not null default 0,
  add column if not exists qty_damaged       numeric not null default 0,
  add column if not exists inspection_status text not null default 'none'
    check (inspection_status in ('none','awaiting','approved','rejected')),
  add column if not exists approved_by       uuid references auth.users(id),
  add column if not exists approved_at       timestamptz;

-- One payment can settle several invoices; one invoice can take several
-- payments. Unallocated money stays an advance (spec page 8).
create table if not exists public.payment_allocations (
  id         uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete cascade,
  invoice_id uuid references public.invoices(id),
  deal_id    uuid references public.deals(id),
  amount     numeric not null check (amount > 0),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

create index if not exists payment_alloc_payment_idx on public.payment_allocations (payment_id);
create index if not exists payment_alloc_invoice_idx on public.payment_allocations (invoice_id);
