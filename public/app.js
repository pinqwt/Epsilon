/* Epsilon Billing — single-file app logic.
 *
 * Plain classic script on purpose: no build step and no ES modules, so this
 * folder works opened straight from disk (file://) as well as hosted.
 */

/* ============================== CONFIG ==============================
 * To point this at a different Supabase project, change these two lines.
 * The publishable key is meant to be public; every table is protected by
 * row-level security, so it grants nothing on its own.
 */
const CONFIG = {
  url: 'https://mgxhwduuqdtxzxkhgfnc.supabase.co',
  key: 'sb_publishable_HOMdxYDy5C2qQrWwWr5Ptw_fNOv1OXo',
  // Usernames are turned into addresses on this domain. It receives no mail.
  emailDomain: 'users.epsilonbilling.local',
};
/* =================================================================== */

const CUR_DEC = { KWD: 3, BHD: 3, OMR: 3, JOD: 3, TND: 3, LYD: 3 };
const CURRENCIES = ['KWD', 'USD', 'EUR', 'AED', 'SAR', 'QAR', 'BHD', 'OMR', 'GBP', 'CNY', 'INR'];

// localStorage is unavailable in some file:// contexts; fall back to memory so
// the app still runs (the session just will not survive a reload).
const safeStorage = (() => {
  try {
    const probe = '__eb__';
    window.localStorage.setItem(probe, '1');
    window.localStorage.removeItem(probe);
    return window.localStorage;
  } catch {
    const mem = new Map();
    return {
      getItem: (k) => (mem.has(k) ? mem.get(k) : null),
      setItem: (k, v) => mem.set(k, String(v)),
      removeItem: (k) => mem.delete(k),
    };
  }
})();

const sb = window.supabase.createClient(CONFIG.url, CONFIG.key, {
  auth: { storage: safeStorage, persistSession: true, autoRefreshToken: true },
});

if (window.pdfjsLib) {
  window.pdfjsLib.GlobalWorkerOptions.workerSrc =
    'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
}

const state = { profile: null, route: null };

/* ----------------------------- live exchange rates ---------------------------- */

/* One free public feed (open.er-api.com) gives every rate against USD, so any
 * pair converts through it. It is kept for 30 minutes in the browser, and if the
 * feed cannot be reached the last rates seen are used and marked as not live.
 */
const FX_KEY = 'eb-fx';
const FX_FRESH_MS = 30 * 60 * 1000;
const fx = { rates: null, fetched: 0, sourceTime: '', live: false };

async function loadRates(force = false) {
  try {
    const c = JSON.parse(safeStorage.getItem(FX_KEY) || 'null');
    if (c?.rates?.KWD) Object.assign(fx, { rates: c.rates, fetched: c.fetched, sourceTime: c.sourceTime });
  } catch { /* a bad cache entry is simply ignored */ }

  if (!force && fx.rates && Date.now() - fx.fetched < FX_FRESH_MS) { fx.live = true; return; }

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 6000);
  try {
    const res = await fetch('https://open.er-api.com/v6/latest/USD', { signal: ctl.signal });
    const j = await res.json();
    if (j.result !== 'success' || !j.rates?.KWD) throw new Error('unexpected response');
    Object.assign(fx, { rates: j.rates, fetched: Date.now(), sourceTime: j.time_last_update_utc || '', live: true });
    safeStorage.setItem(FX_KEY, JSON.stringify({ rates: fx.rates, fetched: fx.fetched, sourceTime: fx.sourceTime }));
  } catch {
    fx.live = false;
  } finally {
    clearTimeout(timer);
  }
}

/** Amount in one currency expressed in another, or null when no rate is known. */
function convert(n, from, to) {
  const r = fx.rates;
  if (!r || !r[from] || !r[to]) return null;
  return (Number(n || 0) / r[from]) * r[to];
}

/** "≈ 309.841 KWD" for any non-KWD amount; empty for KWD or when there is no rate. */
function fxApprox(n, cur) {
  const from = String(cur).toUpperCase();
  if (from === 'KWD') return '';
  const v = convert(n, from, 'KWD');
  return v == null ? '' : `≈ ${money(v, 'KWD', 3)}`;
}

/* ---------------------------- small helpers ---------------------------- */

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const decOf = (cur) => CUR_DEC[String(cur || '').toUpperCase()] ?? 2;

/** 1234.5 KWD -> "1,234.500" */
function fmt(n, cur, dec) {
  const d = dec ?? decOf(cur);
  const v = Number(n || 0);
  return new Intl.NumberFormat('en-US', { minimumFractionDigits: d, maximumFractionDigits: d })
    .format(Object.is(v, -0) ? 0 : v);
}

/** "1,234.500 KWD" */
const money = (n, cur, dec) => `${fmt(n, cur, dec)} ${String(cur || '').toUpperCase()}`;

const qty = (n) => {
  const v = Number(n || 0);
  return Number.isInteger(v) ? String(v) : String(v).replace(/0+$/, '').replace(/\.$/, '');
};

function dateLabel(d) {
  if (!d) return '';
  const dt = new Date(`${d}T00:00:00`);
  if (isNaN(dt)) return String(d);
  return dt.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
}

const todayISO = () => new Date().toISOString().slice(0, 10);

/** Reads "$1,234.50", "KD 12.500", "1.234,56" or a number. Returns null if none. */
function parseNum(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (value == null) return null;
  let s = String(value).replace(/[^\d.,\-]/g, '');
  if (!/\d/.test(s)) return null;
  const neg = /^-/.test(s);
  s = s.replace(/-/g, '');
  const lastDot = s.lastIndexOf('.');
  const lastComma = s.lastIndexOf(',');
  if (lastDot >= 0 && lastComma >= 0) {
    s = lastComma > lastDot ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,/g, '');
  } else if (lastComma >= 0) {
    s = s.indexOf(',') === lastComma && /,\d{1,3}$/.test(s) ? s.replace(',', '.') : s.replace(/,/g, '');
  }
  const n = Number(s);
  if (!Number.isFinite(n)) return null;
  return neg ? -n : n;
}

const STATUS_TEXT = {
  covered: 'Covered', partial: 'Part paid', unpaid: 'Unpaid',
  overpaid: 'Overpaid', empty: 'Empty',
};

const DIR = {
  receiving: { label: 'Receiving', word: 'Customer', verb: 'sold', cls: 'in',
    icon: '<path d="M12 5v14"/><path d="M19 12l-7 7-7-7"/>' },
  sending: { label: 'Sending', word: 'Supplier', verb: 'bought', cls: 'out',
    icon: '<path d="M12 19V5"/><path d="M5 12l7-7 7 7"/>' },
};

/* An account balance is money moved minus goods moved. Whoever is holding
 * value they have not matched yet is the one in debt, so the same number
 * reads differently depending on which way round the deal is.
 */
const BALANCE = {
  even:       { cls: 'even', tag: 'Even' },
  party_owes: { cls: 'owed', tag: 'In debt' },
  you_owe:    { cls: 'owing', tag: 'You owe' },
};

/** "Supplier owes you 10,000.000 KWD" — phrased from your side of the books. */
function balanceLine(state, amount, cur, dec, word = 'Supplier') {
  const sum = money(Math.abs(Number(amount || 0)), cur, dec);
  if (state === 'even') return 'Even — nothing owed either way';
  if (state === 'party_owes') return `${word} owes you ${sum}`;
  return `You owe ${word.toLowerCase()} ${sum}`;
}

/** Signed balance with its currency; a + balance is the yellow chip. */
function balHtml(n, cur, dec) {
  const v = Number(n || 0);
  const text = `${signed(v, cur, dec)} ${esc(cur)}`;
  return v > 0 ? `<b class="plus-chip">${text}</b>`
    : v < 0 ? `<span class="minus-text">${text}</span>` : text;
}

/** True when the search text (already lower-cased) appears in any of the values; empty search matches all. */
const matchAny = (q, values) => !q || values.some((v) => String(v ?? '').toLowerCase().includes(q));

/** Value of an order whose goods have not all been recorded yet (what is "left" to come). */
const goodsLeft = (d) => Math.max(0, Number(d.bill_total || 0) - Number(d.goods_value || 0));

/** Ledger totals worked out from the order list, so "left" means goods still to come. */
function totalsFrom(deals) {
  const m = new Map();
  for (const d of deals) {
    const key = `${d.direction}|${d.currency}`;
    const t = m.get(key) || {
      direction: d.direction, currency: d.currency, cur_decimals: d.cur_decimals,
      bill: 0, paid: 0, amount_left: 0, goods_left: 0, deal_count: 0, open_count: 0,
    };
    const gl = goodsLeft(d);
    t.bill += Number(d.bill_total); t.paid += Number(d.paid);
    t.amount_left += Number(d.amount_left); t.goods_left += gl;
    t.deal_count += 1;
    if (gl > 0 || Number(d.amount_left) !== 0) t.open_count += 1;
    m.set(key, t);
  }
  return [...m.values()];
}

/** Amount still to pay: a yellow +chip while money is left, green zero when settled. */
function leftHtml(n, cur, dec) {
  const v = Number(n || 0);
  if (v > 0) return `<b class="plus-chip">+${fmt(v, cur, dec)}</b>`;
  if (v < 0) return `<span class="minus-text">−${fmt(Math.abs(v), cur, dec)}</span>`;
  return `<span class="cell-left-ok">${fmt(0, cur, dec)}</span>`;
}

/** An account balance with its sign: +25,266.540 / −1,000.000 / 0.000 */
function signed(n, cur, dec) {
  const v = Number(n || 0);
  return `${v > 0 ? '+' : v < 0 ? '−' : ''}${fmt(Math.abs(v), cur, dec)}`;
}

