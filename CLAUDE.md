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
- Tables: `deals`, `deal_items`, `payments`, `invoices`, `profiles`; view `deal_list` computes bill / paid / left.
- Free tier pauses after ~1 week idle — if the app can't reach the DB, Resume it in the dashboard.

## Behaviour to preserve
- Currency decimals: KWD/BHD/OMR/JOD/TND/LYD = 3, everything else = 2 (`CUR_DEC`), so "zero left" means exactly zero.
- Excel/CSV import auto-detects headings (Brand, Description, Unit Price, Model/SKU, Quantity) in any order, skips title rows and a trailing Total row, shows a column-mapping preview before import.
- Invoice upload (PDF/Excel/CSV) extracts invoice number, date, currency and total; prefers "Total after discount". An uploaded invoice's total replaces the item-list total as the bill; mismatch shows an amber warning. Newest invoice wins, older ones are kept. Files are private, opened via 10-minute signed links.
- Record shipment (Shipments page) opens on an upload box only. The file is read, the order is matched by invoice number (+60 for order reference, +10 per item model found), arrived quantities are read from the lines carrying each model, and the result shows "settles to zero" or "N items left" before saving. A full delivery books exactly the outstanding value so the account lands on zero; a partial one books the value share of the items that arrived. `shipments.items` (jsonb `[{key, model, qty}]`) remembers which units arrived so later shipments know what is left. Logic: `rankOrders` / `readArrivals` / `shipmentOutcome` in `public/app.js`.
- First run shows "Create owner account" (only one owner can be created this way); afterwards it is a normal login.

## Current state (as of 2026-10-26)
- App UI (`public/`) last edited 2026-10-25 (logo set, styles, app.js all in place).
- Sample data in the project root, from a DSPPA proforma invoice `PI-D261009LJ028`:
  - `PI-D261009LJ028.pdf` — the original invoice.
  - `DSPPA-PI-D261009LJ028.xlsx` / `.csv` — its 19 line items (Brand, Description, Unit Price, Model (SKU), Quantity), in the format the importer expects.
- `graphify-out/` was generated 2026-10-26 by a graphify run over this folder (AST extraction done, semantic cache for the converted CSV). No `graph.json` / report has been produced yet — the run was not completed.
- Not a git repository; nothing is committed or deployed from here.

## Working notes
- Keep edits inside `public/`; keep the three logo PNG filenames and transparent backgrounds.
- Don't paste real passwords or the service-role key into chat or files; only the publishable key belongs in `CONFIG`.
- The README tells the owner to change any password they previously typed into a chat window.
