/**
 * Modul Pencatatan & Riwayat Barang Rusak (Gudang & Pengiriman)
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

let filterState = {
  preset: 'this_month',
  ...getPeriodRange('this_month'),
  warehouseId: '',
  sourceType: ''
};

export async function renderModule(container, ctx) {
  const canRecord = canPerformAction(ctx.role, 'record_warehouse_damage');

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Pencatatan Barang Rusak</h2>
        <p>Log barang rusak di gudang maupun rusak selama proses pengiriman agar tidak terjadi pemotongan stok ganda</p>
      </div>
      ${
        canRecord
          ? `<div class="page-actions no-print">
              <button type="button" class="btn btn-primary" id="btn-record-damage">
                <span class="material-symbols-outlined">broken_image</span>
                Catat Barang Rusak Gudang
              </button>
            </div>`
          : ''
      }
    </div>

    <div id="dmg-period-bar"></div>
    <div id="dmg-extra-filters"></div>
    <div id="dmg-list-body">${renderLoadingState()}</div>
  `;

  renderPeriodFilterBar('dmg-period-bar', filterState, async (nextFilter) => {
    filterState = { ...filterState, ...nextFilter };
    await loadDamagedGoods(ctx);
  });

  if (canRecord) {
    document.getElementById('btn-record-damage')?.addEventListener('click', () => {
      openRecordDamageModal(ctx);
    });
  }

  await loadDamagedGoods(ctx);
}

async function loadDamagedGoods(ctx) {
  const listEl = document.getElementById('dmg-list-body');
  const extraFilterEl = document.getElementById('dmg-extra-filters');
  if (!listEl) return;

  listEl.innerHTML = renderLoadingState();
  const canViewCost = canPerformAction(ctx.role, 'view_cogs_and_profit');

  try {
    const [whRes, prodRes, unitRes, profilesRes] = await Promise.all([
      supabase.from('warehouses').select('id, code, name').order('name'),
      supabase.from('products').select('id, sku, name').order('name'),
      supabase.from('units').select('id, code'),
      supabase.from('profiles').select('id, full_name')
    ]);

    const warehouses = unwrapResponse(whRes) || [];
    const products = unwrapResponse(prodRes) || [];
    const units = unwrapResponse(unitRes) || [];
    const profiles = unwrapResponse(profilesRes) || [];

    const whMap = new Map(warehouses.map((w) => [w.id, w.name]));
    const prodMap = new Map(products.map((p) => [p.id, `${p.sku} - ${p.name}`]));
    const unitMap = new Map(units.map((u) => [u.id, u.code]));
    const profileMap = new Map(profiles.map((p) => [p.id, p.full_name]));

    let query = supabase
      .from('damaged_goods')
      .select('*')
      .order('damage_date', { ascending: false })
      .order('created_at', { ascending: false });

    if (filterState.startDate) {
      query = query.gte('damage_date', filterState.startDate);
    }
    if (filterState.endDate) {
      query = query.lte('damage_date', filterState.endDate);
    }
    if (filterState.warehouseId) {
      query = query.eq('warehouse_id', filterState.warehouseId);
    }
    if (filterState.sourceType) {
      query = query.eq('source_type', filterState.sourceType);
    }

    const records = unwrapResponse(await query) || [];

    if (extraFilterEl) {
      const whOpts =
        `<option value="">Semua Gudang</option>` +
        warehouses
          .map(
            (w) =>
              `<option value="${w.id}" ${filterState.warehouseId === w.id ? 'selected' : ''}>${escapeHtml(w.name)}</option>`
          )
          .join('');

      extraFilterEl.innerHTML = `
        <div class="filter-bar no-print">
          <div class="filter-item">
            <label for="dmg-wh-filter">Gudang</label>
            <select id="dmg-wh-filter" class="form-control">${whOpts}</select>
          </div>
          <div class="filter-item">
            <label for="dmg-src-filter">Sumber Kejadian</label>
            <select id="dmg-src-filter" class="form-control">
              <option value="" ${filterState.sourceType === '' ? 'selected' : ''}>Semua Sumber</option>
              <option value="warehouse" ${filterState.sourceType === 'warehouse' ? 'selected' : ''}>Kerusakan di Gudang</option>
              <option value="delivery" ${filterState.sourceType === 'delivery' ? 'selected' : ''}>Rusak Saat Pengiriman</option>
              <option value="sales_return" ${filterState.sourceType === 'sales_return' ? 'selected' : ''}>Retur Barang Rusak</option>
            </select>
          </div>
        </div>
      `;

      document.getElementById('dmg-wh-filter')?.addEventListener('change', (e) => {
        filterState.warehouseId = e.target.value;
        loadDamagedGoods(ctx);
      });
      document.getElementById('dmg-src-filter')?.addEventListener('change', (e) => {
        filterState.sourceType = e.target.value;
        loadDamagedGoods(ctx);
      });
    }

    const totalQty = records.reduce((sum, r) => sum + Number(r.qty || 0), 0);
    const totalLossCost = records.reduce((sum, r) => sum + Number(r.total_cost || 0), 0);

    const kpiHtml = canViewCost
      ? `
        <div class="grid-3" style="margin-bottom:1.25rem;">
          <div class="kpi-card">
            <span class="kpi-label">Jumlah Laporan Rusak</span>
            <span class="kpi-value">${formatNumber(records.length, 0)} Dokumen</span>
            <span class="kpi-sub">Sesuai periode terpilih</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Total Kuantitas Rusak</span>
            <span class="kpi-value text-danger">${formatNumber(totalQty)} Unit</span>
            <span class="kpi-sub">Karton / Galon rusak</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Total Nilai Kerugian (HPP)</span>
            <span class="kpi-value text-danger">${formatRupiah(totalLossCost)}</span>
            <span class="kpi-sub">Tercatat pada beban kerugian persediaan</span>
          </div>
        </div>
      `
      : `
        <div class="grid-2" style="margin-bottom:1.25rem;">
          <div class="kpi-card">
            <span class="kpi-label">Jumlah Laporan Rusak</span>
            <span class="kpi-value">${formatNumber(records.length, 0)} Dokumen</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Total Kuantitas Rusak</span>
            <span class="kpi-value text-danger">${formatNumber(totalQty)} Unit</span>
          </div>
        </div>
      `;

    const sourceLabelMap = {
      warehouse: 'Gudang Internal',
      delivery: 'Pengiriman SO',
      sales_return: 'Retur Pelanggan'
    };

    const rowsHtml = records
      .map((r) => {
        const unitCode = unitMap.get(r.unit_id) || '';
        const srcLabel = sourceLabelMap[r.source_type] || r.source_type;
        return `
          <tr>
            <td><strong>${escapeHtml(r.damage_number)}</strong></td>
            <td>${formatDateID(r.damage_date)}</td>
            <td>${escapeHtml(whMap.get(r.warehouse_id) || '-')}</td>
            <td><strong>${escapeHtml(prodMap.get(r.product_id) || '-')}</strong></td>
            <td>
              <span class="badge ${r.source_type === 'delivery' ? 'badge-warning' : 'badge-neutral'}">
                ${escapeHtml(srcLabel)}
              </span>
              ${r.source_number ? `<div class="text-muted" style="font-size:0.8rem;">Ref: ${escapeHtml(r.source_number)}</div>` : ''}
            </td>
            <td class="num text-danger font-semibold">${formatNumber(r.qty)} ${escapeHtml(unitCode)}</td>
            ${
              canViewCost
                ? `<td class="num">${formatRupiah(r.total_cost)}</td>`
                : ''
            }
            <td>${escapeHtml(r.reason || '-')}</td>
            <td>${escapeHtml(profileMap.get(r.reported_by) || '-')}</td>
          </tr>
        `;
      })
      .join('');

    listEl.innerHTML = `
      ${kpiHtml}
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Riwayat Barang Rusak (${records.length} Catatan)</h3>
        </div>
        ${
          records.length === 0
            ? `<div class="card-body">${renderEmptyState('Belum ada catatan barang rusak pada periode ini.')}</div>`
            : `<div class="table-responsive">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>No. Dokumen</th>
                      <th>Tanggal</th>
                      <th>Gudang</th>
                      <th>Produk</th>
                      <th>Sumber</th>
                      <th class="num">Qty Rusak</th>
                      ${canViewCost ? '<th class="num">Nilai HPP</th>' : ''}
                      <th>Penyebab / Keterangan</th>
                      <th>Pelapor</th>
                    </tr>
                  </thead>
                  <tbody>${rowsHtml}</tbody>
                </table>
              </div>`
        }
      </div>
    `;
  } catch (err) {
    listEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

async function openRecordDamageModal(ctx) {
  const [whRes, prodRes, unitRes, balRes] = await Promise.all([
    supabase.from('warehouses').select('id, code, name').eq('is_active', true).order('name'),
    supabase
      .from('products')
      .select('id, sku, name, base_unit_id')
      .eq('is_active', true)
      .order('name'),
    supabase.from('units').select('id, code'),
    supabase.from('stock_balances').select('warehouse_id, product_id, qty_on_hand')
  ]);

  const warehouses = unwrapResponse(whRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const balances = unwrapResponse(balRes) || [];

  if (warehouses.length === 0 || products.length === 0) {
    showToast('Pastikan minimal 1 Gudang dan 1 Produk aktif sudah terdaftar di Data Master.', 'warning');
    return;
  }

  const unitMap = new Map(units.map((u) => [u.id, u]));
  const productMap = new Map(products.map((p) => [p.id, p]));
  const balanceMap = new Map(
    balances.map((b) => [`${b.warehouse_id}_${b.product_id}`, Number(b.qty_on_hand || 0)])
  );

  const whOpts = warehouses
    .map((w) => `<option value="${w.id}">${escapeHtml(w.code)} - ${escapeHtml(w.name)}</option>`)
    .join('');

  const prodOpts = products
    .map((p) => {
      const u = unitMap.get(p.base_unit_id);
      return `<option value="${p.id}">${escapeHtml(p.sku)} - ${escapeHtml(p.name)} (${escapeHtml(u ? u.code : '-')})</option>`;
    })
    .join('');

  openModal({
    title: 'Catat Barang Rusak di Gudang',
    bodyHtml: `
      <div class="alert alert-warning">
        Pencatatan ini akan langsung mengurangi saldo stok layak jual di gudang terpilih dan mencatat beban kerugian barang rusak secara otomatis.
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="dm-date">Tanggal Kejadian <span class="req">*</span></label>
          <input type="date" id="dm-date" class="form-control" value="${getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="dm-wh">Lokasi Gudang <span class="req">*</span></label>
          <select id="dm-wh" class="form-control">${whOpts}</select>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="dm-prod">Produk Rusak <span class="req">*</span></label>
        <select id="dm-prod" class="form-control">${prodOpts}</select>
        <span class="form-help" id="dm-avail-info">Stok layak jual tersedia: -</span>
      </div>
      <div class="form-group">
        <label class="form-label" for="dm-qty">Jumlah Barang Rusak (Karton / Galon) <span class="req">*</span></label>
        <input type="number" step="1" min="1" id="dm-qty" class="form-control" placeholder="Contoh: 2" required />
      </div>
      <div class="form-group">
        <label class="form-label" for="dm-reason">Penyebab Kerusakan <span class="req">*</span></label>
        <input type="text" id="dm-reason" class="form-control" placeholder="Contoh: Kemasan bocor / galon retak di gudang" required />
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="dm-cancel">Batal</button>
      <button type="button" class="btn btn-danger" id="dm-save">Simpan & Potong Stok</button>
    `,
    onMount: () => {
      const whEl = document.getElementById('dm-wh');
      const prodEl = document.getElementById('dm-prod');
      const availInfoEl = document.getElementById('dm-avail-info');

      const updateAvailText = () => {
        const avail = balanceMap.get(`${whEl.value}_${prodEl.value}`) || 0;
        const prod = productMap.get(prodEl.value);
        const unitCode = unitMap.get(prod?.base_unit_id)?.code || '';
        availInfoEl.textContent = `Stok layak jual tersedia di gudang ini: ${formatNumber(avail)} ${unitCode}`;
      };

      updateAvailText();
      whEl.addEventListener('change', updateAvailText);
      prodEl.addEventListener('change', updateAvailText);

      document.getElementById('dm-cancel')?.addEventListener('click', closeModal);
      document.getElementById('dm-save')?.addEventListener('click', async () => {
        const qty = Number(document.getElementById('dm-qty').value || 0);
        const reason = document.getElementById('dm-reason').value.trim();

        if (qty <= 0) {
          showToast('Jumlah barang rusak harus lebih dari nol.', 'warning');
          return;
        }
        if (!reason) {
          showToast('Penyebab kerusakan wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('dm-save');
        btn.disabled = true;

        try {
          await callRpc('rpc_record_warehouse_damage', {
            p_damage_date: document.getElementById('dm-date').value,
            p_warehouse_id: whEl.value,
            p_product_id: prodEl.value,
            p_qty: qty,
            p_reason: reason
          });
          closeModal();
          showToast('Laporan barang rusak berhasil dicatat dan stok telah dikurangi.', 'success');
          await loadDamagedGoods(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}
