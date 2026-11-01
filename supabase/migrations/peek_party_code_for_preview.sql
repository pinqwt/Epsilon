-- The import preview has to show a brand-new supplier the number they are
-- about to get, not a promise of one ("on save" tells the owner nothing).
--
-- It cannot call next_party_code() to find out: that bumps doc_sequences, so
-- every import that was opened and then cancelled would burn a code. Codes are
-- never reused, so each abandoned preview would leave a permanent hole in the
-- sequence -- and spec page 3 wants document numbers to run unbroken.
--
-- So this reads the counter instead of advancing it. It is a prediction, not a
-- reservation: next_party_code() still has the final say when the record is
-- actually saved, and the unique index on parties.supplier_no is still what
-- guarantees no two accounts share a number.
create or replace function public.peek_party_code(p_company uuid, p_kind text)
returns text language plpgsql stable security definer set search_path to '' as $fn$
declare
  pfx  text := case when p_kind = 'customer' then 'CUS-' else 'SUP-' end;
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

  -- No row yet means the sequence has never been drawn from, so the first code
  -- is the first number, exactly as next_party_code() would give it.
  n := coalesce(n, 1);

  -- Skip anything already taken. The 11 accounts carried over from phase 1
  -- adopted their sup_code as their visible number, so a code can be in use
  -- under any of the three columns.
  loop
    code := pfx || lpad(n::text, 6, '0');
    exit when not exists (
      select 1 from public.parties
       where cus_code = code or sup_code = code
          or lower(btrim(supplier_no)) = lower(code));
    n := n + 1;
  end loop;

  return code;
end;
$fn$;