function toast(msg, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind ? `toast-${kind}` : ''}`;
  el.textContent = msg;
  $('#toasts').append(el);
  setTimeout(() => el.remove(), kind === 'err' ? 7000 : 3600);
}

const errText = (e) => (e && (e.message || e.error_description || e.error)) || 'Something went wrong.';

/* -------------------------------- modal -------------------------------- */

let modalCleanup = null;

function openModal({ title, body, foot, width }) {
  closeModal();
  const root = $('#modal-root');
  root.innerHTML = `
    <div class="modal" role="dialog" aria-modal="true" ${width ? `style="max-width:${width}"` : ''}>
      <div class="modal-head">
        <h3>${esc(title)}</h3>
        <div class="spacer"></div>
        <button class="btn btn-ghost btn-sm" data-close type="button">Close</button>
      </div>
      <div class="modal-body">${body}</div>
      ${foot ? `<div class="modal-foot">${foot}</div>` : ''}
    </div>`;
  root.hidden = false;

  const onClick = (e) => {
    if (e.target === root || e.target.closest('[data-close]')) closeModal();
  };
  const onKey = (e) => { if (e.key === 'Escape') closeModal(); };
  root.addEventListener('click', onClick);
  document.addEventListener('keydown', onKey);
  modalCleanup = () => {
    root.removeEventListener('click', onClick);
    document.removeEventListener('keydown', onKey);
  };
  return root.querySelector('.modal');
}

function closeModal() {
  if (modalCleanup) modalCleanup();
  modalCleanup = null;
  const root = $('#modal-root');
  root.hidden = true;
  root.innerHTML = '';
}

function confirmAction(message, confirmLabel = 'Confirm') {
  return new Promise((resolve) => {
    const m = openModal({
      title: 'Please confirm',
      body: `<p style="margin:0">${esc(message)}</p>`,
      foot: `<button class="btn" data-close type="button">Cancel</button>
             <button class="btn btn-danger" data-go type="button">${esc(confirmLabel)}</button>`,
      width: '460px',
    });
    let done = false;
    m.querySelector('[data-go]').onclick = () => { done = true; closeModal(); resolve(true); };
    const root = $('#modal-root');
    const obs = new MutationObserver(() => {
      if (root.hidden) { obs.disconnect(); if (!done) resolve(false); }
    });
    obs.observe(root, { attributes: true, attributeFilter: ['hidden'] });
  });
}

/* ------------------------------ data access ---------------------------- */

const emailFor = (username) => `${String(username).trim().toLowerCase()}@${CONFIG.emailDomain}`;

async function callUsersFn(payload) {
  const { data: { session } } = await sb.auth.getSession();
  const res = await fetch(`${CONFIG.url}/functions/v1/users`, {
    method: 'POST',
    headers: {
      apikey: CONFIG.key,
      'Content-Type': 'application/json',
      ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
    },
    body: JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error || `Request failed (${res.status})`);
  return body;
}

const api = {
  async totals() {
    const { data, error } = await sb.rpc('ledger_totals');
    if (error) throw error;
    return data || [];
  },

  async deals({ direction, limit = 100, openOnly = false, deleted = false } = {}) {
    let q = sb.from('deal_list').select('*').order('updated_at', { ascending: false }).limit(limit);
    if (direction) q = q.eq('direction', direction);
    if (openOnly) q = q.neq('amount_left', 0);
    // Deleted records are only ever returned when asked for by name.
    q = deleted ? q.not('deleted_at', 'is', null) : q.is('deleted_at', null);
    const { data, error } = await q;
    if (error) throw error;
    return data || [];
  },

  async suggest(term) {
    const { data, error } = await sb.rpc('search_suggestions', { q: term, lim: 5 });
    if (error) throw error;
    return data || [];
  },

  async search(term, direction) {
    const { data, error } = await sb.rpc('search_deals', {
      q: term || '', dir: direction || null, lim: 100,
    });
    if (error) throw error;
    return data || [];
  },

  async deal(id) {
    const [head, items, payments, invoices] = await Promise.all([
      sb.from('deal_list').select('*').eq('id', id).maybeSingle(),
      sb.from('deal_items').select('*').eq('deal_id', id).order('position').order('id'),
      sb.from('payments').select('*').eq('deal_id', id).order('paid_on').order('created_at'),
      sb.from('invoices').select('*').eq('deal_id', id).order('uploaded_at', { ascending: false }),
    ]);
    for (const r of [head, items, payments, invoices]) if (r.error) throw r.error;
    return {
      head: head.data,
      items: items.data || [],
      payments: payments.data || [],
      invoices: invoices.data || [],
    };
  },

  async createDeal(fields) {
    const { data, error } = await sb.from('deals').insert(fields).select().single();
    if (error) throw error;
    return data;
  },

  async updateDeal(id, fields) {
    const { error } = await sb.from('deals').update(fields).eq('id', id);
    if (error) throw error;
  },

  // Deleting hides the record and records who did it. The owner still sees it
  // and is the only one who can restore it or destroy it for good.
  async deleteDeal(id) {
    const { error } = await sb.rpc('soft_delete_deal', { target: id });
    if (error) throw error;
  },

  async restoreDeal(id) {
    const { error } = await sb.rpc('restore_deal', { target: id });
    if (error) throw error;
  },

  async purgeDeal(id) {
    const { error } = await sb.from('deals').delete().eq('id', id);
    if (error) throw error;
  },

  async addItems(dealId, items) {
    const rows = items.map((it, i) => ({
      deal_id: dealId,
      position: i + 1,
      party_name: it.party_name || '',
      brand: it.brand || '',
      model: it.model || '',
      description: it.description || '',
      qty: it.qty ?? 1,
      unit_price: it.unit_price ?? 0,
    }));
    const { error } = await sb.from('deal_items').insert(rows);
    if (error) throw error;
  },

  async deleteItem(id) {
    const { error } = await sb.from('deal_items').delete().eq('id', id);
    if (error) throw error;
  },

  async clearItems(dealId) {
    const { error } = await sb.from('deal_items').delete().eq('deal_id', dealId);
    if (error) throw error;
  },

  async addPayment(row) {
    const { error } = await sb.from('payments').insert(row);
    if (error) throw error;
  },

  async deletePayment(id) {
    const { error } = await sb.from('payments').delete().eq('id', id);
    if (error) throw error;
  },

  async addInvoice(row) {
    const { error } = await sb.from('invoices').insert(row);
    if (error) throw error;
  },

  async updateParty(id, fields) {
    const { error } = await sb.from('parties').update(fields).eq('id', id);
    if (error) throw error;
  },

  /* The supplier number and contact details read off an invoice. A detail
   * already on the account is left alone — what is on file was either typed in
   * or came from an earlier invoice, and a thinner line on a later invoice
   * should not wipe it. Returns which fields were actually filled in.
   */
  async savePartyDetails(partyId, { supplier_no, details }) {
    if (!partyId) return [];
    const { data: party, error: readErr } = await sb.from('parties')
      .select('supplier_no,details').eq('id', partyId).maybeSingle();
    if (readErr) throw readErr;
    if (!party) return [];

    const patch = {};
    if (supplier_no && !String(party.supplier_no || '').trim()) patch.supplier_no = supplier_no;
    if (details && !String(party.details || '').trim()) patch.details = details;
    if (!Object.keys(patch).length) return [];

    const { error } = await sb.from('parties').update(patch).eq('id', partyId);
    if (error) throw error;
    return Object.keys(patch);
  },

  async invoices() {
    const { data, error } = await sb.from('invoices')
      .select('id,deal_id,invoice_no,file_path,file_name,uploaded_at')
      .order('uploaded_at', { ascending: false });
    if (error) throw error;
    return data || [];
  },

  async deleteInvoice(inv) {
    if (inv.file_path) await sb.storage.from('invoices').remove([inv.file_path]).catch(() => {});
    const { error } = await sb.from('invoices').delete().eq('id', inv.id);
    if (error) throw error;
  },

  async uploadInvoiceFile(dealId, file) {
    const safe = file.name.replace(/[^\w.\-]+/g, '_').slice(-90);
    const path = `${dealId}/${Date.now()}-${safe}`;
    const { error } = await sb.storage.from('invoices').upload(path, file, {
      contentType: file.type || mimeFor(file.name),
      upsert: false,
    });
    if (error) throw error;
    return path;
  },

  /** Every recorded shipment, newest first. Deleted orders are filtered out by the caller. */
  async shipments() {
    const { data, error } = await sb.from('shipments').select('*')
      .order('shipped_on', { ascending: false }).order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  },

  /** The item lines of several orders at once, for working out what is still to arrive. */
  async itemsFor(dealIds) {
    if (!dealIds.length) return [];
    const { data, error } = await sb.from('deal_items').select('*').in('deal_id', dealIds)
      .order('position').order('id');
    if (error) throw error;
    return data || [];
  },

  async stock() {
    const { data, error } = await sb.from('stock_levels').select('*').order('sku');
    if (error) throw error;
    return data || [];
  },

  async addShipment(row) {
    const { error } = await sb.from('shipments').insert(row);
    if (error) throw error;
  },

  async deleteShipment(sh) {
    if (sh.file_path) await sb.storage.from('shipments').remove([sh.file_path]).catch(() => {});
    const { error } = await sb.from('shipments').delete().eq('id', sh.id);
    if (error) throw error;
  },

  async uploadShipmentFile(dealId, file) {
    const safe = file.name.replace(/[^\w.\-]+/g, '_').slice(-90);
    const path = `${dealId}/${Date.now()}-${safe}`;
    const { error } = await sb.storage.from('shipments').upload(path, file, {
      contentType: file.type || mimeFor(file.name),
      upsert: false,
    });
    if (error) throw error;
    return path;
  },

  /* ----------------------------- accounts ----------------------------- */

  async parties() {
    const [list, totals] = await Promise.all([
      sb.from('parties').select('*').order('name'),
      sb.from('party_account').select('*'),
    ]);
    for (const r of [list, totals]) if (r.error) throw r.error;
    return { parties: list.data || [], totals: totals.data || [] };
  },

  async party(id) {
    const [head, totals, deals, entries] = await Promise.all([
      sb.from('parties').select('*').eq('id', id).maybeSingle(),
      sb.from('party_account').select('*').eq('party_id', id),
      sb.from('deal_list').select('*').eq('party_id', id).is('deleted_at', null)
        .order('deal_date', { ascending: false }),
      sb.rpc('party_statement', { target: id }),
    ]);
    for (const r of [head, totals, deals, entries]) if (r.error) throw r.error;
    return {
      party: head.data,
      totals: totals.data || [],
      deals: deals.data || [],
      entries: entries.data || [],
    };
  },

  async signedUrl(path, bucket = 'invoices') {
    const { data, error } = await sb.storage.from(bucket).createSignedUrl(path, 600);
    if (error) throw error;
    return data.signedUrl;
  },
};

function mimeFor(name) {
  const ext = String(name).toLowerCase().split('.').pop();
  return {
    pdf: 'application/pdf', png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg',
    webp: 'image/webp', csv: 'text/csv', txt: 'text/plain',
    xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    xls: 'application/vnd.ms-excel',
  }[ext] || 'application/octet-stream';
}

/* --------------------------- spreadsheet import ------------------------ */

/* The columns an invoice spreadsheet can carry. The first four say who the
 * invoice is from and which invoice it is — they repeat on every line, and one
 * value is taken for the whole file. The rest describe the goods, line by line.
 */
const FIELD_HINTS = {
  invoice_no: ['invoice number', 'invoice no', 'invoice no.', 'invoice #', 'invoice num',
    'invoice ref', 'proforma invoice no', 'proforma invoice number', 'pi number', 'pi no',
    'order no', 'order number', 'bill number', 'bill no', 'invoice'],
  party_name: ['supplier name', 'customer name', 'supplier', 'seller', 'sold by', 'bought from',
    'vendor name', 'account name'],
  party_no: ['supplier number', 'supplier no', 'supplier no.', 'supplier code', 'supplier ref',
    'supplier id', 'supplier account', 'vendor number', 'vendor no', 'vendor code',
    'customer number', 'customer no', 'customer code', 'account number', 'account no',
    'account code', 'party number'],
  party_details: ['supplier details', 'supplier detail', 'supplier address', 'supplier contact',
    'supplier info', 'supplier information', 'vendor details', 'customer details',
    'contact details', 'party details'],
  brand: ['brand', 'make', 'manufacturer', 'maker', 'vendor', 'company'],
  model: ['model (sku)', 'model(sku)', 'model', 'sku', 'part number', 'part no', 'partno',
    'item code', 'product code', 'code', 'cat no', 'catalogue', 'ref no'],
  description: ['description of goods', 'description', 'desc', 'particulars', 'product name',
    'item name', 'product', 'item', 'details', 'goods', 'name'],
  qty: ['quantity', 'qty', 'qnty', 'pcs', 'pieces', 'units', 'nos', 'count'],
  unit_price: ['unit price', 'unitprice', 'unit cost', 'unit rate', 'u.price', 'price each',
    'price', 'rate', 'cost'],
};

const normHeader = (s) => String(s ?? '').toLowerCase().replace(/\s+/g, ' ').trim();

/** Best column index for a field, scored by how early its hint matches. */
function scoreColumn(header, field) {
  const h = normHeader(header);
  if (!h) return -1;
  const hints = FIELD_HINTS[field];
  for (let i = 0; i < hints.length; i++) {
    const hint = hints[i];
    if (h === hint) return 1000 - i;
    if (h.includes(hint)) return 500 - i;
  }
  return -1;
}

/* One column can only mean one thing. Headings overlap — "Supplier Details"
 * contains "details", "Supplier Number" contains "supplier" — so every
 * field/column pair is scored and the strongest claims are settled first.
 * That way "Supplier Details" goes to the details field and not to Description.
 */
function mapRow(cells) {
  const claims = [];
  for (const field of Object.keys(FIELD_HINTS)) {
    for (let c = 0; c < cells.length; c++) {
      const s = scoreColumn(cells[c], field);
      if (s > 0) claims.push({ field, col: c, score: s });
    }
  }
  claims.sort((a, b) => b.score - a.score);
  const map = {};
  const taken = new Set();
  for (const { field, col } of claims) {
    if (map[field] != null || taken.has(col)) continue;
    map[field] = col;
    taken.add(col);
  }
  return map;
}

/** Finds the header row within the first rows and maps each field to a column. */
function detectLayout(rows) {
  const limit = Math.min(rows.length, 12);
  let best = { row: -1, hits: 0, map: {} };

  for (let r = 0; r < limit; r++) {
    const map = mapRow(rows[r] || []);
    const hits = Object.keys(map).length;
    if (hits > best.hits) best = { row: r, hits, map };
  }

  if (best.hits >= 2) return { headerRow: best.row, map: best.map };
  return { headerRow: -1, map: {} };
}

function readSheet(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error('Could not read that file.'));
    fr.onload = () => {
      try {
        const wb = XLSX.read(new Uint8Array(fr.result), { type: 'array', cellDates: true });
        const sheets = wb.SheetNames.map((name) => ({
          name,
          rows: XLSX.utils.sheet_to_json(wb.Sheets[name], { header: 1, blankrows: false, defval: '' }),
        })).filter((s) => s.rows.length);
        if (!sheets.length) throw new Error('That file has no readable rows.');
        resolve(sheets);
      } catch (e) {
        reject(new Error(`Could not read that spreadsheet: ${errText(e)}`));
      }
    };
    fr.readAsArrayBuffer(file);
  });
}

function rowsToItems(rows, headerRow, map) {
  const out = [];
  const get = (row, field) => (map[field] >= 0 && map[field] != null ? row[map[field]] : '');
  for (let r = headerRow + 1; r < rows.length; r++) {
    const row = rows[r] || [];
    const party_name = String(get(row, 'party_name') ?? '').trim();
    const brand = String(get(row, 'brand') ?? '').trim();
    const model = String(get(row, 'model') ?? '').trim();
    const description = String(get(row, 'description') ?? '').trim();
    if (!brand && !model && !description) continue;
    // Skip summary lines such as "Total" that carry no product identity.
    if (!brand && !model && /^(total|sub ?total|grand total|discount|vat|tax)\b/i.test(description)) continue;
    const q = parseNum(get(row, 'qty'));
    const p = parseNum(get(row, 'unit_price'));
    out.push({
      party_name, brand, model, description,
      qty: q == null || q === 0 ? 1 : Math.abs(q),
      unit_price: p == null ? 0 : Math.abs(p),
      // Who the invoice is from and which invoice it is. These repeat on every
      // line; sheetInfo() boils them down to one value for the whole file.
      party_no: String(get(row, 'party_no') ?? '').trim(),
      party_details: String(get(row, 'party_details') ?? '').trim(),
      invoice_no: String(get(row, 'invoice_no') ?? '').trim(),
    });
  }
  return out;
}

/* The invoice number and the party behind a whole spreadsheet. Each of these
 * columns repeats its value down the sheet, so the one used on the most lines
 * wins — a stray blank or a typo on a single line cannot decide it.
 */
function sheetInfo(items) {
  const pick = (field) => {
    const tally = new Map();
    for (const it of items) {
      const v = String(it[field] || '').trim();
      if (v) tally.set(v, (tally.get(v) || 0) + 1);
    }
    const top = [...tally.entries()].sort((a, b) => b[1] - a[1])[0];
    return top ? top[0] : '';
  };
  return {
    party_name: pick('party_name'),
    party_no: pick('party_no'),
    party_details: pick('party_details'),
    invoice_no: pick('invoice_no'),
    total: items.reduce((a, it) => a + it.qty * it.unit_price, 0),
  };
}

/* What an invoice spreadsheet leaves behind besides its items: its invoice
 * number against the order, and the supplier's own number and contact details
 * against their account. Nothing already on file is overwritten, so the first
 * invoice from a new supplier is what opens their account properly.
 * Returns plain-language notes on what was saved.
 */
async function saveSheetInfo(deal, info, invoices = []) {
  const done = [];

  if (info.party_no || info.party_details) {
    const filled = await api.savePartyDetails(deal.party_id, {
      supplier_no: info.party_no,
      details: info.party_details,
    });
    if (filled.length) {
      done.push(`${filled.includes('supplier_no') ? 'supplier number' : ''}${
        filled.length === 2 ? ' and ' : ''}${filled.includes('details') ? 'contact details' : ''} saved to the account`);
    }
  }

  /* A recorded invoice total becomes the bill, so an invoice is only put on
   * file when the sheet priced it. An invoice number with nothing behind it
   * would book a bill of zero and quietly flatten the order.
   */
  const same = (a, b) => String(a || '').trim().toLowerCase() === String(b || '').trim().toLowerCase();
  if (info.invoice_no && !(Number(info.total) > 0)) {
    done.push(`invoice ${info.invoice_no} not recorded — add items or use “Upload an invoice” to give it a total`);
  } else if (info.invoice_no && !invoices.some((v) => same(v.invoice_no, info.invoice_no))) {
    await api.addInvoice({
      deal_id: deal.id,
      invoice_no: info.invoice_no,
      invoice_date: deal.deal_date || null,
      // The sheet is the invoice, so its lines are its total.
      total: info.total,
      currency: deal.currency,
      parsed: true,
    });
    done.push(`invoice ${info.invoice_no} recorded`);
  }

  return done;
}

/** Opens the mapping dialog and resolves `{ items, info }` once accepted, or null. */
function importItemsFlow(file) {
  return new Promise(async (resolve) => {
    let sheets;
    try {
      sheets = await readSheet(file);
    } catch (e) {
      toast(errText(e), 'err');
      return resolve(null);
    }

    let sheetIdx = 0;
    let layout = detectLayout(sheets[0].rows);

    const fieldRow = (field, label, note) => `
      <label class="field">
        <span>${esc(label)} ${note ? `<em>(${esc(note)})</em>` : ''}</span>
        <select data-map="${field}"></select>
      </label>`;

    const m = openModal({
      title: `Import items from ${file.name}`,
      body: `
        <div id="imp-sheet-wrap" class="field" ${sheets.length > 1 ? '' : 'hidden'}>
          <span>Sheet</span>
          <select id="imp-sheet">
            ${sheets.map((s, i) => `<option value="${i}">${esc(s.name)} (${s.rows.length} rows)</option>`).join('')}
          </select>
        </div>
        <div class="field">
          <span>Header row</span>
          <select id="imp-header"></select>
        </div>
        <p class="preview-note" id="imp-detect"></p>
        <div class="map-grid">
          ${fieldRow('invoice_no', 'Invoice number')}
          ${fieldRow('party_name', 'Name', 'supplier or customer')}
          ${fieldRow('party_no', 'Supplier number', 'their code')}
          ${fieldRow('party_details', 'Supplier details', 'their phone, address')}
          ${fieldRow('brand', 'Brand')}
          ${fieldRow('description', 'Description')}
          ${fieldRow('unit_price', 'Price', 'per unit')}
          ${fieldRow('model', 'Model (SKU)')}
          ${fieldRow('qty', 'Quantity', 'blank = 1')}
        </div>
        <div id="imp-preview"></div>`,
      foot: `<button class="btn" data-close type="button">Cancel</button>
             <button class="btn btn-primary" id="imp-go" type="button">Import items</button>`,
    });

    const rowsNow = () => sheets[sheetIdx].rows;

    function fillHeaderOptions() {
      const rows = rowsNow();
      const opts = rows.slice(0, 15).map((r, i) => {
        const text = r.slice(0, 6).map((c) => String(c ?? '').trim()).filter(Boolean).join(' | ').slice(0, 70);
        return `<option value="${i}">Row ${i + 1}: ${esc(text || '(blank)')}</option>`;
      });
      opts.unshift('<option value="-1">No header row — data starts at row 1</option>');
      $('#imp-header', m).innerHTML = opts.join('');
      $('#imp-header', m).value = String(layout.headerRow);
    }

    function fillColumnOptions() {
      const rows = rowsNow();
      const hr = Number($('#imp-header', m).value);
      const headerCells = hr >= 0 ? (rows[hr] || []) : [];
      const width = Math.max(...rows.slice(0, 30).map((r) => r.length), headerCells.length, 1);
      const letters = (n) => String.fromCharCode(65 + (n % 26)).repeat(Math.floor(n / 26) + 1);

      for (const sel of $$('[data-map]', m)) {
        const field = sel.dataset.map;
        const opts = ['<option value="-1">— not in file —</option>'];
        for (let c = 0; c < width; c++) {
          const name = String(headerCells[c] ?? '').trim();
          opts.push(`<option value="${c}">${esc(name || `Column ${letters(c)}`)}</option>`);
        }
        sel.innerHTML = opts.join('');
        sel.value = String(layout.map[field] ?? -1);
      }
    }

    function currentMap() {
      const map = {};
      for (const sel of $$('[data-map]', m)) {
        const v = Number(sel.value);
        map[sel.dataset.map] = v >= 0 ? v : null;
      }
      return map;
    }

    function refreshPreview() {
      const hr = Number($('#imp-header', m).value);
      const items = rowsToItems(rowsNow(), hr, currentMap());
      const detect = $('#imp-detect', m);
      const info = sheetInfo(items);
      // Say what was read off the invoice columns, so it is clear before saving
      // which supplier this is and what will be kept on their account.
      const read = [
        info.invoice_no ? `invoice <b>${esc(info.invoice_no)}</b>` : null,
        info.party_name ? `from <b>${esc(info.party_name)}</b>` : null,
        info.party_no ? `no. <b>${esc(info.party_no)}</b>` : null,
        info.party_details ? 'with contact details' : null,
      ].filter(Boolean);
      detect.innerHTML = items.length
        ? `Found <b>${items.length}</b> item${items.length === 1 ? '' : 's'}${
            read.length ? ` — ${read.join(', ')}` : ''}. Check them below, then import.`
        : 'No items found yet — try a different header row or column mapping.';

      // Every row is listed; the area scrolls so the mapping controls and the
      // Import button stay put while you check the list.
      $('#imp-preview', m).innerHTML = items.length
        ? `<div class="table-scroll preview-scroll"><table class="data">
             <thead><tr><th>Name</th><th>Brand</th><th>Model (SKU)</th><th>Description</th>
               <th class="r">Qty</th><th class="r">Price</th><th class="r">Amount</th></tr></thead>
             <tbody>${items.map((it) => `
               <tr>
                 <td>${esc(it.party_name)}</td>
                 <td>${esc(it.brand)}</td>
                 <td class="sku">${esc(it.model)}</td>
                 <td class="desc">${esc(it.description)}</td>
                 <td class="r">${qty(it.qty)}</td>
                 <td class="r">${fmt(it.unit_price, null, 2)}</td>
                 <td class="r">${fmt(it.qty * it.unit_price, null, 2)}</td>
               </tr>`).join('')}</tbody>
             <tfoot><tr>
               <td colspan="6" class="r">Total of ${items.length} item${items.length === 1 ? '' : 's'}</td>
               <td class="r">${fmt(items.reduce((a, it) => a + it.qty * it.unit_price, 0), null, 2)}</td>
             </tr></tfoot>
           </table></div>`
        : '';

      $('#imp-go', m).disabled = !items.length;
      return items;
    }

    $('#imp-sheet', m)?.addEventListener('change', (e) => {
      sheetIdx = Number(e.target.value);
      layout = detectLayout(rowsNow());
      fillHeaderOptions();
      fillColumnOptions();
      refreshPreview();
    });

    $('#imp-header', m).addEventListener('change', () => {
      const rows = rowsNow();
      const hr = Number($('#imp-header', m).value);
      if (hr >= 0) {
        const re = detectLayout([rows[hr]]);
        if (Object.keys(re.map).length) layout.map = re.map;
      }
      fillColumnOptions();
      refreshPreview();
    });

    m.addEventListener('change', (e) => { if (e.target.dataset.map) refreshPreview(); });

    $('#imp-go', m).onclick = () => {
      const items = rowsToItems(rowsNow(), Number($('#imp-header', m).value), currentMap());
      if (!items.length) return;
      closeModal();
      resolve({ items, info: sheetInfo(items) });
    };

    const root = $('#modal-root');
    const obs = new MutationObserver(() => {
      if (root.hidden) { obs.disconnect(); resolve(null); }
    });
    obs.observe(root, { attributes: true, attributeFilter: ['hidden'] });

    fillHeaderOptions();
    fillColumnOptions();
    refreshPreview();
  });
}

/* ---------------------------- invoice reading -------------------------- */

const TOTAL_PATTERNS = [
  /total\s*after\s*discount/i, /grand\s*total/i, /net\s*(?:total|amount|payable)/i,
  /amount\s*(?:due|payable)/i, /total\s*due/i, /balance\s*due/i,
  /total\s*payable/i, /invoice\s*total/i, /total\s*amount/i, /^\s*total\b/i, /total/i,
];

const lastNumberIn = (line) => {
  const nums = String(line).match(/-?[\d][\d.,]*/g);
  if (!nums) return null;
  for (let i = nums.length - 1; i >= 0; i--) {
    const n = parseNum(nums[i]);
    if (n != null && Math.abs(n) > 0) return n;
  }
  return null;
};

function detectCurrency(text) {
  // Count every mention and take the most frequent, so one stray "KWD" in an
  // address cannot outvote an invoice that is priced throughout in USD.
  const t = String(text);
  const score = {};
  const add = (code, n) => { if (n) score[code] = (score[code] || 0) + n; };
  for (const code of CURRENCIES) add(code, (t.match(new RegExp(`\\b${code}\\b`, 'gi')) || []).length);
  add('KWD', (t.match(/\bK\.?D\.?\b/gi) || []).length);
  add('CNY', (t.match(/\bRMB\b/gi) || []).length);
  add('USD', (t.match(/US\s?\$|\$/g) || []).length);
  add('EUR', (t.match(/€/g) || []).length);
  add('GBP', (t.match(/£/g) || []).length);
  const best = Object.entries(score).sort((a, b) => b[1] - a[1])[0];
  return best ? best[0] : null;
}

const MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };

function parseDateLoose(text) {
  const t = String(text);
  let m = t.match(/\b(20\d{2})[-/](\d{1,2})[-/](\d{1,2})\b/);
  if (m) return iso(m[1], m[2], m[3]);
  m = t.match(/\b(\d{1,2})[-/\s]([A-Za-z]{3,})[-/\s](20\d{2}|\d{2})\b/);
  if (m) {
    const mon = MONTHS[m[2].slice(0, 3).toLowerCase()];
    if (mon) return iso(full(m[3]), mon, m[1]);
  }
  m = t.match(/\b([A-Za-z]{3,})\s+(\d{1,2}),?\s+(20\d{2})\b/);
  if (m) {
    const mon = MONTHS[m[1].slice(0, 3).toLowerCase()];
    if (mon) return iso(m[3], mon, m[2]);
  }
  // Ambiguous d/m/y: treat the first number as the day, as used in Kuwait.
  m = t.match(/\b(\d{1,2})[-/.](\d{1,2})[-/.](20\d{2}|\d{2})\b/);
  if (m) return iso(full(m[3]), m[2], m[1]);
  return null;

  function full(y) { return String(y).length === 2 ? `20${y}` : String(y); }
  function iso(y, mo, d) {
    const mm = String(Number(mo)).padStart(2, '0');
    const dd = String(Number(d)).padStart(2, '0');
    if (Number(mo) < 1 || Number(mo) > 12 || Number(d) < 1 || Number(d) > 31) return null;
    return `${y}-${mm}-${dd}`;
  }
}

/* The supplier is whoever issued the invoice: a labelled "Supplier: …" line if
 * there is one, otherwise the first company-looking line in the header. Our own
 * company (the "To" / "Bill to" block) is skipped, as are titles, addresses and
 * phone lines, and lines with no Latin letters (the Chinese / Arabic twin of the name).
 */
const OWN_COMPANY = /epsilon/i;
const COMPANY_SUFFIX = /\b(co\.?|ltd\.?|limited|llc|l\.l\.c|inc\.?|corp\.?|corporation|company|gmbh|fze|fzco|fzc|w\.?l\.?l\.?|est\.?|establishment|trading|industries|s\.?a\.?|b\.?v\.?)(?=[\s,.]|$)/i;
const NOT_A_NAME = /^(proforma|pro-forma|tax|commercial|sales|purchase)?\s*(tax\s*)?(invoice|quotation|quote|order|packing\s*list|delivery\s*note)\b|^(add(ress)?|p\.?\s?o\.?\s*box|tel|fax|phone|web|email|e-mail|trn|vat|date|to|bill\s*to|ship\s*to|attn|mr|mrs|ms|dear|page|no|www)\b/i;

function extractSupplierName(lines) {
  const clean = (s) => s
    .replace(/\s+(add(ress)?|p\.?\s?o\.?\s*box|tel|fax|phone|web|email|trn|vat)\b.*$/i, '')
    .replace(/[\s,;:|-]+$/, '')
    .replace(/\s+/g, ' ').trim();

  for (const l of lines.slice(0, 40)) {
    const m = l.match(/^(?:supplier|seller|vendor|sold\s*by|exporter|beneficiary|from)\s*(?:name)?\s*[:\-]\s*(.{3,80})$/i);
    if (m && !OWN_COMPANY.test(m[1])) return clean(m[1]);
  }

  const head = lines.slice(0, 12).filter((l) => /[A-Za-z]{3}/.test(l) && !OWN_COMPANY.test(l) && !NOT_A_NAME.test(l.trim()));
  const company = head.find((l) => COMPANY_SUFFIX.test(l) && l.length <= 90);
  if (company) return clean(company);
  // No "Ltd" / "FZE" at all (e.g. "Mindware For Computers"): the first plain name line.
  const plain = head.find((l) => l.length <= 60 && !/\d{3}/.test(l) && !/[:@]/.test(l));
  return plain ? clean(plain) : '';
}

/* Matching a name to an existing account, tolerant of legal suffixes and small
 * spelling differences ("GUANGZHOU DSPPA AUDIO CO., LTD." ~ "Guanghzow").
 */
const PARTY_NOISE = new Set(['co', 'ltd', 'limited', 'llc', 'inc', 'corp', 'corporation', 'company', 'the', 'and', 'for', 'of',
  'fze', 'fzco', 'fzc', 'wll', 'gmbh', 'est', 'establishment', 'group', 'international', 'trading', 'general', 'electrical',
  'electronic', 'electronics', 'electric', 'industries', 'industrial', 'kuwait', 'middle', 'east', 'systems', 'security',
  'lighting', 'marketing', 'power', 'telecom', 'cable', 'cables', 'computers']);
const partyTokens = (s) => String(s || '').toLowerCase().split(/[^a-z0-9]+/).filter((t) => t.length >= 3 && !PARTY_NOISE.has(t));

function editDistance(a, b) { // optimal string alignment: a swapped pair of letters counts as one slip
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
    }
  }
  return d[a.length][b.length];
}

function partyScore(a, b) {
  const ta = partyTokens(a), tb = partyTokens(b);
  if (!ta.length || !tb.length) return 0;
  if (ta.join(' ') === tb.join(' ')) return 1;
  const same = (x, y) => x === y
    || (x.length >= 4 && y.length >= 4 && (x.startsWith(y) || y.startsWith(x)))
    || (x.length >= 6 && y.length >= 6 && editDistance(x, y) <= 2);
  const hitsA = ta.filter((x) => tb.some((y) => same(x, y)));
  const hitsB = tb.filter((y) => ta.some((x) => same(x, y)));
  if (!hitsA.some((x) => x.length >= 5) && !hitsB.some((y) => y.length >= 5)) return 0; // nothing distinctive in common
  return Math.max(hitsA.length / ta.length, hitsB.length / tb.length);
}

/** The existing account this name most likely is, or null when none is close (or two are equally close). */
function matchParty(name, parties) {
  const scored = parties.map((p) => ({ party: p, score: partyScore(name, p.name) }))
    .filter((r) => r.score >= 0.6).sort((a, b) => b.score - a.score);
  if (!scored.length) return null;
  if (scored[1] && scored[1].score >= scored[0].score) return null;
  return scored[0];
}

function extractFromLines(lines) {
  const text = lines.join('\n');
  const flat = lines.join(' ');

  /* An invoice number hides behind a lot of different labels, and the next
   * word is often not it: "PROFORMA INVOICE Order No: SOB-260500556" names the
   * number after a second label, and a flattened spreadsheet reads "Invoice
   * Number Supplier Name". So the labels are tried from most explicit down,
   * and a candidate only counts when it carries a digit — as every invoice
   * number does — and is not plainly another column's heading.
   */
  const NO_LABELS = [
    /\b(?:proforma\s+)?(?:tax\s+)?invoice\s*(?:no|number|num|#|ref)\s*\.?\s*[:#]?\s*([A-Za-z0-9][A-Za-z0-9\-\/_]{2,30})/gi,
    /\b(?:order|bill|pi|p\/i)\s*(?:no|number|#)\s*\.?\s*[:#]?\s*([A-Za-z0-9][A-Za-z0-9\-\/_]{2,30})/gi,
    /\b(?:proforma\s+)?(?:tax\s+)?invoice\s*(?:no|number|num|#|ref)?\s*\.?\s*[:#]?\s*([A-Za-z0-9][A-Za-z0-9\-\/_]{2,30})/gi,
  ];
  const NOT_A_NUMBER = /^(no|number|num|date|to|of|ref|code|name|order|bill|supplier|customer|vendor|details?|brand|description|qty|quantity|price|model|sku|total|invoice|proforma|tax)$/i;
  // The date often sits right after the label — "Invoice No … 08-Oct-2026" —
  // and a piece of one ("Oct-2026") is no more an invoice number than the whole.
  const LOOKS_LIKE_DATE = new RegExp(
    `^(?:\\d{1,4}[-\\/.][A-Za-z0-9]{1,9}[-\\/.]\\d{2,4}`
    + `|(?:${Object.keys(MONTHS).join('|')})[a-z]*[-\\/.\\s]*\\d{2,4})$`, 'i');
  const isNumber = (s) => /\d/.test(s) && !NOT_A_NUMBER.test(s) && !LOOKS_LIKE_DATE.test(s);
  let invoiceNo = '';
  for (const re of NO_LABELS) {
    for (const m of flat.matchAll(re)) {
      const hit = m[1].replace(/[.,;]+$/, '');
      if (isNumber(hit)) { invoiceNo = hit; break; }
    }
    if (invoiceNo) break;
  }
  /* A document can print the label in a table heading and the number on the
   * line underneath — "PI Number  Date  LPO Number" then "SOR-03180  08-Oct-2026",
   * which is also the shape a spreadsheet takes once flattened. A heading line
   * carries no digits of its own, so the first letters-then-digits token on the
   * line below it is the number. Dates start with digits and are left alone.
   */
  if (!invoiceNo) {
    const at = lines.findIndex((l) =>
      /\b(?:invoice|pi|p\/i|order|bill)\s*(?:no|number|#)\b/i.test(l) && !/\d/.test(l));
    const below = at >= 0 ? String(lines[at + 1] || '') : '';
    // Only a whole token counts, never the tail of one: the "Oct-2026" inside
    // "08-Oct-2026" must not pass for a number.
    const tok = below.match(/(?<![\w\-\/])([A-Za-z]{1,6}[-\/]?\d[A-Za-z0-9\-\/_]{2,30})\b/);
    if (tok && isNumber(tok[1])) invoiceNo = tok[1];
  }

  let total = null;
  for (const re of TOTAL_PATTERNS) {
    const hits = lines.filter((l) => re.test(l));
    for (let i = hits.length - 1; i >= 0; i--) {
      const n = lastNumberIn(hits[i]);
      if (n != null) { total = n; break; }
    }
    if (total != null) break;
  }

  // Prefer a date that sits on a line mentioning the invoice date.
  const dateLine = lines.find((l) => /invoice\s*date|^\s*date\b|date\s*[:#]/i.test(l));
  const invoiceDate = parseDateLoose(dateLine || '') || parseDateLoose(text);

  return { invoiceNo, total, currency: detectCurrency(text), invoiceDate, supplier: extractSupplierName(lines) };
}

async function readPdfLines(file) {
  const buf = await file.arrayBuffer();
  const pdf = await window.pdfjsLib.getDocument({ data: new Uint8Array(buf) }).promise;
  const lines = [];
  for (let p = 1; p <= pdf.numPages; p++) {
    const page = await pdf.getPage(p);
    const content = await page.getTextContent();
    // Group text pieces into visual lines by their vertical position.
    const byY = new Map();
    for (const item of content.items) {
      if (!item.str || !item.str.trim()) continue;
      const y = Math.round(item.transform[5]);
      const key = [...byY.keys()].find((k) => Math.abs(k - y) <= 2);
      const bucket = key == null ? (byY.set(y, []), byY.get(y)) : byY.get(key);
      bucket.push({ x: item.transform[4], str: item.str });
    }
    for (const y of [...byY.keys()].sort((a, b) => b - a)) {
      lines.push(byY.get(y).sort((a, b) => a.x - b.x).map((i) => i.str).join(' ').replace(/\s+/g, ' ').trim());
    }
  }
  return lines.filter(Boolean);
}

async function extractInvoice(file) {
  const ext = file.name.toLowerCase().split('.').pop();
  try {
    if (ext === 'pdf') return extractFromLines(await readPdfLines(file));
    if (['xlsx', 'xls', 'csv', 'txt'].includes(ext)) {
      const sheets = await readSheet(file);
      const lines = [];
      for (const s of sheets) {
        for (const row of s.rows) lines.push(row.map((c) => String(c ?? '').trim()).filter(Boolean).join(' '));
      }
      return extractFromLines(lines.filter(Boolean));
    }
  } catch (e) {
    console.warn('invoice read failed', e);
    return { readError: errText(e) };
  }
  return {}; // images and anything else: fill in by hand
}

/* ------------------------------- rendering ----------------------------- */

const canEdit = () => !!state.profile?.can_edit;
const isOwner = () => state.profile?.role === 'owner';

function dealRow(d, showDir = true) {
  const dir = DIR[d.direction];
  const left = Number(d.amount_left);
  const hit = d.deleted_at
    ? `<div class="row-hit row-gone">Deleted by ${esc(d.deleted_by_name || d.deleted_by_username || 'a removed user')} · ${esc(dateLabel(String(d.deleted_at).slice(0, 10)))}</div>`
    : d.match_note ? `<div class="row-hit">${esc(d.match_note)}</div>` : '';
  return `
    <a class="row-deal" href="#/deal/${d.id}">
      ${showDir
        ? `<span class="dir-badge dir-${dir.cls}" title="${dir.label}"><svg viewBox="0 0 24 24">${dir.icon}</svg></span>`
        : '<span></span>'}
      <div class="row-party">
        <strong>${esc(d.party)}</strong>
        <div class="row-meta">
          ${d.reference ? `<span>${esc(d.reference)}</span>` : ''}
          <span>${esc(dateLabel(d.deal_date))}</span>
          <span>${d.item_count} item${d.item_count === 1 ? '' : 's'}</span>
          ${d.invoice_count ? `<span>${d.invoice_count} invoice${d.invoice_count === 1 ? '' : 's'}</span>` : ''}
        </div>
        ${hit}
      </div>
      <span class="cell cell-bill"><span class="cell-k">Bill</span>${fmt(d.bill_total, d.currency, d.cur_decimals)}</span>
      <span class="cell cell-paid"><span class="cell-k">Paid</span>${fmt(d.paid, d.currency, d.cur_decimals)}${
        left > 0 ? `<span class="to-pay">${fmt(left, d.currency, d.cur_decimals)} to pay</span>` : ''}</span>
      <span class="cell"><span class="cell-k">Left</span>${leftHtml(goodsLeft(d), d.currency, d.cur_decimals)}</span>
      <span class="cell cell-bal"><span class="cell-k">Account</span>${balHtml(d.balance, d.currency, d.cur_decimals)}</span>
      <span class="pill pill-${d.status}">${STATUS_TEXT[d.status] || d.status}</span>
    </a>`;
}

function tile(t) {
  const left = Number(t.goods_left);
  const toPay = Number(t.amount_left);
  const cls = left > 0 ? 'tile-left-due' : 'tile-left-ok';
  const dir = DIR[t.direction];
  return `
    <div class="tile tile-${dir.cls} ${cls}">
      <div class="tile-top"><span class="tile-dot"></span>${dir.label} · ${esc(t.currency)}</div>
      <div class="tile-val">${left > 0 ? '+' : ''}${fmt(left, t.currency, t.cur_decimals)}<span class="tile-cur">${esc(t.currency)} left</span></div>
      <div class="tile-sub">
        <span>Billed <b>${fmt(t.bill, t.currency, t.cur_decimals)}</b></span>
        <span>Paid <b>${fmt(t.paid, t.currency, t.cur_decimals)}</b></span>
        ${toPay > 0 ? `<span>To pay <b>${fmt(toPay, t.currency, t.cur_decimals)}</b></span>` : ''}
        <span><b>${t.open_count}</b> of ${t.deal_count} open</span>
        ${fxApprox(left, t.currency) ? `<span>Left ${fxApprox(left, t.currency)}</span>` : ''}
      </div>
    </div>`;
}

function rowsBlock(deals, emptyMsg, showDir = true) {
  if (!deals.length) return `<div class="empty">${esc(emptyMsg)}</div>`;
  return `<div class="rows">${deals.map((d) => dealRow(d, showDir)).join('')}</div>`;
}

/* --------------------------------- views ------------------------------- */

const view = () => $('#view');

function setLoading() {
  view().innerHTML = '<div class="empty"><div class="spinner" style="margin:0 auto 12px"></div>Loading…</div>';
}

async function viewHome() {
  setLoading();
  const all = await api.deals({ limit: 500 });
  const totals = totalsFrom(all);
  const recent = all.slice(0, 12);

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>Home</h2>
        <p>What is outstanding right now, and the latest activity on both ledgers.</p>
      </div>
    </div>

    ${totals.length ? `<div class="tiles">${totals.map(tile).join('')}</div>` : ''}

    <div class="card">
      <div class="card-head">
        <h3>Recent activity</h3>
        <div class="spacer"></div>
        <a class="btn btn-ghost btn-sm" href="#/receiving">Receiving</a>
        <a class="btn btn-ghost btn-sm" href="#/sending">Sending</a>
      </div>
      <div class="card-body tight">
        ${rowsBlock(recent, 'Nothing here yet. Use the New button to add your first sale or purchase.')}
      </div>
    </div>`;
}

