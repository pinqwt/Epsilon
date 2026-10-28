# Epsilon Billing (Payments Epsilon)

Billing tracker for Epsilon Electrical & Electronic Contracting (Kuwait). Two ledgers —
**Receiving** (sold, money in) and **Sending** (bought, money out) — each showing bill,
down payment, paid and left to pay. Full user-facing docs are in `README.md`.

## Architecture
- No server, no build step. Static files in `public/` talk directly to Supabase from the browser.
- `public/index.html` — layout. `public/styles.css` — light/dark theme, IBM Plex, orange `#ea7a00`.
- `public/app.js` — all logic (~1950 lines, vanilla JS, `window.supabase` client). `CONFIG` is at the top (Supabase URL, publishable key, email domain).
- Logins are username-based: username is mapped to `<username>@<CONFIG.emailDomain>` for Supabase Auth. User management goes through an edge function (`callUsersFn`).
- Permissions (see/edit/manage users) are enforced by database RLS, not just hidden in the UI.

## Supabase
- Project **Epsilon Billing**, ref `mgxhwduuqdtxzxkhgfnc` (Frankfurt), account `mkerba2011@gmail.com`.
- Tables: `deals`, `deal_items`, `payments`, `invoices`, `shipments`, `parties`, `profiles`; view `deal_list` computes bill / paid / left. `parties` carries `supplier_no` and `details` (migration `add_supplier_no_and_details_to_parties`, 2026-10-28).
- Free tier pauses after ~1 week idle — if the app can't reach the DB, Resume it in the dashboard.

## Behaviour to preserve
- Currency decimals: KWD/BHD/OMR/JOD/TND/LYD = 3, everything else = 2 (`CUR_DEC`), so "zero left" means exactly zero.
- Excel/CSV import auto-detects headings in any order, skips title rows and a trailing Total row, shows a column-mapping preview before import. The invoice format is **Invoice Number, Supplier Name, Supplier Number, Supplier Details, Brand, Description, Unit Price, Model (SKU), Quantity**. The first four repeat on every row and describe the file, not the item: `sheetInfo` takes the value used on the most rows. Supplier Details is the supplier own phone/address/email, never Epsilon. Supplier Number is their account/ref code. Headings overlap ("Supplier Details" contains "details"), so `mapRow` scores every field/column pair and settles the strongest claim first, one field per column. Files in the older layout (no invoice/supplier columns) still import.
- Invoice upload (PDF/Excel/CSV) extracts invoice number, date, currency and total; prefers "Total after discount". An uploaded invoice's total replaces the item-list total as the bill; mismatch shows an amber warning. Newest invoice wins, older ones are kept. Files are private, opened via 10-minute signed links.
- Record shipment (Shipments page) opens on an upload box only. The file is read, the order is matched by invoice number (+60 for order reference, +10 per item model found), arrived quantities are read from the lines carrying each model, and the result shows "settles to zero" or "N items left" before saving. A full delivery books exactly the outstanding value so the account lands on zero; a partial one books the value share of the items that arrived. `shipments.items` (jsonb `[{key, model, qty}]`) remembers which units arrived so later shipments know what is left. Logic: `rankOrders` / `readArrivals` / `shipmentOutcome` in `public/app.js`.
- Supplier name from an invoice: `extractSupplierName` takes a labelled "Supplier:" line, else the first company-looking header line (skipping Epsilon's own "To/Bill to" block, titles, addresses, non-Latin twins). `matchParty` maps it to an existing account tolerant of legal suffixes and small typos (e.g. "GUANGZHOU DSPPA AUDIO CO., LTD." → account "Guanghzow"), because the database links a deal to an account only on an exact lowercase name and otherwise creates a new account. Used on New purchase (accepts a PDF) and as a +40 nudge when matching a shipment invoice to an order.
- A sheet imports more than items: `saveSheetInfo` writes the invoice number to `invoices` for the order and the supplier number/details to `parties.supplier_no` / `parties.details`. It never overwrites a value already on file - the first invoice from a new supplier is what opens their account - so corrections go through **Edit details** on the account page (`partyDialog`). An invoice row is only written when the sheet priced it, because a recorded total becomes the bill and a zero would flatten the order.
- Shipments read a spreadsheet structurally (`sheetHeaderInfo`) rather than by regex: flattening a sheet puts headings side by side ("Invoice Number Supplier Name"), which a loose "invoice no:" pattern reads as the supplier. `extractFromLines` tries labels most-explicit-first, requires a digit, rejects dates and heading words, and falls back to the line under a heading row ("PI Number / Date" then "SOR-03180 08-Oct-2026").
- First run shows "Create owner account" (only one owner can be created this way); afterwards it is a normal login.

## Current state (as of 2026-10-28)
- App UI (`public/`) last edited 2026-10-28 (new invoice format: supplier name/number/details plus invoice number).
- Sample data in the project root, all four spreadsheets in the new format (converted 2026-10-28), their supplier details taken from the matching PDFs rather than invented:
  - `PI-D261009LJ028.pdf` + `DSPPA-PI-D261009LJ028.xlsx` / `.csv` — 19 line items, invoice `D261009LJ028`.
  - `DSPPA-PI-D261009LJ028-rev12Oct.csv` — the 14-line revision of the same PI.
  - `PI-SOB-260500556.pdf` + `Mindware-SOB-260500556.csv` — 20 lines, invoice `SOB-260500556`.
  - `SOR-03180_EPSILON- Available Items- PI.PDF` + `NMK-SOR-03180.csv` — 21 lines, invoice `SOR-03180` (NMK labels it "PI Number"). No invoice prints a code for the supplier itself, so every Supplier Number is blank for the owner to fill in.
- `graphify-out/` was generated 2026-10-26 by a graphify run over this folder (AST extraction done, semantic cache for the converted CSV). No `graph.json` / report has been produced yet — the run was not completed.
- Git repository on `main`, remote `pinqwt/Epsilon`; GitHub Pages serves `public/` via the root `index.html` redirect. Invoices and secrets are never committed.

## Working notes
- Keep edits inside `public/`; keep the three logo PNG filenames and transparent backgrounds.
- Don't paste real passwords or the service-role key into chat or files; only the publishable key belongs in `CONFIG`.
- The README tells the owner to change any password they previously typed into a chat window.
