-- ERP phase 1, part 2: row-level security and opening setup.
--
-- The browser holds only the publishable key, so RLS is the whole security
-- boundary. Every new table gets policies before it holds a single row.
-- Reuses the existing private.can_edit() / private.is_owner() helpers.

-- ============================ ENABLE RLS =============================

alter table public.companies           enable row level security;
alter table public.warehouses          enable row level security;
alter table public.accounts            enable row level security;
alter table public.fx_rates            enable row level security;
alter table public.bank_accounts       enable row level security;
alter table public.items               enable row level security;
alter table public.item_costs          enable row level security;
alter table public.doc_sequences       enable row level security;
alter table public.journals            enable row level security;
alter table public.journal_lines       enable row level security;
alter table public.stock_moves         enable row level security;
alter table public.audit_log           enable row level security;
alter table public.payment_allocations enable row level security;

-- ===================== SETUP TABLES: OWNER WRITES =====================
-- Company, warehouses, chart of accounts and bank accounts are
-- configuration. Any signed-in user may read them; only the owner changes
-- them, because an edit here silently re-routes every future journal.

do $do$
declare
  t text;
begin
  foreach t in array array['companies','warehouses','accounts','bank_accounts']
  loop
    execute format('drop policy if exists %I_read on public.%I', t, t);
    execute format(
      'create policy %I_read on public.%I for select to authenticated using (true)', t, t);

    execute format('drop policy if exists %I_write on public.%I', t, t);
    execute format(
      'create policy %I_write on public.%I for all to authenticated '
      'using (private.is_owner()) with check (private.is_owner())', t, t);
  end loop;
end
$do$;

-- ================== OPERATIONAL TABLES: can_edit WRITES ===============
-- Items, costs, rates and allocations are day-to-day work.

do $do$
declare
  t text;
begin
  foreach t in array array['items','item_costs','fx_rates','payment_allocations']
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

-- ===================== JOURNALS: POST, NEVER REWRITE ==================
-- Read for anyone signed in, so the Accounting screens can show a journal.
-- Insert and update need can_edit; the triggers in part 1 then refuse any
-- change to a posted row, so a policy is never the thing that lets a
-- posted journal be edited.

drop policy if exists journals_read on public.journals;
create policy journals_read on public.journals
  for select to authenticated using (true);

drop policy if exists journals_insert on public.journals;
create policy journals_insert on public.journals
  for insert to authenticated with check (private.can_edit());

drop policy if exists journals_update on public.journals;
create policy journals_update on public.journals
  for update to authenticated using (private.can_edit()) with check (private.can_edit());

-- No delete policy at all: a journal is never deleted, only reversed.

drop policy if exists journal_lines_read on public.journal_lines;
create policy journal_lines_read on public.journal_lines
  for select to authenticated using (true);

drop policy if exists journal_lines_write on public.journal_lines;
create policy journal_lines_write on public.journal_lines
  for all to authenticated
  using (private.can_edit()) with check (private.can_edit());

drop policy if exists stock_moves_read on public.stock_moves;
create policy stock_moves_read on public.stock_moves
  for select to authenticated using (true);

drop policy if exists stock_moves_insert on public.stock_moves;
create policy stock_moves_insert on public.stock_moves
  for insert to authenticated with check (private.can_edit());

-- ===================== AUDIT LOG: APPEND ONLY =========================

drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log
  for select to authenticated using (true);

drop policy if exists audit_append on public.audit_log;
create policy audit_append on public.audit_log
  for insert to authenticated with check (true);

-- No update and no delete policy: the trail cannot be rewritten.

-- ================== NUMBERING: FUNCTION ACCESS ONLY ===================
-- next_doc_no() is security definer, so it still allocates numbers.
-- Nobody reaches the counter directly and rewinds it.

drop policy if exists doc_sequences_read on public.doc_sequences;
create policy doc_sequences_read on public.doc_sequences
  for select to authenticated using (true);

-- ========================= CHART OF ACCOUNTS ==========================
-- Exactly the categories listed on spec page 4.

