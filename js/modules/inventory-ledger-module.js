/**
 * Modul Persediaan, Saldo Nilai Stok, Input Saldo Awal, & Kartu Stok (Stock Movement Ledger)
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
  showToast
} from '../ui/ui-components.js';

let activeTab = 'balances';
let balanceFilters = {
  warehouseId: '',
  search: '',
  onlyLowStock: false
};

let ledgerFilterState = {
  preset: 'this_month',
  ...getPeriodRange('this_month'),
  warehouseId: '',
  productId: '',
  movementType: '',
  page: 1,
  pageSize: 25
};

const MOVEMENT_TYPE_LABELS = Object.freeze({
  opening_stock: 'Saldo Awal Stok',
  purchase_receipt: 'Penerimaan Pembelian',
  sales_delivery: 'Pengeluaran Pengiriman SO',
  sales_return: 'Retur Penjualan Layak Jual',
  transfer_out: 'Transfer Keluar Gudang',
  transfer_in: 'Transfer Masuk Gudang',
  adjustment_in: 'Penyesuaian Tambah (Opname)',
  adjustment_out: 'Penyesuaian Kurang (Opname)',
  damage_out: 'Pengurangan Barang Rusak'
});

export async function renderModule(container, ctx) {
  const canViewCost = canPerformAction(ctx.role, 'view_cogs_and_profit');

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Persediaan & Kartu Stok Gudang</h2>
        <p>Pantau saldo stok per gudang${canViewCost ? ', nilai persediaan (Moving Weighted Average),' : ''} dan riwayat mutasi keluar-masuk barang</p>
      </div>
      ${
        canViewCost
          ? `<div class="page-actions no-print">
              <button type="button" class="btn btn-primary" id="btn-open-opening-stock">
                <span class="material-symbols-outlined">add_box</span>
                Input Saldo Awal Stok
              </button>
            </div>`
          : ''
      }
    </div>

    <div class="tabs no-print">
      <button type="button" class="tab-btn ${activeTab === 'balances' ? 'active' : ''}" data-tab="balances">Saldo Stok Gudang</button>
      <button type="button" class="tab-btn ${activeTab === 'ledger' ? 'active' : ''}" data-tab="ledger">Kartu Stok (Mutasi)</button>
    </div>

    <div id="inventory-tab-body">${renderLoadingState()}</div>
  `;

  container.querySelectorAll('.tab-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      activeTab = btn.getAttribute('data-tab');
      container.querySelectorAll('.tab-btn').forEach((b) => b.classList.toggle('active', b === btn));
      loadActiveTab(ctx);
    });
  });

  if (canViewCost) {
    document.getElementById('btn-open-opening-stock')?.addEventListener('click', () => {
      openOpeningStockModal(ctx);
    });
  }

  await loadActiveTab(ctx);
}

async function loadActiveTab(ctx) {
  const bodyEl = document.getElementById('inventory-tab-body');
  if (!bodyEl) return;
  bodyEl.innerHTML = renderLoadingState();

  try {
    if (activeTab === 'balances') {
      await renderBalancesTab(bodyEl, ctx);
    } else {
      await renderLedgerTab(bodyEl, ctx);
    }
  } catch (err) {
    bodyEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

/* ============================================================================
   TAB 1: SALDO & NILAI PERSEDIAAN PER GUDANG
   ============================================================================ */
