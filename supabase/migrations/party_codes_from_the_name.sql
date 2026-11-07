-- Account numbers built from the NAME, the owner's own way (2026-11-07).
--
-- Applied as:
--   party_codes_from_the_name
--
-- The owner's existing accounts are numbered the way they have always done it
-- by hand: three letters taken from the name, then a number not used before.
-- "Mindware Computers" is `MNC-0037` - M, then the next consonant of
-- "Mindware", then the initial of "Computers". Asked for on 2026-11-07:
-- "taking the first 3 letters or the first letter and other 2 relevant
-- letters and then you add numbers that weren't added before."
--
-- This REPLACES the `SUP0012` / `CUS0001` shape for NEW accounts (set
-- 2026-11-01, superseded by the owner here). Accounts already numbered keep
-- what they hold: one account, one number, for ever - renumbering is
-- retroactive across every invoice already recorded, so it is never
-- automatic.
--
-- WHY THERE IS NO SEQUENCE BEHIND THIS. `next_party_code` drew from
-- `doc_sequences`, which is why `peek_party_code` had to exist beside it: a
-- preview that called the real generator burned a code. A name-derived code
-- has no counter to burn - it is computed from the rows that exist - so the
-- preview and the assignment are the same function, and abandoning the New
-- account form costs nothing. The partial unique index on
-- lower(btrim(supplier_no)) stays the backstop if two inserts race.

-- ========================= THE THREE LETTERS ========================

create or replace function public.party_code_prefix(p_name text)
returns text language plpgsql immutable set search_path to '' as $fn$
declare
  w    text[];
  sig  text[] := '{}';
  x    text;
  pre  text;
  rest text;
begin
  -- Everything that is not a letter becomes a gap, so "Co., Ltd." and
  -- "Power & Telecom" split into words the same way.
  w := regexp_split_to_array(
         btrim(regexp_replace(upper(coalesce(p_name, '')), '[^A-Z]+', ' ', 'g')),
         '\s+');

  -- Legal and filler words carry no identity: "Bosch Security Systems FZE"
  -- should read BSS, not BSF.
  foreach x in array w loop
    if x <> '' and x not in ('CO','COMPANY','LTD','LIMITED','LLC','WLL','FZE',
                             'FZCO','EST','ESTABLISHMENT','THE','AND','FOR',
                             'OF','INC','SA','SARL','PLC','GMBH','BV','NV')
    then
      sig := sig || x;
    end if;
  end loop;

  if array_length(sig, 1) is null then
    return 'ACC';                      -- a name with no letters in it at all
  end if;

  if array_length(sig, 1) >= 3 then
    -- Three or more words: their initials. "Al Babtain Power Telecom" -> ABP.
    pre := left(sig[1], 1) || left(sig[2], 1) || left(sig[3], 1);

  elsif array_length(sig, 1) = 2 then
    -- Two words: the owner's shape. First letter, then the next CONSONANT of
    -- that first word (the "other relevant letter" - a vowel carries less),
    -- then the second word's initial. "Mindware Computers" -> MNC.
    rest := regexp_replace(substr(sig[1], 2), '[AEIOU]', '', 'g');
    pre := left(sig[1], 1)
        || coalesce(nullif(left(rest, 1), ''), nullif(substr(sig[1], 2, 1), ''), 'X')
        || left(sig[2], 1);

  else
    -- One word: its first three letters. "Guanghzow" -> GUA.
    pre := left(sig[1], 3);
  end if;

  return rpad(left(regexp_replace(pre, '[^A-Z]', '', 'g'), 3), 3, 'X');
end;
$fn$;

-- ===================== THE NUMBER NOT USED BEFORE ===================
-- Highest number already issued under this prefix, plus one. Never reuses a
-- number, which is the rule that makes an account number permanent, and it
-- respects what is already on file: Mindware holds MNC-0037, so the next
-- Mindware-shaped account is MNC-0038, not MNC-0001.

create or replace function public.party_code_for(p_name text)
returns text language plpgsql stable set search_path to '' as $fn$
declare
  pre text;
  n   int;
begin
  pre := public.party_code_prefix(p_name);

  -- Only rows that already match the shape are considered, so the cast to
  -- int cannot meet anything that is not four digits.
  select coalesce(max(substring(p.supplier_no from '[0-9]{4}$')::int), 0)
    into n
    from public.parties p
   where p.supplier_no ~ ('^' || pre || '-[0-9]{4}$');

  if n >= 9999 then
    raise exception
      'Account numbers under % are exhausted at %-9999. Widening to five digits would leave two formats in the ledger.',
      pre, pre;
  end if;

  return pre || '-' || lpad((n + 1)::text, 4, '0');
end;
$fn$;

revoke all on function public.party_code_for(text) from public;
grant execute on function public.party_code_for(text) to authenticated;
revoke all on function public.party_code_prefix(text) from public;
grant execute on function public.party_code_prefix(text) to authenticated;

-- ===================== WHAT ISSUES IT ON INSERT =====================
-- Same trigger as before, now drawing from the name instead of the kind.
-- An insert that already carries a number still keeps it.

create or replace function private.parties_autonumber()
returns trigger language plpgsql security definer set search_path to '' as $fn$
declare
  code text;
begin
  if coalesce(btrim(new.supplier_no), '') <> '' then
    return new;   -- the caller claimed one; honour it
  end if;

  -- An existing phase 1 code counts as the number, exactly as the real
  -- accounts adopted theirs rather than being reissued.
  code := coalesce(nullif(btrim(new.sup_code), ''), nullif(btrim(new.cus_code), ''));

  if code is null then
    code := public.party_code_for(new.name);
    if new.kind = 'customer' then
      new.cus_code := coalesce(new.cus_code, code);
    else
      new.sup_code := coalesce(new.sup_code, code);
    end if;
  end if;

  new.supplier_no := code;
  return new;
end;
$fn$;

-- ensure_party_no generates the same way, so an account numbered by hand
-- later and one numbered on insert cannot come out in two different shapes.
create or replace function public.ensure_party_no(
  p_party uuid, p_claim text default null)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  cur  text;
  knd  text;
  nm   text;
  code text;
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to change accounts.';
  end if;

  select coalesce(nullif(btrim(p.supplier_no), ''),
                  nullif(btrim(p.sup_code), ''),
                  nullif(btrim(p.cus_code), '')),
         p.kind, p.name
    into cur, knd, nm
    from public.parties p where p.id = p_party;

  if not found then
    raise exception 'That account does not exist.';
  end if;

  if cur is not null then
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
    code := public.party_code_for(nm);
  end if;

  update public.parties
     set supplier_no = code,
         sup_code = case when knd <> 'customer' then coalesce(sup_code, code) else sup_code end,
         cus_code = case when knd =  'customer' then coalesce(cus_code, code) else cus_code end
   where id = p_party;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('parties', p_party, 'numbered', (select auth.uid()), '',
          jsonb_build_object('account_no', code, 'kind', knd));

  return code;
end;
$fn$;
