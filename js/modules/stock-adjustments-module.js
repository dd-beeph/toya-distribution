/**
 * Modul Penyesuaian Stok & Stock Opname (Pengajuan Gudang & Persetujuan Finance/Owner)
 */

import { supabase } from '../config/supabase-client.js';
import { canPerformAction } from '../auth/permission-guard.js';
import { callRpc, unwrapResponse } from '../services/base-service.js';
import { formatDateID, formatDateTimeID, getJakartaToday, getPeriodRange } from '../utils/date-utils.js';
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
  warehouseId: '',
  status: ''
};

export async function renderModule(container, ctx) {
  const canRequest = canPerformAction(ctx.role, 'request_stock_adjustment');

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Penyesuaian Stok (Stock Opname)</h2>
        <p>Pengajuan koreksi selisih stok fisik gudang dengan persetujuan Finance Admin atau Owner</p>
      </div>
      ${
        canRequest
          ? `<div class="page-actions no-print">
              <button type="button" class="btn btn-primary" id="btn-new-adjustment">
                <span class="material-symbols-outlined">tune</span>
                Ajukan Penyesuaian Stok
              </button>
            </div>`
          : ''
      }
    </div>

    <div id="adj-period-bar"></div>
    <div id="adj-extra-filters"></div>
    <div id="adj-list-body">${renderLoadingState()}</div>
  `;

  renderPeriodFilterBar('adj-period-bar', filterState, async (nextFilter) => {
    filterState = { ...filterState, ...nextFilter };
    await loadAdjustments(ctx);
  });

  if (canRequest) {
    document.getElementById('btn-new-adjustment')?.addEventListener('click', () => {
      openNewAdjustmentModal(ctx);
    });
  }

  await loadAdjustments(ctx);
}

async function loadAdjustments(ctx) {
  const listEl = document.getElementById('adj-list-body');
  const extraFilterEl = document.getElementById('adj-extra-filters');
  if (!listEl) return;

  listEl.innerHTML = renderLoadingState();

  try {
    const [whRes, profilesRes] = await Promise.all([
      supabase.from('warehouses').select('id, code, name').order('name'),
      supabase.from('profiles').select('id, full_name')
    ]);

    const warehouses = unwrapResponse(whRes) || [];
    const profiles = unwrapResponse(profilesRes) || [];
    const whMap = new Map(warehouses.map((w) => [w.id, w.name]));
    const profileMap = new Map(profiles.map((p) => [p.id, p.full_name]));

    let query = supabase
      .from('stock_adjustment_requests')
      .select('*')
      .order('adjustment_date', { ascending: false })
      .order('created_at', { ascending: false });

    if (filterState.startDate) {
      query = query.gte('adjustment_date', filterState.startDate);
    }
    if (filterState.endDate) {
      query = query.lte('adjustment_date', filterState.endDate);
    }
    if (filterState.warehouseId) {
      query = query.eq('warehouse_id', filterState.warehouseId);
    }
    if (filterState.status) {
      query = query.eq('status', filterState.status);
    }

    const adjustments = unwrapResponse(await query) || [];

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
            <label for="adj-wh-filter">Gudang</label>
            <select id="adj-wh-filter" class="form-control">${whOpts}</select>
          </div>
          <div class="filter-item">
            <label for="adj-status-filter">Status Pengajuan</label>
            <select id="adj-status-filter" class="form-control">
              <option value="" ${filterState.status === '' ? 'selected' : ''}>Semua Status</option>
              <option value="pending" ${filterState.status === 'pending' ? 'selected' : ''}>Menunggu Persetujuan</option>
              <option value="approved" ${filterState.status === 'approved' ? 'selected' : ''}>Disetujui</option>
              <option value="rejected" ${filterState.status === 'rejected' ? 'selected' : ''}>Ditolak</option>
            </select>
          </div>
        </div>
      `;

      document.getElementById('adj-wh-filter')?.addEventListener('change', (e) => {
        filterState.warehouseId = e.target.value;
        loadAdjustments(ctx);
      });
      document.getElementById('adj-status-filter')?.addEventListener('change', (e) => {
        filterState.status = e.target.value;
        loadAdjustments(ctx);
      });
    }

    const rowsHtml = adjustments
      .map(
        (adj) => `
        <tr>
          <td><strong>${escapeHtml(adj.adjustment_number)}</strong></td>
          <td>${formatDateID(adj.adjustment_date)}</td>
          <td>${escapeHtml(whMap.get(adj.warehouse_id) || '-')}</td>
          <td>${escapeHtml(adj.reason || '-')}</td>
          <td>${escapeHtml(profileMap.get(adj.requested_by) || '-')}</td>
          <td>${renderStatusBadge(adj.status)}</td>
          <td class="text-right">
            <button type="button" class="btn btn-secondary btn-sm" data-view-adj="${adj.id}">
              ${adj.status === 'pending' ? 'Tinjau / Detail' : 'Lihat Detail'}
            </button>
          </td>
        </tr>
      `
      )
      .join('');

    listEl.innerHTML = `
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Daftar Pengajuan Penyesuaian Stok (${adjustments.length} Dokumen)</h3>
        </div>
        ${
          adjustments.length === 0
            ? `<div class="card-body">${renderEmptyState('Belum ada pengajuan penyesuaian stok pada periode ini.')}</div>`
            : `<div class="table-responsive">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>No. Dokumen</th>
                      <th>Tanggal Opname</th>
                      <th>Gudang</th>
                      <th>Alasan Penyesuaian</th>
                      <th>Diajukan Oleh</th>
                      <th>Status</th>
                      <th class="text-right">Tindakan</th>
                    </tr>
                  </thead>
                  <tbody>${rowsHtml}</tbody>
                </table>
              </div>`
        }
      </div>
    `;

    listEl.querySelectorAll('[data-view-adj]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const adj = adjustments.find((item) => item.id === btn.getAttribute('data-view-adj'));
        if (adj) {
          openAdjustmentDetailModal(adj, whMap, profileMap, ctx);
        }
      });
    });
  } catch (err) {
    listEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

async function openNewAdjustmentModal(ctx) {
  const [whRes, prodRes, unitRes, balRes] = await Promise.all([
    supabase.from('warehouses').select('id, code, name').eq('is_active', true).order('name'),
    supabase
      .from('products')
      .select('id, sku, name, base_unit_id')
      .eq('is_active', true)
      .order('name'),
    supabase.from('units').select('id, code'),
    supabase.from('stock_balances').select('warehouse_id, product_id, qty_on_hand, avg_unit_cost')
  ]);

  const warehouses = unwrapResponse(whRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const balances = unwrapResponse(balRes) || [];

  if (warehouses.length === 0 || products.length === 0) {
    showToast('Pastikan minimal 1 Gudang dan 1 Produk aktif sudah tersedia di Data Master.', 'warning');
    return;
  }

  const unitMap = new Map(units.map((u) => [u.id, u]));
  const productMap = new Map(products.map((p) => [p.id, p]));
  const balanceMap = new Map(
    balances.map((b) => [`${b.warehouse_id}_${b.product_id}`, b])
  );

  const whOpts = warehouses
    .map((w) => `<option value="${w.id}">${escapeHtml(w.code)} - ${escapeHtml(w.name)}</option>`)
    .join('');

  const getSysQty = (whId, prodId) => {
    const bal = balanceMap.get(`${whId}_${prodId}`);
    return Number(bal?.qty_on_hand || 0);
  };

  let lineItems = [
    {
      product_id: products[0].id,
      actual_qty: getSysQty(warehouses[0].id, products[0].id),
      notes: ''
    }
  ];

  openModal({
    title: 'Ajukan Penyesuaian Stok (Stock Opname)',
    size: 'lg',
    bodyHtml: `
      <div class="alert alert-info">
        Masukkan jumlah stok fisik hasil penghitungan nyata di gudang. Saldo stok dan jurnal selisih opname baru akan berubah setelah disetujui oleh Finance Admin atau Owner.
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="na-date">Tanggal Stock Opname <span class="req">*</span></label>
          <input type="date" id="na-date" class="form-control" value="${getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="na-wh">Lokasi Gudang <span class="req">*</span></label>
          <select id="na-wh" class="form-control">${whOpts}</select>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="na-reason">Alasan / Keterangan Opname <span class="req">*</span></label>
        <input type="text" id="na-reason" class="form-control" placeholder="Contoh: Hasil Stock Opname Akhir Bulan" required />
      </div>

      <div style="display:flex;justify-content:space-between;align-items:center;margin:1rem 0 0.5rem;">
        <strong>Rincian Barang yang Disesuaikan</strong>
        <button type="button" class="btn btn-secondary btn-sm" id="na-add-row">+ Tambah Produk</button>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Stok Sistem</th>
              <th class="num" style="width:130px;">Stok Fisik</th>
              <th class="num">Selisih</th>
              <th>Catatan</th>
              <th style="width:50px;"></th>
            </tr>
          </thead>
          <tbody id="na-items-body"></tbody>
        </table>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="na-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="na-save">Kirim Pengajuan Opname</button>
    `,
    onMount: () => {
      const whSelect = document.getElementById('na-wh');

      const renderRows = () => {
        const tbody = document.getElementById('na-items-body');
        if (!tbody) return;
        const currentWh = whSelect.value;

        tbody.innerHTML = lineItems
          .map((item, idx) => {
            const sysQty = getSysQty(currentWh, item.product_id);
            const diff = Number(item.actual_qty || 0) - sysQty;
            const prod = productMap.get(item.product_id);
            const unitCode = unitMap.get(prod?.base_unit_id)?.code || '';

            const prodOpts = products
              .map(
                (p) =>
                  `<option value="${p.id}" ${p.id === item.product_id ? 'selected' : ''}>${escapeHtml(p.sku)} - ${escapeHtml(p.name)}</option>`
              )
              .join('');

            const diffClass = diff > 0 ? 'text-success' : diff < 0 ? 'text-danger' : 'text-muted';
            const diffPrefix = diff > 0 ? '+' : '';

            return `
              <tr>
                <td>
                  <select class="form-control" data-adj-prod="${idx}">${prodOpts}</select>
                </td>
                <td class="num">${formatNumber(sysQty)} ${escapeHtml(unitCode)}</td>
                <td>
                  <input type="number" step="1" min="0" class="form-control num" data-adj-actual="${idx}" value="${item.actual_qty}" />
                </td>
                <td class="num font-semibold ${diffClass}" id="adj-diff-cell-${idx}">
                  ${diffPrefix}${formatNumber(diff)} ${escapeHtml(unitCode)}
                </td>
                <td>
                  <input type="text" class="form-control" data-adj-note="${idx}" value="${escapeHtml(item.notes || '')}" placeholder="Opsional" />
                </td>
                <td class="text-right">
                  ${
                    lineItems.length > 1
                      ? `<button type="button" class="btn btn-ghost btn-sm text-danger" data-adj-del="${idx}">&times;</button>`
                      : ''
                  }
                </td>
              </tr>
            `;
          })
          .join('');

        tbody.querySelectorAll('[data-adj-prod]').forEach((el) => {
          el.addEventListener('change', (e) => {
            const idx = Number(e.target.getAttribute('data-adj-prod'));
            const newProdId = e.target.value;
            lineItems[idx].product_id = newProdId;
            lineItems[idx].actual_qty = getSysQty(whSelect.value, newProdId);
            renderRows();
          });
        });

        tbody.querySelectorAll('[data-adj-actual]').forEach((el) => {
          el.addEventListener('input', (e) => {
            const idx = Number(e.target.getAttribute('data-adj-actual'));
            const newActual = Number(e.target.value || 0);
            lineItems[idx].actual_qty = newActual;

            const sysQty = getSysQty(whSelect.value, lineItems[idx].product_id);
            const diff = newActual - sysQty;
            const prod = productMap.get(lineItems[idx].product_id);
            const unitCode = unitMap.get(prod?.base_unit_id)?.code || '';
            const cell = document.getElementById(`adj-diff-cell-${idx}`);
            if (cell) {
              cell.className = `num font-semibold ${diff > 0 ? 'text-success' : diff < 0 ? 'text-danger' : 'text-muted'}`;
              cell.textContent = `${diff > 0 ? '+' : ''}${formatNumber(diff)} ${unitCode}`;
            }
          });
        });

        tbody.querySelectorAll('[data-adj-note]').forEach((el) => {
          el.addEventListener('input', (e) => {
            const idx = Number(e.target.getAttribute('data-adj-note'));
            lineItems[idx].notes = e.target.value;
          });
        });

        tbody.querySelectorAll('[data-adj-del]').forEach((el) => {
          el.addEventListener('click', (e) => {
            const idx = Number(e.target.getAttribute('data-adj-del'));
            lineItems.splice(idx, 1);
            renderRows();
          });
        });
      };

      renderRows();

      whSelect.addEventListener('change', () => {
        lineItems = lineItems.map((item) => ({
          ...item,
          actual_qty: getSysQty(whSelect.value, item.product_id)
        }));
        renderRows();
      });

      document.getElementById('na-add-row')?.addEventListener('click', () => {
        const unusedProduct =
          products.find((p) => !lineItems.some((item) => item.product_id === p.id)) || products[0];
        lineItems.push({
          product_id: unusedProduct.id,
          actual_qty: getSysQty(whSelect.value, unusedProduct.id),
          notes: ''
        });
        renderRows();
      });

      document.getElementById('na-cancel')?.addEventListener('click', closeModal);
      document.getElementById('na-save')?.addEventListener('click', async () => {
        const reason = document.getElementById('na-reason').value.trim();
        const whId = whSelect.value;

        if (!reason) {
          showToast('Alasan penyesuaian stok wajib diisi.', 'warning');
          return;
        }

        const seenProducts = new Set();
        let hasNonZeroDiff = false;

        for (const item of lineItems) {
          if (seenProducts.has(item.product_id)) {
            showToast('Terdapat produk yang dipilih ganda. Gabungkan menjadi satu baris.', 'warning');
            return;
          }
          seenProducts.add(item.product_id);

          if (item.actual_qty < 0) {
            showToast('Stok fisik tidak boleh bernilai negatif.', 'warning');
            return;
          }

          const sysQty = getSysQty(whId, item.product_id);
          if (item.actual_qty !== sysQty) {
            hasNonZeroDiff = true;
          }
        }

        if (!hasNonZeroDiff) {
          showToast('Minimal satu produk harus memiliki selisih antara stok sistem dan stok fisik.', 'warning');
          return;
        }

        const btn = document.getElementById('na-save');
        btn.disabled = true;

        try {
          const header = unwrapResponse(
            await supabase
              .from('stock_adjustment_requests')
              .insert({
                adjustment_date: document.getElementById('na-date').value,
                warehouse_id: whId,
                reason,
                status: 'pending',
                requested_by: ctx.user.id
              })
              .select()
              .single()
          );

          const itemsPayload = lineItems.map((item) => {
            const prod = productMap.get(item.product_id);
            const bal = balanceMap.get(`${whId}_${item.product_id}`);
            return {
              adjustment_id: header.id,
              product_id: item.product_id,
              unit_id: prod.base_unit_id,
              system_qty: Number(bal?.qty_on_hand || 0),
              actual_qty: Number(item.actual_qty || 0),
              unit_cost: Number(bal?.avg_unit_cost || 0),
              notes: item.notes.trim() || null
            };
          });

          unwrapResponse(await supabase.from('stock_adjustment_items').insert(itemsPayload));

          closeModal();
          showToast(`Pengajuan opname ${header.adjustment_number} berhasil dikirim.`, 'success');
          await loadAdjustments(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

async function openAdjustmentDetailModal(adj, whMap, profileMap, ctx) {
  const canApprove = canPerformAction(ctx.role, 'approve_stock_adjustment');
  const canViewCost = canPerformAction(ctx.role, 'view_cogs_and_profit');

  const [itemsRes, prodRes, unitRes] = await Promise.all([
    supabase.from('stock_adjustment_items').select('*').eq('adjustment_id', adj.id),
    supabase.from('products').select('id, sku, name'),
    supabase.from('units').select('id, code')
  ]);

  const items = unwrapResponse(itemsRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];

  const prodMap = new Map(products.map((p) => [p.id, `${p.sku} - ${p.name}`]));
  const unitMap = new Map(units.map((u) => [u.id, u.code]));

  const itemsHtml = items
    .map((item) => {
      const diff = Number(item.actual_qty) - Number(item.system_qty);
      const diffClass = diff > 0 ? 'text-success' : diff < 0 ? 'text-danger' : '';
      const unitCode = unitMap.get(item.unit_id) || '';
      const diffValue = diff * Number(item.unit_cost || 0);

      return `
        <tr>
          <td>
            <strong>${escapeHtml(prodMap.get(item.product_id) || '-')}</strong>
            ${item.notes ? `<div class="text-muted" style="font-size:0.8rem;">${escapeHtml(item.notes)}</div>` : ''}
          </td>
          <td class="num">${formatNumber(item.system_qty)} ${escapeHtml(unitCode)}</td>
          <td class="num font-semibold">${formatNumber(item.actual_qty)} ${escapeHtml(unitCode)}</td>
          <td class="num font-semibold ${diffClass}">${diff > 0 ? '+' : ''}${formatNumber(diff)} ${escapeHtml(unitCode)}</td>
          ${
            canViewCost
              ? `<td class="num">${formatRupiah(item.unit_cost)}</td>
                 <td class="num ${diffClass}">${formatRupiah(diffValue)}</td>`
              : ''
          }
        </tr>
      `;
    })
    .join('');

  const isPending = adj.status === 'pending';

  openModal({
    title: `Detail Penyesuaian Stok: ${adj.adjustment_number}`,
    size: 'lg',
    bodyHtml: `
      <div class="grid-2" style="margin-bottom:1rem;">
        <div>
          <div class="text-muted">Gudang</div>
          <strong>${escapeHtml(whMap.get(adj.warehouse_id) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Tanggal Opname</div>
          <strong>${formatDateID(adj.adjustment_date)}</strong>
        </div>
        <div>
          <div class="text-muted">Diajukan Oleh</div>
          <strong>${escapeHtml(profileMap.get(adj.requested_by) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Status</div>
          <div>${renderStatusBadge(adj.status)}</div>
        </div>
      </div>

      <div class="alert alert-info">
        <strong>Alasan:</strong> ${escapeHtml(adj.reason || '-')}
      </div>

      ${
        adj.status === 'rejected' && adj.rejection_reason
          ? `<div class="alert alert-danger"><strong>Alasan Penolakan:</strong> ${escapeHtml(adj.rejection_reason)}</div>`
          : ''
      }
      ${
        adj.status === 'approved' && adj.approved_at
          ? `<p class="text-muted" style="margin-bottom:0.75rem;">Disetujui pada ${formatDateTimeID(adj.approved_at)}</p>`
          : ''
      }

      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Stok Sistem</th>
              <th class="num">Stok Fisik</th>
              <th class="num">Selisih</th>
              ${
                canViewCost
                  ? `<th class="num">HPP Satuan</th>
                     <th class="num">Nilai Selisih</th>`
                  : ''
              }
            </tr>
          </thead>
          <tbody>${itemsHtml}</tbody>
        </table>
      </div>

      ${
        isPending && canApprove
          ? `<div class="form-group" style="margin-top:1rem;">
              <label class="form-label" for="adj-reject-reason">Alasan Penolakan (Wajib diisi jika menolak pengajuan)</label>
              <input type="text" id="adj-reject-reason" class="form-control" placeholder="Contoh: Perlu hitung ulang fisik di rak B" />
            </div>`
          : ''
      }
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="dadj-close">Tutup</button>
      ${
        isPending && canApprove
          ? `<button type="button" class="btn btn-danger" id="dadj-reject">Tolak Pengajuan</button>
             <button type="button" class="btn btn-primary" id="dadj-approve">Setujui & Sesuaikan Stok</button>`
          : ''
      }
    `,
    onMount: () => {
      document.getElementById('dadj-close')?.addEventListener('click', closeModal);

      document.getElementById('dadj-reject')?.addEventListener('click', async () => {
        const rejectReason = document.getElementById('adj-reject-reason')?.value.trim();
        if (!rejectReason) {
          showToast('Masukkan alasan penolakan terlebih dahulu.', 'warning');
          return;
        }

        const btn = document.getElementById('dadj-reject');
        btn.disabled = true;

        try {
          await callRpc('rpc_decide_stock_adjustment', {
            p_adjustment_id: adj.id,
            p_decision: 'rejected',
            p_rejection_reason: rejectReason
          });
          closeModal();
          showToast('Pengajuan penyesuaian stok ditolak.', 'info');
          await loadAdjustments(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });

      document.getElementById('dadj-approve')?.addEventListener('click', async () => {
        const btn = document.getElementById('dadj-approve');
        btn.disabled = true;

        try {
          await callRpc('rpc_decide_stock_adjustment', {
            p_adjustment_id: adj.id,
            p_decision: 'approved',
            p_rejection_reason: null
          });
          closeModal();
          showToast('Penyesuaian stok disetujui. Saldo kartu stok dan jurnal telah diperbarui.', 'success');
          await loadAdjustments(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}