async function renderBalancesTab(bodyEl, ctx) {
  const canViewCost = canPerformAction(ctx.role, 'view_cogs_and_profit');

  const [whRes, valRes] = await Promise.all([
    supabase.from('warehouses').select('id, code, name').eq('is_active', true).order('name'),
    supabase
      .from('view_inventory_valuation')
      .select('*')
      .order('warehouse_name', { ascending: true })
      .order('product_name', { ascending: true })
  ]);

  const warehouses = unwrapResponse(whRes) || [];
  const allRows = unwrapResponse(valRes) || [];

  const filteredRows = allRows.filter((row) => {
    if (balanceFilters.warehouseId && row.warehouse_id !== balanceFilters.warehouseId) {
      return false;
    }
    if (balanceFilters.onlyLowStock && !row.is_low_stock) {
      return false;
    }
    if (balanceFilters.search) {
      const q = balanceFilters.search.toLowerCase();
      const matchSku = (row.sku || '').toLowerCase().includes(q);
      const matchName = (row.product_name || '').toLowerCase().includes(q);
      const matchBrand = (row.brand || '').toLowerCase().includes(q);
      if (!matchSku && !matchName && !matchBrand) return false;
    }
    return true;
  });

  const totalQty = filteredRows.reduce((sum, r) => sum + Number(r.qty_on_hand || 0), 0);
  const totalValue = filteredRows.reduce((sum, r) => sum + Number(r.total_value || 0), 0);
  const lowStockCount = filteredRows.filter((r) => r.is_low_stock).length;

  const whOptions =
    `<option value="">Semua Gudang</option>` +
    warehouses
      .map(
        (w) =>
          `<option value="${w.id}" ${balanceFilters.warehouseId === w.id ? 'selected' : ''}>${escapeHtml(w.name)}</option>`
      )
      .join('');

  const kpiHtml = canViewCost
    ? `
      <div class="grid-3" style="margin-bottom:1.25rem;">
        <div class="kpi-card">
          <span class="kpi-label">Total Kuantitas Stok</span>
          <span class="kpi-value">${formatNumber(totalQty)} Unit</span>
          <span class="kpi-sub">${filteredRows.length} baris SKU gudang</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Total Nilai Persediaan</span>
          <span class="kpi-value text-success">${formatRupiah(totalValue)}</span>
          <span class="kpi-sub">Metode Moving Weighted Average</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Item Stok Menipis</span>
          <span class="kpi-value ${lowStockCount > 0 ? 'text-danger' : ''}">${formatNumber(lowStockCount, 0)} Item</span>
          <span class="kpi-sub">Di bawah batas minimum stok</span>
        </div>
      </div>
    `
    : `
      <div class="grid-2" style="margin-bottom:1.25rem;">
        <div class="kpi-card">
          <span class="kpi-label">Total Kuantitas Stok</span>
          <span class="kpi-value">${formatNumber(totalQty)} Unit</span>
          <span class="kpi-sub">${filteredRows.length} baris SKU gudang</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Item Stok Menipis</span>
          <span class="kpi-value ${lowStockCount > 0 ? 'text-danger' : ''}">${formatNumber(lowStockCount, 0)} Item</span>
          <span class="kpi-sub">Perlu restok atau transfer gudang</span>
        </div>
      </div>
    `;

  const rowsHtml = filteredRows
    .map(
      (r) => `
      <tr>
        <td>${escapeHtml(r.warehouse_name)}</td>
        <td>
          <strong>${escapeHtml(r.sku)}</strong> - ${escapeHtml(r.product_name)}
          <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(r.brand || '-')}</div>
        </td>
        <td class="num font-semibold ${r.is_low_stock ? 'text-danger' : ''}">
          ${formatNumber(r.qty_on_hand)} ${escapeHtml(r.unit_code || '')}
        </td>
        <td class="num">${formatNumber(r.min_stock_alert)} ${escapeHtml(r.unit_code || '')}</td>
        ${
          canViewCost
            ? `<td class="num">${formatRupiah(r.avg_unit_cost)}</td>
               <td class="num font-semibold">${formatRupiah(r.total_value)}</td>`
            : ''
        }
        <td>
          <span class="badge ${r.is_low_stock ? 'badge-danger' : 'badge-success'}">
            ${r.is_low_stock ? 'Menipis' : 'Aman'}
          </span>
        </td>
      </tr>
    `
    )
    .join('');

  bodyEl.innerHTML = `
    <div class="filter-bar no-print">
      <div class="filter-item">
        <label for="bal-wh">Gudang</label>
        <select id="bal-wh" class="form-control">${whOptions}</select>
      </div>
      <div class="filter-item">
        <label for="bal-search">Cari SKU / Nama Produk</label>
        <input type="text" id="bal-search" class="form-control" value="${escapeHtml(balanceFilters.search)}" placeholder="Ketik SKU atau nama minuman..." />
      </div>
      <div class="filter-item" style="justify-content:flex-end;">
        <label style="display:flex;align-items:center;gap:0.4rem;cursor:pointer;margin-bottom:0.45rem;">
          <input type="checkbox" id="bal-low" ${balanceFilters.onlyLowStock ? 'checked' : ''} />
          <span>Hanya stok menipis</span>
        </label>
      </div>
    </div>

    ${kpiHtml}

    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Posisi Saldo Stok Saat Ini (${filteredRows.length} Baris)</h3>
      </div>
      ${
        filteredRows.length === 0
          ? `<div class="card-body">${renderEmptyState('Belum ada saldo stok. Gunakan "Input Saldo Awal Stok" atau "Penerimaan Barang" untuk menambah stok.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Gudang</th>
                    <th>Produk</th>
                    <th class="num">Stok Tersedia</th>
                    <th class="num">Min. Stok</th>
                    ${
                      canViewCost
                        ? `<th class="num">HPP Rata-Rata</th>
                           <th class="num">Nilai Persediaan</th>`
                        : ''
                    }
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>`
      }
    </div>
  `;

  document.getElementById('bal-wh')?.addEventListener('change', (e) => {
    balanceFilters.warehouseId = e.target.value;
    loadActiveTab(ctx);
  });

  document.getElementById('bal-low')?.addEventListener('change', (e) => {
    balanceFilters.onlyLowStock = e.target.checked;
    loadActiveTab(ctx);
  });

  let searchTimer = null;
  document.getElementById('bal-search')?.addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      balanceFilters.search = e.target.value.trim();
      loadActiveTab(ctx);
    }, 300);
  });
}

