/**
 * Modul Sales Order (SO): Pembuatan Pesanan, Pengajuan Diskon, Persetujuan, & Penyesuaian Owner
 */

import { supabase } from '../config/supabase-client.js';
import { canPerformAction } from '../auth/permission-guard.js';
import { callRpc, unwrapResponse } from '../services/base-service.js';
import { formatDateID, getJakartaToday, getPeriodRange } from '../utils/date-utils.js';
import { escapeHtml, formatNumber, formatRupiah } from '../utils/formatter.js';
import {
  closeModal,
  openModal,
  renderEmptyState,
  renderLoadingState,
  renderPeriodFilterBar,
  renderStatusBadge,
  showToast
} from '../ui/ui-components.js';

let filterState = {
  preset: 'this_month',
  ...getPeriodRange('this_month'),
  status: '',
  customerId: '',
  search: ''
};

export async function renderModule(container, ctx) {
  const canCreate = canPerformAction(ctx.role, 'create_sales_order');

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Sales Order (SO)</h2>
        <p>Pencatatan pesanan pelanggan, perhitungan PPN otomatis, pengajuan diskon, dan kesiapan kirim</p>
      </div>
      ${
        canCreate
          ? `<div class="page-actions no-print">
              <button type="button" class="btn btn-primary" id="btn-new-so">
                <span class="material-symbols-outlined">add_shopping_cart</span>
                Buat Sales Order Baru
              </button>
            </div>`
          : ''
      }
    </div>

    <div id="so-period-bar"></div>
    <div id="so-extra-filters"></div>
    <div id="so-list-body">${renderLoadingState()}</div>
  `;

  renderPeriodFilterBar('so-period-bar', filterState, async (nextFilter) => {
    filterState = { ...filterState, ...nextFilter };
    await loadSalesOrders(ctx);
  });

  if (canCreate) {
    document.getElementById('btn-new-so')?.addEventListener('click', () => {
      openSalesOrderFormModal(null, ctx);
    });
  }

  await loadSalesOrders(ctx);
}

async function loadSalesOrders(ctx) {
  const listEl = document.getElementById('so-list-body');
  const extraFilterEl = document.getElementById('so-extra-filters');
  if (!listEl) return;

  listEl.innerHTML = renderLoadingState();

  try {
    const [custRes, whRes, profRes, rolesRes] = await Promise.all([
      supabase.from('customers').select('id, code, name').order('name'),
      supabase.from('warehouses').select('id, code, name').order('name'),
      supabase.from('profiles').select('id, full_name'),
      supabase.from('user_roles').select('user_id, role')
    ]);

    const customers = unwrapResponse(custRes) || [];
    const warehouses = unwrapResponse(whRes) || [];
    const rawProfiles = unwrapResponse(profRes) || [];
    const roleRows = rolesRes.error ? [] : rolesRes.data || [];

    const roleByUserId = new Map(roleRows.map((r) => [r.user_id, r.role]));
    const profiles = rawProfiles.map((p) => ({
      ...p,
      role: roleByUserId.get(p.id) || ''
    }));

    const custMap = new Map(customers.map((c) => [c.id, c.name]));
    const whMap = new Map(warehouses.map((w) => [w.id, w.name]));
    const profMap = new Map(profiles.map((p) => [p.id, p.full_name]));

    let query = supabase
      .from('sales_orders')
      .select('*')
      .order('order_date', { ascending: false })
      .order('created_at', { ascending: false });

    if (filterState.startDate) {
      query = query.gte('order_date', filterState.startDate);
    }
    if (filterState.endDate) {
      query = query.lte('order_date', filterState.endDate);
    }
    if (filterState.status) {
      query = query.eq('status', filterState.status);
    }
    if (filterState.customerId) {
      query = query.eq('customer_id', filterState.customerId);
    }

    let orders = unwrapResponse(await query) || [];

    if (filterState.search) {
      const q = filterState.search.toLowerCase();
      orders = orders.filter((o) => {
        const matchNo = (o.so_number || '').toLowerCase().includes(q);
        const matchCust = (custMap.get(o.customer_id) || '').toLowerCase().includes(q);
        return matchNo || matchCust;
      });
    }

    if (extraFilterEl) {
      const custOpts =
        `<option value="">Semua Pelanggan</option>` +
        customers
          .map(
            (c) =>
              `<option value="${c.id}" ${filterState.customerId === c.id ? 'selected' : ''}>${escapeHtml(c.name)}</option>`
          )
          .join('');

      extraFilterEl.innerHTML = `
        <div class="filter-bar no-print">
          <div class="filter-item">
            <label for="so-status-filter">Status SO</label>
            <select id="so-status-filter" class="form-control">
              <option value="" ${filterState.status === '' ? 'selected' : ''}>Semua Status</option>
              <option value="draft" ${filterState.status === 'draft' ? 'selected' : ''}>Draft</option>
              <option value="pending_approval" ${filterState.status === 'pending_approval' ? 'selected' : ''}>Menunggu Persetujuan Diskon</option>
              <option value="approved" ${filterState.status === 'approved' ? 'selected' : ''}>Disetujui (Siap Kirim)</option>
              <option value="delivered" ${filterState.status === 'delivered' ? 'selected' : ''}>Sudah Dikirim</option>
              <option value="rejected" ${filterState.status === 'rejected' ? 'selected' : ''}>Ditolak</option>
              <option value="cancelled" ${filterState.status === 'cancelled' ? 'selected' : ''}>Dibatalkan</option>
            </select>
          </div>
          <div class="filter-item">
            <label for="so-cust-filter">Pelanggan</label>
            <select id="so-cust-filter" class="form-control">${custOpts}</select>
          </div>
          <div class="filter-item">
            <label for="so-search-input">Cari Nomor SO / Toko</label>
            <input type="text" id="so-search-input" class="form-control" value="${escapeHtml(filterState.search)}" placeholder="Ketik nomor SO atau nama toko..." />
          </div>
        </div>
      `;

      document.getElementById('so-status-filter')?.addEventListener('change', (e) => {
        filterState.status = e.target.value;
        loadSalesOrders(ctx);
      });
      document.getElementById('so-cust-filter')?.addEventListener('change', (e) => {
        filterState.customerId = e.target.value;
        loadSalesOrders(ctx);
      });

      let timer = null;
      document.getElementById('so-search-input')?.addEventListener('input', (e) => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          filterState.search = e.target.value.trim();
          loadSalesOrders(ctx);
        }, 300);
      });
    }

    const totalOmzet = orders
      .filter((o) => !['cancelled', 'rejected'].includes(o.status))
      .reduce((sum, o) => sum + Number(o.grand_total || 0), 0);

    const pendingCount = orders.filter((o) => o.status === 'pending_approval').length;
    const readyCount = orders.filter((o) => ['approved', 'ready_for_delivery'].includes(o.status)).length;

    const rowsHtml = orders
      .map((o) => {
        const payLabel =
          o.payment_type === 'credit'
            ? `Tempo (${Number(o.payment_term_days || 0)} Hr)`
            : 'Tunai / COD';
        return `
          <tr>
            <td>
              <strong>${escapeHtml(o.so_number)}</strong>
              <div class="text-muted" style="font-size:0.8rem;">${formatDateID(o.order_date)}</div>
            </td>
            <td>
              <strong>${escapeHtml(custMap.get(o.customer_id) || '-')}</strong>
              <div class="text-muted" style="font-size:0.8rem;">Gudang: ${escapeHtml(whMap.get(o.warehouse_id) || '-')}</div>
            </td>
            <td>${escapeHtml(profMap.get(o.sales_user_id) || '-')}</td>
            <td>${escapeHtml(payLabel)}</td>
            <td class="num font-semibold">${formatRupiah(o.grand_total)}</td>
            <td>${renderStatusBadge(o.status)}</td>
            <td class="text-right">
              <button type="button" class="btn btn-secondary btn-sm" data-view-so="${o.id}">
                ${o.status === 'draft' ? 'Edit / Ajukan' : 'Detail'}
              </button>
            </td>
          </tr>
        `;
      })
      .join('');

    listEl.innerHTML = `
      <div class="grid-3" style="margin-bottom:1.25rem;">
        <div class="kpi-card">
          <span class="kpi-label">Total Nilai Sales Order</span>
          <span class="kpi-value">${formatRupiah(totalOmzet)}</span>
          <span class="kpi-sub">${orders.length} dokumen pada periode terpilih</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Siap Kirim Gudang</span>
          <span class="kpi-value text-success">${formatNumber(readyCount, 0)} SO</span>
          <span class="kpi-sub">Menunggu proses Surat Jalan</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Menunggu Persetujuan</span>
          <span class="kpi-value ${pendingCount > 0 ? 'text-warning' : ''}">${formatNumber(pendingCount, 0)} SO</span>
          <span class="kpi-sub">Pengajuan potongan harga</span>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Daftar Sales Order (${orders.length})</h3>
        </div>
        ${
          orders.length === 0
            ? `<div class="card-body">${renderEmptyState('Belum ada Sales Order pada periode dan filter yang dipilih.')}</div>`
            : `<div class="table-responsive">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>No. SO & Tanggal</th>
                      <th>Pelanggan & Gudang</th>
                      <th>Sales</th>
                      <th>Pembayaran</th>
                      <th class="num">Total Tagihan</th>
                      <th>Status</th>
                      <th class="text-right">Aksi</th>
                    </tr>
                  </thead>
                  <tbody>${rowsHtml}</tbody>
                </table>
              </div>`
        }
      </div>
    `;

    listEl.querySelectorAll('[data-view-so]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const so = orders.find((item) => item.id === btn.getAttribute('data-view-so'));
        if (so) {
          openSalesOrderDetailModal(so, custMap, whMap, profMap, profiles, ctx);
        }
      });
    });
  } catch (err) {
    listEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

/* ============================================================================
   HELPER PERHITUNGAN TARIF PAJAK & BARIS SO
   ============================================================================ */
function resolveTaxRates(taxCode) {
  if (!taxCode) {
    return { ratePercent: 0, dppMultiplier: 1 };
  }
  const codeUpper = (taxCode.code || '').toUpperCase();
  const typeLower = (taxCode.tax_type || '').toLowerCase();
  const nameLower = (taxCode.name || '').toLowerCase();

  if (typeLower.includes('non') || codeUpper.includes('NON') || codeUpper === 'BEBAS') {
    return { ratePercent: 0, dppMultiplier: 1 };
  }
  if (typeLower.includes('nilai_lain') || codeUpper.includes('DPP') || nameLower.includes('11/12')) {
    return { ratePercent: 12, dppMultiplier: 11 / 12 };
  }
  return { ratePercent: 11, dppMultiplier: 1 };
}

function calculateLinePreview(item, ppnMode) {
  const qty = Number(item.qty || 0);
  const price = Number(item.unit_price || 0);
  const discPct = Number(item.discount_percent || 0);
  const gross = Math.round(qty * price * 100) / 100;
  const discAmt =
    discPct > 0 ? Math.round(gross * (discPct / 100) * 100) / 100 : Number(item.discount_amount || 0);
  const net = Math.max(0, gross - discAmt);

  const rate = Number(item.tax_rate_percent || 0);
  const mult = Number(item.dpp_multiplier || 1);

  if (ppnMode === 'exclude_ppn' && rate > 0) {
    const dpp = Math.round(net * mult * 100) / 100;
    const tax = Math.round(dpp * (rate / 100) * 100) / 100;
    return { gross, discAmt, dpp, tax, total: net + tax };
  }
  if (ppnMode === 'include_ppn' && rate > 0) {
    const divisor = 1 + (mult * rate) / 100;
    const dpp = Math.round((net / divisor) * 100) / 100;
    const tax = Math.round((net - dpp) * 100) / 100;
    return { gross, discAmt, dpp, tax, total: net };
  }
  return { gross, discAmt, dpp: net, tax: 0, total: net };
}

/* ============================================================================
   MODAL BUAT / EDIT DRAFT SALES ORDER
   ============================================================================ */
async function openSalesOrderFormModal(existingSo, ctx) {
  const isEdit = Boolean(existingSo);

  const [custRes, whRes, prodRes, unitRes, taxRes, balRes, settingRes, existingItemsRes] =
    await Promise.all([
      supabase.from('customers').select('*').eq('is_active', true).order('name'),
      supabase.from('warehouses').select('id, code, name').eq('is_active', true).order('name'),
      supabase.from('products').select('*').eq('is_active', true).order('name'),
      supabase.from('units').select('id, code, name'),
      supabase.from('tax_codes').select('*').eq('is_active', true),
      supabase.from('stock_balances').select('warehouse_id, product_id, qty_on_hand'),
      supabase
        .from('system_settings')
        .select('setting_value')
        .eq('setting_key', 'ppn_sales_price_mode')
        .maybeSingle(),
      isEdit
        ? supabase.from('sales_order_items').select('*').eq('sales_order_id', existingSo.id)
        : Promise.resolve({ data: [], error: null })
    ]);

  const customers = unwrapResponse(custRes) || [];
  const warehouses = unwrapResponse(whRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const taxCodes = unwrapResponse(taxRes) || [];
  const balances = unwrapResponse(balRes) || [];
  const existingItems = unwrapResponse(existingItemsRes) || [];

  if (customers.length === 0 || warehouses.length === 0 || products.length === 0) {
    showToast('Pastikan Pelanggan, Gudang, dan Produk aktif sudah tersedia di Data Master.', 'warning');
    return;
  }

  const ppnCfg = settingRes?.data?.setting_value || {};
  const systemPpnMode = ppnCfg.enabled ? ppnCfg.mode || 'exclude_ppn' : 'non_ppn';
  const activePpnMode = existingSo?.ppn_mode_snapshot || systemPpnMode;

  const custMap = new Map(customers.map((c) => [c.id, c]));
  const prodMap = new Map(products.map((p) => [p.id, p]));
  const unitMap = new Map(units.map((u) => [u.id, u]));
  const taxMap = new Map(taxCodes.map((t) => [t.id, t]));
  const balMap = new Map(
    balances.map((b) => [`${b.warehouse_id}_${b.product_id}`, Number(b.qty_on_hand || 0)])
  );

  const makeDefaultLine = (prod) => {
    const tc = taxMap.get(prod.tax_code_id);
    const rates = resolveTaxRates(tc);
    return {
      product_id: prod.id,
      qty: 1,
      unit_price: Number(prod.standard_sell_price || 0),
      discount_percent: 0,
      discount_amount: 0,
      tax_code_id: prod.tax_code_id || null,
      tax_rate_percent: rates.ratePercent,
      dpp_multiplier: rates.dppMultiplier
    };
  };

  let lineItems =
    existingItems.length > 0
      ? existingItems.map((it) => ({
          product_id: it.product_id,
          qty: Number(it.qty || 1),
          unit_price: Number(it.unit_price || 0),
          discount_percent: Number(it.discount_percent || 0),
          discount_amount: Number(it.discount_amount || 0),
          tax_code_id: it.tax_code_id || null,
          tax_rate_percent: Number(it.tax_rate_percent || 0),
          dpp_multiplier: Number(it.dpp_multiplier || 1)
        }))
      : [makeDefaultLine(products[0])];

  const defaultCust = custMap.get(existingSo?.customer_id) || customers[0];
  const defaultPayType =
    existingSo?.payment_type || (Number(defaultCust.payment_term_days || 0) > 0 ? 'credit' : 'cash');
  const defaultTermDays =
    existingSo?.payment_term_days !== undefined
      ? Number(existingSo.payment_term_days)
      : Number(defaultCust.payment_term_days || 0);

  const custOpts = customers
    .map(
      (c) =>
        `<option value="${c.id}" ${c.id === defaultCust.id ? 'selected' : ''}>${escapeHtml(c.code)} - ${escapeHtml(c.name)}</option>`
    )
    .join('');

  const whOpts = warehouses
    .map(
      (w) =>
        `<option value="${w.id}" ${existingSo?.warehouse_id === w.id ? 'selected' : ''}>${escapeHtml(w.code)} - ${escapeHtml(w.name)}</option>`
    )
    .join('');

  openModal({
    title: isEdit ? `Edit Draft Sales Order: ${existingSo.so_number}` : 'Buat Sales Order (SO) Baru',
    size: 'lg',
    bodyHtml: `
      <div id="so-modal-error" class="alert alert-danger hidden"></div>

      <div class="grid-3">
        <div class="form-group">
          <label class="form-label" for="so-date">Tanggal Order <span class="req">*</span></label>
          <input type="date" id="so-date" class="form-control" value="${existingSo?.order_date || getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="so-exp-date">Rencana Tanggal Kirim</label>
          <input type="date" id="so-exp-date" class="form-control" value="${existingSo?.expected_delivery_date || getJakartaToday()}" />
        </div>
        <div class="form-group">
          <label class="form-label" for="so-wh">Gudang Pengirim <span class="req">*</span></label>
          <select id="so-wh" class="form-control">${whOpts}</select>
        </div>
      </div>

      <div class="grid-3">
        <div class="form-group">
          <label class="form-label" for="so-cust">Pelanggan / Outlet <span class="req">*</span></label>
          <select id="so-cust" class="form-control">${custOpts}</select>
          <span class="form-help" id="so-cust-limit-info"></span>
        </div>
        <div class="form-group">
          <label class="form-label" for="so-pay-type">Metode Pembayaran <span class="req">*</span></label>
          <select id="so-pay-type" class="form-control">
            <option value="cash" ${defaultPayType === 'cash' ? 'selected' : ''}>Tunai / COD</option>
            <option value="credit" ${defaultPayType === 'credit' ? 'selected' : ''}>Kredit / Tempo</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" for="so-term">Termin Kredit (Hari)</label>
          <input type="number" min="0" id="so-term" class="form-control" value="${defaultTermDays}" ${defaultPayType === 'cash' ? 'disabled' : ''} />
        </div>
      </div>

      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="so-ppn-mode">Mode PPN Aktif (Sesuai Pengaturan)</label>
          <select id="so-ppn-mode" class="form-control" disabled>
            <option value="include_ppn" ${activePpnMode === 'include_ppn' ? 'selected' : ''}>Harga Sudah Termasuk PPN (Include PPN)</option>
            <option value="exclude_ppn" ${activePpnMode === 'exclude_ppn' ? 'selected' : ''}>Harga Belum Termasuk PPN (Exclude PPN)</option>
            <option value="non_ppn" ${activePpnMode === 'non_ppn' ? 'selected' : ''}>Tanpa PPN (Non-PPN)</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" for="so-notes">Catatan Pesanan / Pengiriman</label>
          <input type="text" id="so-notes" class="form-control" value="${escapeHtml(existingSo?.notes || '')}" placeholder="Contoh: Kirim pagi sebelum jam 11" />
        </div>
      </div>

      <div style="display:flex;justify-content:space-between;align-items:center;margin:1rem 0 0.5rem;">
        <strong>Rincian Barang Pesanan</strong>
        <button type="button" class="btn btn-secondary btn-sm" id="so-add-line">+ Tambah Produk</button>
      </div>

      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Stok</th>
              <th class="num" style="width:95px;">Qty</th>
              <th class="num" style="width:135px;">Harga Satuan</th>
              <th class="num" style="width:90px;">Disc %</th>
              <th class="num">Jumlah</th>
              <th style="width:45px;"></th>
            </tr>
          </thead>
          <tbody id="so-lines-tbody"></tbody>
        </table>
      </div>

      <div id="so-disc-reason-wrap" class="form-group hidden" style="margin-top:0.75rem;">
        <label class="form-label" for="so-disc-reason">Alasan Pengajuan Diskon <span class="req">*</span></label>
        <input type="text" id="so-disc-reason" class="form-control" value="${escapeHtml(existingSo?.discount_reason || '')}" placeholder="Wajib diisi karena terdapat potongan harga (memerlukan persetujuan Finance/Owner)" />
      </div>

      <div class="card" style="margin-top:1rem;background:var(--color-bg);">
        <div class="card-body" id="so-totals-summary" style="display:flex;justify-content:flex-end;gap:1.5rem;flex-wrap:wrap;"></div>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="so-cancel-modal">Batal</button>
      <button type="button" class="btn btn-secondary" id="so-save-draft">Simpan Draft</button>
      <button type="button" class="btn btn-primary" id="so-save-submit">Simpan & Ajukan SO</button>
    `,
    onMount: () => {
      const custSelect = document.getElementById('so-cust');
      const whSelect = document.getElementById('so-wh');
      const payTypeSelect = document.getElementById('so-pay-type');
      const termInput = document.getElementById('so-term');
      const ppnModeSelect = document.getElementById('so-ppn-mode');
      const custLimitInfo = document.getElementById('so-cust-limit-info');
      const discReasonWrap = document.getElementById('so-disc-reason-wrap');
      const summaryEl = document.getElementById('so-totals-summary');
      const modalErrEl = document.getElementById('so-modal-error');

      const showModalError = (msg) => {
        if (modalErrEl) {
          modalErrEl.textContent = msg;
          modalErrEl.classList.remove('hidden');
        }
        showToast(msg, 'danger');
      };

      const clearModalError = () => {
        if (modalErrEl) {
          modalErrEl.textContent = '';
          modalErrEl.classList.add('hidden');
        }
      };

      const updateCustomerInfo = (applyDefaults = false) => {
        const c = custMap.get(custSelect.value);
        if (!c) return;
        const limit = Number(c.credit_limit || 0);
        custLimitInfo.textContent =
          limit > 0 ? `Limit kredit: ${formatRupiah(limit)}` : 'Pelanggan tunai (tanpa limit kredit)';

        if (applyDefaults) {
          const term = Number(c.payment_term_days || 0);
          payTypeSelect.value = term > 0 ? 'credit' : 'cash';
          termInput.value = term;
          termInput.disabled = payTypeSelect.value === 'cash';
        }
      };

      updateCustomerInfo(false);

      custSelect.addEventListener('change', () => updateCustomerInfo(true));
      payTypeSelect.addEventListener('change', () => {
        const isCash = payTypeSelect.value === 'cash';
        termInput.disabled = isCash;
        if (isCash) {
          termInput.value = 0;
        } else if (Number(termInput.value) === 0) {
          const c = custMap.get(custSelect.value);
          termInput.value = Number(c?.payment_term_days || 14);
        }
      });

      const updateTotals = () => {
        const ppnMode = ppnModeSelect.value;
        let subtotal = 0;
        let discTotal = 0;
        let dppTotal = 0;
        let taxTotal = 0;
        let grandTotal = 0;

        lineItems.forEach((it, idx) => {
          const calc = calculateLinePreview(it, ppnMode);
          subtotal += calc.gross;
          discTotal += calc.discAmt;
          dppTotal += calc.dpp;
          taxTotal += calc.tax;
          grandTotal += calc.total;

          const rowTotalCell = document.getElementById(`so-row-total-${idx}`);
          if (rowTotalCell) {
            rowTotalCell.textContent = formatRupiah(calc.total);
          }
        });

        discReasonWrap.classList.toggle('hidden', discTotal <= 0);

        summaryEl.innerHTML = `
          <div><span class="text-muted">Subtotal:</span> <strong>${formatRupiah(subtotal)}</strong></div>
          <div><span class="text-muted">Diskon:</span> <strong class="text-danger">${formatRupiah(discTotal)}</strong></div>
          <div><span class="text-muted">DPP:</span> <strong>${formatRupiah(dppTotal)}</strong></div>
          <div><span class="text-muted">PPN:</span> <strong>${formatRupiah(taxTotal)}</strong></div>
          <div><span class="text-muted">Grand Total:</span> <strong class="text-success" style="font-size:1.1rem;">${formatRupiah(grandTotal)}</strong></div>
        `;
      };

      const renderLines = () => {
        const tbody = document.getElementById('so-lines-tbody');
        if (!tbody) return;
        const currentWh = whSelect.value;

        tbody.innerHTML = lineItems
          .map((item, idx) => {
            const avail = balMap.get(`${currentWh}_${item.product_id}`) || 0;
            const prod = prodMap.get(item.product_id);
            const unitCode = unitMap.get(prod?.base_unit_id)?.code || '';

            const prodOpts = products
              .map(
                (p) =>
                  `<option value="${p.id}" ${p.id === item.product_id ? 'selected' : ''}>${escapeHtml(p.sku)} - ${escapeHtml(p.name)}</option>`
              )
              .join('');

            return `
              <tr>
                <td>
                  <select class="form-control" data-so-prod="${idx}">${prodOpts}</select>
                </td>
                <td class="num ${avail < item.qty ? 'text-danger' : ''}">
                  ${formatNumber(avail)} ${escapeHtml(unitCode)}
                </td>
                <td>
                  <input type="number" step="1" min="1" class="form-control num" data-so-qty="${idx}" value="${item.qty}" />
                </td>
                <td>
                  <input type="number" step="1" min="0" class="form-control num" data-so-price="${idx}" value="${item.unit_price}" />
                </td>
                <td>
                  <input type="number" step="0.1" min="0" max="100" class="form-control num" data-so-disc="${idx}" value="${item.discount_percent}" />
                </td>
                <td class="num font-semibold" id="so-row-total-${idx}">Rp 0</td>
                <td class="text-right">
                  ${
                    lineItems.length > 1
                      ? `<button type="button" class="btn btn-ghost btn-sm text-danger" data-so-del="${idx}">&times;</button>`
                      : ''
                  }
                </td>
              </tr>
            `;
          })
          .join('');

        tbody.querySelectorAll('[data-so-prod]').forEach((el) => {
          el.addEventListener('change', (e) => {
            const idx = Number(e.target.getAttribute('data-so-prod'));
            const prod = prodMap.get(e.target.value);
            if (prod) {
              lineItems[idx] = {
                ...makeDefaultLine(prod),
                qty: lineItems[idx].qty
              };
            }
            renderLines();
          });
        });

        tbody.querySelectorAll('[data-so-qty]').forEach((el) => {
          el.addEventListener('input', (e) => {
            const idx = Number(e.target.getAttribute('data-so-qty'));
            lineItems[idx].qty = Number(e.target.value || 0);
            updateTotals();
          });
        });

        tbody.querySelectorAll('[data-so-price]').forEach((el) => {
          el.addEventListener('input', (e) => {
            const idx = Number(e.target.getAttribute('data-so-price'));
            lineItems[idx].unit_price = Number(e.target.value || 0);
            updateTotals();
          });
        });

        tbody.querySelectorAll('[data-so-disc]').forEach((el) => {
          el.addEventListener('input', (e) => {
            const idx = Number(e.target.getAttribute('data-so-disc'));
            lineItems[idx].discount_percent = Number(e.target.value || 0);
            lineItems[idx].discount_amount = 0;
            updateTotals();
          });
        });

        tbody.querySelectorAll('[data-so-del]').forEach((el) => {
          el.addEventListener('click', (e) => {
            const idx = Number(e.target.getAttribute('data-so-del'));
            lineItems.splice(idx, 1);
            renderLines();
          });
        });

        updateTotals();
      };

      renderLines();

      whSelect.addEventListener('change', renderLines);
      document.getElementById('so-add-line')?.addEventListener('click', () => {
        lineItems.push(makeDefaultLine(products[0]));
        renderLines();
      });

      document.getElementById('so-cancel-modal')?.addEventListener('click', closeModal);

      const handlePersist = async (shouldSubmit) => {
        clearModalError();

        if (lineItems.length === 0) {
          showModalError('Sales Order wajib memiliki minimal satu produk.');
          return;
        }

        const ppnMode = ppnModeSelect.value;
        let subtotal = 0;
        let discountTotal = 0;
        let dppTotal = 0;
        let taxTotal = 0;
        let grandTotal = 0;

        for (const it of lineItems) {
          if (!it.product_id || it.qty <= 0 || it.unit_price < 0) {
            showModalError('Periksa kembali produk, kuantitas (minimal 1), dan harga satuan.');
            return;
          }
          const c = calculateLinePreview(it, ppnMode);
          subtotal += c.gross;
          discountTotal += c.discAmt;
          dppTotal += c.dpp;
          taxTotal += c.tax;
          grandTotal += c.total;
        }

        const discReason = document.getElementById('so-disc-reason').value.trim();
        if (discountTotal > 0 && !discReason) {
          showModalError('Alasan pengajuan diskon wajib diisi.');
          return;
        }

        const btnDraft = document.getElementById('so-save-draft');
        const btnSubmit = document.getElementById('so-save-submit');
        btnDraft.disabled = true;
        btnSubmit.disabled = true;

        try {
          const payType = payTypeSelect.value;
          const headerPayload = {
            order_date: document.getElementById('so-date').value,
            expected_delivery_date: document.getElementById('so-exp-date').value || null,
            customer_id: custSelect.value,
            warehouse_id: whSelect.value,
            sales_user_id: existingSo?.sales_user_id || ctx.user.id,
            payment_type: payType,
            payment_term_days: payType === 'cash' ? 0 : Number(termInput.value || 0),
            ppn_mode_snapshot: ppnMode,
            status: 'draft',
            subtotal,
            discount_total: discountTotal,
            dpp_total: dppTotal,
            tax_total: taxTotal,
            grand_total: grandTotal,
            has_discount_request: discountTotal > 0,
            discount_reason: discountTotal > 0 ? discReason : null,
            notes: document.getElementById('so-notes').value.trim() || null
          };

          let soId = existingSo?.id;
          let soNumber = existingSo?.so_number;

          if (isEdit) {
            unwrapResponse(await supabase.from('sales_orders').update(headerPayload).eq('id', soId));
            unwrapResponse(await supabase.from('sales_order_items').delete().eq('sales_order_id', soId));
          } else {
            const inserted = unwrapResponse(
              await supabase
                .from('sales_orders')
                .insert({ ...headerPayload, created_by: ctx.user.id })
                .select()
                .single()
            );
            soId = inserted.id;
            soNumber = inserted.so_number;
          }

          const itemsPayload = lineItems.map((it) => {
            const prod = prodMap.get(it.product_id);
            const calc = calculateLinePreview(it, ppnMode);
            return {
              sales_order_id: soId,
              product_id: it.product_id,
              unit_id: prod.base_unit_id,
              qty: Number(it.qty),
              unit_price: Number(it.unit_price),
              discount_percent: Number(it.discount_percent || 0),
              discount_amount: calc.discAmt,
              tax_code_id: it.tax_code_id || null,
              tax_rate_percent: ppnMode === 'non_ppn' ? 0 : Number(it.tax_rate_percent || 0),
              dpp_multiplier: ppnMode === 'non_ppn' ? 1 : Number(it.dpp_multiplier || 1),
              dpp_amount: calc.dpp,
              tax_amount: calc.tax,
              line_total: calc.total
            };
          });

          unwrapResponse(await supabase.from('sales_order_items').insert(itemsPayload));

          if (shouldSubmit) {
            await callRpc('rpc_submit_sales_order', { p_sales_order_id: soId });
            closeModal();
            showToast(
              discountTotal > 0
                ? `SO ${soNumber} diajukan dan menunggu persetujuan diskon.`
                : `SO ${soNumber} berhasil diajukan dan siap dikirim oleh gudang.`,
              'success'
            );
          } else {
            closeModal();
            showToast(`Draft SO ${soNumber} berhasil disimpan.`, 'success');
          }

          await loadSalesOrders(ctx);
        } catch (err) {
          showModalError(err.message);
          btnDraft.disabled = false;
          btnSubmit.disabled = false;
        }
      };

      document.getElementById('so-save-draft')?.addEventListener('click', () => handlePersist(false));
      document.getElementById('so-save-submit')?.addEventListener('click', () => handlePersist(true));
    }
  });
}

/* ============================================================================
   MODAL DETAIL SALES ORDER, PERSETUJUAN DISKON, & TINDAKAN KHUSUS OWNER
   ============================================================================ */
async function openSalesOrderDetailModal(so, custMap, whMap, profMap, allProfiles, ctx) {
  const [itemsRes, prodRes, unitRes, apprRes] = await Promise.all([
    supabase.from('sales_order_items').select('*').eq('sales_order_id', so.id),
    supabase.from('products').select('id, sku, name'),
    supabase.from('units').select('id, code'),
    supabase
      .from('sales_order_approvals')
      .select('*')
      .eq('sales_order_id', so.id)
      .order('created_at', { ascending: false })
  ]);

  const items = unwrapResponse(itemsRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const approvals = unwrapResponse(apprRes) || [];

  const prodMap = new Map(products.map((p) => [p.id, `${p.sku} - ${p.name}`]));
  const unitMap = new Map(units.map((u) => [u.id, u.code]));

  const pendingApproval = approvals.find((a) => a.status === 'pending');
  const canApproveDiscount = canPerformAction(ctx.role, 'approve_discount');
  const canOverridePrice = canPerformAction(ctx.role, 'override_so_price');
  const canReattribute = canPerformAction(ctx.role, 'reattribute_so_sales');
  const canDispatch = canPerformAction(ctx.role, 'dispatch_delivery');
  const isDraftOwner = so.status === 'draft' && (ctx.role === 'owner' || so.sales_user_id === ctx.user.id);

  const itemsHtml = items
    .map((it) => {
      const unitCode = unitMap.get(it.unit_id) || '';
      return `
        <tr>
          <td><strong>${escapeHtml(prodMap.get(it.product_id) || '-')}</strong></td>
          <td class="num">${formatNumber(it.qty)} ${escapeHtml(unitCode)}</td>
          <td class="num">${formatRupiah(it.unit_price)}</td>
          <td class="num text-danger">${Number(it.discount_amount) > 0 ? formatRupiah(it.discount_amount) : '-'}</td>
          <td class="num font-semibold">${formatRupiah(it.line_total)}</td>
          ${
            canOverridePrice && !['delivered', 'cancelled'].includes(so.status)
              ? `<td class="text-right">
                  <button type="button" class="btn btn-ghost btn-sm" data-override-item="${it.id}" data-cur-price="${it.unit_price}">Ubah Harga</button>
                </td>`
              : ''
          }
        </tr>
      `;
    })
    .join('');

  const salesProfiles = allProfiles.filter((p) => ['sales', 'owner', ''].includes(p.role));
  const salesOpts = salesProfiles
    .map(
      (p) =>
        `<option value="${p.id}" ${p.id === so.sales_user_id ? 'selected' : ''}>${escapeHtml(p.full_name)}</option>`
    )
    .join('');

  openModal({
    title: `Detail Sales Order: ${so.so_number}`,
    size: 'lg',
    bodyHtml: `
      <div class="grid-3" style="margin-bottom:1rem;">
        <div>
          <div class="text-muted">Pelanggan</div>
          <strong>${escapeHtml(custMap.get(so.customer_id) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Gudang Pengirim</div>
          <strong>${escapeHtml(whMap.get(so.warehouse_id) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Status</div>
          <div>${renderStatusBadge(so.status)}</div>
        </div>
        <div>
          <div class="text-muted">Tanggal Order</div>
          <strong>${formatDateID(so.order_date)}</strong>
        </div>
        <div>
          <div class="text-muted">Sales PIC</div>
          <strong>${escapeHtml(profMap.get(so.sales_user_id) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Termin Pembayaran</div>
          <strong>${so.payment_type === 'credit' ? `Tempo ${so.payment_term_days} Hari` : 'Tunai / COD'}</strong>
        </div>
      </div>

      ${so.notes ? `<div class="alert alert-info">Catatan: ${escapeHtml(so.notes)}</div>` : ''}

      ${
        pendingApproval
          ? `<div class="alert alert-warning">
              <strong>Pengajuan Persetujuan Diskon:</strong> ${escapeHtml(pendingApproval.request_reason || so.discount_reason || '-')}
            </div>`
          : ''
      }

      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Qty</th>
              <th class="num">Harga Satuan</th>
              <th class="num">Diskon</th>
              <th class="num">Total Baris</th>
              ${canOverridePrice && !['delivered', 'cancelled'].includes(so.status) ? '<th class="text-right">Owner</th>' : ''}
            </tr>
          </thead>
          <tbody>${itemsHtml}</tbody>
        </table>
      </div>

      <div style="display:flex;justify-content:flex-end;gap:1.5rem;margin-top:0.75rem;padding:0.75rem;background:var(--color-bg);border-radius:var(--radius-sm);">
        <div><span class="text-muted">Subtotal:</span> <strong>${formatRupiah(so.subtotal)}</strong></div>
        <div><span class="text-muted">Diskon:</span> <strong class="text-danger">${formatRupiah(so.discount_total)}</strong></div>
        <div><span class="text-muted">DPP:</span> <strong>${formatRupiah(so.dpp_total)}</strong></div>
        <div><span class="text-muted">PPN:</span> <strong>${formatRupiah(so.tax_total)}</strong></div>
        <div><span class="text-muted">Grand Total:</span> <strong class="text-success">${formatRupiah(so.grand_total)}</strong></div>
      </div>

      ${
        pendingApproval && canApproveDiscount
          ? `<div class="form-group" style="margin-top:1rem;">
              <label class="form-label" for="so-appr-notes">Catatan Keputusan Diskon</label>
              <input type="text" id="so-appr-notes" class="form-control" placeholder="Opsional untuk persetujuan, wajib jika menolak" />
            </div>`
          : ''
      }

      ${
        canReattribute
          ? `<div class="card" style="margin-top:1rem;">
              <div class="card-body">
                <strong>Kontrol Khusus Owner: Ganti Atribusi Sales</strong>
                <div class="grid-3" style="margin-top:0.5rem;align-items:end;">
                  <div class="form-group" style="margin-bottom:0;">
                    <label class="form-label" for="so-reattr-user">Sales Baru</label>
                    <select id="so-reattr-user" class="form-control">${salesOpts}</select>
                  </div>
                  <div class="form-group" style="margin-bottom:0;">
                    <label class="form-label" for="so-reattr-reason">Alasan Perubahan</label>
                    <input type="text" id="so-reattr-reason" class="form-control" placeholder="Contoh: Koreksi wilayah sales" />
                  </div>
                  <div>
                    <button type="button" class="btn btn-secondary" id="so-reattr-btn">Simpan Perubahan Sales</button>
                  </div>
                </div>
              </div>
            </div>`
          : ''
      }
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="dso-close">Tutup</button>
      ${
        isDraftOwner
          ? `<button type="button" class="btn btn-secondary" id="dso-edit">Edit Draft</button>
             <button type="button" class="btn btn-primary" id="dso-submit">Ajukan SO</button>`
          : ''
      }
      ${
        pendingApproval && canApproveDiscount
          ? `<button type="button" class="btn btn-danger" id="dso-reject">Tolak Diskon</button>
             <button type="button" class="btn btn-primary" id="dso-approve">Setujui Diskon</button>`
          : ''
      }
      ${
        ['approved', 'ready_for_delivery'].includes(so.status) && canDispatch
          ? `<button type="button" class="btn btn-primary" id="dso-dispatch">Proses Pengiriman (Surat Jalan)</button>`
          : ''
      }
    `,
    onMount: () => {
      document.getElementById('dso-close')?.addEventListener('click', closeModal);

      document.getElementById('dso-edit')?.addEventListener('click', () => {
        openSalesOrderFormModal(so, ctx);
      });

      document.getElementById('dso-submit')?.addEventListener('click', async () => {
        const btn = document.getElementById('dso-submit');
        btn.disabled = true;
        try {
          await callRpc('rpc_submit_sales_order', { p_sales_order_id: so.id });
          closeModal();
          showToast(`Sales Order ${so.so_number} berhasil diajukan.`, 'success');
          await loadSalesOrders(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });

      const handleApproval = async (decision) => {
        const notes = document.getElementById('so-appr-notes')?.value.trim() || '';
        if (decision === 'rejected' && !notes) {
          showToast('Masukkan alasan penolakan diskon terlebih dahulu.', 'warning');
          return;
        }
        try {
          await callRpc('rpc_decide_so_approval', {
            p_approval_id: pendingApproval.id,
            p_decision: decision,
            p_notes: notes || null
          });
          closeModal();
          showToast(
            decision === 'approved'
              ? 'Diskon disetujui. SO siap diproses oleh gudang.'
              : 'Pengajuan diskon ditolak.',
            decision === 'approved' ? 'success' : 'info'
          );
          await loadSalesOrders(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
        }
      };

      document.getElementById('dso-approve')?.addEventListener('click', () => handleApproval('approved'));
      document.getElementById('dso-reject')?.addEventListener('click', () => handleApproval('rejected'));

      document.getElementById('dso-dispatch')?.addEventListener('click', () => {
        openDispatchFromSoModal(so, custMap, whMap, ctx);
      });

      document.getElementById('so-reattr-btn')?.addEventListener('click', async () => {
        const newUserId = document.getElementById('so-reattr-user').value;
        const reason = document.getElementById('so-reattr-reason').value.trim();
        if (!reason) {
          showToast('Alasan perubahan sales wajib diisi.', 'warning');
          return;
        }
        try {
          await callRpc('rpc_owner_reattribute_so_sales', {
            p_sales_order_id: so.id,
            p_new_sales_user_id: newUserId,
            p_reason: reason
          });
          closeModal();
          showToast('Atribusi sales berhasil diperbarui dan tercatat di audit log.', 'success');
          await loadSalesOrders(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
        }
      });

      document.querySelectorAll('[data-override-item]').forEach((btn) => {
        btn.addEventListener('click', async () => {
          const itemId = btn.getAttribute('data-override-item');
          const curPrice = btn.getAttribute('data-cur-price');
          const newPriceStr = window.prompt('Masukkan harga satuan baru (Rp):', curPrice);
          if (newPriceStr === null) return;
          const newPrice = Number(newPriceStr);
          if (Number.isNaN(newPrice) || newPrice < 0) {
            showToast('Harga satuan tidak valid.', 'warning');
            return;
          }
          const reason = window.prompt('Alasan perubahan harga khusus Owner:');
          if (!reason || !reason.trim()) {
            showToast('Alasan perubahan harga wajib diisi.', 'warning');
            return;
          }
          try {
            await callRpc('rpc_owner_override_so_price', {
              p_so_item_id: itemId,
              p_new_unit_price: newPrice,
              p_reason: reason.trim()
            });
            closeModal();
            showToast('Harga item SO berhasil diperbarui.', 'success');
            await loadSalesOrders(ctx);
          } catch (err) {
            showToast(err.message, 'danger');
          }
        });
      });
    }
  });
}

function openDispatchFromSoModal(so, custMap, whMap, ctx) {
  openModal({
    title: `Buat Surat Jalan & Keluarkan Stok: ${so.so_number}`,
    bodyHtml: `
      <div class="alert alert-warning">
        Mengeluarkan barang akan langsung memotong stok di <strong>${escapeHtml(whMap.get(so.warehouse_id) || 'Gudang')}</strong> dan menerbitkan dokumen Surat Jalan untuk <strong>${escapeHtml(custMap.get(so.customer_id) || 'Pelanggan')}</strong>.
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="dsp-date">Tanggal Pengiriman <span class="req">*</span></label>
          <input type="date" id="dsp-date" class="form-control" value="${getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="dsp-driver">Nama Sopir / Pengemudi <span class="req">*</span></label>
          <input type="text" id="dsp-driver" class="form-control" placeholder="Contoh: Pak Budi" required />
        </div>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="dsp-plate">Nomor Polisi Kendaraan</label>
          <input type="text" id="dsp-plate" class="form-control" placeholder="Contoh: B 9123 KDA" />
        </div>
        <div class="form-group">
          <label class="form-label" for="dsp-notes">Catatan Surat Jalan</label>
          <input type="text" id="dsp-notes" class="form-control" value="${escapeHtml(so.notes || '')}" />
        </div>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="dsp-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="dsp-confirm">Terbitkan Surat Jalan & Potong Stok</button>
    `,
    onMount: () => {
      document.getElementById('dsp-cancel')?.addEventListener('click', closeModal);
      document.getElementById('dsp-confirm')?.addEventListener('click', async () => {
        const driverName = document.getElementById('dsp-driver').value.trim();
        if (!driverName) {
          showToast('Nama pengemudi wajib diisi.', 'warning');
          return;
        }
        const btn = document.getElementById('dsp-confirm');
        btn.disabled = true;
        try {
          await callRpc('rpc_dispatch_sales_order', {
            p_sales_order_id: so.id,
            p_delivery_date: document.getElementById('dsp-date').value,
            p_driver_name: driverName,
            p_vehicle_number: document.getElementById('dsp-plate').value.trim() || null,
            p_notes: document.getElementById('dsp-notes').value.trim() || null
          });
          closeModal();
          showToast(`Surat Jalan untuk ${so.so_number} berhasil diterbitkan dan stok dipotong.`, 'success');
          await loadSalesOrders(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}