async function viewLedger(direction) {
  setLoading();
  const dir = DIR[direction];
  const deals = await api.deals({ direction, limit: 200 });
  const mine = totalsFrom(deals);

  const blurb = direction === 'receiving'
    ? 'What you sold, what each customer has paid as a down payment, and what they still owe you.'
    : 'What you bought, the down payment you have paid, and what you still owe the supplier.';

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>${dir.label} <span class="dim" style="font-size:15px;font-weight:500">· ${direction === 'receiving' ? 'sales' : 'purchases'}</span></h2>
        <p>${blurb}</p>
      </div>
      <div class="spacer"></div>
      ${canEdit() ? `<a class="btn btn-primary" href="#/new/${direction}">
        <svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>
        New ${direction === 'receiving' ? 'sale' : 'purchase'}</a>` : ''}
    </div>

    ${mine.length ? `<div class="tiles">${mine.map(tile).join('')}</div>` : ''}

    <div class="card">
      <div class="card-head">
        <h3>All ${direction === 'receiving' ? 'sales' : 'purchases'}</h3>
        <div class="spacer"></div>
        <input type="search" id="ledger-q" placeholder="Search name or UID" style="width:200px">
        <select id="ledger-filter" style="width:auto">
          <option value="all">Show all</option>
          <option value="open">Still owing</option>
          <option value="covered">Fully covered</option>
          ${isOwner() ? '<option value="deleted">Deleted</option>' : ''}
        </select>
      </div>
      <div class="card-body tight" id="ledger-rows">
        ${rowsBlock(deals, `No ${direction === 'receiving' ? 'sales' : 'purchases'} recorded yet.`, false)}
      </div>
    </div>`;

  const paintLedger = async () => {
    const f = $('#ledger-filter').value;
    const q = $('#ledger-q').value.trim().toLowerCase();
    if (f === 'deleted') {
      $('#ledger-rows').innerHTML = '<div class="empty">Loading…</div>';
      const gone = (await api.deals({ direction, limit: 200, deleted: true }))
        .filter((d) => matchAny(q, [d.party, d.party_uid, d.reference]));
      $('#ledger-rows').innerHTML = gone.length
        ? rowsBlock(gone, '', false)
        : '<div class="empty">Nothing has been deleted.</div>';
      return;
    }
    const base = f === 'all' ? deals
      : f === 'open' ? deals.filter((d) => Number(d.amount_left) !== 0)
        : deals.filter((d) => Number(d.amount_left) === 0 && d.status !== 'empty');
    const shown = base.filter((d) => matchAny(q, [d.party, d.party_uid, d.reference, d.last_receipt]));
    $('#ledger-rows').innerHTML = rowsBlock(shown, 'Nothing matches that.', false);
  };
  $('#ledger-filter').addEventListener('change', paintLedger);
  $('#ledger-q').addEventListener('input', paintLedger);
}

async function viewSearch(term) {
  setLoading();
  const deals = await api.search(term);
  $('#search-input').value = term;

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>Search</h2>
        <p>${deals.length} result${deals.length === 1 ? '' : 's'} for “${esc(term)}” — matched on customer, supplier, reference, invoice number, brand, model or description.</p>
      </div>
      <div class="spacer"></div>
      <a class="btn" href="#/home">Clear</a>
    </div>
    <div class="card"><div class="card-body tight">
      ${rowsBlock(deals, 'Nothing matched. Try part of a brand, model or customer name.')}
    </div></div>`;
}

async function viewNewDeal(direction) {
  if (!canEdit()) return viewDenied();
  const dir = DIR[direction];
  let pending = [];
  let sheet = {};   // invoice number and party details read off the imported file

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>New ${direction === 'receiving' ? 'sale' : 'purchase'}</h2>
        <p>${direction === 'receiving' ? 'Something you sold to a customer.' : 'Something you bought from a supplier.'}
           You can attach the price list now or add items later.</p>
      </div>
      <div class="spacer"></div>
      <a class="btn" href="#/${direction}">Cancel</a>
    </div>

    <form class="card" id="new-form">
      <div class="card-body">
        <div class="grid-form">
          <label class="field" style="grid-column:span 2">
            <span>${dir.word} name</span>
            <input name="party" required placeholder="${direction === 'receiving' ? 'e.g. Ministry of Public Works' : 'e.g. GUANGZHOU DSPPA AUDIO CO., LTD.'}">
          </label>
          <label class="field">
            <span>${direction === 'receiving' ? 'Quote no' : 'Purchase no'}</span>
            <input name="reference" placeholder="generated automatically">
          </label>
          <label class="field">
            <span>Invoice number <em>(optional)</em></span>
            <input name="invoice_no" placeholder="read from the file"
              autocapitalize="characters" spellcheck="false">
          </label>
          <label class="field">
            <span>Date</span>
            <input name="deal_date" type="date" value="${todayISO()}" required>
          </label>
          <label class="field">
            <span>Currency</span>
            <select name="currency">
              ${CURRENCIES.map((c) => `<option value="${c}"${c === 'KWD' ? ' selected' : ''}>${c}</option>`).join('')}
            </select>
          </label>
          <label class="field">
            <span>Discount % <em>(optional)</em></span>
            <input name="discount_pct" type="number" step="0.01" min="0" max="100" value="0">
          </label>
          <label class="field wide">
            <span>Notes <em>(optional)</em></span>
            <textarea name="notes" rows="2"></textarea>
          </label>
        </div>
      </div>

      <div class="card-head" style="border-top:1px solid var(--rule); padding-top:16px">
        <h3>Down payment</h3>
        <div class="spacer"></div>
        <span class="dim">${direction === 'receiving' ? 'what the customer paid you up front' : 'what you paid the supplier up front'}</span>
      </div>
      <div class="card-body" style="padding-top:16px">
        <div class="grid-form">
          <label class="field">
            <span>Amount <em>(leave blank if none)</em></span>
            <input name="down_amount" type="number" step="0.001" min="0" placeholder="0">
          </label>
          <label class="field">
            <span>Date paid</span>
            <input name="down_date" type="date" value="${todayISO()}">
          </label>
          <label class="field">
            <span>Method <em>(optional)</em></span>
            <input name="down_method" placeholder="TT, cash, cheque">
          </label>
        </div>
      </div>
      <div class="card-head" style="border-top:1px solid var(--rule);border-bottom:0">
        <h3>Items</h3>
        <div class="spacer"></div>
        <span class="dim" id="pending-count">none yet</span>
      </div>
      <div class="card-body">
        <div class="dropzone" id="new-drop">
          <strong>Choose an Excel or CSV file</strong> with Invoice Number, ${dir.word} Name,
          ${dir.word} Number, ${dir.word} Details, Brand, Description, Unit Price, Model (SKU) and Quantity
          <small>or drag it here — .xlsx, .xls, .csv${direction === 'sending'
            ? '. A supplier invoice (PDF) fills in the supplier, invoice number, date and currency.' : ''}</small>
          <input type="file" id="new-file" accept=".xlsx,.xls,.csv${direction === 'sending' ? ',.pdf' : ''}" hidden>
        </div>
        <div id="pending-preview"></div>
      </div>
      <div class="modal-foot" style="border-top:1px solid var(--rule)">
        <a class="btn" href="#/${direction}">Cancel</a>
        <button class="btn btn-primary" type="submit" id="create-btn">Create ${direction === 'receiving' ? 'sale' : 'purchase'}</button>
      </div>
    </form>`;

  // Show the number this record will get. Overwrite it to use your own.
  sb.rpc('next_reference', { dir: direction }).then(({ data }) => {
    const input = $('#new-form [name=reference]');
    if (data && input && !input.value) input.value = data;
  }).catch(() => { /* the database fills it in on save anyway */ });

  const drop = $('#new-drop');
  const fileInput = $('#new-file');

  const showPending = () => {
    // Imported items live only in this page until the record is created, so say so.
    const noun = direction === 'receiving' ? 'sale' : 'purchase';
    const n = pending.length;
    $('#pending-count').textContent = n ? `${n} item${n === 1 ? '' : 's'} ready — not saved yet` : 'none yet';
    const createBtn = $('#create-btn');
    if (createBtn) {
      createBtn.textContent = n ? `Create ${noun} with ${n} item${n === 1 ? '' : 's'}` : `Create ${noun}`;
    }
    $('#pending-preview').innerHTML = pending.length
      ? `<div class="table-scroll preview-scroll" style="margin-top:14px"><table class="data">
           <thead><tr><th>Name</th><th>Brand</th><th>Model (SKU)</th><th>Description</th><th class="r">Qty</th><th class="r">Price</th><th class="r">Amount</th></tr></thead>
           <tbody>${pending.map((it) => `<tr>
             <td>${esc(it.party_name)}</td>
             <td>${esc(it.brand)}</td><td class="sku">${esc(it.model)}</td>
             <td class="desc">${esc(it.description)}</td>
             <td class="r">${qty(it.qty)}</td><td class="r">${fmt(it.unit_price, null, 2)}</td>
             <td class="r">${fmt(it.qty * it.unit_price, null, 2)}</td></tr>`).join('')}</tbody>
           <tfoot><tr>
             <td colspan="6" class="r">Total of ${pending.length} item${pending.length === 1 ? '' : 's'}</td>
             <td class="r">${fmt(pending.reduce((a, it) => a + it.qty * it.unit_price, 0), null, 2)}</td>
           </tr></tfoot>
         </table></div>`
      : '';
  };

  // A supplier invoice: read who it is from, and reuse their existing account so no duplicate is made.
  const takeInvoicePdf = async (file) => {
    const info = await extractInvoice(file);
    if (info.readError || !info.supplier) {
      return toast('Could not find a supplier name on that invoice — type it in.', 'err');
    }
    let hit = null;
    try { hit = matchParty(info.supplier, (await api.parties()).parties); } catch { /* fall back to the name as printed */ }
    const nameInput = $('#new-form [name=party]');
    if (nameInput && !nameInput.value.trim()) nameInput.value = hit ? hit.party.name : info.supplier;
    const invInput = $('#new-form [name=invoice_no]');
    if (invInput && !invInput.value.trim() && info.invoiceNo) invInput.value = info.invoiceNo;
    if (info.invoiceDate) $('#new-form [name=deal_date]').value = info.invoiceDate;
    if (info.currency && CURRENCIES.includes(info.currency)) $('#new-form [name=currency]').value = info.currency;
    toast(hit ? `Supplier “${info.supplier}” — using your existing account ${hit.party.name}`
      : `Supplier “${info.supplier}” — no existing account, a new one will be created`, 'ok');
  };

  const take = async (file) => {
    if (!file) return;
    if (direction === 'sending' && /\.pdf$/i.test(file.name)) return takeInvoicePdf(file);
    const got = await importItemsFlow(file);
    if (got) {
      pending = got.items;
      sheet = got.info;
      showPending();
      // The invoice columns tell us who the record is with and which invoice it
      // is, so those are filled in rather than retyped. They stay editable.
      const nameInput = $('#new-form [name=party]');
      if (nameInput && !nameInput.value.trim() && sheet.party_name) {
        // Reuse the existing account where the name is a near match, so a legal
        // suffix or a small difference in spelling does not open a second one.
        let hit = null;
        try { hit = matchParty(sheet.party_name, (await api.parties()).parties); } catch { /* use the name as printed */ }
        nameInput.value = hit ? hit.party.name : sheet.party_name;
        toast(hit ? `Name from the file: ${sheet.party_name} — using your existing account ${hit.party.name}`
          : `Name taken from the file: ${sheet.party_name}`, 'ok');
      }
      const invInput = $('#new-form [name=invoice_no]');
      if (invInput && !invInput.value.trim() && sheet.invoice_no) invInput.value = sheet.invoice_no;
    }
  };

  drop.addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', (e) => take(e.target.files[0]));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('is-over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('is-over'));
  drop.addEventListener('drop', (e) => {
    e.preventDefault(); drop.classList.remove('is-over');
    take(e.dataTransfer.files[0]);
  });

  $('#new-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('[type=submit]');
    btn.disabled = true;
    try {
      const f = new FormData(e.target);
      const deal = await api.createDeal({
        direction,
        party: String(f.get('party')).trim(),
        reference: String(f.get('reference') || '').trim(),
        deal_date: f.get('deal_date') || todayISO(),
        currency: f.get('currency'),
        discount_pct: Number(f.get('discount_pct') || 0),
        notes: String(f.get('notes') || '').trim(),
      });
      if (pending.length) await api.addItems(deal.id, pending);

      // The invoice number and the supplier's own details go on file with the
      // order. What is typed into the form wins over what the file said.
      const info = {
        ...sheet,
        invoice_no: String(f.get('invoice_no') || '').trim() || sheet.invoice_no || '',
        total: pending.reduce((a, it) => a + it.qty * it.unit_price, 0),
      };
      let saved = [];
      try {
        saved = await saveSheetInfo(deal, info);
      } catch (err) {
        // The order itself is already created, so this must not lose it.
        toast(`Order created, but its invoice details could not be saved: ${errText(err)}`, 'err');
      }

      const down = Number(f.get('down_amount') || 0);
      if (down > 0) {
        await api.addPayment({
          deal_id: deal.id,
          amount: down,
          paid_on: f.get('down_date') || todayISO(),
          method: String(f.get('down_method') || '').trim(),
          note: 'Down payment',
          is_down_payment: true,
        });
      }

      const bits = [
        pending.length ? `${pending.length} items imported` : 'no items yet',
        down > 0 ? `down payment ${money(down, f.get('currency'))} recorded` : null,
        ...saved,
      ].filter(Boolean);
      toast(`${deal.reference} created — ${bits.join(', ')}`, 'ok');
      location.hash = `#/deal/${deal.id}`;
    } catch (err) {
      toast(errText(err), 'err');
      btn.disabled = false;
    }
  });
}

