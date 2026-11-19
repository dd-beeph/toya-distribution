/**
 * Modul Transfer Antar Gudang (Stock Transfers)
 */

import { supabase } from '../config/supabase-client.js';
import { canPerformAction } from '../auth/permission-guard.js';
import { callRpc, unwrapResponse } from '../services/base-service.js';
import { formatDateID, getJakartaToday, getPeriodRange } from '../utils/date-utils.js';
import { escapeHtml, formatNumber } from '../utils/formatter.js';
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
  const canTransfer = canPerformAction(ctx.role, 'transfer_stock');

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Transfer Barang Antar Gudang</h2>
        <p>Pemindahan stok antar lokasi gudang beserta pencatatan otomatis kartu stok keluar dan masuk</p>
      </div>
      ${
        canTransfer
          ? `<div class="page-actions no-print">
              <button type="button" class="btn btn-primary" id="btn-new-transfer">
                <span class="material-symbols-outlined">swap_horiz</span>
                Buat Transfer Gudang
              </button>
            </div>`
          : ''
      }
    </div>

    <div id="trf-period-bar"></div>
    <div id="trf-extra-filters"></div>
    <div id="trf-list-body">${renderLoadingState()}</div>
  `;

  renderPeriodFilterBar('trf-period-bar', filterState, async (nextFilter) => {
    filterState = { ...filterState, ...nextFilter };
    await loadTransfers(ctx);
  });

  if (canTransfer) {
    document.getElementById('btn-new-transfer')?.addEventListener('click', () => {
      openNewTransferModal(ctx);
    });
  }

  await loadTransfers(ctx);
}

async function loadTransfers(ctx) {
  const listEl = document.getElementById('trf-list-body');
  const extraFilterEl = document.getElementById('trf-extra-filters');
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
      .from('stock_transfers')
      .select('*')
      .order('transfer_date', { ascending: false })
      .order('created_at', { ascending: false });

    if (filterState.startDate) {
      query = query.gte('transfer_date', filterState.startDate);
    }
    if (filterState.endDate) {
      query = query.lte('transfer_date', filterState.endDate);
    }
    if (filterState.status) {
      query = query.eq('status', filterState.status);
    }
    if (filterState.warehouseId) {
      query = query.or(
        `from_warehouse_id.eq.${filterState.warehouseId},to_warehouse_id.eq.${filterState.warehouseId}`
      );
    }

    const transfers = unwrapResponse(await query) || [];

    if (extraFilterEl) {
      const whOpts =
        `<option value="">Semua Gudang (Asal / Tujuan)</option>` +
        warehouses
          .map(
            (w) =>
              `<option value="${w.id}" ${filterState.warehouseId === w.id ? 'selected' : ''}>${escapeHtml(w.name)}</option>`
          )
          .join('');

      extraFilterEl.innerHTML = `
        <div class="filter-bar no-print">
          <div class="filter-item">
            <label for="trf-wh-filter">Lokasi Gudang</label>
            <select id="trf-wh-filter" class="form-control">${whOpts}</select>
          </div>
          <div class="filter-item">
            <label for="trf-status-filter">Status Transfer</label>
            <select id="trf-status-filter" class="form-control">
              <option value="" ${filterState.status === '' ? 'selected' : ''}>Semua Status</option>
              <option value="draft" ${filterState.status === 'draft' ? 'selected' : ''}>Draft (Belum Dikirim)</option>
              <option value="completed" ${filterState.status === 'completed' ? 'selected' : ''}>Selesai (Stok Dipindah)</option>
              <option value="cancelled" ${filterState.status === 'cancelled' ? 'selected' : ''}>Dibatalkan</option>
            </select>
          </div>
        </div>
      `;

      document.getElementById('trf-wh-filter')?.addEventListener('change', (e) => {
        filterState.warehouseId = e.target.value;
        loadTransfers(ctx);
      });
      document.getElementById('trf-status-filter')?.addEventListener('change', (e) => {
        filterState.status = e.target.value;
        loadTransfers(ctx);
      });
    }

    const rowsHtml = transfers
      .map(
        (t) => `
        <tr>
          <td><strong>${escapeHtml(t.transfer_number)}</strong></td>
          <td>${formatDateID(t.transfer_date)}</td>
          <td>${escapeHtml(whMap.get(t.from_warehouse_id) || '-')}</td>
          <td>${escapeHtml(whMap.get(t.to_warehouse_id) || '-')}</td>
          <td>${escapeHtml(profileMap.get(t.created_by) || '-')}</td>
          <td>${renderStatusBadge(t.status)}</td>
          <td class="text-right">
            <button type="button" class="btn btn-secondary btn-sm" data-view-trf="${t.id}">
              ${t.status === 'draft' ? 'Proses / Detail' : 'Lihat Detail'}
            </button>
          </td>
        </tr>
      `
      )
      .join('');

    listEl.innerHTML = `
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Daftar Dokumen Transfer Gudang (${transfers.length} Dokumen)</h3>
        </div>
        ${
          transfers.length === 0
            ? `<div class="card-body">${renderEmptyState('Belum ada transaksi transfer gudang pada periode ini.')}</div>`
            : `<div class="table-responsive">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>No. Transfer</th>
                      <th>Tanggal</th>
                      <th>Gudang Asal</th>
                      <th>Gudang Tujuan</th>
                      <th>Dibuat Oleh</th>
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

    listEl.querySelectorAll('[data-view-trf]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const trf = transfers.find((item) => item.id === btn.getAttribute('data-view-trf'));
        if (trf) {
          openTransferDetailModal(trf, whMap, profileMap, ctx);
        }
      });
    });
  } catch (err) {
    listEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

async function openNewTransferModal(ctx) {
  const [whRes, prodRes, unitRes, balRes] = await Promise.all([
    supabase.from('warehouses').select('id, code, name').eq('is_active', true).order('name'),
    supabase
      .from('products')
      .select('id, sku, name, base_unit_id')
      .eq('is_active', true)
      .order('name'),
    supabase.from('units').select('id, code, name'),
    supabase.from('stock_balances').select('warehouse_id, product_id, qty_on_hand, avg_unit_cost')
  ]);

  const warehouses = unwrapResponse(whRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const balances = unwrapResponse(balRes) || [];

  if (warehouses.length < 2) {
    showToast('Minimal harus ada 2 gudang aktif untuk melakukan transfer antar gudang.', 'warning');
    return;
  }
  if (products.length === 0) {
    showToast('Belum ada produk aktif di Data Master.', 'warning');
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

  let lineItems = [{ product_id: products[0].id, qty: 1 }];

  openModal({
    title: 'Buat Dokumen Transfer Antar Gudang',
    size: 'lg',
    bodyHtml: `
      <div class="grid-3">
        <div class="form-group">
          <label class="form-label" for="nt-date">Tanggal Transfer <span class="req">*</span></label>
          <input type="date" id="nt-date" class="form-control" value="${getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="nt-from">Gudang Asal <span class="req">*</span></label>
          <select id="nt-from" class="form-control">${whOpts}</select>
        </div>
        <div class="form-group">
          <label class="form-label" for="nt-to">Gudang Tujuan <span class="req">*</span></label>
          <select id="nt-to" class="form-control">${whOpts}</select>
        </div>
      </div>

      <div class="form-group">
        <label class="form-label" for="nt-notes">Catatan Pengiriman Internal</label>
        <input type="text" id="nt-notes" class="form-control" placeholder="Contoh: Pengisian stok cabang / kendaraan operasional" />
      </div>

      <div style="display:flex;justify-content:space-between;align-items:center;margin:1rem 0 0.5rem;">
        <strong>Daftar Barang yang Ditransfer</strong>
        <button type="button" class="btn btn-secondary btn-sm" id="nt-add-row">+ Tambah Baris Produk</button>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Stok Asal</th>
              <th class="num" style="width:140px;">Qty Transfer</th>
              <th style="width:60px;"></th>
            </tr>
          </thead>
          <tbody id="nt-items-body"></tbody>
        </table>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="nt-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="nt-save">Simpan Draft Transfer</button>
    `,
    onMount: () => {
      const fromSelect = document.getElementById('nt-from');
      const toSelect = document.getElementById('nt-to');
      if (warehouses.length > 1) {
        toSelect.value = warehouses[1].id;
      }

      const renderRows = () => {
        const tbody = document.getElementById('nt-items-body');
        if (!tbody) return;
        const fromWhId = fromSelect.value;

        tbody.innerHTML = lineItems
          .map((item, idx) => {
            const bal = balanceMap.get(`${fromWhId}_${item.product_id}`);
            const availQty = Number(bal?.qty_on_hand || 0);
            const prod = productMap.get(item.product_id);
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
                  <select class="form-control" data-row-prod="${idx}">${prodOpts}</select>
                </td>
                <td class="num ${availQty <= 0 ? 'text-danger' : ''}">
                  ${formatNumber(availQty)} ${escapeHtml(unitCode)}
                </td>
                <td>
                  <input type="number" step="1" min="1" class="form-control num" data-row-qty="${idx}" value="${item.qty}" />
                </td>
                <td class="text-right">
                  ${
                    lineItems.length > 1
                      ? `<button type="button" class="btn btn-ghost btn-sm text-danger" data-row-del="${idx}">&times;</button>`
                      : ''
                  }
                </td>
              </tr>
            `;
          })
          .join('');

        tbody.querySelectorAll('[data-row-prod]').forEach((el) => {
          el.addEventListener('change', (e) => {
            const idx = Number(e.target.getAttribute('data-row-prod'));
            lineItems[idx].product_id = e.target.value;
            renderRows();
          });
        });

        tbody.querySelectorAll('[data-row-qty]').forEach((el) => {
          el.addEventListener('input', (e) => {
            const idx = Number(e.target.getAttribute('data-row-qty'));
            lineItems[idx].qty = Number(e.target.value || 0);
          });
        });

        tbody.querySelectorAll('[data-row-del]').forEach((el) => {
          el.addEventListener('click', (e) => {
            const idx = Number(e.target.getAttribute('data-row-del'));
            lineItems.splice(idx, 1);
            renderRows();
          });
        });
      };

      renderRows();

      fromSelect.addEventListener('change', renderRows);
      document.getElementById('nt-add-row')?.addEventListener('click', () => {
        lineItems.push({ product_id: products[0].id, qty: 1 });
        renderRows();
      });

      document.getElementById('nt-cancel')?.addEventListener('click', closeModal);
      document.getElementById('nt-save')?.addEventListener('click', async () => {
        const fromWhId = fromSelect.value;
        const toWhId = toSelect.value;

        if (fromWhId === toWhId) {
          showToast('Gudang asal dan gudang tujuan tidak boleh sama.', 'warning');
          return;
        }

        const mergedMap = new Map();
        for (const item of lineItems) {
          if (!item.product_id || item.qty <= 0) {
            showToast('Pastikan setiap produk memiliki kuantitas transfer lebih dari nol.', 'warning');
            return;
          }
          mergedMap.set(item.product_id, (mergedMap.get(item.product_id) || 0) + item.qty);
        }

        const btn = document.getElementById('nt-save');
        btn.disabled = true;

        try {
          const transferHeader = unwrapResponse(
            await supabase
              .from('stock_transfers')
              .insert({
                transfer_date: document.getElementById('nt-date').value,
                from_warehouse_id: fromWhId,
                to_warehouse_id: toWhId,
                status: 'draft',
                notes: document.getElementById('nt-notes').value.trim() || null,
                created_by: ctx.user.id
              })
              .select()
              .single()
          );

          const itemsPayload = Array.from(mergedMap.entries()).map(([productId, qty]) => {
            const prod = productMap.get(productId);
            const bal = balanceMap.get(`${fromWhId}_${productId}`);
            return {
              transfer_id: transferHeader.id,
              product_id: productId,
              unit_id: prod.base_unit_id,
              qty,
              unit_cost: Number(bal?.avg_unit_cost || 0)
            };
          });

          unwrapResponse(await supabase.from('stock_transfer_items').insert(itemsPayload));

          closeModal();
          showToast(`Draft transfer ${transferHeader.transfer_number} berhasil dibuat.`, 'success');
          await loadTransfers(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

async function openTransferDetailModal(transfer, whMap, profileMap, ctx) {
  const canTransfer = canPerformAction(ctx.role, 'transfer_stock');

  const [itemsRes, prodRes, unitRes] = await Promise.all([
    supabase.from('stock_transfer_items').select('*').eq('transfer_id', transfer.id),
    supabase.from('products').select('id, sku, name'),
    supabase.from('units').select('id, code')
  ]);

  const items = unwrapResponse(itemsRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];

  const prodMap = new Map(products.map((p) => [p.id, `${p.sku} - ${p.name}`]));
  const unitMap = new Map(units.map((u) => [u.id, u.code]));

  const itemsHtml = items
    .map(
      (item) => `
      <tr>
        <td><strong>${escapeHtml(prodMap.get(item.product_id) || '-')}</strong></td>
        <td class="num font-semibold">${formatNumber(item.qty)} ${escapeHtml(unitMap.get(item.unit_id) || '')}</td>
      </tr>
    `
    )
    .join('');

  const isDraft = transfer.status === 'draft';

  openModal({
    title: `Detail Transfer: ${transfer.transfer_number}`,
    bodyHtml: `
      <div class="grid-2" style="margin-bottom:1rem;">
        <div>
          <div class="text-muted">Gudang Asal</div>
          <strong>${escapeHtml(whMap.get(transfer.from_warehouse_id) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Gudang Tujuan</div>
          <strong>${escapeHtml(whMap.get(transfer.to_warehouse_id) || '-')}</strong>
        </div>
        <div>
          <div class="text-muted">Tanggal Transfer</div>
          <strong>${formatDateID(transfer.transfer_date)}</strong>
        </div>
        <div>
          <div class="text-muted">Status</div>
          <div>${renderStatusBadge(transfer.status)}</div>
        </div>
      </div>
      ${
        transfer.notes
          ? `<div class="alert alert-info">Catatan: ${escapeHtml(transfer.notes)}</div>`
          : ''
      }
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Kuantitas Transfer</th>
            </tr>
          </thead>
          <tbody>${itemsHtml}</tbody>
        </table>
      </div>
      ${
        isDraft
          ? `<p class="form-help" style="margin-top:0.75rem;">
              Klik <strong>Selesaikan & Pindahkan Stok</strong> apabila barang fisik sudah diberangkatkan dari gudang asal. Saldo stok kedua gudang akan otomatis diperbarui.
            </p>`
          : ''
      }
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="dt-close">Tutup</button>
      ${
        isDraft && canTransfer
          ? `<button type="button" class="btn btn-danger" id="dt-void">Batalkan Draft</button>
             <button type="button" class="btn btn-primary" id="dt-complete">Selesaikan & Pindahkan Stok</button>`
          : ''
      }
    `,
    onMount: () => {
      document.getElementById('dt-close')?.addEventListener('click', closeModal);

      document.getElementById('dt-void')?.addEventListener('click', async () => {
        const btn = document.getElementById('dt-void');
        btn.disabled = true;
        try {
          unwrapResponse(
            await supabase
              .from('stock_transfers')
              .update({ status: 'cancelled' })
              .eq('id', transfer.id)
          );
          closeModal();
          showToast('Draft transfer gudang dibatalkan.', 'info');
          await loadTransfers(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });

      document.getElementById('dt-complete')?.addEventListener('click', async () => {
        const btn = document.getElementById('dt-complete');
        btn.disabled = true;
        try {
          await callRpc('rpc_complete_stock_transfer', {
            p_transfer_id: transfer.id
          });
          closeModal();
          showToast(`Transfer ${transfer.transfer_number} selesai. Kartu stok kedua gudang telah diperbarui.`, 'success');
          await loadTransfers(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}
