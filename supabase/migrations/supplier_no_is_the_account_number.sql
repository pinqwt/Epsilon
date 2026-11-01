-- The supplier number is the account number WE give a supplier, not a code
-- they print. None of the real invoices (DSPPA, Mindware, NMK) carries one,
-- so left to hand entry the field stays blank -- and the owner's rule, one
-- supplier one number, has nothing enforcing it. Typed by hand, the same
-- supplier can pick up a second number on the next sheet, which quietly
-- splits their balance across two accounts.
--
-- So: parties.supplier_no becomes the single visible number, the app assigns
-- it, and the database refuses a second one.

-- Existing accounts already hold an internal SUP- code from phase 1. Adopt
-- it as the visible number rather than issuing everyone a new one, which
-- would be the exact "two numbers" problem this is meant to stop.
update public.parties
   set supplier_no = sup_code
 where coalesce(btrim(supplier_no), '') = ''
   and coalesce(btrim(sup_code), '') <> '';

-- One number, one account, case-insensitively: 'sup-000003' and 'SUP-000003'
-- are the same account, and letting both exist is how a balance splits in two.
create unique index if not exists parties_supplier_no_uq
  on public.parties (lower(btrim(supplier_no)))
  where coalesce(btrim(supplier_no), '') <> '';

-- Hand an account its number, or give back the one it already has. Safe to
-- call twice: it reuses what is on file rather than issuing a second number,
-- and that idempotence is the whole point of the function. A caller-supplied
-- code (a supplier who does print one) wins over a generated SUP-, but only
-- while the account has nothing on file yet -- an uploaded sheet must never
-- renumber a supplier already being traded with.
create or replace function public.ensure_supplier_no(p_party uuid, p_claim text default null)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  cur  text;
  code text;
  co   uuid;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change accounts.';
  end if;

  select coalesce(nullif(btrim(supplier_no), ''), nullif(btrim(sup_code), ''))
    into cur
    from public.parties where id = p_party;

  if not found then
    raise exception 'That account does not exist.';
  end if;

  if cur is not null then
    update public.parties set supplier_no = cur
     where id = p_party and coalesce(btrim(supplier_no), '') = '';
    return cur;
  end if;

  code := nullif(btrim(coalesce(p_claim, '')), '');

  -- A claimed code already belonging to someone else is not usable.
  if code is not null and exists (
       select 1 from public.parties
        where id <> p_party and lower(btrim(supplier_no)) = lower(code)) then
    code := null;
  end if;

  if code is null then
    select id into co from public.companies limit 1;
    code := public.next_party_code(co, 'supplier');
  end if;

  update public.parties
     set supplier_no = code,
         sup_code    = coalesce(sup_code, code)
   where id = p_party;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('parties', p_party, 'numbered', (select auth.uid()), '',
          jsonb_build_object('supplier_no', code));

  return code;
end;
$fn$;