async function viewDeal(id) {
  setLoading();
  const { head: d, items, payments, invoices } = await api.deal(id);
  if (!d) {
    view().innerHTML = '<div class="card"><div class="empty">That record does not exist, or you do not have access to it.</div></div>';
    return;
  }

  const dir = DIR[d.direction];
  const dec = d.cur_decimals;
  // Money leaves you on a purchase and comes in on a sale, which is what
  // decides whose account is credited and whose is debited.
  const out = d.direction === 'sending';
  const left = Number(d.amount_left);
  const covered = left === 0 && d.status !== 'empty';
  const over = left < 0;
  const leftCls = over ? 'is-over' : covered ? 'is-covered' : 'is-due';

  const headline = over
    ? `Overpaid by ${money(Math.abs(left), d.currency, dec)}`
    : covered
      ? 'Fully covered — nothing left to pay'
      : d.bill_total == 0
        ? 'No bill yet — add items or upload the invoice'
        : `${dir.cls === 'in' ? 'Customer still owes' : 'You still owe'} ${money(left, d.currency, dec)}`;

  const billNote = d.bill_source === 'invoice'
    ? `From uploaded invoice${d.invoice_no ? ` ${esc(d.invoice_no)}` : ''}`
    : Number(d.discount_pct) > 0
      ? `From item list, after ${fmt(d.discount_pct, null, 2)}% discount`
      : 'From item list';

  const mismatch = d.bill_source === 'invoice' && Number(d.items_vs_bill) !== 0;

  view().innerHTML = `
    <div class="page-head">
      <div>
        <div class="row-meta" style="margin-bottom:4px">
          <a href="#/${d.direction}">${dir.label}</a>
          <span>·</span>
          <span>${esc(dateLabel(d.deal_date))}</span>
          ${d.reference ? `<span>·</span><span>${esc(d.reference)}</span>` : ''}
        </div>
        <h2>${esc(d.party)}
          <a class="uid-chip" href="#/party/${d.party_id}"
             title="Open the account for ${esc(d.party)}">${esc(d.party_uid)}</a>
        </h2>
        ${d.notes ? `<p>${esc(d.notes)}</p>` : ''}
      </div>
      <div class="spacer"></div>
      ${d.deleted_at ? `
        <button class="btn" data-act="restore-deal" type="button">Restore</button>
        <button class="btn btn-danger" data-act="purge-deal" type="button">Delete permanently</button>`
      : canEdit() ? `
        <button class="btn" data-act="edit-deal" type="button">Edit details</button>
        <button class="btn btn-danger" data-act="delete-deal" type="button">Delete</button>` : ''}
    </div>

    ${d.deleted_at ? `<div class="notice notice-warn" style="margin-bottom:18px">
      <strong>Deleted by ${esc(d.deleted_by_name || d.deleted_by_username || 'a removed user')}</strong>
      on ${esc(new Date(d.deleted_at).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' }))}.
      It is hidden from everyone else and left out of all totals. Nothing has actually been erased —
      restore it, or delete it permanently.
    </div>` : ''}

    <div class="money-panel">
      <div class="money-left ${leftCls}">
        <h4>${over ? 'Overpaid by' : 'Left to pay'}</h4>
        <div class="amount">${left > 0 ? '+' : ''}${fmt(Math.abs(left), d.currency, dec)}<small>${esc(d.currency)} LEFT</small></div>
        <div class="headline">
          ${covered ? '<svg viewBox="0 0 24 24"><path d="m4 12.5 5 5L20 6.5"/></svg>' : ''}
          ${esc(headline)}
        </div>
        <div class="progress-wrap">
          <div class="progress-labels">
            <span>${fmt(d.percent_paid, null, 1)}% paid</span>
            <span>of ${fmt(d.bill_total, d.currency, dec)} ${esc(d.currency)}</span>
          </div>
          <div class="bar bar-${d.status}"><i style="width:${Math.min(100, Math.max(0, Number(d.percent_paid)))}%"></i></div>
        </div>
      </div>
      <div class="money-side">
        <div class="money-cell">
          <h4>Bill total</h4>
          <div class="amount">${fmt(d.bill_total, d.currency, dec)}<small>${esc(d.currency)}</small></div>
          <div class="note">${billNote}${fxApprox(d.bill_total, d.currency) ? ` · ${fxApprox(d.bill_total, d.currency)}` : ''}</div>
        </div>
        <div class="money-cell">
          <h4>Paid so far</h4>
          <div class="amount">${fmt(d.paid, d.currency, dec)}<small>${esc(d.currency)}</small></div>
          <div class="note">${Number(d.down_payment) > 0
            ? `Down payment ${money(d.down_payment, d.currency, dec)}`
            : payments.length ? `${payments.length} payment${payments.length === 1 ? '' : 's'}` : 'Nothing paid yet'}${fxApprox(d.paid, d.currency) ? ` · ${fxApprox(d.paid, d.currency)}` : ''}</div>
        </div>
        <div class="money-cell">
          <h4>${esc(dir.word)} account</h4>
          <div class="amount bal-${BALANCE[d.balance_state].cls}">
            ${signed(d.balance, d.currency, dec)}<small>${esc(d.currency)}</small>
          </div>
          <div class="note">${esc(balanceLine(d.balance_state, d.balance, d.currency, dec, dir.word))}
            ${Number(d.shipment_count) > 0
              ? ` · ${fmt(d.percent_shipped, null, 1)}% shipped`
              : ' · nothing shipped yet'}
            · <a href="#/shipments">Shipments tab</a></div>
        </div>
      </div>
    </div>

    ${mismatch ? `<div class="notice notice-warn" style="margin-top:14px">
      <strong>Invoice and item list disagree.</strong>
      The item list comes to ${money(d.items_total, d.currency, dec)} but the uploaded invoice says
      ${money(d.bill_total, d.currency, dec)} — a difference of ${money(Math.abs(d.items_vs_bill), d.currency, dec)}.
      The invoice total is what is being used.
    </div>` : ''}

    <div class="card">
      <div class="card-head">
        <h3>Items</h3>
        <div class="spacer"></div>
        ${canEdit() ? `
          <button class="btn btn-sm" data-act="add-item" type="button">Add row</button>
          <button class="btn btn-sm" data-act="import-items" type="button">Import Excel</button>
          ${items.length ? '<button class="btn btn-sm btn-danger" data-act="clear-items" type="button">Clear</button>' : ''}` : ''}
      </div>
      <div class="card-body tight">
        ${items.length ? `
          <div class="table-scroll"><table class="data">
            <thead><tr>
              <th>Name</th><th>Brand</th><th>Model (SKU)</th><th>Description</th>
              <th class="r">Qty</th><th class="r">Unit price</th><th class="r">Amount</th>
              ${canEdit() ? '<th></th>' : ''}
            </tr></thead>
            <tbody>
              ${items.map((it) => `<tr>
                <td>${esc(it.party_name)}</td>
                <td>${esc(it.brand)}</td>
                <td class="sku">${esc(it.model)}</td>
                <td class="desc">${esc(it.description)}</td>
                <td class="r">${qty(it.qty)}</td>
                <td class="r">${fmt(it.unit_price, d.currency, dec)}</td>
                <td class="r">${fmt(it.amount, d.currency, dec)}</td>
                ${canEdit() ? `<td class="act"><button class="btn btn-ghost btn-sm" data-act="del-item" data-id="${it.id}" type="button">✕</button></td>` : ''}
              </tr>`).join('')}
            </tbody>
            <tfoot>
              <tr>
                <td colspan="6" class="r">Subtotal</td>
                <td class="r">${fmt(d.subtotal, d.currency, dec)}</td>
                ${canEdit() ? '<td></td>' : ''}
              </tr>
              ${Number(d.discount_pct) > 0 ? `<tr>
                <td colspan="6" class="r">Discount ${fmt(d.discount_pct, null, 2)}%</td>
                <td class="r">−${fmt(d.discount_amount, d.currency, dec)}</td>
                ${canEdit() ? '<td></td>' : ''}
              </tr>
              <tr>
                <td colspan="6" class="r">Item list total</td>
                <td class="r">${fmt(d.items_total, d.currency, dec)}</td>
                ${canEdit() ? '<td></td>' : ''}
              </tr>` : ''}
            </tfoot>
          </table></div>`
          : `<div class="empty">No items yet.${canEdit() ? ' Import an Excel price list or add rows by hand.' : ''}</div>`}
      </div>
    </div>

    <div class="card">
      <div class="card-head">
        <h3>${d.direction === 'receiving' ? 'Payments received' : 'Payments made'}</h3>
        <div class="spacer"></div>
        ${canEdit() ? '<button class="btn btn-sm btn-accent" data-act="add-payment" type="button">Record payment</button>' : ''}
      </div>
      <div class="card-body tight">
        ${payments.length ? `
          <div class="table-scroll"><table class="data">
            <thead><tr>
              <th>Date</th><th>Method</th><th>Note</th><th class="r">Amount</th>
              <th class="r">${esc(dir.word)} account</th><th class="r">Your account</th>
              ${canEdit() ? '<th></th>' : ''}
            </tr></thead>
            <tbody>
              ${payments.map((p) => `<tr>
                <td>${esc(dateLabel(p.paid_on))}</td>
                <td>${esc(p.method || '—')} ${p.is_down_payment ? '<span class="tag tag-down">Down payment</span>' : ''}</td>
                <td class="desc">${esc(p.note || '')}</td>
                <td class="r">${fmt(p.amount, d.currency, dec)}</td>
                <td class="r"><span class="entry-${out ? 'cr' : 'dr'}">${out ? 'Credited' : 'Debited'} ${fmt(p.amount, d.currency, dec)}</span></td>
                <td class="r"><span class="entry-${out ? 'dr' : 'cr'}">${out ? 'Debited' : 'Credited'} ${fmt(p.amount, d.currency, dec)}</span></td>
                ${canEdit() ? `<td class="act"><button class="btn btn-ghost btn-sm" data-act="del-payment" data-id="${p.id}" type="button">✕</button></td>` : ''}
              </tr>`).join('')}
            </tbody>
            <tfoot><tr>
              <td colspan="3" class="r">Total paid</td>
              <td class="r">${fmt(d.paid, d.currency, dec)}</td>
              <td class="r">${fmt(d.paid, d.currency, dec)}</td>
              <td class="r">${fmt(d.paid, d.currency, dec)}</td>
              ${canEdit() ? '<td></td>' : ''}
            </tr></tfoot>
          </table></div>
          <p class="preview-note" style="padding-bottom:12px;margin:0">
            ${d.direction === 'sending'
              ? `Money you send credits the ${esc(dir.word.toLowerCase())}’s account and debits yours, leaving them holding value until the goods arrive.`
              : `Money the customer sends debits their account and credits yours, leaving you holding value until you deliver.`}
          </p>`
          : `<div class="empty">No payments recorded yet.</div>`}
      </div>
    </div>

    <div class="card">
      <div class="card-head">
        <h3>Invoices</h3>
        <div class="spacer"></div>
        ${canEdit() ? '<button class="btn btn-sm" data-act="upload-invoice" type="button">Upload invoice</button>' : ''}
      </div>
      <div class="card-body tight">
        ${invoices.length ? `
          <div class="table-scroll"><table class="data">
            <thead><tr><th>Invoice no</th><th>Date</th><th>File</th><th>Uploaded</th><th class="r">Total</th>${canEdit() ? '<th></th>' : ''}</tr></thead>
            <tbody>
              ${invoices.map((iv, i) => `<tr>
                <td>${esc(iv.invoice_no || '—')} ${i === 0 ? '<span class="tag">In use</span>' : ''}</td>
                <td>${esc(dateLabel(iv.invoice_date) || '—')}</td>
                <td>${iv.file_path
                  ? `<a href="#" data-act="open-file" data-path="${esc(iv.file_path)}">${esc(iv.file_name || 'view')}</a>`
                  : '<span class="dim">no file</span>'}</td>
                <td class="dim">${esc(new Date(iv.uploaded_at).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' }))}</td>
                <td class="r">${fmt(iv.total, iv.currency || d.currency, decOf(iv.currency || d.currency))}${
                  iv.parsed?.read_currency && iv.parsed.read_currency !== (iv.currency || d.currency)
                    ? `<div class="dim" style="font-size:12px">from ${fmt(iv.parsed.read_total, iv.parsed.read_currency)} ${esc(iv.parsed.read_currency)}</div>` : ''}</td>
                ${canEdit() ? `<td class="act"><button class="btn btn-ghost btn-sm" data-act="del-invoice" data-id="${iv.id}" type="button">✕</button></td>` : ''}
              </tr>`).join('')}
            </tbody>
          </table></div>
          <p class="preview-note" style="padding:10px 12px;margin:0">The newest invoice sets the bill total. Older ones are kept for your records.</p>`
          : `<div class="empty">No invoice uploaded. The bill is the item list total until you upload one.</div>`}
      </div>
    </div>`;

  // Keep the ledger this record belongs to highlighted in the sidebar.
  for (const a of $$("[data-nav]")) a.classList.toggle("is-active", a.dataset.nav === d.direction);

  wireDealActions(d, invoices);
}

function wireDealActions(d, invoices) {
  const reload = () => viewDeal(d.id);

  view().addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const act = btn.dataset.act;

    if (act === 'open-file') {
      e.preventDefault();
      try {
        window.open(await api.signedUrl(btn.dataset.path), '_blank', 'noopener');
      } catch (err) { toast(errText(err), 'err'); }
      return;
    }

    if (!canEdit()) return;

    try {
      if (act === 'del-item') {
        await api.deleteItem(btn.dataset.id); toast('Item removed', 'ok'); return reload();
      }
      if (act === 'clear-items') {
        if (!await confirmAction('Remove every item from this record?', 'Remove all')) return;
        await api.clearItems(d.id); toast('Items cleared', 'ok'); return reload();
      }
      if (act === 'del-payment') {
        if (!await confirmAction('Delete this payment?', 'Delete')) return;
        await api.deletePayment(btn.dataset.id); toast('Payment deleted', 'ok'); return reload();
      }
      if (act === 'del-invoice') {
        const inv = invoices.find((i) => i.id === btn.dataset.id);
        if (!await confirmAction('Delete this invoice and its file?', 'Delete')) return;
        await api.deleteInvoice(inv); toast('Invoice deleted', 'ok'); return reload();
      }
      if (act === 'delete-deal') {
        if (!await confirmAction(
          `Delete "${d.party}"? It disappears from your lists and totals, but the owner can still see it and who deleted it.`,
          'Delete')) return;
        await api.deleteDeal(d.id); toast('Deleted — the owner can still restore it', 'ok');
        location.hash = `#/${d.direction}`; return;
      }
      if (act === 'restore-deal') {
        await api.restoreDeal(d.id); toast('Restored', 'ok'); return reload();
      }
      if (act === 'purge-deal') {
        if (!await confirmAction(
          `Permanently delete "${d.party}" with all its items, payments and invoices? This cannot be undone.`,
          'Delete for good')) return;
        await api.purgeDeal(d.id); toast('Deleted permanently', 'ok');
        location.hash = `#/${d.direction}`; return;
      }
      if (act === 'import-items') {
        const file = await pickFile('.xlsx,.xls,.csv');
        if (!file) return;
        const got = await importItemsFlow(file);
        if (!got) return;
        const { items, info } = got;
        const replace = await confirmAction(
          `Import ${items.length} items. Replace the items already on this record?`, 'Replace');
        if (replace) await api.clearItems(d.id);
        await api.addItems(d.id, items);
        // Same file, same invoice: its number and the supplier's details go on
        // file too, so a re-import keeps the account as complete as a new order.
        let saved = [];
        try {
          saved = await saveSheetInfo(d, info, invoices);
        } catch (err) {
          toast(`Items imported, but the invoice details could not be saved: ${errText(err)}`, 'err');
        }
        toast([`${items.length} items imported`, ...saved].join(' — '), 'ok');
        return reload();
      }
      if (act === 'add-item') return itemDialog(d, reload);
      if (act === 'add-payment') return paymentDialog(d, reload);
      if (act === 'upload-invoice') return invoiceDialog(d, reload);
      if (act === 'edit-deal') return dealDialog(d, reload);
    } catch (err) {
      toast(errText(err), 'err');
    }
  }, { once: false });
}

function pickFile(accept) {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = accept;
    input.onchange = () => resolve(input.files[0] || null);
    input.click();
  });
}