/* ============================================================================
   MODAL INPUT SALDO AWAL STOK (KHUSUS FINANCE ADMIN & OWNER)
   ============================================================================ */
async function openOpeningStockModal(ctx) {
  const [whRes, prodRes, unitRes] = await Promise.all([
    supabase.from('warehouses').select('id, code, name').eq('is_active', true).order('name'),
    supabase
      .from('products')
      .select('id, sku, name, base_unit_id')
      .eq('is_active', true)
      .order('name'),
    supabase.from('units').select('id, code, name')
  ]);

  const warehouses = unwrapResponse(whRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const unitMap = new Map(units.map((u) => [u.id, u]));

  if (warehouses.length === 0 || products.length === 0) {
    showToast('Pastikan minimal 1 Gudang dan 1 Produk aktif sudah terdaftar di Data Master.', 'warning');
    return;
  }

  const whOptions = warehouses
    .map((w) => `<option value="${w.id}">${escapeHtml(w.code)} - ${escapeHtml(w.name)}</option>`)
    .join('');

  const prodOptions = products
    .map((p) => {
      const u = unitMap.get(p.base_unit_id);
      return `<option value="${p.id}">${escapeHtml(p.sku)} - ${escapeHtml(p.name)} (${escapeHtml(u ? u.code : '-')})</option>`;
    })
    .join('');

  openModal({
    title: 'Input Saldo Awal Persediaan Gudang',
    bodyHtml: `
      <div class="alert alert-info">
        Fitur ini digunakan untuk mencatat stok awal fisik yang sudah ada di gudang sebelum transaksi berjalan. Sistem otomatis mencatat jurnal akuntansi saldo awal persediaan.
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="os-date">Tanggal Saldo Awal <span class="req">*</span></label>
          <input type="date" id="os-date" class="form-control" value="${getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="os-wh">Lokasi Gudang <span class="req">*</span></label>
          <select id="os-wh" class="form-control" required>${whOptions}</select>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="os-prod">Produk <span class="req">*</span></label>
        <select id="os-prod" class="form-control" required>${prodOptions}</select>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="os-qty">Jumlah Stok Awal (Karton / Galon) <span class="req">*</span></label>
          <input type="number" step="1" min="1" id="os-qty" class="form-control" placeholder="Contoh: 100" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="os-cost">Harga Pokok per Satuan (Rp) <span class="req">*</span></label>
          <input type="number" step="1" min="0" id="os-cost" class="form-control" placeholder="Contoh: 38000" required />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="os-notes">Catatan / Keterangan</label>
        <input type="text" id="os-notes" class="form-control" placeholder="Contoh: Saldo awal gudang per pembukaan sistem" />
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="os-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="os-save">Simpan Saldo Awal</button>
    `,
    onMount: () => {
      document.getElementById('os-cancel')?.addEventListener('click', closeModal);
      document.getElementById('os-save')?.addEventListener('click', async () => {
        const qty = Number(document.getElementById('os-qty').value || 0);
        const unitCost = Number(document.getElementById('os-cost').value || 0);

        if (qty <= 0) {
          showToast('Jumlah stok awal harus lebih dari nol.', 'warning');
          return;
        }
        if (unitCost < 0) {
          showToast('Harga pokok tidak boleh negatif.', 'warning');
          return;
        }

        const btn = document.getElementById('os-save');
        btn.disabled = true;

        try {
          await callRpc('rpc_record_opening_stock', {
            p_movement_date: document.getElementById('os-date').value,
            p_warehouse_id: document.getElementById('os-wh').value,
            p_product_id: document.getElementById('os-prod').value,
            p_qty: qty,
            p_unit_cost: unitCost,
            p_notes: document.getElementById('os-notes').value.trim() || null
          });
          closeModal();
          showToast('Saldo awal persediaan dan jurnal berhasil dicatat.', 'success');
          await loadActiveTab(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

/* ============================================================================
   TAB 2: KARTU STOK (RIWAYAT PERGERAKAN STOK / STOCK MOVEMENT LEDGER)
   ============================================================================ */
async function renderLedgerTab(bodyEl, ctx) {
  const canViewCost = canPerformAction(ctx.role, 'view_cogs_and_profit');

  const [whRes, prodRes, unitRes] = await Promise.all([
    supabase.from('warehouses').select('id, name').order('name'),
    supabase.from('products').select('id, sku, name').order('name'),
    supabase.from('units').select('id, code')
  ]);

  const warehouses = unwrapResponse(whRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];

  const whMap = new Map(warehouses.map((w) => [w.id, w.name]));
  const prodMap = new Map(products.map((p) => [p.id, `${p.sku} - ${p.name}`]));
  const unitMap = new Map(units.map((u) => [u.id, u.code]));

  const fromIdx = (ledgerFilterState.page - 1) * ledgerFilterState.pageSize;
  const toIdx = fromIdx + ledgerFilterState.pageSize - 1;

  let query = supabase
    .from('stock_movements')
    .select('*', { count: 'exact' })
    .order('movement_date', { ascending: false })
    .order('created_at', { ascending: false })
    .range(fromIdx, toIdx);

  if (ledgerFilterState.startDate) {
    query = query.gte('movement_date', ledgerFilterState.startDate);
  }
  if (ledgerFilterState.endDate) {
    query = query.lte('movement_date', ledgerFilterState.endDate);
  }
  if (ledgerFilterState.warehouseId) {
    query = query.eq('warehouse_id', ledgerFilterState.warehouseId);
  }
  if (ledgerFilterState.productId) {
    query = query.eq('product_id', ledgerFilterState.productId);
  }
  if (ledgerFilterState.movementType) {
    query = query.eq('movement_type', ledgerFilterState.movementType);
  }

  const res = await query;
  const movements = res.data || [];
  const totalCount = res.count || 0;
  if (res.error) throw new Error(res.error.message);

  const whOpts =
    `<option value="">Semua Gudang</option>` +
    warehouses
      .map(
        (w) =>
          `<option value="${w.id}" ${ledgerFilterState.warehouseId === w.id ? 'selected' : ''}>${escapeHtml(w.name)}</option>`
      )
      .join('');

  const prodOpts =
    `<option value="">Semua Produk</option>` +
    products
      .map(
        (p) =>
          `<option value="${p.id}" ${ledgerFilterState.productId === p.id ? 'selected' : ''}>${escapeHtml(p.sku)} - ${escapeHtml(p.name)}</option>`
      )
      .join('');

  const typeOpts =
    `<option value="">Semua Jenis Mutasi</option>` +
    Object.entries(MOVEMENT_TYPE_LABELS)
      .map(
        ([key, label]) =>
          `<option value="${key}" ${ledgerFilterState.movementType === key ? 'selected' : ''}>${escapeHtml(label)}</option>`
      )
      .join('');

  const rowsHtml = movements
    .map((m) => {
      const isIn = Number(m.direction) === 1;
      const unitCode = unitMap.get(m.unit_id) || '';
      const typeLabel = MOVEMENT_TYPE_LABELS[m.movement_type] || m.movement_type;

      return `
        <tr>
          <td>${formatDateID(m.movement_date)}</td>
          <td>${escapeHtml(whMap.get(m.warehouse_id) || '-')}</td>
          <td><strong>${escapeHtml(prodMap.get(m.product_id) || '-')}</strong></td>
          <td>
            <div>${escapeHtml(typeLabel)}</div>
            <div class="text-muted" style="font-size:0.8rem;">Doc: ${escapeHtml(m.source_number || '-')}</div>
          </td>
          <td class="num text-success font-semibold">${isIn ? '+' + formatNumber(m.qty_base) + ' ' + escapeHtml(unitCode) : '-'}</td>
          <td class="num text-danger font-semibold">${!isIn ? '-' + formatNumber(m.qty_base) + ' ' + escapeHtml(unitCode) : '-'}</td>
          <td class="num font-semibold">${formatNumber(m.balance_qty_after)} ${escapeHtml(unitCode)}</td>
          ${
            canViewCost
              ? `<td class="num">${formatRupiah(m.unit_cost)}</td>
                 <td class="num">${formatRupiah(m.balance_value_after)}</td>`
              : ''
          }
          <td>${escapeHtml(m.notes || '-')}</td>
        </tr>
      `;
    })
    .join('');

  const totalPages = Math.max(1, Math.ceil(totalCount / ledgerFilterState.pageSize));

  bodyEl.innerHTML = `
    <div id="ledger-period-bar"></div>

    <div class="filter-bar no-print">
      <div class="filter-item">
        <label for="ld-wh">Gudang</label>
        <select id="ld-wh" class="form-control">${whOpts}</select>
      </div>
      <div class="filter-item">
        <label for="ld-prod">Produk</label>
        <select id="ld-prod" class="form-control">${prodOpts}</select>
      </div>
      <div class="filter-item">
        <label for="ld-type">Jenis Pergerakan</label>
        <select id="ld-type" class="form-control">${typeOpts}</select>
      </div>
    </div>

    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Riwayat Kartu Stok (${formatNumber(totalCount, 0)} Mutasi)</h3>
      </div>
      ${
        movements.length === 0
          ? `<div class="card-body">${renderEmptyState('Tidak ada pergerakan stok pada periode dan filter yang dipilih.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Tanggal</th>
                    <th>Gudang</th>
                    <th>Produk</th>
                    <th>Jenis & Referensi</th>
                    <th class="num">Masuk</th>
                    <th class="num">Keluar</th>
                    <th class="num">Saldo Akhir</th>
                    ${
                      canViewCost
                        ? `<th class="num">HPP Satuan</th>
                           <th class="num">Nilai Saldo</th>`
                        : ''
                    }
                    <th>Catatan</th>
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>
            <div class="card-body no-print" style="display:flex;justify-content:space-between;align-items:center;border-top:1px solid var(--color-border);">
              <span class="text-muted">Halaman ${ledgerFilterState.page} dari ${totalPages}</span>
              <div style="display:flex;gap:0.5rem;">
                <button type="button" class="btn btn-secondary btn-sm" id="ld-prev" ${ledgerFilterState.page <= 1 ? 'disabled' : ''}>Sebelumnya</button>
                <button type="button" class="btn btn-secondary btn-sm" id="ld-next" ${ledgerFilterState.page >= totalPages ? 'disabled' : ''}>Berikutnya</button>
              </div>
            </div>`
      }
    </div>
  `;

  renderPeriodFilterBar('ledger-period-bar', ledgerFilterState, async (nextPeriod) => {
    ledgerFilterState = {
      ...ledgerFilterState,
      ...nextPeriod,
      page: 1
    };
    await loadActiveTab(ctx);
  });

  document.getElementById('ld-wh')?.addEventListener('change', (e) => {
    ledgerFilterState.warehouseId = e.target.value;
    ledgerFilterState.page = 1;
    loadActiveTab(ctx);
  });

  document.getElementById('ld-prod')?.addEventListener('change', (e) => {
    ledgerFilterState.productId = e.target.value;
    ledgerFilterState.page = 1;
    loadActiveTab(ctx);
  });

  document.getElementById('ld-type')?.addEventListener('change', (e) => {
    ledgerFilterState.movementType = e.target.value;
    ledgerFilterState.page = 1;
    loadActiveTab(ctx);
  });

  document.getElementById('ld-prev')?.addEventListener('click', () => {
    if (ledgerFilterState.page > 1) {
      ledgerFilterState.page -= 1;
      loadActiveTab(ctx);
    }
  });

  document.getElementById('ld-next')?.addEventListener('click', () => {
    if (ledgerFilterState.page < totalPages) {
      ledgerFilterState.page += 1;
      loadActiveTab(ctx);
    }
  });
}
