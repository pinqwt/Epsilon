# Epsilon Billing

A billing tracker for Epsilon Electrical & Electronic Contracting. It keeps two
ledgers — what you **sold** and what you **bought** — and shows, for each one,
the down payment, what has been paid and what is still left.

There is **no server to run**. The app is three static files that talk directly
to Supabase.

---

## Opening it

**On your computer** — double-click `public/index.html`.

**On a website** — upload the three files in `public/` to any static host
(Netlify drop, Vercel, GitHub Pages, Cloudflare Pages, or your own hosting).
There is no build step. Because everything is behind a login, it is safe to put
on a public URL.

The app needs an internet connection: the data lives in Supabase, not on your
computer, so the same figures appear on your laptop, your phone and your office PC.

---

## First run

The first time it opens you get a **Create owner account** screen. Pick your
username (for example `ultimate15`) and a password of at least 8 characters.

That account is the owner: it can see everything, change everything and create
other users. Only one owner account can be made this way — after that, the
screen becomes a normal login.

> **Note on the password you typed into the chat:** anything typed into a chat
> window should be treated as no longer private. Use a different password here.

---

## The two tabs

| Tab | Meaning | The down payment is… |
|---|---|---|
| **Receiving** | What you **sold**. Money coming in. | what the customer has paid you |
| **Sending** | What you **bought**. Money going out. | what you have paid the supplier |

**Home** shows what is outstanding on both ledgers, plus recent activity.
The **search box** at the top finds a record by customer, supplier, reference,
invoice number, brand, model (SKU) or description.

---

## Adding a sale or purchase

Press **New**, fill in the name, date and currency, then attach your price list.

### The Excel file

Give it a row of headings and one row per item. These headings are recognised
automatically, in any column order:

| What it is | Headings it recognises |
|---|---|
| Brand | Brand, Make, Manufacturer |
| Description | Description, Description Of Goods, Item, Product, Particulars |
| Price | Unit Price, Price, Rate, Cost |
| Model (SKU) | Model, Model (SKU), SKU, Part No, Item Code |
| Quantity | Quantity, Qty, Pcs, Units *(leave it out and every item counts as 1)* |

Title rows above the headings are skipped, and a trailing `Total` row is
ignored. Prices may be written as `3,337.08` or `$3,337.08`. `.xlsx`, `.xls`
and `.csv` all work.

Before anything is imported you get a preview showing which column was matched
to which field, so you can correct it if a heading is unusual.

---

## Payments and the balance

**Record payment** adds a payment. Tick *"This is the down payment"* on the
first one. The dialog tells you exactly what is outstanding, so entering that
figure clears the balance to zero.

The **Left to pay** figure is the headline on every record:

- **`0.000 KWD LEFT`** in green with *"Fully covered"* when nothing is owed
- the outstanding amount in red when something is still due
- *"Overpaid by …"* in purple if more was paid than billed

Kuwaiti dinar is handled to 3 decimal places and dollars to 2, so zero means
exactly zero.

---

## Uploading an invoice

Press **Upload invoice** and choose the file. From a PDF, Excel or CSV the app
reads the **invoice number, date, currency and total** by itself — and it
correctly prefers a *"Total after discount"* line over the gross total. Photos
of invoices can be stored too, but their figures are typed in by hand.

Every field is editable before saving, so you can correct anything it misread.

**Once an invoice is uploaded, its total becomes the bill** instead of the item
list. If the two disagree, an amber warning shows the difference. Upload a
revised invoice later and the newest one takes over; older ones are kept.

Invoice files are stored privately and opened through links that expire after
10 minutes.

---

## Users

The **Users** tab (owner only) creates logins and sets what each person may do:

- **See Receiving** / **See Sending** — which ledger they see. Neither ticked means they see nothing.
- **Add & change records** — without it they can look but not alter anything.
- **Manage users** — can create and remove logins.

These limits are enforced by the database itself, not just hidden in the
screen, so a user cannot reach data they are not permitted to see.

Passwords are stored hashed and cannot be read back by anyone — give a new user
their password yourself, and use **Password** to set a new one if it is forgotten.

---

## Where the data lives

Supabase project **Epsilon Billing** (`mgxhwduuqdtxzxkhgfnc`, Frankfurt), in the
account `mkerba2011@gmail.com`. The dashboard is at
<https://supabase.com/dashboard/project/mgxhwduuqdtxzxkhgfnc>.

To point the app at a different project, edit the `CONFIG` block at the top of
`public/app.js`.

**Free-tier note:** a Supabase project pauses after about a week with no use.
If the app ever cannot reach the database, open the dashboard and press Resume.

### Tables

- `deals` — one sale or purchase (direction, party, date, currency, discount)
- `deal_items` — brand, model (SKU), description, qty, unit price
- `payments` — each payment, with a down-payment flag
- `invoices` — uploaded invoices and their totals
- `profiles` — logins and their permissions
- `deal_list` — the view that works out bill, paid and left

---

## Appearance

White background, IBM Plex, and the orange taken from the logo artwork
(`#ea7a00`). Colour is kept for meaning: **green** settled, **orange** part
paid, **red** still owed. To swap the logo, replace the three PNGs in
`public/` — keep the same filenames and transparent backgrounds.

## Files

```
public/index.html     screen layout
public/styles.css     appearance, light and dark (loads IBM Plex from Google Fonts)
public/app.js         all logic — CONFIG is at the top
public/logo.png       the Epsilon lockup, used on white
public/logo-dark.png  same artwork with the lettering lifted, for dark mode
public/logo-mark.png  square crop of the EC mark, used as the browser tab icon
```