function itemDialog(d, done) {
  const m = openModal({
    title: 'Add an item',
    width: '560px',
    body: `<form id="f" class="grid-form">
      <label class="field"><span>Brand</span><input name="brand" placeholder="DSPPA"></label>
      <label class="field"><span>Model (SKU)</span><input name="model" placeholder="E750U"></label>
      <label class="field wide"><span>Description</span><input name="description" placeholder="Medium Throw laser WUXGA Projector"></label>
      <label class="field"><span>Quantity</span><input name="qty" type="number" step="0.001" min="0" value="1" required></label>
      <label class="field"><span>Unit price (${esc(d.currency)})</span><input name="unit_price" type="number" step="0.0001" min="0" value="0" required></label>
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-primary" id="go" type="button">Add item</button>`,
  });

  $('#go', m).onclick = async () => {
    const f = new FormData($('#f', m));
    if (!String(f.get('brand') || '').trim() && !String(f.get('model') || '').trim() && !String(f.get('description') || '').trim()) {
      return toast('Give the item at least a brand, model or description.', 'err');
    }
    try {
      await api.addItems(d.id, [{
        brand: String(f.get('brand') || '').trim(),
        model: String(f.get('model') || '').trim(),
        description: String(f.get('description') || '').trim(),
        qty: Number(f.get('qty') || 1),
        unit_price: Number(f.get('unit_price') || 0),
      }]);
      closeModal(); toast('Item added', 'ok'); done();
    } catch (e) { toast(errText(e), 'err'); }
  };
}

function paymentDialog(d, done) {
  const left = Number(d.amount_left);
  const suggest = left > 0 ? left : 0;
  const isFirst = Number(d.paid) === 0;
  const dec = d.cur_decimals;
  const out = d.direction === 'sending';
  const word = DIR[d.direction].word;

  const m = openModal({
    title: d.direction === 'receiving' ? 'Record a payment received' : 'Record a payment made',
    width: '560px',
    body: `<form id="f" class="grid-form">
      <label class="field">
        <span>Amount (${esc(d.currency)})</span>
        <input name="amount" type="number" step="0.001" min="0" value="${suggest || ''}" required autofocus>
      </label>
      <label class="field"><span>Date</span><input name="paid_on" type="date" value="${todayISO()}" required></label>
      <label class="field"><span>Method <em>(optional)</em></span><input name="method" placeholder="TT, cash, cheque"></label>
      <label class="field"><span>Note <em>(optional)</em></span><input name="note"></label>
      <label class="check wide">
        <input type="checkbox" name="is_down_payment" ${isFirst ? 'checked' : ''}>
        This is the down payment
      </label>
      <div class="entry-preview wide" id="pay-entries"></div>
      ${left > 0 ? `<p class="preview-note wide" style="margin:0">
        Outstanding right now: <b>${money(left, d.currency, d.cur_decimals)}</b>.
        Enter that exact amount to clear the balance to zero.</p>` : ''}
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-accent" id="go" type="button">Save payment</button>`,
  });

  // Show the pair of entries this payment writes, and where it leaves the
  // account, before it is saved.
  const amountInput = $('[name=amount]', m);
  const paintEntries = () => {
    const amount = Number(amountInput.value || 0);
    const box = $('#pay-entries', m);
    if (!(amount > 0)) { box.innerHTML = ''; return; }
    const after = Number(d.balance || 0) + (out ? amount : -amount);
    const state = after === 0 ? 'even' : after > 0 ? 'party_owes' : 'you_owe';
    box.innerHTML = `
      <div class="entry-row">
        <span>${esc(word)}’s account</span>
        <b class="entry-${out ? 'cr' : 'dr'}">${out ? 'Credited' : 'Debited'} ${money(amount, d.currency, dec)}</b>
      </div>
      <div class="entry-row">
        <span>Your account</span>
        <b class="entry-${out ? 'dr' : 'cr'}">${out ? 'Debited' : 'Credited'} ${money(amount, d.currency, dec)}</b>
      </div>
      <div class="entry-row entry-total bal-${BALANCE[state].cls}">
        <span>After this</span>
        <b>${esc(balanceLine(state, after, d.currency, dec, word))}</b>
      </div>`;
  };
  amountInput.addEventListener('input', paintEntries);
  paintEntries();

  $('#go', m).onclick = async () => {
    const f = new FormData($('#f', m));
    const amount = Number(f.get('amount'));
    if (!(amount > 0)) return toast('Enter an amount greater than zero.', 'err');
    try {
      await api.addPayment({
        deal_id: d.id,
        amount,
        paid_on: f.get('paid_on') || todayISO(),
        method: String(f.get('method') || '').trim(),
        note: String(f.get('note') || '').trim(),
        is_down_payment: f.get('is_down_payment') === 'on',
      });
      closeModal(); toast('Payment recorded', 'ok'); done();
    } catch (e) { toast(errText(e), 'err'); }
  };
}

/* Recording the shipment is what closes the loop: the money already moved,
 * and this says the goods did too. Typing the receipt number is enough —
 * the goods value is pre-filled with whatever is still unshipped, so a full
 * delivery against a fully paid order lands the account on zero.
 */
function shipmentDialog(d, done) {
  const dec = d.cur_decimals;
  const out = d.direction === 'sending';
  const word = DIR[d.direction].word;
  const remaining = Math.max(0, Number(d.bill_total) - Number(d.goods_value));
  let file = null;

  const m = openModal({
    title: out ? 'Record a shipment received' : 'Record goods delivered',
    body: `<form id="f" class="grid-form">
      <label class="field">
        <span>Receipt no</span>
        <input name="receipt_id" placeholder="e.g. RCPT-0001" required autofocus
               autocapitalize="characters" spellcheck="false">
      </label>
      <label class="field">
        <span>Date ${out ? 'received' : 'delivered'}</span>
        <input name="shipped_on" type="date" value="${todayISO()}" required>
      </label>
      <label class="field">
        <span>Price / goods value (${esc(d.currency)})</span>
        <input name="amount" type="number" step="0.001" min="0" value="${remaining || ''}" required>
      </label>
      <label class="field">
        <span>Carrier <em>(optional)</em></span>
        <input name="carrier" placeholder="DHL, Aramex, sea freight">
      </label>
      <label class="field wide"><span>Note <em>(optional)</em></span><input name="note"></label>

      <div class="dropzone wide" id="sh-drop">
        <strong>Attach the receipt or packing list <em>(optional)</em></strong>
        <small>PDF, Excel, CSV or a photo — or drag it here</small>
        <input type="file" id="sh-file" accept=".pdf,.xlsx,.xls,.csv,.png,.jpg,.jpeg,.webp" hidden>
      </div>

      <div class="entry-preview wide" id="sh-entries"></div>
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-accent" id="go" type="button">Save shipment</button>`,
  });

  const amountInput = $('[name=amount]', m);
  const paintEntries = () => {
    const amount = Number(amountInput.value || 0);
    const box = $('#sh-entries', m);
    if (!(amount > 0)) { box.innerHTML = ''; return; }
    // Goods move the opposite way to the money, so they cancel it out.
    const after = Number(d.balance || 0) + (out ? -amount : amount);
    const state = after === 0 ? 'even' : after > 0 ? 'party_owes' : 'you_owe';
    box.innerHTML = `
      <div class="entry-row">
        <span>${esc(word)}’s account</span>
        <b class="entry-${out ? 'dr' : 'cr'}">${out ? 'Debited' : 'Credited'} ${money(amount, d.currency, dec)}</b>
      </div>
      <div class="entry-row entry-total bal-${BALANCE[state].cls}">
        <span>After this</span>
        <b>${state === 'even'
            ? `Even — everything settled, account at zero`
            : esc(balanceLine(state, after, d.currency, dec, word))}</b>
      </div>`;
  };

  const drop = $('#sh-drop', m);
  const input = $('#sh-file', m);
  const handle = (f) => {
    if (!f) return;
    file = f;
    drop.innerHTML = `<strong>${esc(f.name)}</strong>
      <small>${(f.size / 1024).toFixed(0)} KB — click to choose a different file</small>`;
  };
  drop.addEventListener('click', () => input.click());
  input.addEventListener('change', (e) => handle(e.target.files[0]));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('is-over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('is-over'));
  drop.addEventListener('drop', (e) => {
    e.preventDefault(); drop.classList.remove('is-over');
    handle(e.dataTransfer.files[0]);
  });

  amountInput.addEventListener('input', paintEntries);
  paintEntries();

  const go = $('#go', m);
  go.onclick = async () => {
    const form = $('#f', m);
    if (!form.reportValidity()) return;
    const f = new FormData(form);
    const amount = Number(f.get('amount'));
    if (!(amount > 0)) return toast('Enter the value of the goods.', 'err');

    go.disabled = true;
    try {
      let filePath = null, fileName = null, fileSize = null;
      if (file) {
        filePath = await api.uploadShipmentFile(d.id, file);
        fileName = file.name;
        fileSize = file.size;
      }
      await api.addShipment({
        deal_id: d.id,
        receipt_id: String(f.get('receipt_id') || '').trim(),
        shipped_on: f.get('shipped_on') || todayISO(),
        amount,
        carrier: String(f.get('carrier') || '').trim(),
        note: String(f.get('note') || '').trim(),
        file_path: filePath,
        file_name: fileName,
        file_size: fileSize,
      });
      closeModal(); toast('Shipment recorded', 'ok'); done();
    } catch (e) {
      toast(errText(e), 'err');
      go.disabled = false;
    }
  };
}

function invoiceDialog(d, done) {
  let file = null;
  let detected = null;     // the currency read from the file, if any
  let rateTouched = false; // true once the rate has been typed by hand
  const dealCur = String(d.currency).toUpperCase();
  const dealDec = decOf(dealCur);

  const m = openModal({
    title: 'Upload an invoice',
    body: `
      <div class="dropzone" id="iv-drop">
        <strong>Choose the invoice file</strong>
        <small>PDF, Excel, CSV or a photo — the total and currency are read automatically from PDF, Excel and CSV</small>
        <input type="file" id="iv-file" accept=".pdf,.xlsx,.xls,.csv,.png,.jpg,.jpeg,.webp" hidden>
      </div>
      <p class="preview-note" id="iv-status" hidden></p>
      <div id="iv-cur"></div>
      <form id="f" class="grid-form">
        <label class="field"><span>Invoice number</span><input name="invoice_no" placeholder="D261009LJ028"></label>
        <label class="field"><span>Invoice date</span><input name="invoice_date" type="date"></label>
        <label class="field">
          <span>Invoice is priced in</span>
          <select name="currency">
            <option value="">Choose USD, KWD…</option>
            ${CURRENCIES.map((c) => `<option value="${c}">${c}</option>`).join('')}
          </select>
        </label>
        <label class="field">
          <span>Invoice total</span>
          <input name="total" type="number" step="0.001" min="0" required>
        </label>
        <label class="field" id="iv-rate-wrap" style="display:none">
          <span id="iv-rate-label">Exchange rate</span>
          <input name="rate" type="number" step="any" min="0">
        </label>
        <label class="field">
          <span>Raise or lower the price by % <em>(optional)</em></span>
          <input name="adjust_pct" type="number" step="0.01" min="-100" placeholder="e.g. 5 or -5">
        </label>
        <div class="pct-quick wide" id="iv-quick">
          ${[-10, -5, -1, 1, 5, 10].map((p) => `<button class="btn btn-sm" type="button" data-pct="${p}">${p > 0 ? '+' : '−'}${Math.abs(p)}%</button>`).join('')}
          <button class="btn btn-ghost btn-sm" type="button" data-pct="0">Reset</button>
        </div>
        <div class="entry-preview wide" id="iv-adjust"></div>
        <p class="preview-note wide" style="margin:0">
          The price at the bottom becomes the bill for this record, in ${esc(dealCur)}, replacing the item list total.
          Check it against the invoice before saving.
        </p>
      </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-primary" id="go" type="button">Save invoice</button>`,
  });

  const drop = $('#iv-drop', m);
  const status = $('#iv-status', m);
  const input = $('#iv-file', m);
  const form = () => $('#f', m);

  // What will be saved: the invoice total, converted to the order's currency
  // when the invoice is in a different one, then moved up or down by the %.
  const calc = () => {
    const f = form();
    const from = f.currency.value.toUpperCase();
    const base = Number(f.total.value);
    const pct = Number(f.adjust_pct.value || 0);
    const converting = !!from && from !== dealCur;
    const rate = converting ? Number(f.rate.value) : 1;
    const factor = 10 ** dealDec;
    const converted = Math.round(base * rate * factor) / factor;
    const value = Math.round(converted * (1 + pct / 100) * factor) / factor;
    return { from, base, pct, converting, rate, converted, value };
  };

  const syncRate = () => {
    const f = form();
    const from = f.currency.value.toUpperCase();
    const differs = !!from && from !== dealCur;
    $('#iv-rate-wrap', m).style.display = differs ? '' : 'none';
    if (!differs) return;
    $('#iv-rate-label', m).textContent = `Rate: 1 ${from} = ? ${dealCur}`;
    if (!rateTouched) {
      const r = convert(1, from, dealCur);
      f.rate.value = r == null ? '' : String(Number(r.toFixed(6)));
    }
  };

  // Every upload gets a currency check, whatever the file says.
  const paintCheck = () => {
    const from = form().currency.value.toUpperCase();
    const how = detected && detected === from ? 'read from the file' : 'chosen by you';
    let cls = 'notice-warn', html;
    if (!from) {
      html = `<strong>Check the currency.</strong> Pick the currency this invoice is priced in
        (USD, KWD…). It could not be read from the file.`;
    } else if (from === dealCur) {
      cls = 'notice-ok';
      html = `<strong>Currency check:</strong> the invoice is in <b>${esc(from)}</b> (${how}),
        the same as this order. No conversion needed.`;
    } else {
      const r = convert(1, from, dealCur);
      html = `<strong>Currency check:</strong> the invoice is in <b>${esc(from)}</b> (${how}) but this
        order is in <b>${esc(dealCur)}</b>. It will be converted to ${esc(dealCur)} before it becomes the bill${
        r == null ? ' — no live rate is available, type one below' : ` at the live rate, 1 ${esc(from)} = ${r.toFixed(r < 1 ? 6 : 4)} ${esc(dealCur)}`}.`;
    }
    $('#iv-cur', m).innerHTML = `<div class="notice ${cls}" style="margin-bottom:14px">${html}</div>`;
  };

  const paintAdjust = () => {
    const box = $('#iv-adjust', m);
    const a = calc();
    const f = form();
    if (!(f.total.value !== '' && a.base >= 0 && (a.converting || a.pct !== 0))) { box.innerHTML = ''; return; }
    let rows = `<div class="entry-row"><span>Invoice total</span><b>${money(a.base, a.from, decOf(a.from))}</b></div>`;
    if (a.converting) {
      rows += `<div class="entry-row"><span>Converted at 1 ${esc(a.from)} = ${esc(String(a.rate || '?'))} ${esc(dealCur)}</span>
        <b>${a.rate > 0 ? money(a.converted, dealCur, dealDec) : '—'}</b></div>`;
    }
    if (a.pct !== 0) {
      rows += `<div class="entry-row entry-total"><span>${a.pct > 0 ? 'Raised' : 'Lowered'} by ${fmt(Math.abs(a.pct), null, 2)}%</span>
        <b class="${a.pct > 0 ? 'bal-owed' : 'bal-owing'}">${signed(a.value - a.converted, dealCur, dealDec)}</b></div>`;
    }
    rows += `<div class="entry-row entry-total"><span>New price (becomes the bill)</span>
      <b>${a.converting && !(a.rate > 0) ? '—' : money(a.value, dealCur, dealDec)}</b></div>`;
    box.innerHTML = rows;
  };

  const refresh = () => { syncRate(); paintCheck(); paintAdjust(); };

  form().addEventListener('input', (e) => {
    if (e.target.name === 'rate') rateTouched = true;
    if (e.target.name === 'currency') rateTouched = false;
    refresh();
  });
  $('#iv-quick', m).addEventListener('click', (e) => {
    const b = e.target.closest('[data-pct]');
    if (!b) return;
    const step = Number(b.dataset.pct);
    // The buttons stack: +5 then +5 again makes +10. Reset clears it.
    form().adjust_pct.value = step === 0 ? '' : Math.round((Number(form().adjust_pct.value || 0) + step) * 100) / 100;
    refresh();
  });

  const handle = async (f) => {
    if (!f) return;
    file = f;
    status.hidden = false;
    status.innerHTML = `Reading <b>${esc(f.name)}</b>…`;
    drop.innerHTML = `<strong>${esc(f.name)}</strong><small>${(f.size / 1024).toFixed(0)} KB — click to choose a different file</small>`;

    const got = await extractInvoice(f);
    const fm = form();
    if (got.invoiceNo) fm.invoice_no.value = got.invoiceNo;
    if (got.invoiceDate) fm.invoice_date.value = got.invoiceDate;
    if (got.total != null) fm.total.value = got.total;
    // Each new file is checked afresh: the currency is whatever this file says,
    // or left blank so it has to be chosen.
    detected = got.currency || null;
    fm.currency.value = detected || '';
    rateTouched = false;
    refresh();

    const found = [
      got.invoiceNo && 'number', got.invoiceDate && 'date',
      got.total != null && 'total', got.currency && 'currency',
    ].filter(Boolean);

    status.innerHTML = got.readError
      ? `Could not read the file automatically (${esc(got.readError)}). Fill the fields in by hand.`
      : found.length
        ? `Read the ${found.join(', ')} from the file. Check the figures, then save.`
        : 'Nothing could be read automatically from this file — fill the fields in by hand.';
  };

  drop.addEventListener('click', () => input.click());
  input.addEventListener('change', (e) => handle(e.target.files[0]));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('is-over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('is-over'));
  drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('is-over'); handle(e.dataTransfer.files[0]); });
  refresh();

  $('#go', m).onclick = async () => {
    const f = new FormData(form());
    const a = calc();
    if (!a.from) return toast('Choose the currency the invoice is priced in.', 'err');
    if (!(a.base >= 0) || f.get('total') === '') return toast('Enter the invoice total.', 'err');
    if (a.converting && !(a.rate > 0)) return toast(`Enter the rate from ${a.from} to ${dealCur}.`, 'err');
    if (a.pct <= -100) return toast('A drop of 100% or more would make the price zero.', 'err');
    const go = $('#go', m);
    go.disabled = true;
    try {
      let path = null, name = null, size = null;
      if (file) {
        path = await api.uploadInvoiceFile(d.id, file);
        name = file.name;
        size = file.size;
      }
      await api.addInvoice({
        deal_id: d.id,
        invoice_no: String(f.get('invoice_no') || '').trim(),
        invoice_date: f.get('invoice_date') || null,
        // The bill is held in the order's currency, so that is what is saved.
        total: a.value,
        currency: dealCur,
        file_path: path, file_name: name, file_size: size,
        // What the invoice itself said, and how it was turned into the bill.
        parsed: {
          read_total: a.base,
          read_currency: a.from,
          ...(a.converting ? { rate: a.rate } : {}),
          ...(a.pct !== 0 ? { adjust_pct: a.pct } : {}),
        },
      });
      closeModal();
      toast('Invoice saved — the balance has been recalculated', 'ok');
      done();
    } catch (e) {
      toast(errText(e), 'err');
      go.disabled = false;
    }
  };
}

function dealDialog(d, done) {
  const m = openModal({
    title: 'Edit details',
    width: '620px',
    body: `<form id="f" class="grid-form">
      <label class="field" style="grid-column:span 2"><span>${DIR[d.direction].word} name</span>
        <input name="party" value="${esc(d.party)}" required></label>
      <label class="field"><span>Reference</span><input name="reference" value="${esc(d.reference)}"></label>
      <label class="field"><span>Date</span><input name="deal_date" type="date" value="${esc(d.deal_date)}" required></label>
      <label class="field"><span>Currency</span>
        <select name="currency">${CURRENCIES.map((c) => `<option value="${c}"${c === d.currency ? ' selected' : ''}>${c}</option>`).join('')}</select></label>
      <label class="field"><span>Discount %</span>
        <input name="discount_pct" type="number" step="0.01" min="0" max="100" value="${esc(d.discount_pct)}"></label>
      <label class="field wide"><span>Notes</span><textarea name="notes" rows="2">${esc(d.notes)}</textarea></label>
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-primary" id="go" type="button">Save changes</button>`,
  });

  $('#go', m).onclick = async () => {
    const f = new FormData($('#f', m));
    try {
      await api.updateDeal(d.id, {
        party: String(f.get('party')).trim(),
        reference: String(f.get('reference') || '').trim(),
        deal_date: f.get('deal_date'),
        currency: f.get('currency'),
        discount_pct: Number(f.get('discount_pct') || 0),
        notes: String(f.get('notes') || '').trim(),
      });
      closeModal(); toast('Saved', 'ok'); done();
    } catch (e) { toast(errText(e), 'err'); }
  };
}

function viewDenied() {
  view().innerHTML = `<div class="card"><div class="empty">
    You have view-only access. Ask the owner for permission to make changes.
  </div></div>`;
}

/* ------------------------------ shipments ------------------------------ */

/* Reading a delivery invoice and working out which order it belongs to.
 * Items are matched by their model / SKU, so it does not matter how the
 * supplier laid the document out — if the model is on a line, the quantity
 * is read from the numbers beside it.
 */