insert into public.accounts (code, name, kind, is_control) values
  ('1100', 'Cash',                 'asset',     false),
  ('1110', 'Bank',                 'asset',     false),
  ('1200', 'Customer receivables', 'asset',     true),
  ('1300', 'Inventory',            'asset',     false),
  ('1310', 'Goods in transit',     'asset',     false),
  ('1400', 'Supplier advances',    'asset',     true),
  ('2100', 'Supplier payables',    'liability', true),
  ('2110', 'Receipt accrual',      'liability', false),
  ('2200', 'Customer advances',    'liability', true),
  ('3000', 'Equity',               'equity',    false),
  ('4000', 'Sales revenue',        'revenue',   false),
  ('5000', 'Cost of goods sold',   'expense',   false),
  ('6000', 'Expenses',             'expense',   false),
  ('6100', 'Exchange result',      'expense',   false)
on conflict (code) do nothing;

-- ====================== COMPANY AND WAREHOUSE =========================

insert into public.companies (code, name, base_currency)
values ('CO-001', 'Epsilon Electrical & Electronic Contracting', 'KWD')
on conflict (code) do nothing;

insert into public.warehouses (company_id, code, name)
select c.id, 'WH-001', 'Main store' from public.companies c where c.code = 'CO-001'
on conflict (company_id, code) do nothing;

insert into public.bank_accounts (company_id, code, name, currency, gl_code)
select c.id, 'BANK-KWD', 'KWD bank', 'KWD', '1110'
  from public.companies c where c.code = 'CO-001'
on conflict (company_id, code) do nothing;

-- ================== BACKFILL THE EXISTING RECORDS =====================
-- Codes for the accounts already on file, in creation order, so the
-- oldest supplier becomes SUP-000001.

with ranked as (
  select p.id,
         row_number() over (order by p.created_at, p.name) as n
    from public.parties p
   where p.kind in ('customer','both') and p.cus_code is null
)
update public.parties p
   set cus_code = 'CUS-' || lpad(r.n::text, 6, '0'),
       ar_code  = coalesce(p.ar_code, '1200')
  from ranked r where r.id = p.id;

with ranked as (
  select p.id,
         row_number() over (order by p.created_at, p.name) as n
    from public.parties p
   where p.kind in ('supplier','both') and p.sup_code is null
)
update public.parties p
   set sup_code = 'SUP-' || lpad(r.n::text, 6, '0'),
       ap_code  = coalesce(p.ap_code, '2100')
  from ranked r where r.id = p.id;

-- Existing deals belong to the one company and the one warehouse, and keep
-- status 'legacy': they were never journal-posted, so the posting engine
-- must not treat them as if they had been.
update public.deals d
   set company_id   = c.id,
       warehouse_id = w.id,
       doc_type     = case d.direction when 'sending' then 'purchase_order'
                                       else 'sales_order' end
  from public.companies c
  join public.warehouses w on w.company_id = c.id and w.code = 'WH-001'
 where c.code = 'CO-001' and d.company_id is null;

update public.payments p
   set company_id = c.id
  from public.companies c where c.code = 'CO-001' and p.company_id is null;

-- ===================== SEED THE ITEM MASTER ===========================
-- One item per distinct stock key already on the order lines, using the
-- same key stock_levels uses, so the existing Stock page keeps matching.
-- Brand and description come from the most recent line that named them.

with keyed as (
  select lower(nullif(btrim(coalesce(nullif(btrim(di.model), ''), di.description)), '')) as k,
         di.brand, di.model, di.description,
         row_number() over (
           partition by lower(nullif(btrim(coalesce(nullif(btrim(di.model), ''), di.description)), ''))
           order by d.deal_date desc nulls last, di.position) as rn
    from public.deal_items di
    join public.deals d on d.id = di.deal_id
   where lower(nullif(btrim(coalesce(nullif(btrim(di.model), ''), di.description)), '')) is not null
),
picked as (
  select k, brand, model, description,
         row_number() over (order by k) as n
    from keyed where rn = 1
)
insert into public.items (code, brand, model, description)
select 'ITM-' || lpad(p.n::text, 6, '0'), p.brand, p.model, p.description
  from picked p
 where not exists (select 1 from public.items i where i.stock_key = p.k);

-- Point the existing order lines at their new master record.
update public.deal_items di
   set item_id = i.id
  from public.items i
 where di.item_id is null
   and i.stock_key = lower(nullif(btrim(coalesce(nullif(btrim(di.model), ''), di.description)), ''));

-- Opening stock is deliberately NOT written here. Spec page 3 is explicit:
-- do not type an unexplained number into a master record. Quantities and
-- costs on hand arrive through an approved opening-balance transaction,
-- which is phase 6.
