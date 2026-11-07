-- Deleting an account from the app (2026-11-07).
--
-- Applied as:
--   delete_account
--
-- The owner asked to be able to delete accounts themselves rather than
-- through ad-hoc SQL, as the legacy screen's Delete button did.
--
-- WHY THIS IS A FUNCTION AND NOT JUST THE RLS DELETE POLICY. `parties_write`
-- already allows a delete, but `deals.party_id` and the invoice tables
-- reference `parties`, so a delete on an account with any history fails on a
-- foreign key - and what reaches the browser is
-- `violates foreign key constraint "deals_party_id_fkey"`, which tells the
-- owner nothing about what to do. This says which records are in the way and
-- how many, so the answer ("mark it inactive instead") is obvious.
--
-- AN ACCOUNT WITH HISTORY IS NEVER DELETED, ONLY DEACTIVATED. A party with a
-- posted journal line behind it is part of the ledger: deleting it would
-- leave entries pointing at nothing, and the trial balance is built on those
-- entries. An order - even a soft-deleted one - is the same argument one step
-- back. So this deletes only an account nothing refers to, which is exactly
-- the case the owner has: an account opened by mistake, or a sample row.
-- `active = false` is the answer for everything else, and the Accounts grid
-- already marks those rows "inactive".

create or replace function public.delete_party(p_party uuid)
returns text language plpgsql security definer set search_path to '' as $fn$
declare
  nm      text;
  code    text;
  n_deals int;
  n_si    int;
  n_pi    int;
  n_jl    int;
  n_ob    int;
  blocked text[] := '{}';
begin
  if not private.can_edit() then
    raise exception 'You do not have permission to delete accounts.';
  end if;

  select p.name, p.supplier_no into nm, code
    from public.parties p where p.id = p_party;
  if nm is null then
    raise exception 'That account does not exist.';
  end if;

  -- Soft-deleted orders count: the row is still there and still points here.
  select count(*) into n_deals from public.deals      where party_id = p_party;
  select count(*) into n_si    from public.sales_invoices    where party_id = p_party;
  select count(*) into n_pi    from public.supplier_invoices where party_id = p_party;
  select count(*) into n_jl    from public.journal_lines     where party_id = p_party;
  select count(*) into n_ob    from public.opening_balance_lines where party_id = p_party;

  if n_deals > 0 then blocked := blocked || (n_deals || ' order'  || case when n_deals = 1 then '' else 's' end); end if;
  if n_si    > 0 then blocked := blocked || (n_si    || ' sales invoice'    || case when n_si  = 1 then '' else 's' end); end if;
  if n_pi    > 0 then blocked := blocked || (n_pi    || ' supplier bill'    || case when n_pi  = 1 then '' else 's' end); end if;
  if n_jl    > 0 then blocked := blocked || (n_jl    || ' ledger entr'      || case when n_jl  = 1 then 'y' else 'ies' end); end if;
  if n_ob    > 0 then blocked := blocked || (n_ob    || ' opening balance line' || case when n_ob = 1 then '' else 's' end); end if;

  if array_length(blocked, 1) is not null then
    raise exception
      '% still has % on file, so it cannot be deleted - that history would be left pointing at nothing. Mark the account inactive instead.',
      nm, array_to_string(blocked, ', ');
  end if;

  -- The audit row is written BEFORE the delete, because audit_log.row_id is
  -- only a uuid and nothing cascades it: the trail has to outlive the row.
  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('parties', p_party, 'deleted', (select auth.uid()), '',
          jsonb_build_object('name', nm, 'account_no', code));

  delete from public.parties where id = p_party;

  return nm;
end;
$fn$;

revoke all on function public.delete_party(uuid) from public;
grant execute on function public.delete_party(uuid) to authenticated;