const normKey = (s) => String(s ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
const itemKey = (it) => normKey(it.model) || normKey(it.description).slice(0, 40);

async function readFileLines(file) {
  const ext = file.name.toLowerCase().split('.').pop();
  if (ext === 'pdf') return readPdfLines(file);
  if (['xlsx', 'xls', 'csv', 'txt'].includes(ext)) {
    const sheets = await readSheet(file);
    return sheets
      .flatMap((s) => s.rows.map((r) => r.map((c) => String(c ?? '').trim()).filter(Boolean).join(' ')))
      .filter(Boolean);
  }
  return []; // a photo has no text to read
}

/* A spreadsheet names its columns, so the invoice number and the supplier are
 * read from them rather than guessed at from the text. Flattening a sheet to
 * lines puts the headings next to each other — "Invoice Number Supplier Name"
 * — which is exactly what a loose "invoice no:" pattern reads wrongly.
 */
async function sheetHeaderInfo(file) {
  const sheets = await readSheet(file);
  for (const s of sheets) {
    const { headerRow, map } = detectLayout(s.rows);
    if (headerRow < 0) continue;
    const info = sheetInfo(rowsToItems(s.rows, headerRow, map));
    if (info.invoice_no || info.party_name || info.party_no) return info;
  }
  return {};
}

/** The quantity printed beside a model: the number that multiplies into the next one (qty × price = amount). */
function qtyOnLine(line, model) {
  const at = line.toLowerCase().indexOf(String(model).trim().toLowerCase());
  const nums = (s) => (s.match(/\d[\d,]*\.?\d*/g) || []).map(parseNum).filter((n) => n != null);
  const pick = (list) => {
    for (let i = 0; i + 2 < list.length; i++) {
      if (Math.abs(list[i] * list[i + 1] - list[i + 2]) <= 0.01 * Math.abs(list[i + 2]) + 0.01) return list[i];
    }
    return list.length && Number.isInteger(list[0]) ? list[0] : null;
  };
  if (at < 0) return pick(nums(line));
  const model_end = at + String(model).trim().length;
  return pick(nums(line.slice(model_end))) ?? pick(nums(line.slice(0, at)));
}

/** Which of the waiting orders is this file for? Best first; invoice number beats item overlap. */
function rankOrders(lines, header, deals, itemsOf) {
  const flat = normKey(lines.join(' '));
  const lineKeys = lines.map(normKey);
  return deals.map((d) => {
    const items = itemsOf(d);
    let score = 0, hits = 0;
    const invNo = normKey(d.invoice_no), ref = normKey(d.reference);
    // A spreadsheet gives its invoice number by name, so compare it outright
    // as well as looking for it in the text.
    const headerNo = normKey(header.invoiceNo);
    if (invNo.length >= 4 && headerNo.length >= 4 && headerNo === invNo) score += 100;
    if (invNo.length >= 4 && flat.includes(invNo)) score += 100;
    if (ref.length >= 4 && flat.includes(ref)) score += 60;
    // The supplier on the invoice is the same account as the order's: a nudge, never enough on its own.
    const sameSupplier = !!header.supplier && partyScore(header.supplier, d.party) >= 0.6;
    if (sameSupplier) score += 40;
    for (const it of items) {
      const k = normKey(it.model);
      if (k.length >= 3 && lineKeys.some((l) => l.includes(k))) hits++;
    }
    score += hits * 10;
    return { deal: d, score, hits, total: items.length, sameSupplier };
  }).filter((r) => r.score > 0).sort((a, b) => b.score - a.score);
}

/** What this file says arrived, item by item, for one order. */
function readArrivals(lines, items) {
  return items.map((it) => {
    const m = String(it.model || '').trim();
    if (normKey(m).length < 3) return { found: false, qty: 0 };
    const k = normKey(m);
    const line = lines.find((l) => normKey(l).includes(k));
    if (!line) return { found: false, qty: 0 };
    const q = qtyOnLine(line, m);
    // Listed on the invoice but no readable quantity: assume the full order, and flag it.
    return { found: true, qty: q != null && q > 0 ? q : Number(it.qty), guessed: q == null || q <= 0 };
  });
}

/** Units of each item that earlier shipments already brought in. */
function receivedBefore(deal, items, ships) {
  const pool = new Map();
  let legacy = 0;
  for (const s of ships) {
    if (Array.isArray(s.items) && s.items.length) {
      for (const it of s.items) pool.set(it.key, (pool.get(it.key) || 0) + Number(it.qty || 0));
    } else legacy += Number(s.amount || 0); // recorded before items were tracked: by value
  }
  const frac = Number(deal.bill_total) > 0 ? Math.min(1, legacy / Number(deal.bill_total)) : 0;
  return items.map((it) => {
    const k = itemKey(it);
    const take = Math.min(Number(it.qty), pool.get(k) || 0);
    pool.set(k, (pool.get(k) || 0) - take);
    return Math.min(Number(it.qty), take + Number(it.qty) * frac);
  });
}

/** The result of booking `arrived` units now: what is left, and the goods value that brings the account to the right point. */
function shipmentOutcome(deal, items, before, arrived) {
  const dec = deal.cur_decimals;
  let orderValue = 0, shipValue = 0, left = 0, leftLines = 0, units = 0;
  const takes = items.map((it, i) => {
    const ord = Number(it.qty), price = Number(it.unit_price);
    const take = Math.max(0, Math.min(Number(arrived[i]) || 0, ord - before[i]));
    orderValue += ord * price; shipValue += take * price; units += take;
    const l = ord - before[i] - take;
    if (l > 1e-9) { left += l; leftLines++; }
    return take;
  });
  const remaining = Math.max(0, Number(deal.bill_total) - Number(deal.goods_value));
  // Everything in: book exactly what is outstanding so the account lands on zero.
  let amount = left <= 1e-9
    ? remaining
    : Math.min(remaining, orderValue > 0 ? Number((Number(deal.bill_total) * shipValue / orderValue).toFixed(dec)) : 0);
  if (!items.length) { left = 0; leftLines = 0; amount = remaining; }
  amount = Number(amount.toFixed(dec)); // whole currency decimals, so "zero left" is exactly zero
  return { amount, left, leftLines, takes, units };
}

async function viewShipments() {
  setLoading();
  const [deals, shipments] = await Promise.all([api.deals({ limit: 500 }), api.shipments()]);
  const byId = new Map(deals.map((d) => [d.id, d]));
  const recorded = shipments.filter((s) => byId.has(s.deal_id));
  const waiting = deals.filter((d) => Number(d.bill_total) > 0 && Number(d.goods_value) < Number(d.bill_total));
  const allItems = await api.itemsFor(waiting.map((d) => d.id));
  const itemsOf = (d) => allItems.filter((i) => i.deal_id === d.id);
  const shipsOf = (d) => recorded.filter((s) => s.deal_id === d.id);
  // "3 items left" beside each waiting order, from the item list minus what arrived.
  const itemsLeftOf = (d) => {
    const items = itemsOf(d);
    if (!items.length) return null;
    const before = receivedBefore(d, items, shipsOf(d));
    return items.reduce((s, it, i) => s + Math.max(0, Number(it.qty) - before[i]), 0);
  };

  const waitingRows = (list) => list.map((d) => {
    const dir = DIR[d.direction];
    const bal = Number(d.balance);
    const left = itemsLeftOf(d);
    return `
      <div class="row-ship">
        <span class="dir-badge dir-${dir.cls}" title="${dir.label}"><svg viewBox="0 0 24 24">${dir.icon}</svg></span>
        <div class="row-party">
          <strong>${esc(d.party)} <a class="uid-chip" href="#/party/${d.party_id}">${esc(d.party_uid)}</a></strong>
          <div class="row-meta">
            <a href="#/deal/${d.id}">${esc(d.reference || 'Open order')}</a>
            <span>${dir.label}</span><span>${esc(dateLabel(d.deal_date))}</span>
            ${left != null ? `<span><b>${qty(left)}</b> item${left === 1 ? '' : 's'} left</span>` : ''}
          </div>
        </div>
        <span class="cell cell-paid"><span class="cell-k">Paid</span>${fmt(d.paid, d.currency, d.cur_decimals)}</span>
        <span class="cell cell-bal"><span class="cell-k">Account</span>${balHtml(bal, d.currency, d.cur_decimals)}</span>
        ${canEdit() ? `<button class="btn btn-sm btn-accent" data-act="ship" data-id="${d.id}" type="button">Upload invoice</button>` : '<span></span>'}
      </div>`;
  }).join('');

  const recordedTable = (list) => list.length ? `
    <div class="table-scroll"><table class="data">
      <thead><tr>
        <th>Receipt no</th><th>Date</th><th>Account</th><th>Order</th><th>Carrier</th><th>File</th>
        <th class="r">Goods value</th>${canEdit() ? '<th></th>' : ''}
      </tr></thead>
      <tbody>
        ${list.map((s) => {
          const d = byId.get(s.deal_id);
          return `<tr>
            <td class="sku">${esc(s.receipt_id || '—')}</td>
            <td>${esc(dateLabel(s.shipped_on))}</td>
            <td>${esc(d.party)} <a class="uid-chip" href="#/party/${d.party_id}">${esc(d.party_uid)}</a></td>
            <td><a href="#/deal/${d.id}">${esc(d.reference || 'open')}</a></td>
            <td>${esc(s.carrier || '—')}</td>
            <td>${s.file_path
              ? `<a href="#" data-act="open-ship-file" data-path="${esc(s.file_path)}">${esc(s.file_name || 'view')}</a>`
              : '<span class="dim">—</span>'}</td>
            <td class="r">${fmt(s.amount, d.currency, d.cur_decimals)} ${esc(d.currency)}</td>
            ${canEdit() ? `<td class="act"><button class="btn btn-ghost btn-sm" data-act="del-ship" data-id="${s.id}" type="button">✕</button></td>` : ''}
          </tr>`;
        }).join('')}
      </tbody>
    </table></div>`
    : '<div class="empty">No shipments recorded yet.</div>';

  view().innerHTML = `
    <div id="ship-root">
      <div class="page-head">
        <div>
          <h2>Shipments</h2>
          <p>Goods that arrived or went out. Upload the invoice and the order is matched for you — it settles to zero when every item is in, or shows how many are left.</p>
        </div>
        <div class="spacer"></div>
        <div class="table-tools">
          <input type="search" id="ship-q" placeholder="Search name, UID, order, receipt">
          ${canEdit() && waiting.length ? `<button class="btn btn-primary" data-act="ship-pick" type="button">
            <svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg> Record shipment</button>` : ''}
        </div>
      </div>

      <div class="card">
        <div class="card-head"><h3>Waiting for shipment</h3></div>
        <div class="card-body tight" id="ship-wait"></div>
      </div>

      <div class="card">
        <div class="card-head"><h3>Recorded shipments</h3></div>
        <div class="card-body tight" id="ship-done"></div>
      </div>
    </div>`;

  // The search matches the account name or UID, the order reference and the receipt number.
  const paintShip = () => {
    const q = $('#ship-q').value.trim().toLowerCase();
    const w = waiting.filter((d) => matchAny(q, [d.party, d.party_uid, d.reference, d.last_receipt]));
    const r = recorded.filter((s) => {
      const d = byId.get(s.deal_id);
      return matchAny(q, [d.party, d.party_uid, d.reference, s.receipt_id, s.carrier]);
    });
    $('#ship-wait').innerHTML = w.length ? `<div class="rows">${waitingRows(w)}</div>`
      : `<div class="empty">${waiting.length ? 'Nothing matches.' : 'Every order has its goods recorded.'}</div>`;
    $('#ship-done').innerHTML = recorded.length && !r.length
      ? '<div class="empty">Nothing matches.</div>' : recordedTable(r);
  };
  paintShip();
  $('#ship-q').addEventListener('input', paintShip);

  const reload = () => viewShipments();
  $('#ship-root').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-act]');
    if (!btn) return;
    const act = btn.dataset.act;

    if (act === 'open-ship-file') {
      e.preventDefault();
      try { window.open(await api.signedUrl(btn.dataset.path, 'shipments'), '_blank', 'noopener'); }
      catch (err) { toast(errText(err), 'err'); }
      return;
    }
    if (!canEdit()) return;

    try {
      const ctx = { waiting, itemsOf, shipsOf, done: reload };
      if (act === 'ship') return shipmentInvoiceDialog({ ...ctx, preselect: btn.dataset.id });
      if (act === 'ship-pick') return shipmentInvoiceDialog(ctx);
      if (act === 'del-ship') {
        const sh = recorded.find((x) => x.id === btn.dataset.id);
        if (!await confirmAction(
          'Delete this shipment? The order goes back to waiting for its goods.', 'Delete')) return;
        await api.deleteShipment(sh); toast('Shipment deleted', 'ok'); return reload();
      }
    } catch (err) { toast(errText(err), 'err'); }
  });
}

/* Record shipment: the dialog opens on the upload box and nothing else. Once a
 * file is in, the order it belongs to is worked out from the invoice number and
 * the item models, the arrived quantities are read from it, and the result is
 * shown before anything is saved — zero left, or how many items are still to come.
 */
function shipmentInvoiceDialog({ waiting, itemsOf, shipsOf, done, preselect }) {
  let file = null, lines = [], header = {}, deal = null, items = [], before = [], arrivals = [], how = '';
  const orderLabel = (d) =>
    `${d.party} (${d.party_uid}) · ${d.reference || dateLabel(d.deal_date)} · ${DIR[d.direction].label}`;

  const m = openModal({
    title: 'Record a shipment',
    width: '760px',
    body: `<div class="dropzone" id="sx-drop">
        <strong>Upload the invoice</strong>
        <small>PDF, Excel, CSV or a photo — or drag it here. The order is found for you.</small>
        <input type="file" id="sx-file" accept=".pdf,.xlsx,.xls,.csv,.png,.jpg,.jpeg,.webp" hidden>
      </div>
      <div id="sx-result"></div>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-accent" id="go" type="button" disabled>Save shipment</button>`,
  });
  const drop = $('#sx-drop', m), input = $('#sx-file', m), box = $('#sx-result', m), go = $('#go', m);

  const arrivedNow = () => $$('input[data-arrived]', m).map((i) => Number(i.value) || 0);

  const paintSummary = () => {
    const out = shipmentOutcome(deal, items, before, arrivedNow());
    $$('[data-left]', m).forEach((c, i) => {
      const l = Number(items[i].qty) - before[i] - out.takes[i];
      c.textContent = qty(Math.max(0, l));
      c.classList.toggle('dim', l <= 1e-9);
    });
    const dec = deal.cur_decimals;
    const sum = $('#sx-sum', m);
    if (!items.length) {
      sum.className = 'entry-row entry-total';
      sum.innerHTML = `<span>No item list on this order</span><b>Records the whole remaining ${money(out.amount, deal.currency, dec)}</b>`;
    } else if (out.left <= 1e-9) {
      sum.className = 'entry-row entry-total bal-even';
      sum.innerHTML = `<span>Every item has arrived</span><b>Order settles to zero</b>`;
    } else {
      sum.className = 'entry-row entry-total bal-owed';
      sum.innerHTML = `<span>Still to arrive</span><b>${qty(out.left)} item${out.left === 1 ? '' : 's'} left
        (${out.leftLines} line${out.leftLines === 1 ? '' : 's'})</b>`;
    }
    go.disabled = !(out.units > 0 || !items.length) || !(out.amount > 0);
    return out;
  };

  const paintOrder = () => {
    items = itemsOf(deal);
    before = receivedBefore(deal, items, shipsOf(deal));
    arrivals = readArrivals(lines, items);
    const rows = items.map((it, i) => {
      const room = Number(it.qty) - before[i];
      const a = arrivals[i];
      const val = a.found ? Math.min(a.qty, room) : 0;
      return `<tr>
        <td>${esc(it.model || it.description || '—')}${a.guessed
          ? ' <span class="dim" title="Listed on the invoice but no quantity could be read — check it.">· check qty</span>' : ''}</td>
        <td class="r">${qty(it.qty)}</td>
        <td class="r">${qty(before[i])}</td>
        <td class="r"><input data-arrived type="number" min="0" max="${room}" step="any" value="${qty(val)}"
            style="width:5.5rem;text-align:right" ${room <= 1e-9 ? 'disabled' : ''}></td>
        <td class="r"><b data-left>0</b></td>
      </tr>`;
    }).join('');

    $('#sx-items', m).innerHTML = items.length ? `
      <div class="table-scroll"><table class="data">
        <thead><tr><th>Item</th><th class="r">Ordered</th><th class="r">Already in</th>
          <th class="r">Arrived now</th><th class="r">Left</th></tr></thead>
        <tbody>${rows}</tbody>
      </table></div>` : '';
    $$('input[data-arrived]', m).forEach((i) => i.addEventListener('input', paintSummary));
    paintSummary();
  };

  const paintAll = () => {
    const ranked = rankOrders(lines, header, waiting, itemsOf);
    const best = waiting.find((d) => d.id === preselect) || ranked[0]?.deal || waiting[0];
    deal = best;
    const first = ranked[0];
    const from = header.supplier
      ? ` Supplier on the invoice: ${header.supplier}${header.supplierNo ? ` (${header.supplierNo})` : ''}.`
      : '';
    how = !waiting.length ? '' : preselect ? 'Order chosen from the list.'
      : !first ? `Could not tell which order this is — pick it below.${from}`
      : first.score >= 100 ? `Matched by invoice number.${from}`
      : first.hits ? `Matched by items (${first.hits} of ${first.total} found on the invoice).${from}`
      : `Matched by supplier only — check the items below.${from}`;
    const tie = !preselect && ranked.length > 1 && ranked[1].score >= ranked[0].score * 0.9;
    const order = [...new Set([deal, ...ranked.map((r) => r.deal), ...waiting])];
    box.innerHTML = `
      <div class="grid-form" style="margin-top:1rem">
        <label class="field wide"><span>Order</span>
          <select id="sx-order">${order.map((d) => `<option value="${d.id}" ${d.id === deal.id ? 'selected' : ''}>${esc(orderLabel(d))}</option>`).join('')}</select>
          <small class="${first || preselect ? '' : 'dim'}">${esc(how)}${tie ? ' Two orders look alike — check this is the right one.' : ''}</small>
        </label>
        <label class="field"><span>Receipt / invoice no</span>
          <input name="receipt_id" value="${esc(header.invoiceNo || '')}" autocapitalize="characters" spellcheck="false"></label>
        <label class="field"><span>Date</span>
          <input name="shipped_on" type="date" value="${esc(header.invoiceDate || todayISO())}"></label>
      </div>
      <div class="entry-preview" style="margin-top:.75rem"><div id="sx-sum" class="entry-row"></div></div>
      <div id="sx-items" style="margin-top:.75rem"></div>`;
    $('#sx-order', m).addEventListener('change', (e) => {
      deal = waiting.find((d) => d.id === e.target.value);
      paintOrder();
    });
    paintOrder();
  };

  const handle = async (f) => {
    if (!f) return;
    file = f;
    drop.innerHTML = `<strong>${esc(f.name)}</strong><small>Reading the invoice…</small>`;
    try { lines = await readFileLines(f); } catch (e) { lines = []; toast(errText(e), 'err'); }
    header = lines.length ? extractFromLines(lines) : {};
    if (/\.(xlsx|xls|csv)$/i.test(f.name)) {
      try {
        const cols = await sheetHeaderInfo(f);
        if (cols.invoice_no) header.invoiceNo = cols.invoice_no;
        if (cols.party_name) header.supplier = cols.party_name;
        if (cols.party_no) header.supplierNo = cols.party_no;
      } catch { /* keep whatever reading it as text gave */ }
    }
    drop.innerHTML = `<strong>${esc(f.name)}</strong>
      <small>${(f.size / 1024).toFixed(0)} KB — click to choose a different file</small>`;
    if (!waiting.length) { box.innerHTML = '<div class="empty">No order is waiting for goods.</div>'; return; }
    paintAll();
  };

  drop.addEventListener('click', () => input.click());
  input.addEventListener('change', (e) => handle(e.target.files[0]));
  drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('is-over'); });
  drop.addEventListener('dragleave', () => drop.classList.remove('is-over'));
  drop.addEventListener('drop', (e) => {
    e.preventDefault(); drop.classList.remove('is-over');
    handle(e.dataTransfer.files[0]);
  });

  go.onclick = async () => {
    if (!deal || !file) return;
    const out = paintSummary();
    if (!(out.amount > 0)) return toast('Nothing arrived to record.', 'err');
    go.disabled = true;
    try {
      const filePath = await api.uploadShipmentFile(deal.id, file);
      await api.addShipment({
        deal_id: deal.id,
        receipt_id: String($('[name=receipt_id]', m).value || '').trim(),
        shipped_on: $('[name=shipped_on]', m).value || todayISO(),
        amount: out.amount,
        carrier: '',
        note: '',
        file_path: filePath,
        file_name: file.name,
        file_size: file.size,
        items: items.map((it, i) => ({ key: itemKey(it), model: it.model || it.description || '', qty: out.takes[i] }))
          .filter((x) => x.qty > 0),
      });
      closeModal();
      toast(out.left > 1e-9 ? `Shipment recorded — ${qty(out.left)} item${out.left === 1 ? '' : 's'} left`
        : 'Shipment recorded — order settled to zero', 'ok');
      done();
    } catch (e) {
      toast(errText(e), 'err');
      go.disabled = false;
    }
  };
}

