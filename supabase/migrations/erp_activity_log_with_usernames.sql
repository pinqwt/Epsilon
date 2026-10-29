-- Applied as: erp_activity_log_with_usernames (20261029120328)
--
-- The audit trail in readable form: who did it, by name, not by uuid.
create or replace view public.activity_log as
  select a.id,
         a.table_name,
         a.row_id,
         a.action,
         a.reason,
         a.detail,
         a.at,
         a.actor,
         p.username      as actor_username,
         p.display_name  as actor_name,
         coalesce(nullif(btrim(p.display_name), ''), p.username, 'a removed user')
                         as actor_label
    from public.audit_log a
    left join public.profiles p on p.id = a.actor;

-- Deleting a deal stamped deleted_by on the row but left no audit entry, so
-- the one place that answers "who changed this?" did not know about the most
-- common change of all.
create or replace function public.soft_delete_deal(target uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  row_direction public.deal_direction;
  already timestamptz;
  ref text;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in first.';
  end if;

  select d.direction, d.deleted_at, d.reference into row_direction, already, ref
    from public.deals d where d.id = target;

  if not found then
    raise exception 'That record no longer exists.';
  end if;
  if not private.can_view(row_direction) then
    raise exception 'That record no longer exists.';
  end if;
  if not private.can_edit() then
    raise exception 'You do not have permission to delete records.';
  end if;
  if already is not null then
    return;
  end if;

  update public.deals
     set deleted_at = now(), deleted_by = (select auth.uid())
   where id = target;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deals', target, 'deleted', (select auth.uid()), '',
          jsonb_build_object('reference', ref));
end;
$fn$;

create or replace function public.restore_deal(target uuid)
returns void language plpgsql security definer set search_path to '' as $fn$
declare
  ref text;
begin
  if not private.is_owner() then
    raise exception 'Only the owner can restore a deleted record.';
  end if;

  select d.reference into ref from public.deals d where d.id = target;

  update public.deals set deleted_at = null, deleted_by = null where id = target;

  insert into public.audit_log (table_name, row_id, action, actor, reason, detail)
  values ('deals', target, 'restored', (select auth.uid()), '',
          jsonb_build_object('reference', ref));
end;
$fn$;
