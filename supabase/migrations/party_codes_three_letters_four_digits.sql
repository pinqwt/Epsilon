-- The owner's format for an account number: three letters, then four digits.
-- SUP-000003 becomes SUP0003.
--
-- This is a reformat, not a renumber. The digits are carried across unchanged,
-- so Bosch Security Systems stays account 3 -- which is what keeps faith with
-- the rule that one supplier holds one number, ever. Reissuing numbers here
-- would be the exact thing that rule exists to stop.

-- Existing accounts first, so the generators below never hand out a code that
-- an old-format row is about to turn into.
update public.parties
   set cus_code    = case when cus_code    ~ '^[A-Z]{3}-[0-9]+$'
                          then substr(cus_code, 1, 3)    || lpad(ltrim(substr(cus_code, 5), '0'), 4, '0')
                          else cus_code end,
       sup_code    = case when sup_code    ~ '^[A-Z]{3}-[0-9]+$'
                          then substr(sup_code, 1, 3)    || lpad(ltrim(substr(sup_code, 5), '0'), 4, '0')
                          else sup_code end,
       supplier_no = case when supplier_no ~ '^[A-Z]{3}-[0-9]+$'
                          then substr(supplier_no, 1, 3) || lpad(ltrim(substr(supplier_no, 5), '0'), 4, '0')
                          else supplier_no end
 where cus_code    ~ '^[A-Z]{3}-[0-9]+$'
    or sup_code    ~ '^[A-Z]{3}-[0-9]+$'
    or supplier_no ~ '^[A-Z]{3}-[0-9]+$';

-- Issue the next one. Four digits stop at 9999, so this says so rather than
-- quietly widening to five and leaving two formats in the ledger.
create or replace function public.next_party_code(p_company uuid, p_kind text)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  pfx  text := case when p_kind = 'customer' then 'CUS' else 'SUP' end;
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

  -- Walk past anything already taken: phase 1 handed codes to the accounts
  -- that existed without touching this counter.
  loop
    update public.doc_sequences
       set next_no = next_no + 1
     where company_id = p_company and doc_type = seq and year = 0
    returning next_no - 1 into n;

    if n > 9999 then
      raise exception 'Account numbers are three letters and four digits, so % is past the last one (%9999).', n, pfx;
    end if;

    code := pfx || lpad(n::text, 4, '0');
    exit when not exists (
      select 1 from public.parties
       where cus_code = code or sup_code = code
          or lower(btrim(supplier_no)) = lower(code));
  end loop;

  return code;
end;
$fn$;

-- The preview's read-only twin, kept in step with it. Still advances nothing.
create or replace function public.peek_party_code(p_company uuid, p_kind text)
returns text language plpgsql stable security definer set search_path to '' as $fn$
declare
  pfx  text := case when p_kind = 'customer' then 'CUS' else 'SUP' end;
  seq  text := 'party_' || p_kind;
  n    int;
  code text;
begin
  if p_kind not in ('customer', 'supplier') then
    raise exception 'A party code is either customer or supplier, not "%".', p_kind;
  end if;

  select next_no into n
    from public.doc_sequences
   where company_id = p_company and doc_type = seq and year = 0;

  n := coalesce(n, 1);

  loop
    if n > 9999 then
      return null;   -- nothing left to predict; next_party_code() will say so
    end if;
    code := pfx || lpad(n::text, 4, '0');
    exit when not exists (
      select 1 from public.parties
       where cus_code = code or sup_code = code
          or lower(btrim(supplier_no)) = lower(code));
    n := n + 1;
  end loop;

  return code;
end;
$fn$;