/* ------------------------------- overview ------------------------------ */

/* Every order on one screen. Click a row, type the receipt number and the
 * price, and the shipment is recorded without opening the order first.
 */
async function viewOverview() {
  setLoading();
  const [deals, invoices] = await Promise.all([api.deals({ limit: 500 }), api.invoices()]);
  const byId = new Map(deals.map((d) => [d.id, d]));
  const latestInv = new Map();
  for (const iv of invoices) if (!latestInv.has(iv.deal_id)) latestInv.set(iv.deal_id, iv);

  // Money paid out (or in) ahead of the goods, per currency.
  const held = new Map();
  for (const d of deals) {
    const b = Number(d.balance);
    if (b <= 0) continue;
    const h = held.get(d.currency) || { sum: 0, n: 0, dec: d.cur_decimals };
    h.sum += b; h.n += 1;
    held.set(d.currency, h);
  }
  const tiles = [...held].map(([cur, h]) => `
    <div class="tile tile-out">
      <div class="tile-top"><span class="tile-dot"></span>Paid, goods not in · ${esc(cur)}</div>
      <div class="tile-val bal-owed">${signed(h.sum, cur, h.dec)}<span class="tile-cur">${esc(cur)}</span></div>
      <div class="tile-sub"><span><b>${h.n}</b> order${h.n === 1 ? '' : 's'} waiting</span>${fxApprox(h.sum, cur) ? `<span>${fxApprox(h.sum, cur)}</span>` : ''}</div>
    </div>`).join('');

  view().innerHTML = `
    <div id="ov-root">
      <div class="page-head">
        <div>
          <h2>Overview</h2>
          <p>All your orders in one place. ${canEdit()
            ? 'Click an order to enter its receipt number and price.' : 'Click an order to open it.'}</p>
        </div>
      </div>
      ${tiles ? `<div class="tiles ov-tiles">${tiles}</div>` : ''}
      <div class="card">
        <div class="card-head">
          <h3>Top suppliers</h3>
          <div class="spacer"></div>
          <select id="rank-by">
            <option value="volume">Most purchased</option>
            <option value="delivery">Best delivery rate</option>
          </select>
        </div>
        <div class="card-body tight" id="rank-rows"></div>
      </div>
      <div class="card">
        <div class="card-head">
          <h3>Orders</h3>
          <div class="spacer"></div>
          <div class="table-tools">
            <input type="search" id="ov-q" placeholder="Search name, UID, order, receipt">
            <select id="ov-f">
              <option value="all">Show all</option>
              <option value="wait">Waiting for goods</option>
              <option value="done">Goods recorded</option>
            </select>
          </div>
        </div>
        <div class="card-body tight" id="ov-rows"></div>
      </div>
    </div>`;

  // Suppliers only: how much was bought from each, and how much of it has arrived.
  const suppliers = new Map();
  for (const d of deals) {
    if (d.direction !== 'sending') continue;
    const key = `${d.party_id}|${d.currency}`;
    const r = suppliers.get(key) || { id: d.party_id, name: d.party, uid: d.party_uid, cur: d.currency,
      dec: d.cur_decimals, orders: 0, billed: 0, goods: 0, held: 0 };
    const bill = Number(d.bill_total);
    r.orders += 1; r.billed += bill;
    r.goods += Math.min(bill, Number(d.goods_value));
    r.held += Math.max(0, Number(d.balance));
    suppliers.set(key, r);
  }
  const paintRank = () => {
    const by = $('#rank-by').value;
    const list = [...suppliers.values()].filter((r) => r.billed > 0)
      .map((r) => ({ ...r, rate: r.goods / r.billed }))
      .sort((a, b) => by === 'delivery' ? (b.rate - a.rate) || (b.billed - a.billed) : b.billed - a.billed)
      .slice(0, 5);
    $('#rank-rows').innerHTML = list.length ? `
      <div class="table-scroll"><table class="data">
        <thead><tr><th>#</th><th>Supplier</th><th class="r">Purchased</th><th class="r">Orders</th>
          <th class="r">Delivered</th><th class="r">Paid, goods not in</th></tr></thead>
        <tbody>${list.map((r, i) => `<tr>
          <td>${i === 0 ? '<span class="plus-chip">★ 1</span>' : i + 1}</td>
          <td><a href="#/party/${r.id}">${esc(r.name)}</a> <span class="uid-chip">${esc(r.uid)}</span></td>
          <td class="r">${fmt(r.billed, r.cur, r.dec)} ${esc(r.cur)}</td>
          <td class="r">${r.orders}</td>
          <td class="r">${fmt(r.rate * 100, null, 1)}%</td>
          <td class="r">${r.held > 0 ? balHtml(r.held, r.cur, r.dec) : '0'}</td>
        </tr>`).join('')}</tbody>
      </table></div>`
      : '<div class="empty">No purchases yet.</div>';
  };

  const paint = () => {
    const q = $('#ov-q').value.trim().toLowerCase();
    const f = $('#ov-f').value;
    const shown = deals.filter((d) => {
      const waiting = Number(d.bill_total) > 0 && Number(d.goods_value) < Number(d.bill_total);
      if (f === 'wait' && !waiting) return false;
      if (f === 'done' && waiting) return false;
      if (!q) return true;
      return [d.party, d.party_uid, d.reference, d.last_receipt, latestInv.get(d.id)?.invoice_no]
        .some((v) => String(v || '').toLowerCase().includes(q));
    });
    $('#ov-rows').innerHTML = shown.length ? `
      <div class="table-scroll"><table class="data">
        <thead><tr>
          <th>Account</th><th>Order</th><th>Type</th>
          <th class="r">Bill</th><th class="r">Paid</th><th class="r">To pay</th><th class="r">Left</th><th class="r">Account</th><th>Receipt</th><th>Invoice</th>${canEdit() ? '<th></th>' : ''}
        </tr></thead>
        <tbody>
          ${shown.map((d) => `<tr class="row-click" data-id="${d.id}">
            <td>${esc(d.party)} <span class="uid-chip">${esc(d.party_uid)}</span></td>
            <td><a href="#/deal/${d.id}">${esc(d.reference || 'open')}</a></td>
            <td>${DIR[d.direction].label}</td>
            <td class="r">${fmt(d.bill_total, d.currency, d.cur_decimals)}</td>
            <td class="r">${fmt(d.paid, d.currency, d.cur_decimals)}</td>
            <td class="r">${Number(d.amount_left) > 0
              ? `<span class="to-pay-inline">${fmt(d.amount_left, d.currency, d.cur_decimals)}</span>`
              : `<span class="dim">${fmt(d.amount_left, d.currency, d.cur_decimals)}</span>`}</td>
            <td class="r">${leftHtml(goodsLeft(d), d.currency, d.cur_decimals)}</td>
            <td class="r">${balHtml(d.balance, d.currency, d.cur_decimals)}</td>
            <td class="sku">${esc(d.last_receipt || '—')}</td>
            <td>${(() => {
              const iv = latestInv.get(d.id);
              if (!iv) return '<span class="dim">—</span>';
              const label = esc(iv.invoice_no || iv.file_name || 'View');
              return iv.file_path ? `<a href="#" data-file="${esc(iv.file_path)}" title="Open the uploaded invoice">${label}</a>` : `${label} <span class="dim">(no file)</span>`;
            })()}</td>
            ${canEdit() ? `<td class="act"><button class="btn btn-sm" data-inv="${d.id}" type="button">Upload invoice</button></td>` : ''}
          </tr>`).join('')}
        </tbody>
      </table></div>`
      : '<div class="empty">Nothing matches.</div>';
  };
  paint();
  paintRank();
  $('#rank-by').addEventListener('change', paintRank);
  $('#ov-q').addEventListener('input', paint);
  $('#ov-f').addEventListener('change', paint);

  $('#ov-root').addEventListener('click', async (e) => {
    const fl = e.target.closest('[data-file]');
    if (fl) {
      e.preventDefault();
      try { window.open(await api.signedUrl(fl.dataset.file), '_blank', 'noopener'); }
      catch (err) { toast(errText(err), 'err'); }
      return;
    }
    if (e.target.closest('a')) return;
    const inv = e.target.closest('[data-inv]');
    if (inv) return invoiceDialog(byId.get(inv.dataset.inv), () => viewOverview());
    const row = e.target.closest('tr[data-id]');
    if (!row) return;
    const d = byId.get(row.dataset.id);
    if (!canEdit()) { location.hash = `#/deal/${d.id}`; return; }
    shipmentDialog(d, () => viewOverview());
  });
}

/* --------------------------------- stock -------------------------------- */

/* Worked out from the orders: what purchases brought in (as each order's
 * goods are recorded) less what sales delivered, matched on model / SKU.
 */
async function viewStock() {
  setLoading();
  const rows = (await api.stock()).map((r) => {
    const received = Number(r.received), delivered = Number(r.delivered);
    return {
      ...r,
      ordered: Number(r.ordered), received, sold: Number(r.sold), delivered,
      onHand: received - delivered,
      incoming: Number(r.ordered) - received,
    };
  });
  const n = (v) => qty(Math.round(v * 100) / 100);

  const units = rows.reduce((a, r) => a + Math.max(0, r.onHand), 0);
  const incoming = rows.reduce((a, r) => a + Math.max(0, r.incoming), 0);

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>Stock</h2>
        <p>What has come in on your purchase orders, less what you have delivered on sales.
          Items are matched on Model (SKU).</p>
      </div>
    </div>
    <div class="tiles ov-tiles">
      <div class="tile tile-in"><div class="tile-top"><span class="tile-dot"></span>On hand</div>
        <div class="tile-val">${n(units)}<span class="tile-cur">units</span></div>
        <div class="tile-sub"><span><b>${rows.filter((r) => r.onHand > 0).length}</b> items in stock</span></div></div>
      <div class="tile tile-out"><div class="tile-top"><span class="tile-dot"></span>Incoming</div>
        <div class="tile-val">${n(incoming)}<span class="tile-cur">units ordered, not received</span></div>
        <div class="tile-sub"><span><b>${rows.filter((r) => r.incoming > 0).length}</b> items on the way</span></div></div>
    </div>
    <div class="card">
      <div class="card-head">
        <h3>Items</h3>
        <div class="spacer"></div>
        <div class="table-tools">
          <input type="search" id="st-q" placeholder="Search model, brand, supplier UID">
          <select id="st-f">
            <option value="all">Show all</option>
            <option value="in">In stock</option>
            <option value="incoming">Incoming</option>
          </select>
        </div>
      </div>
      <div class="card-body tight" id="st-rows"></div>
    </div>`;

  const paint = () => {
    const q = $('#st-q').value.trim().toLowerCase();
    const f = $('#st-f').value;
    const shown = rows.filter((r) => {
      if (f === 'in' && !(r.onHand > 0)) return false;
      if (f === 'incoming' && !(r.incoming > 0)) return false;
      return matchAny(q, [r.sku, r.brand, r.description, r.party_uids, r.party_names]);
    });
    $('#st-rows').innerHTML = shown.length ? `
      <div class="table-scroll"><table class="data">
        <thead><tr>
          <th>Model (SKU)</th><th>Brand</th><th>Description</th><th>Accounts</th>
          <th class="r">Ordered</th><th class="r">Received</th><th class="r">Delivered</th>
          <th class="r">On hand</th><th class="r">Incoming</th>
        </tr></thead>
        <tbody>
          ${shown.map((r) => `<tr>
            <td class="sku">${esc(r.sku)}</td>
            <td>${esc(r.brand || '')}</td>
            <td class="desc">${esc(r.description || '')}</td>
            <td>${String(r.party_uids || '').split(',').filter(Boolean)
              .map((u) => `<span class="uid-chip">${esc(u)}</span>`).join(' ')}</td>
            <td class="r">${n(r.ordered)}</td>
            <td class="r">${n(r.received)}</td>
            <td class="r">${n(r.delivered)}</td>
            <td class="r ${r.onHand < 0 ? 'stock-low' : r.onHand > 0 ? 'stock-ok' : ''}">${n(r.onHand)}</td>
            <td class="r">${r.incoming > 0 ? `<span class="plus-chip">+${n(r.incoming)}</span>` : '0'}</td>
          </tr>`).join('')}
        </tbody>
      </table></div>`
      : `<div class="empty">${rows.length ? 'Nothing matches.' : 'No items yet. Add items to a purchase order and they appear here.'}</div>`;
  };
  paint();
  $('#st-q').addEventListener('input', paint);
  $('#st-f').addEventListener('change', paint);
}

/* ------------------------------- accounts ------------------------------ */

const KIND_TEXT = { supplier: 'Supplier', customer: 'Customer', both: 'Both' };

async function viewAccounts() {
  setLoading();
  const { parties, totals } = await api.parties();

  // One party can run balances in more than one currency, so the rows are
  // grouped by account and each currency listed under it.
  const byParty = new Map();
  for (const t of totals) {
    if (!byParty.has(t.party_id)) byParty.set(t.party_id, []);
    byParty.get(t.party_id).push(t);
  }

  // An account only shows while it has a live order. Ones whose every order
  // was deleted (the sample data) stay in the database but out of this list.
  const rowsFor = (q) => parties.filter((p) => byParty.has(p.id)
      && matchAny(q, [p.uid, p.name, p.kind, p.supplier_no, p.details])).map((p) => {
    const lines = byParty.get(p.id) || [];
    const owed = lines.filter((l) => Number(l.balance) !== 0);
    return `
      <a class="row-acct" href="#/party/${p.id}">
        <span class="uid-chip">${esc(p.uid)}</span>
        <div class="row-party">
          <strong>${esc(p.name)}</strong>
          <div class="row-meta">
            <span>${esc(KIND_TEXT[p.kind] || p.kind)}</span>
            ${p.supplier_no ? `<span class="sku">${esc(p.supplier_no)}</span>` : ''}
            <span>${lines.reduce((a, l) => a + Number(l.deal_count), 0)} order${
              lines.reduce((a, l) => a + Number(l.deal_count), 0) === 1 ? '' : 's'}</span>
          </div>
        </div>
        <div class="acct-bals">
          ${lines.length
            ? lines.map((l) => `<span class="pill pill-bal bal-${BALANCE[l.balance_state].cls}">
                ${signed(l.balance, l.currency, l.cur_decimals)} ${esc(l.currency)}
                <em>${l.balance_state === 'even' ? 'even'
                     : l.balance_state === 'party_owes' ? 'owes you' : 'you owe'}</em>
              </span>`).join('')
            : '<span class="dim">no orders yet</span>'}
        </div>
      </a>`;
  }).join('');

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>Accounts</h2>
        <p>Every customer and supplier, each with its own id. An account is even when the
          money that moved and the goods that moved match.</p>
      </div>
      <div class="spacer"></div>
      <div class="table-tools">
        <input type="search" id="acct-q" placeholder="Search name or UID, e.g. GU8151">
      </div>
    </div>

    <div class="card"><div class="card-body tight" id="acct-rows"></div></div>`;

  const paintAccts = () => {
    const q = $('#acct-q').value.trim().toLowerCase();
    const rows = rowsFor(q);
    $('#acct-rows').innerHTML = rows ? `<div class="rows">${rows}</div>`
      : `<div class="empty">${q ? 'No account matches that name or UID.'
          : 'No accounts yet. They open themselves as you add orders.'}</div>`;
  };
  paintAccts();
  $('#acct-q').addEventListener('input', paintAccts);
}

async function viewParty(id) {
  setLoading();
  const { party: p, totals, deals, entries } = await api.party(id);
  if (!p) {
    view().innerHTML = '<div class="card"><div class="empty">That account does not exist, or you do not have access to it.</div></div>';
    return;
  }

  // The statement is one table per currency, since balances never mix.
  const currencies = [...new Set(entries.map((e) => e.currency))];

  const statement = currencies.map((cur) => {
    const rows = entries.filter((e) => e.currency === cur);
    const dec = rows[0]?.cur_decimals ?? decOf(cur);
    const last = rows[rows.length - 1];
    const bal = Number(last?.balance ?? 0);
    const state = bal === 0 ? 'even' : bal > 0 ? 'party_owes' : 'you_owe';
    return `
      <div class="card">
        <div class="card-head">
          <h3>Statement <span class="dim" style="font-weight:500">· ${esc(cur)}</span></h3>
          <div class="spacer"></div>
          <span class="pill pill-bal bal-${BALANCE[state].cls}">
            ${signed(bal, cur, dec)} ${esc(cur)}
            <em>${state === 'even' ? 'even' : state === 'party_owes' ? 'owes you' : 'you owe'}</em>
          </span>
        </div>
        <div class="card-body tight">
          <div class="table-scroll"><table class="data">
            <thead><tr>
              <th>Date</th><th>Entry</th><th>Receipt / ref</th><th>Order</th>
              <th class="r">Debit</th><th class="r">Credit</th><th class="r">Balance</th>
            </tr></thead>
            <tbody>
              ${rows.map((e) => {
                const b = Number(e.balance);
                return `<tr>
                  <td>${esc(dateLabel(e.entry_date))}</td>
                  <td>${esc(e.label)}${e.kind === 'shipment'
                    ? ' <span class="tag tag-ship">Goods</span>' : ''}</td>
                  <td class="sku">${esc(e.ref || '—')}</td>
                  <td><a href="#/deal/${e.deal_id}">${esc(e.reference || 'open')}</a></td>
                  <td class="r">${Number(e.party_debit) ? fmt(e.party_debit, cur, dec) : ''}</td>
                  <td class="r">${Number(e.party_credit) ? fmt(e.party_credit, cur, dec) : ''}</td>
                  <td class="r bal-${b === 0 ? 'even' : b > 0 ? 'owed' : 'owing'}">
                    ${fmt(Math.abs(b), cur, dec)}${b === 0 ? '' : b > 0 ? ' Dr' : ' Cr'}
                  </td>
                </tr>`;
              }).join('')}
            </tbody>
          </table></div>
          <p class="preview-note ${state === 'even' ? 'note-even' : ''}" style="padding-bottom:12px;margin:0">
            ${state === 'even'
              ? 'Even — the money and the goods match, nothing owed either way.'
              : esc(balanceLine(state, bal, cur, dec,
                  p.kind === 'customer' ? 'Customer' : 'Supplier'))}
          </p>
        </div>
      </div>`;
  }).join('');

  view().innerHTML = `
    <div class="page-head">
      <div>
        <div class="row-meta" style="margin-bottom:4px">
          <a href="#/accounts">Accounts</a>
          <span>·</span>
          <span>${esc(KIND_TEXT[p.kind] || p.kind)}</span>
        </div>
        <h2>${esc(p.name)} <span class="uid-chip is-big">${esc(p.uid)}</span></h2>
        ${p.supplier_no ? `<p class="row-meta"><span>${
          esc(KIND_TEXT[p.kind] === 'Customer' ? 'Customer no' : 'Supplier no')}</span>
          <strong class="sku">${esc(p.supplier_no)}</strong></p>` : ''}
        ${p.details ? `<p class="party-details">${esc(p.details)}</p>` : ''}
        ${p.notes ? `<p>${esc(p.notes)}</p>` : ''}
      </div>
      <div class="spacer"></div>
      ${canEdit() ? '<button class="btn" data-act="edit-party" type="button">Edit details</button>' : ''}
    </div>

    ${totals.length ? `<div class="tiles">${totals.map((t) => `
      <div class="tile tile-${DIR[t.direction].cls}">
        <div class="tile-top"><span class="tile-dot"></span>${DIR[t.direction].label} · ${esc(t.currency)}</div>
        <div class="tile-val bal-${BALANCE[t.balance_state].cls}">
          ${signed(t.balance, t.currency, t.cur_decimals)}
          <span class="tile-cur">${esc(t.currency)} ${
            t.balance_state === 'even' ? 'even' : t.balance_state === 'party_owes' ? 'owes you' : 'you owe'}</span>
        </div>
        <div class="tile-sub">
          <span>Billed <b>${fmt(t.bill, t.currency, t.cur_decimals)}</b></span>
          <span>Paid <b>${fmt(t.paid, t.currency, t.cur_decimals)}</b></span>
          <span>Shipped <b>${fmt(t.goods, t.currency, t.cur_decimals)}</b></span>
        </div>
      </div>`).join('')}</div>` : ''}

    ${statement || `<div class="card"><div class="empty">
      Nothing has moved on this account yet — no payments and no shipments.
    </div></div>`}

    <div class="card">
      <div class="card-head"><h3>Orders</h3></div>
      <div class="card-body tight">
        ${rowsBlock(deals, 'No orders on this account yet.')}
      </div>
    </div>`;

  // An invoice never overwrites a detail already on file, so this is where a
  // number or an address that came in wrong gets put right.
  $('[data-act=edit-party]')?.addEventListener('click', () => partyDialog(p, () => viewParty(id)));
}

