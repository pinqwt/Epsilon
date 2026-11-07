-- Accounts screen: contact fields, and a number that assigns itself (2026-11-07).
--
-- Applied as:
--   accounts_screen_and_party_numbering
--
-- The owner asked for three things that all land on `parties`:
--   1. open a customer or supplier account from the app, not only as a
--      side effect of importing an invoice;
--   2. have the app issue the account number itself, for customers as well
--      as suppliers;
--   3. carry the fields of the legacy "Account Receivable" screen that still
--      mean something here.
--
-- ONE ACCOUNT, ONE NUMBER - FOR CUSTOMERS TOO. `parties.supplier_no` is
-- already "the account number we give them" (decided 2026-11-01), and the
-- partial unique index on lower(btrim(supplier_no)) is already the backstop
-- that stops a balance splitting across two accounts. A customer needs
-- exactly the same guarantee, so a customer's number lives in the same
-- column rather than in a second one: a second column would need a second
-- index, a second rule, and would have nothing to say about an account whose
-- kind is `both`. `next_party_code(company, kind)` already emits CUS0001 for
-- a customer and SUP0012 for a supplier, so only the wrapper was missing.
-- `sup_code` / `cus_code` keep their phase 1 meaning and are filled to match.

-- ======================= THE CONTACT FIELDS =========================
-- From the legacy screen. Dropped deliberately, as having no meaning in this
-- app: Category 1/2 (no classification scheme), Date of Birth (accounts are
-- companies), Any Price and Sales Flag (no per-customer price lists),
-- Branch 1/2 (there are companies and warehouses here, not branches),
-- Alternate Print / SPCL / Print[1/0] (legacy printer routing), Salesman (no
-- salesman model), and Pager / Fax / Res.Tel. P.O. Box folds into `address`.

alter table public.parties
  add column if not exists name_ar        text not null default '',
  add column if not exists mobile         text not null default '',
  add column if not exists phone_office   text not null default '',
  add column if not exists email          text not null default '',
  add column if not exists address        text not null default '',
  add column if not exists contact_person text not null default '',
  add column if not exists updated_at     timestamptz,
  add column if not exists updated_by     uuid references auth.users(id);

comment on column public.parties.supplier_no is
  'The account number this app gives the account - SUP0012 for a supplier, '
  'CUS0001 for a customer. One account holds one number, for ever.';

-- Searching by name is what the Accounts screen does on every keystroke.
create index if not exists parties_name_lower_idx
  on public.parties (lower(name));

-- =================== THE NUMBER, FOR EITHER KIND ====================
-- The generalisation of ensure_supplier_no. Same three rules, which is the
-- whole point of it: a number already on file always wins, a claimed number
-- is taken up only by an account that has none, and a claim belonging to
-- someone else is refused and a fresh code generated instead. It is
-- idempotent, so calling it twice cannot issue a second number.
--
-- ensure_supplier_no is left exactly as it was: the import path calls it and
-- its behaviour is documented. This one is what the Accounts screen calls.

create or replace function public.ensure_party_no(
  p_party uuid, p_claim text default null)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  cur  text;
  knd  text;
  fam  text;
  code text;
  co   uuid;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change accounts.';
  end if;

  select coalesce(nullif(btrim(p.supplier_no), ''),
                  nullif(btrim(p.sup_code), ''),
                  nullif(btrim(p.cus_code), '')),
         p.kind
    into cur, knd
    from public.parties p where p.id = p_party;

  if not found then
    raise exception 'That account does not exist.';
  end if;

  -- A customer is numbered CUS, everything else SUP. An account whose kind
  -- is `both` buys and sells under one number, and it is a supplier number:
  -- picking by kind each time would renumber it the moment the kind changed,
  -- which is exactly what one-account-one-number forbids.
  fam := case when knd = 'customer' then 'customer' else 'supplier' end;

  if cur is not null then
    -- Already numbered. Keep it, and make sure the column actually holds it.
    update public.parties set supplier_no = cur
     where id = p_party and coalesce(btrim(supplier_no), '') = '';
    return cur;
  end if;

  code := nullif(btrim(coalesce(p_claim, '')), '');

  if code is not null and exists (
       select 1 from public.parties
        where id <> p_party and lower(btrim(supplier_no)) = lower(code)) then
    code := null;
  end if;

  if code is null then
    select id into co from public.companies limit 1;
    code := public.next_party_code(co, fam);
  end if;

  update public.parties
     set supplier_no = code,
         sup_code    = case when fam = 'supplier' then coalesce(sup_code, code)
                            else sup_code end,
         cus_code    = case when fam = 'customer' then coalesce(cus_code, code)
                            else cus_code end
   where id = p_party;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('parties', p_party, 'numbered', (select auth.uid()), '',
          jsonb_build_object('account_no', code, 'kind', knd));

  return code;
end;
$fn$;

revoke all on function public.ensure_party_no(uuid, text) from public;
grant execute on function public.ensure_party_no(uuid, text) to authenticated;

-- ===================== NUMBERED ON THE WAY IN =======================
-- The owner's ask: "the app should automatically create a supplier number or
-- customer number when creating one." So the number is issued by a trigger
-- rather than by whichever screen happened to open the account - an account
-- created from the Accounts screen, from an invoice import, or by the
-- deal-to-account link all come out numbered the same way.
--
-- An insert that already carries a number keeps it, so a caller that means to
-- claim a specific code still can. That is also the seam the import path uses:
-- a sheet's claimed number has to be supplied ON the insert to be adopted,
-- because once the row exists it is numbered and ensure_supplier_no's
-- "already numbered, keep it" branch is then the correct answer.

create or replace function private.parties_autonumber()
returns trigger language plpgsql security definer set search_path to '' as $fn$
declare
  fam  text;
  co   uuid;
  code text;
begin
  if coalesce(btrim(new.supplier_no), '') <> '' then
    return new;   -- the caller claimed one; honour it
  end if;

  -- An existing phase 1 code counts as the number, exactly as the 11 real
  -- accounts adopted theirs rather than being reissued.
  code := coalesce(nullif(btrim(new.sup_code), ''), nullif(btrim(new.cus_code), ''));

  if code is null then
    fam := case when new.kind = 'customer' then 'customer' else 'supplier' end;
    select id into co from public.companies limit 1;
    if co is null then
      return new;   -- no company configured yet; nothing to number against
    end if;
    code := public.next_party_code(co, fam);
    if fam = 'customer' then
      new.cus_code := coalesce(new.cus_code, code);
    else
      new.sup_code := coalesce(new.sup_code, code);
    end if;
  end if;

  new.supplier_no := code;
  return new;
end;
$fn$;

-- `create or replace` rather than drop-then-create: re-running the migration
-- then never leaves a window with no trigger on the table.
create or replace trigger parties_autonumber
  before insert on public.parties
  for each row execute function private.parties_autonumber();

-- ========================= WHO TOUCHED IT ===========================
-- The legacy screen showed Created By / Created Date / Updated By / Updated
-- Date, and they are worth keeping: an account number is retroactive across
-- every invoice already recorded, so who last changed one matters.

create or replace function private.parties_touch()
returns trigger language plpgsql security definer set search_path to '' as $fn$
begin
  new.updated_at := now();
  new.updated_by := (select auth.uid());
  return new;
end;
$fn$;

create or replace trigger parties_touch
  before update on public.parties
  for each row execute function private.parties_touch();
