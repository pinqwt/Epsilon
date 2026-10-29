# Database migrations

SQL for the Supabase project **Epsilon Billing** (`mgxhwduuqdtxzxkhgfnc`, Frankfurt).

Migrations are applied through the Supabase MCP tool (`apply_migration`), which records
them in `supabase_migrations.schema_migrations`. The files here exist so a schema change
can be read and reviewed in a diff instead of only living in the project's history.

## What is in this folder

The ERP build described in `Software_Sequence_Charts_With_Module_Screens.pdf`
(phases 1 and 5 of the spec's six-phase build order).

| File | Applied as | Version |
|------|-----------|---------|
| `erp_phase1_foundation.sql` | `erp_phase1_foundation_tables` | 20261029082938 |
| | `erp_phase1_document_numbering` | 20261029082959 |
| | `erp_phase1_journals_and_lines` | 20261029083020 |
| | `erp_phase1_posting_guards` | 20261029083531 |
| | `erp_phase1_extend_existing_tables` | 20261029083555 |
| `erp_phase1_rls_and_seed.sql` | `erp_phase1_rls_policies` | 20261029083621 |
| | `erp_phase1_seed_accounts_and_company` | 20261029083639 |
| | `erp_phase1_backfill_codes_and_items` | 20261029083700 |
| `erp_phase5_posting_and_currency.sql` | `erp_phase5_templates_locks_currency` | 20261029083739 |
| | `erp_phase5_post_event_and_preview` | 20261029083804 |
| | `erp_phase5_settlement_with_exchange_difference` | 20261029083832 |
| | `erp_phase5_reversal_fx_conversion_and_trial_balance` | 20261029091037 |
| | `erp_phase5_fix_reversed_journals_stay_in_ledger` | 20261029091306 |
| `erp_phase2_purchase_path.sql` | `erp_phase2_goods_receipts` | 20261029121* |
| | `erp_phase2_landed_costs` | |
| | `erp_phase2_rls_policies` | |
| | `erp_phase2_post_goods_receipt` | |
| | `erp_phase2_order_progress_and_stock_on_hand` | |
| | `erp_phase2_cancel_posted_goods_receipt` | |
| | `erp_phase2_cancel_receipt_permission_fix` | |
| | `erp_phase2_allocate_landed_cost` | |
| `erp_activity_log_with_usernames.sql` | `erp_activity_log_with_usernames` | 20261029120328 |
| `erp_views_security_invoker.sql` | `erp_views_security_invoker` | 20261029* |
| `erp_phase2_only_drafts_are_editable.sql` | `erp_phase2_receipts_only_drafts_editable` | 20261029* |
| | `erp_phase2_receipt_lines_only_drafts_editable` | |
| | `erp_phase2_landed_costs_only_drafts_editable` | |

Each file was applied as several migrations because the tool rejects very large
statements; the files group them by purpose. They match the deployed state, including
the `general_ledger` fix in the last migration.

## What is NOT in this folder

**The 22 migrations before these are not here.** They built the billing app itself —
`deals`, `deal_items`, `payments`, `invoices`, `parties`, `shipments`, `profiles`, the
`deal_list` / `deal_summary` / `deal_settlement` / `account_entries` / `party_account` /
`stock_levels` views, and the `private.is_owner()` / `can_view()` / `can_edit()` helpers
that every policy here depends on. They run from `billing_core_schema` (20261025081807)
to `add_supplier_no_and_details_to_parties` (20261028154548) and exist only in the
project's own migration history.

**So this folder cannot rebuild the database from empty.** Phase 1 references
`public.parties`, `public.deals`, `public.invoices` and the `private` schema, none of
which it creates. To get a replayable history, export the earlier ones first:

```sql
-- the full SQL of every migration, oldest first
select version, name, array_to_string(statements, E';\n') as sql
  from supabase_migrations.schema_migrations
 order by version;
```

or, with the Supabase CLI linked to the project:

```sh
supabase db pull          # writes the current schema as a baseline migration
```

## Convention

One file per logical change, named `<area>_<what_it_does>.sql`, lower case with
underscores. Apply it with `apply_migration` under the same name, then commit the file
in the same change. Never edit a file that has already been applied — add another.

Row-level security is the whole security boundary: the browser holds only the
publishable key, which is public in `CONFIG`. Every new table needs its policies in the
same migration that creates it, or it is readable by anyone with the key.

**Every view needs `security_invoker = true`.** Without it a view reads its base
tables with the view owner's rights and RLS never runs, so the view is readable by
anyone holding the publishable key. This was a real hole: the four views added by the
ERP work were missing it, and `order_progress` returned all 19 purchase lines to an
anonymous caller. Fixed in `erp_views_security_invoker.sql`. To check that none have
regressed:

```sql
select c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'v'
   and coalesce(array_to_string(c.reloptions, ','), '') not like '%security_invoker=true%';
```