function partyDialog(p, done) {
  const word = p.kind === 'customer' ? 'Customer' : 'Supplier';
  const m = openModal({
    title: `Edit ${p.name}`,
    width: '620px',
    body: `<form id="f" class="grid-form">
      <label class="field wide"><span>Name</span>
        <input name="name" value="${esc(p.name)}" required></label>
      <label class="field"><span>${word} number <em>(their code)</em></span>
        <input name="supplier_no" value="${esc(p.supplier_no || '')}"
          placeholder="e.g. SUP-0012" autocapitalize="characters" spellcheck="false"></label>
      <label class="field"><span>Kind</span>
        <select name="kind">${['supplier', 'customer', 'both'].map((k) =>
          `<option value="${k}"${k === p.kind ? ' selected' : ''}>${KIND_TEXT[k]}</option>`).join('')}</select></label>
      <label class="field wide"><span>${word} details <em>(their phone, address, email — not yours)</em></span>
        <textarea name="details" rows="3" placeholder="+965 0000 0000 | Street, City | sales@example.com">${esc(p.details || '')}</textarea></label>
      <label class="field wide"><span>Notes</span>
        <textarea name="notes" rows="2">${esc(p.notes || '')}</textarea></label>
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-primary" id="go" type="button">Save changes</button>`,
  });

  $('#go', m).onclick = async () => {
    const f = new FormData($('#f', m));
    const name = String(f.get('name') || '').trim();
    if (!name) return toast('An account needs a name.', 'err');
    try {
      await api.updateParty(p.id, {
        name,
        kind: f.get('kind'),
        supplier_no: String(f.get('supplier_no') || '').trim() || null,
        details: String(f.get('details') || '').trim() || null,
        notes: String(f.get('notes') || '').trim() || null,
      });
      closeModal(); toast('Saved', 'ok'); done();
    } catch (e) { toast(errText(e), 'err'); }
  };
}

/* ------------------------------ users admin ---------------------------- */

const PERMS = [
  ['can_view_receiving', 'See Receiving'],
  ['can_view_sending', 'See Sending'],
  ['can_edit', 'Add &amp; change records'],
  ['can_manage_users', 'Manage users'],
];

async function viewUsers() {
  if (!state.profile?.can_manage_users) return viewDenied();
  setLoading();
  const { users } = await callUsersFn({ action: 'list' });

  view().innerHTML = `
    <div class="page-head">
      <div>
        <h2>Users</h2>
        <p>Who can sign in, and what each person is allowed to see and change.</p>
      </div>
      <div class="spacer"></div>
      <button class="btn btn-primary" id="add-user" type="button">
        <svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg> Add user
      </button>
    </div>

    <div class="card"><div class="card-body tight"><div class="table-scroll">
      <table class="data">
        <thead><tr>
          <th>Username</th><th>Name</th><th>Role</th>
          ${PERMS.map(([, label]) => `<th style="text-align:center">${label}</th>`).join('')}
          <th></th>
        </tr></thead>
        <tbody>
          ${users.map((u) => `<tr data-user="${u.id}">
            <td><strong>${esc(u.username)}</strong>${u.id === state.profile.id ? ' <span class="tag">you</span>' : ''}</td>
            <td class="desc">${esc(u.display_name || '')}</td>
            <td>${u.role === 'owner' ? '<span class="tag">Owner</span>' : '<span class="dim">Staff</span>'}</td>
            ${PERMS.map(([key]) => `<td style="text-align:center">
              <input type="checkbox" data-perm="${key}" ${u[key] ? 'checked' : ''}
                     ${u.role === 'owner' ? 'disabled title="The owner keeps full access"' : ''}>
            </td>`).join('')}
            <td class="act">
              ${u.role === 'owner' ? '' : '<button class="btn btn-ghost btn-sm" data-u-act="save" type="button">Save</button>'}
              <button class="btn btn-ghost btn-sm" data-u-act="pw" type="button">Password</button>
              ${u.role === 'owner' || u.id === state.profile.id ? '' : '<button class="btn btn-ghost btn-sm btn-danger" data-u-act="del" type="button">Delete</button>'}
            </td>
          </tr>`).join('')}
        </tbody>
      </table>
    </div></div></div>

    <div class="card"><div class="card-body">
      <p class="preview-note" style="margin:0">
        <b>Receiving</b> is what you sold and what customers still owe. <b>Sending</b> is what you
        bought and what you still owe suppliers. Someone with neither box ticked sees no records at all.
        Without <b>Add &amp; change records</b> a user can look but not alter anything.
      </p>
    </div></div>`;

  $('#add-user').onclick = () => userDialog(viewUsers);

  view().addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-u-act]');
    if (!btn) return;
    const tr = btn.closest('[data-user]');
    const id = tr.dataset.user;
    const username = tr.querySelector('strong').textContent;

    try {
      if (btn.dataset.uAct === 'save') {
        const permissions = {};
        for (const cb of tr.querySelectorAll('[data-perm]')) permissions[cb.dataset.perm] = cb.checked;
        await callUsersFn({ action: 'update', id, permissions });
        toast(`Permissions saved for ${username}`, 'ok');
        if (id === state.profile.id) await loadProfile();
        return;
      }
      if (btn.dataset.uAct === 'pw') return passwordDialog(id, username);
      if (btn.dataset.uAct === 'del') {
        if (!await confirmAction(`Delete the login "${username}"? Their records stay, but they can no longer sign in.`, 'Delete user')) return;
        await callUsersFn({ action: 'delete', id });
        toast('User deleted', 'ok');
        return viewUsers();
      }
    } catch (err) {
      toast(errText(err), 'err');
    }
  });
}

function userDialog(done) {
  const m = openModal({
    title: 'Add a user',
    width: '560px',
    body: `<form id="f" class="grid-form">
      <label class="field"><span>Username</span>
        <input name="username" required autocapitalize="none" spellcheck="false" placeholder="lowercase, numbers, . _ -"></label>
      <label class="field"><span>Display name <em>(optional)</em></span><input name="display_name"></label>
      <label class="field wide"><span>Password <em>(8 characters or more)</em></span>
        <input name="password" type="password" required minlength="8" autocomplete="new-password"></label>
      <div class="wide" style="display:grid;gap:9px">
        ${PERMS.map(([key, label]) => `<label class="check">
          <input type="checkbox" data-perm="${key}" ${key.startsWith('can_view') ? 'checked' : ''}> ${label}
        </label>`).join('')}
      </div>
      <p class="preview-note wide" style="margin:0">
        Tell the person their password yourself — it is stored hashed and cannot be shown again.
      </p>
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-primary" id="go" type="button">Create user</button>`,
  });

  $('#go', m).onclick = async () => {
    const form = $('#f', m);
    if (!form.reportValidity()) return;
    const f = new FormData(form);
    const permissions = { display_name: String(f.get('display_name') || '').trim() };
    for (const cb of form.querySelectorAll('[data-perm]')) permissions[cb.dataset.perm] = cb.checked;
    const go = $('#go', m);
    go.disabled = true;
    try {
      await callUsersFn({
        action: 'create',
        username: String(f.get('username')).trim().toLowerCase(),
        password: String(f.get('password')),
        permissions,
      });
      closeModal(); toast('User created', 'ok'); done();
    } catch (e) { toast(errText(e), 'err'); go.disabled = false; }
  };
}

function passwordDialog(id, username) {
  const m = openModal({
    title: `New password for ${username}`,
    width: '460px',
    body: `<form id="f" style="display:grid;gap:13px">
      <label class="field"><span>New password <em>(8 characters or more)</em></span>
        <input name="password" type="password" required minlength="8" autocomplete="new-password" autofocus></label>
      <label class="field"><span>Repeat password</span>
        <input name="password2" type="password" required minlength="8" autocomplete="new-password"></label>
    </form>`,
    foot: `<button class="btn" data-close type="button">Cancel</button>
           <button class="btn btn-primary" id="go" type="button">Set password</button>`,
  });

  $('#go', m).onclick = async () => {
    const form = $('#f', m);
    if (!form.reportValidity()) return;
    const f = new FormData(form);
    if (f.get('password') !== f.get('password2')) return toast('The two passwords do not match.', 'err');
    try {
      await callUsersFn({ action: 'set_password', id, password: String(f.get('password')) });
      closeModal(); toast(`Password changed for ${username}`, 'ok');
    } catch (e) { toast(errText(e), 'err'); }
  };
}

/* ------------------------- search type-ahead --------------------------- */

const SUGGEST_KIND = {
  uid: 'Account UID',
  receipt: 'Receipt no',
  party: 'Name',
  reference: 'Quote / purchase no',
  invoice: 'Invoice no',
  item: 'Item',
};

let suggestItems = [];
let suggestAt = -1;

function closeSuggest() {
  const box = $('#suggest');
  if (box) { box.hidden = true; box.innerHTML = ''; }
  suggestItems = [];
  suggestAt = -1;
}

function paintSuggest() {
  const box = $('#suggest');
  box.innerHTML = suggestItems.map((s, i) => `
    <button class="suggest-row${i === suggestAt ? ' is-on' : ''}" type="button" data-i="${i}">
      <span class="suggest-kind">${esc(SUGGEST_KIND[s.kind] || s.kind)}</span>
      <span class="suggest-label">${esc(s.label)}</span>
      <span class="suggest-sub">${esc(s.sub || '')}</span>
    </button>`).join('');
  box.hidden = !suggestItems.length;
}

function takeSuggest(i) {
  const s = suggestItems[i];
  if (!s) return;
  closeSuggest();
  $('#search-input').value = '';
  location.hash = `#/deal/${s.deal_id}`;
}

function wireSuggest() {
  const input = $('#search-input');
  const box = $('#suggest');
  let timer = null;
  let seq = 0;

  input.addEventListener('input', () => {
    clearTimeout(timer);
    const term = input.value.trim();
    if (term.length < 2) return closeSuggest();
    // Debounced so typing does not fire a query per keystroke.
    timer = setTimeout(async () => {
      const mine = ++seq;
      try {
        const rows = await api.suggest(term);
        if (mine !== seq) return;           // a later keystroke already won
        suggestItems = rows;
        suggestAt = -1;
        paintSuggest();
      } catch { closeSuggest(); }
    }, 180);
  });

  input.addEventListener('keydown', (e) => {
    if (box.hidden || !suggestItems.length) return;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      suggestAt = e.key === 'ArrowDown'
        ? (suggestAt + 1) % suggestItems.length
        : (suggestAt - 1 + suggestItems.length) % suggestItems.length;
      paintSuggest();
    } else if (e.key === 'Enter' && suggestAt >= 0) {
      e.preventDefault();
      takeSuggest(suggestAt);
    } else if (e.key === 'Escape') {
      closeSuggest();
    }
  });

  box.addEventListener('mousedown', (e) => {
    const row = e.target.closest('[data-i]');
    if (row) { e.preventDefault(); takeSuggest(Number(row.dataset.i)); }
  });

  input.addEventListener('blur', () => setTimeout(closeSuggest, 120));
  document.addEventListener('click', (e) => {
    if (!e.target.closest('.search')) closeSuggest();
  });
}

/* ------------------------------- converter ------------------------------ */

function paintFxChip() {
  const chip = $('#fx-chip');
  if (!chip) return;
  const k = fx.rates?.KWD;
  chip.classList.toggle('is-stale', !fx.live);
  chip.innerHTML = k
    ? `<i class="fx-dot"></i>1 USD = <b>${k.toFixed(4)}</b> KWD`
    : '<i class="fx-dot"></i>Rates unavailable';
  chip.title = k
    ? (fx.live ? 'Live rate. Click to convert.' : 'Could not reach the rate feed — showing the last rate seen. Click to convert.')
    : 'Could not load exchange rates';
}

function fxDialog() {
  const opts = (sel) => [...new Set(['USD', 'KWD', ...CURRENCIES])]
    .map((c) => `<option value="${c}"${c === sel ? ' selected' : ''}>${c}</option>`).join('');

  const m = openModal({
    title: 'Currency converter',
    body: `<form id="f" class="grid-form">
        <label class="field"><span>Amount</span>
          <input name="amount" type="number" step="any" min="0" value="1000" autofocus></label>
        <label class="field"><span>From</span><select name="from">${opts('USD')}</select></label>
        <label class="field"><span>To</span><select name="to">${opts('KWD')}</select></label>
      </form>
      <div class="entry-preview" id="fx-out" style="margin-top:14px"></div>
      <p class="preview-note" id="fx-meta" style="margin-top:12px"></p>`,
    foot: `<button class="btn" id="fx-swap" type="button">Swap</button>
           <button class="btn" id="fx-refresh" type="button">Refresh rate</button>
           <button class="btn btn-primary" data-close type="button">Done</button>`,
  });

  const f = $('#f', m);
  const paint = () => {
    const from = f.from.value, to = f.to.value;
    const amount = Number(f.amount.value || 0);
    const out = convert(amount, from, to);
    const one = convert(1, from, to);
    $('#fx-out', m).innerHTML = out == null
      ? '<div class="entry-row"><span>No rate available for this pair.</span></div>'
      : `<div class="entry-row entry-total"><span>${fmt(amount, from)} ${from} =</span><b>${fmt(out, to)} ${to}</b></div>
         <div class="entry-row"><span>Rate</span><b>1 ${from} = ${one.toFixed(one < 1 ? 6 : 4)} ${to}</b></div>`;
    const ago = fx.fetched ? Math.max(0, Math.round((Date.now() - fx.fetched) / 60000)) : null;
    $('#fx-meta', m).textContent = fx.rates
      ? `${fx.live ? 'Live' : 'Last known (feed unreachable)'} · fetched ${ago === 0 ? 'just now' : `${ago} min ago`}${
          fx.sourceTime ? ` · feed last updated ${fx.sourceTime.replace(' +0000', ' UTC')}` : ''}. Source: open.er-api.com, which refreshes once a day.`
      : 'Exchange rates could not be loaded. Check the internet connection and press Refresh.';
  };
  f.addEventListener('input', paint);
  $('#fx-swap', m).onclick = () => { [f.from.value, f.to.value] = [f.to.value, f.from.value]; paint(); };
  $('#fx-refresh', m).onclick = async () => {
    const b = $('#fx-refresh', m);
    b.disabled = true;
    await loadRates(true);
    paintFxChip(); paint();
    b.disabled = false;
    toast(fx.live ? 'Rate refreshed' : 'Could not reach the rate feed', fx.live ? 'ok' : 'err');
  };
  paint();
}

/* -------------------------------- routing ------------------------------ */

const ROUTES = {
  home: viewHome,
  receiving: () => viewLedger('receiving'),
  sending: () => viewLedger('sending'),
  shipments: viewShipments,
  overview: viewOverview,
  stock: viewStock,
  accounts: viewAccounts,
  users: viewUsers,
};

async function route() {
  const hash = location.hash.replace(/^#\/?/, '');
  const [head, ...rest] = hash.split('/');
  const arg = rest.join('/');

  // A single account page belongs under Accounts in the sidebar.
  const navFor = head === 'party' ? 'accounts' : (head || 'home');
  for (const a of $$('[data-nav]')) {
    a.classList.toggle('is-active', a.dataset.nav === navFor);
  }
  if (head !== 'search') $('#search-input').value = '';

  try {
    if (!head || head === 'home') return await viewHome();
    if (head === 'deal' && arg) return await viewDeal(arg);
    if (head === 'party' && arg) return await viewParty(arg);
    if (head === 'new') return await viewNewDeal(arg === 'sending' ? 'sending' : 'receiving');
    if (head === 'search') return await viewSearch(decodeURIComponent(arg || ''));
    if (ROUTES[head]) return await ROUTES[head]();
    location.hash = '#/home';
  } catch (e) {
    console.error(e);
    view().innerHTML = `<div class="card"><div class="empty">${esc(errText(e))}</div></div>`;
  }
}

/* ------------------------------ auth + boot ---------------------------- */

async function loadProfile() {
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return null;
  const { data, error } = await sb.from('profiles').select('*').eq('id', user.id).maybeSingle();
  if (error) throw error;
  state.profile = data;
  return data;
}

function showAuth(initialized) {
  $('#boot').hidden = true;
  $('#shell').hidden = true;
  $('#auth').hidden = false;
  $('#login-form').hidden = !initialized;
  $('#setup-form').hidden = !!initialized;
}

function showShell() {
  const p = state.profile;
  $('#boot').hidden = true;
  $('#auth').hidden = true;
  $('#shell').hidden = false;
  $('#who-name').textContent = p.display_name || p.username;
  $('#who-role').textContent = p.role === 'owner' ? 'Owner' : p.can_edit ? 'Staff · can edit' : 'Staff · view only';
  $('#who-avatar').textContent = (p.display_name || p.username).trim().charAt(0).toUpperCase();
  $('#nav-users').hidden = !p.can_manage_users;
  $('#new-deal-btn').hidden = !p.can_edit;

  // Send the New button to whichever ledger the user is allowed to work in.
  $('#new-deal-btn').onclick = () => {
    const here = location.hash.replace(/^#\/?/, '').split('/')[0];
    const dir = here === 'sending' ? 'sending'
      : here === 'receiving' ? 'receiving'
        : p.can_view_receiving ? 'receiving' : 'sending';
    location.hash = `#/new/${dir}`;
  };
}

async function enterApp() {
  const profile = await loadProfile();
  if (!profile) {
    await sb.auth.signOut();
    showAuth(true);
    $('#login-error').hidden = false;
    $('#login-error').textContent =
      'That login has no access set up yet. Ask the owner to add permissions for it.';
    return;
  }
  await loadRates();
  paintFxChip();
  showShell();
  if (!location.hash) location.hash = '#/home';
  else await route();
}

function wireAuthForms() {
  $('#login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('[type=submit]');
    const err = $('#login-error');
    err.hidden = true;
    btn.disabled = true;
    const f = new FormData(e.target);
    try {
      const { error } = await sb.auth.signInWithPassword({
        email: emailFor(f.get('username')),
        password: String(f.get('password')),
      });
      if (error) throw error;
      e.target.reset();
      await enterApp();
    } catch (ex) {
      // A page left open from before the owner account existed keeps showing
      // this form, and no password can ever work. Re-check and send them to
      // setup instead of letting them guess.
      let stale = false;
      try {
        const { initialized } = await callUsersFn({ action: 'status' });
        stale = !initialized;
      } catch { /* offline: fall through to the normal message */ }

      if (stale) {
        showAuth(false);
        const se = $('#setup-error');
        se.hidden = false;
        se.textContent = 'No account exists yet, so there is nothing to sign in to. Create the owner account here.';
        return;
      }

      err.hidden = false;
      err.textContent = /invalid/i.test(errText(ex))
        ? 'Wrong username or password.'
        : errText(ex);
    } finally {
      btn.disabled = false;
    }
  });

  $('#setup-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('[type=submit]');
    const err = $('#setup-error');
    err.hidden = true;
    const f = new FormData(e.target);
    if (f.get('password') !== f.get('password2')) {
      err.hidden = false;
      err.textContent = 'The two passwords do not match.';
      return;
    }
    btn.disabled = true;
    try {
      const username = String(f.get('username')).trim().toLowerCase();
      await callUsersFn({
        action: 'bootstrap',
        username,
        password: String(f.get('password')),
        display_name: String(f.get('display_name') || '').trim(),
      });
      const { error } = await sb.auth.signInWithPassword({
        email: emailFor(username),
        password: String(f.get('password')),
      });
      if (error) throw error;
      e.target.reset();
      toast('Owner account created. Welcome.', 'ok');
      await enterApp();
    } catch (ex) {
      err.hidden = false;
      err.textContent = errText(ex);
    } finally {
      btn.disabled = false;
    }
  });

  $('#sign-out').onclick = async () => {
    await sb.auth.signOut();
    state.profile = null;
    location.hash = '';
    location.reload();
  };

  $('#search-form').addEventListener('submit', (e) => {
    e.preventDefault();
    closeSuggest();
    const q = $('#search-input').value.trim();
    location.hash = q ? `#/search/${encodeURIComponent(q)}` : '#/home';
  });

  wireSuggest();

  $('#fx-chip').onclick = fxDialog;
  setInterval(async () => { await loadRates(true); paintFxChip(); }, FX_FRESH_MS);

  const THEME_KEY = 'eb-theme';
  const applyTheme = (t) => {
    if (t) document.documentElement.dataset.theme = t;
    else delete document.documentElement.dataset.theme;
  };
  // Light is the default look: with no saved choice the app starts light
  // whatever the computer's own dark-mode setting says.
  applyTheme(safeStorage.getItem(THEME_KEY) || 'light');
  $('#theme-toggle').onclick = () => {
    const now = document.documentElement.dataset.theme || 'light';
    const next = now === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    safeStorage.setItem(THEME_KEY, next);
  };
}

async function boot() {
  wireAuthForms();
  window.addEventListener('hashchange', route);

  try {
    const { data: { session } } = await sb.auth.getSession();
    if (session) return await enterApp();
    const { initialized } = await callUsersFn({ action: 'status' });
    showAuth(initialized);
  } catch (e) {
    $('#boot').innerHTML = `<p style="max-width:420px;text-align:center;color:var(--due)">
      Could not reach the database.<br><small style="color:var(--ink-3)">${esc(errText(e))}</small></p>`;
  }
}

boot();
