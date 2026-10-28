# Handoff — Payments Epsilon

Standing instructions for any Claude session working in this folder.
Read this with `CLAUDE.md`, which covers the architecture.

## Always auto-commit and push

Set by the owner on 2026-10-28, and it applies from then on:

> Always auto-commit and push to GitHub.

So, without stopping to ask each time:

- After any change that leaves the app in a working state, commit it.
- Push to the GitHub remote (`origin`) in the same breath.
- Write a real commit message — what changed and why, not "update files".
- Never use `--no-verify`, and never force-push over a shared branch.
- One commit per coherent change. Don't bundle a theme tweak with a schema migration.
- If a push is rejected, pull/rebase and push again. Don't leave work uncommitted
  and don't silently give up — say so if it stays broken.

This is durable authorization for the commit and the push. It is **not**
authorization to force-push, to make the repository public, to add collaborators,
or to commit anything listed under "Never commit" below.

## Status (as of 2026-10-28)

Local git is set up; the GitHub side is not done yet:

- Local repo exists on branch `main`, initial commit `44a09ad`, working tree clean.
- `origin` is set to `https://github.com/MukarramKebra/payments-epsilon.git`.
- **That GitHub repo does not exist yet and nothing has been pushed.** Creating it
  was blocked by the Claude Code permission classifier, so the owner runs it.
- `gh` is authenticated as **MukarramKebra**.

To finish, from the project folder:

```
gh repo create payments-epsilon --private --source=. --remote=origin --push
```

`origin` already exists, so if that complains, use `git push -u origin main` after
creating the repo. Once it is pushed, follow the standing instruction above on
every change. A session asked to redo setup should confirm
`.gitignore` still covers everything below before any push.

## Never commit

The folder holds real commercial documents, not just code. `.gitignore` is the
guard — check it still covers these before the first push:

- **Supplier proforma invoices** (`*.pdf`, `*.PDF`, `*.xlsx`, the `*-PI*` files) —
  real supplier pricing, contact names, phone numbers and the company address.
  Publishing a supplier's prices is a commercial problem, not a technical one.
- **The converted item CSVs** (`DSPPA-*.csv`, `Mindware-*.csv`, `NMK-*.csv`) — same
  pricing, in plain text.
- **`graphify-out/`** — generated, and it caches content from the files above.
- **Any service-role key, password or `.env`.** Only the Supabase *publishable*
  key belongs in `public/app.js` `CONFIG`, as `CLAUDE.md` says.

Code in `public/` is what gets committed. If a sample file is genuinely needed in
the repo, redact the prices first.
