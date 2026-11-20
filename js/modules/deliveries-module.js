/**
 * Modul Pengiriman & Surat Jalan (Dispatch Gudang, Konfirmasi Hasil Kirim, & Cetak Surat Jalan)
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

let activeTab = 'deliveries';
let filterState = {
  preset: 'this_month',
  ...getPeriodRange('this_month'),
  status: '',
  warehouseId: ''
};

export async function renderModule(container, ctx) {
  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Pengiriman & Surat Jalan</h2>
        <p>Proses pengeluaran barang dari gudang, cetak Surat Jalan, dan konfirmasi hasil serah-terima di toko</p>
      </div>
    </div>

    <div class="tabs no-print">
      <button type="button" class="tab-btn ${activeTab === 'deliveries' ? 'active' : ''}" data-tab="deliveries">Daftar Surat Jalan</button>
      <button type="button" class="tab-btn ${activeTab === 'ready_so' ? 'active' : ''}" data-tab="ready_so">SO Siap Kirim (Antrean Gudang)</button>
    </div>

    <div id="del-tab-body">${renderLoadingState()}</div>
  `;

  container.querySelectorAll('.tab-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      activeTab = btn.getAttribute('data-tab');
      container.querySelectorAll('.tab-btn').forEach((b) => b.classList.toggle('active', b === btn));
      loadTabContent(ctx);
    });
  });

  await loadTabContent(ctx);
}

async function loadTabContent(ctx) {
  const bodyEl = document.getElementById('del-tab-body');
  if (!bodyEl) return;
  bodyEl.innerHTML = renderLoadingState();

  try {
    if (activeTab === 'ready_so') {
      await renderReadySoTab(bodyEl, ctx);
    } else {
      await renderDeliveriesTab(bodyEl, ctx);
    }
  } catch (err) {
    bodyEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

/* ============================================================================
   TAB 1: DAFTAR SURAT JALAN & KONFIRMASI HASIL PENGIRIMAN
   ============================================================================ */
async function renderDeliveriesTab(bodyEl, ctx) {
  const [custRes, whRes, soRes] = await Promise.all([
    supabase.from('customers').select('id, name, address, phone'),
    supabase.from('warehouses').select('id, name'),
    supabase.from('sales_orders').select('id, so_number')
  ]);

  const customers = unwrapResponse(custRes) || [];
  const warehouses = unwrapResponse(whRes) || [];
  const salesOrders = unwrapResponse(soRes) || [];

  const custMap = new Map(customers.map((c) => [c.id, c]));
  const whMap = new Map(warehouses.map((w) => [w.id, w.name]));
  const soMap = new Map(salesOrders.map((s) => [s.id, s.so_number]));

  let query = supabase
    .from('deliveries')
    .select('*')
    .order('delivery_date', { ascending: false })
    .order('created_at', { ascending: false });

  if (filterState.startDate) {
    query = query.gte('delivery_date', filterState.startDate);
  }
  if (filterState.endDate) {
    query = query.lte('delivery_date', filterState.endDate);
  }
  if (filterState.status) {
    query = query.eq('status', filterState.status);
  }
  if (filterState.warehouseId) {
    query = query.eq('warehouse_id', filterState.warehouseId);
  }

  const deliveries = unwrapResponse(await query) || [];

  const whOpts =
    `<option value="">Semua Gudang</option>` +
    warehouses
      .map(
        (w) =>
          `<option value="${w.id}" ${filterState.warehouseId === w.id ? 'selected' : ''}>${escapeHtml(w.name)}</option>`
      )
      .join('');

  const rowsHtml = deliveries
    .map((d) => {
      const cust = custMap.get(d.customer_id);
      return `
        <tr>
          <td>
            <strong>${escapeHtml(d.delivery_number)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">SO: ${escapeHtml(soMap.get(d.sales_order_id) || '-')}</div>
          </td>
          <td>${formatDateID(d.delivery_date)}</td>
          <td>
            <strong>${escapeHtml(cust?.name || '-')}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(whMap.get(d.warehouse_id) || '-')}</div>
          </td>
          <td>
            <div>${escapeHtml(d.driver_name || '-')}</div>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(d.vehicle_number || '')}</div>
          </td>
          <td>${renderStatusBadge(d.status)}</td>
          <td class="text-right">
            <button type="button" class="btn btn-secondary btn-sm" data-open-del="${d.id}">
              ${d.status === 'dispatched' ? 'Konfirmasi Hasil' : 'Detail / Cetak'}
            </button>
          </td>
        </tr>
      `;
    })
    .join('');

  bodyEl.innerHTML = `
    <div id="del-period-bar"></div>

    <div class="filter-bar no-print">
      <div class="filter-item">
        <label for="del-wh-filter">Gudang</label>
        <select id="del-wh-filter" class="form-control">${whOpts}</select>
      </div>
      <div class="filter-item">
        <label for="del-status-filter">Status Pengiriman</label>
        <select id="del-status-filter" class="form-control">
          <option value="" ${filterState.status === '' ? 'selected' : ''}>Semua Status</option>
          <option value="dispatched" ${filterState.status === 'dispatched' ? 'selected' : ''}>Dalam Perjalanan (Dispatched)</option>
          <option value="delivered" ${filterState.status === 'delivered' ? 'selected' : ''}>Terkirim / Dikonfirmasi</option>
          <option value="invoiced" ${filterState.status === 'invoiced' ? 'selected' : ''}>Sudah Dibuat Faktur</option>
        </select>
      </div>
    </div>

    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Daftar Surat Jalan (${deliveries.length} Dokumen)</h3>
      </div>
      ${
        deliveries.length === 0
          ? `<div class="card-body">${renderEmptyState('Belum ada dokumen Surat Jalan pada periode ini.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>No. Surat Jalan</th>
                    <th>Tgl Kirim</th>
                    <th>Pelanggan & Gudang</th>
                    <th>Sopir & Kendaraan</th>
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

  renderPeriodFilterBar('del-period-bar', filterState, async (nextFilter) => {
    filterState = { ...filterState, ...nextFilter };
    await loadTabContent(ctx);
  });

  document.getElementById('del-wh-filter')?.addEventListener('change', (e) => {
    filterState.warehouseId = e.target.value;
    loadTabContent(ctx);
  });
  document.getElementById('del-status-filter')?.addEventListener('change', (e) => {
    filterState.status = e.target.value;
    loadTabContent(ctx);
  });

  bodyEl.querySelectorAll('[data-open-del]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const del = deliveries.find((item) => item.id === btn.getAttribute('data-open-del'));
      if (del) {
        openDeliveryDetailModal(del, custMap, whMap, soMap, ctx);
      }
    });
  });
}

/* ============================================================================
   TAB 2: ANTREAN SO SIAP KIRIM (UNTUK DIPROSES GUDANG)
   ============================================================================ */
async function renderReadySoTab(bodyEl, ctx) {
  const canDispatch = canPerformAction(ctx.role, 'dispatch_delivery');

  const [soRes, custRes, whRes] = await Promise.all([
    supabase
      .from('sales_orders')
      .select('*')
      .in('status', ['approved', 'ready_for_delivery'])
      .order('expected_delivery_date', { ascending: true })
      .order('order_date', { ascending: true }),
    supabase.from('customers').select('id, name, address'),
    supabase.from('warehouses').select('id, name')
  ]);

  const readyOrders = unwrapResponse(soRes) || [];
  const customers = unwrapResponse(custRes) || [];
  const warehouses = unwrapResponse(whRes) || [];

  const custMap = new Map(customers.map((c) => [c.id, c]));
  const whMap = new Map(warehouses.map((w) => [w.id, w.name]));

  const rowsHtml = readyOrders
    .map((so) => {
      const cust = custMap.get(so.customer_id);
      return `
        <tr>
          <td><strong>${escapeHtml(so.so_number)}</strong></td>
          <td>${formatDateID(so.expected_delivery_date || so.order_date)}</td>
          <td>
            <strong>${escapeHtml(cust?.name || '-')}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(cust?.address || '-')}</div>
          </td>
          <td>${escapeHtml(whMap.get(so.warehouse_id) || '-')}</td>
          <td>${renderStatusBadge(so.status)}</td>
          ${
            canDispatch
              ? `<td class="text-right">
                  <button type="button" class="btn btn-primary btn-sm" data-dispatch-so="${so.id}">Proses Surat Jalan</button>
                </td>`
              : ''
          }
        </tr>
      `;
    })
    .join('');

  bodyEl.innerHTML = `
    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Antrean Sales Order Siap Kirim (${readyOrders.length})</h3>
      </div>
      ${
        readyOrders.length === 0
          ? `<div class="card-body">${renderEmptyState('Tidak ada Sales Order yang menunggu pengiriman saat ini.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>No. SO</th>
                    <th>Jadwal Kirim</th>
                    <th>Pelanggan & Alamat</th>
                    <th>Gudang Asal</th>
                    <th>Status</th>
                    ${canDispatch ? '<th class="text-right">Tindakan</th>' : ''}
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>`
      }
    </div>
  `;

  if (canDispatch) {
    bodyEl.querySelectorAll('[data-dispatch-so]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const so = readyOrders.find((item) => item.id === btn.getAttribute('data-dispatch-so'));
        if (so) {
          openDispatchModal(so, custMap, whMap, ctx);
        }
      });
    });
  }
}

function openDispatchModal(so, custMap, whMap, ctx) {
  const cust = custMap.get(so.customer_id);
  openModal({
    title: `Terbitkan Surat Jalan: ${so.so_number}`,
    bodyHtml: `
      <div class="alert alert-warning">
        Stok pada <strong>${escapeHtml(whMap.get(so.warehouse_id) || 'Gudang')}</strong> akan langsung dipotong saat Surat Jalan diterbitkan.
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="qd-date">Tanggal Kirim <span class="req">*</span></label>
          <input type="date" id="qd-date" class="form-control" value="${getJakartaToday()}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="qd-driver">Nama Pengemudi <span class="req">*</span></label>
          <input type="text" id="qd-driver" class="form-control" placeholder="Nama sopir armada" required />
        </div>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="qd-plate">Nomor Polisi Kendaraan</label>
          <input type="text" id="qd-plate" class="form-control" placeholder="Contoh: B 9012 KDA" />
        </div>
        <div class="form-group">
          <label class="form-label" for="qd-notes">Catatan Pengiriman</label>
          <input type="text" id="qd-notes" class="form-control" value="${escapeHtml(so.notes || '')}" />
        </div>
      </div>
      <p class="form-help">Tujuan: <strong>${escapeHtml(cust?.name || '-')}</strong> (${escapeHtml(cust?.address || '-')})</p>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="qd-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="qd-save">Terbitkan Surat Jalan</button>
    `,
    onMount: () => {
      document.getElementById('qd-cancel')?.addEventListener('click', closeModal);
      document.getElementById('qd-save')?.addEventListener('click', async () => {
        const driver = document.getElementById('qd-driver').value.trim();
        if (!driver) {
          showToast('Nama pengemudi wajib diisi.', 'warning');
          return;
        }
        const btn = document.getElementById('qd-save');
        btn.disabled = true;
        try {
          await callRpc('rpc_dispatch_sales_order', {
            p_sales_order_id: so.id,
            p_delivery_date: document.getElementById('qd-date').value,
            p_driver_name: driver,
            p_vehicle_number: document.getElementById('qd-plate').value.trim() || null,
            p_notes: document.getElementById('qd-notes').value.trim() || null
          });
          closeModal();
          showToast(`Surat Jalan untuk ${so.so_number} berhasil diterbitkan.`, 'success');
          activeTab = 'deliveries';
          await loadTabContent(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

/* ============================================================================
   MODAL DETAIL SURAT JALAN, CETAK, & KONFIRMASI HASIL PENGIRIMAN
   ============================================================================ */
async function openDeliveryDetailModal(del, custMap, whMap, soMap, ctx) {
  const canConfirm = canPerformAction(ctx.role, 'confirm_delivery_result');
  const isEditable = canConfirm && del.status !== 'invoiced';

  const [itemsRes, prodRes, unitRes] = await Promise.all([
    supabase.from('delivery_items').select('*').eq('delivery_id', del.id),
    supabase.from('products').select('id, sku, name'),
    supabase.from('units').select('id, code')
  ]);

  const items = unwrapResponse(itemsRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];

  const prodMap = new Map(products.map((p) => [p.id, `${p.sku} - ${p.name}`]));
  const unitMap = new Map(units.map((u) => [u.id, u.code]));
  const cust = custMap.get(del.customer_id);

  const itemsHtml = items
    .map((it, idx) => {
      const unitCode = unitMap.get(it.unit_id) || '';
      const disp = Number(it.qty_dispatched || 0);
      const deliv = Number(it.qty_delivered ?? disp);
      const dmg = Number(it.qty_damaged || 0);
      const ret = Number(it.qty_returned_undelivered || 0);

      if (!isEditable) {
        return `
          <tr>
            <td><strong>${escapeHtml(prodMap.get(it.product_id) || '-')}</strong></td>
            <td class="num">${formatNumber(disp)} ${escapeHtml(unitCode)}</td>
            <td class="num text-success font-semibold">${formatNumber(deliv)} ${escapeHtml(unitCode)}</td>
            <td class="num text-danger">${formatNumber(dmg)} ${escapeHtml(unitCode)}</td>
            <td class="num">${formatNumber(ret)} ${escapeHtml(unitCode)}</td>
          </tr>
        `;
      }

      return `
        <tr>
          <td>
            <strong>${escapeHtml(prodMap.get(it.product_id) || '-')}</strong>
            <div class="text-muted" style="font-size:0.8rem;">Keluar Gudang: ${formatNumber(disp)} ${escapeHtml(unitCode)}</div>
          </td>
          <td class="num font-semibold">${formatNumber(disp)}</td>
          <td>
            <input type="number" step="1" min="0" max="${disp}" class="form-control num" data-cf-deliv="${idx}" value="${deliv}" />
          </td>
          <td>
            <input type="number" step="1" min="0" max="${disp}" class="form-control num" data-cf-dmg="${idx}" value="${dmg}" />
          </td>
          <td>
            <input type="number" step="1" min="0" max="${disp}" class="form-control num" data-cf-ret="${idx}" value="${ret}" />
          </td>
        </tr>
      `;
    })
    .join('');

  openModal({
    title: `Surat Jalan: ${del.delivery_number}`,
    size: 'lg',
    bodyHtml: `
      <div class="grid-3" style="margin-bottom:1rem;">
        <div>
          <div class="text-muted">Pelanggan</div>
          <strong>${escapeHtml(cust?.name || '-')}</strong>
          <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(cust?.address || '-')}</div>
        </div>
        <div>
          <div class="text-muted">Gudang & Referensi SO</div>
          <strong>${escapeHtml(whMap.get(del.warehouse_id) || '-')}</strong>
          <div class="text-muted" style="font-size:0.8rem;">SO: ${escapeHtml(soMap.get(del.sales_order_id) || '-')}</div>
        </div>
        <div>
          <div class="text-muted">Status Pengiriman</div>
          <div>${renderStatusBadge(del.status)}</div>
        </div>
      </div>

      ${
        isEditable
          ? `<div class="grid-3" style="margin-bottom:1rem;">
              <div class="form-group">
                <label class="form-label" for="cf-date">Tanggal Tiba <span class="req">*</span></label>
                <input type="date" id="cf-date" class="form-control" value="${del.delivery_date || getJakartaToday()}" required />
              </div>
              <div class="form-group">
                <label class="form-label" for="cf-driver">Nama Pengemudi <span class="req">*</span></label>
                <input type="text" id="cf-driver" class="form-control" value="${escapeHtml(del.driver_name || '')}" required />
              </div>
              <div class="form-group">
                <label class="form-label" for="cf-plate">No. Polisi Kendaraan</label>
                <input type="text" id="cf-plate" class="form-control" value="${escapeHtml(del.vehicle_number || '')}" />
              </div>
            </div>`
          : `<div class="grid-3" style="margin-bottom:1rem;">
              <div><span class="text-muted">Tgl Kirim:</span> <strong>${formatDateID(del.delivery_date)}</strong></div>
              <div><span class="text-muted">Sopir:</span> <strong>${escapeHtml(del.driver_name || '-')}</strong></div>
              <div><span class="text-muted">Kendaraan:</span> <strong>${escapeHtml(del.vehicle_number || '-')}</strong></div>
            </div>`
      }

      ${
        isEditable
          ? `<div class="alert alert-info">
              Pastikan jumlah <strong>Diterima Toko + Rusak Kirim + Batal Kirim</strong> pada setiap baris sama persis dengan jumlah <strong>Keluar Gudang</strong>.
            </div>`
          : ''
      }

      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Keluar Gudang</th>
              <th class="num" style="width:115px;">Diterima Toko</th>
              <th class="num" style="width:115px;">Rusak Kirim</th>
              <th class="num" style="width:115px;">Batal Kirim</th>
            </tr>
          </thead>
          <tbody>${itemsHtml}</tbody>
        </table>
      </div>

      ${
        isEditable && del.status === 'delivered'
          ? `<div class="form-group" style="margin-top:1rem;">
              <label class="form-label" for="cf-edit-reason">Alasan Koreksi Hasil Pengiriman <span class="req">*</span></label>
              <input type="text" id="cf-edit-reason" class="form-control" placeholder="Wajib diisi karena dokumen sudah pernah dikonfirmasi sebelumnya" />
            </div>`
          : ''
      }
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary no-print" id="ddel-print">Cetak Surat Jalan</button>
      <button type="button" class="btn btn-secondary no-print" id="ddel-close">Tutup</button>
      ${
        isEditable
          ? `<button type="button" class="btn btn-primary no-print" id="ddel-confirm">Simpan Hasil Pengiriman</button>`
          : ''
      }
    `,
    onMount: () => {
      document.getElementById('ddel-close')?.addEventListener('click', closeModal);
      document.getElementById('ddel-print')?.addEventListener('click', () => window.print());

      document.getElementById('ddel-confirm')?.addEventListener('click', async () => {
        const driverName = document.getElementById('cf-driver')?.value.trim();
        if (!driverName) {
          showToast('Nama pengemudi wajib diisi.', 'warning');
          return;
        }

        const editReason = document.getElementById('cf-edit-reason')?.value.trim() || '';
        if (del.status === 'delivered' && !editReason) {
          showToast('Alasan koreksi hasil pengiriman wajib diisi.', 'warning');
          return;
        }

        const payloadItems = [];
        for (let idx = 0; idx < items.length; idx += 1) {
          const it = items[idx];
          const disp = Number(it.qty_dispatched || 0);
          const qDel = Number(document.querySelector(`[data-cf-deliv="${idx}"]`)?.value || 0);
          const qDmg = Number(document.querySelector(`[data-cf-dmg="${idx}"]`)?.value || 0);
          const qRet = Number(document.querySelector(`[data-cf-ret="${idx}"]`)?.value || 0);

          if (qDel < 0 || qDmg < 0 || qRet < 0) {
            showToast('Kuantitas pengiriman tidak boleh negatif.', 'warning');
            return;
          }
          if (qDel + qDmg + qRet !== disp) {
            showToast(
              `Total diterima (${qDel}) + rusak (${qDmg}) + batal (${qRet}) harus sama dengan keluar gudang (${disp}).`,
              'warning'
            );
            return;
          }

          payloadItems.push({
            delivery_item_id: it.id,
            qty_delivered: qDel,
            qty_damaged: qDmg,
            qty_returned_undelivered: qRet,
            notes: it.notes || null
          });
        }

        const btn = document.getElementById('ddel-confirm');
        btn.disabled = true;

        try {
          await callRpc('rpc_confirm_delivery_result', {
            p_delivery_id: del.id,
            p_driver_name: driverName,
            p_vehicle_number: document.getElementById('cf-plate')?.value.trim() || null,
            p_delivery_date: document.getElementById('cf-date')?.value || null,
            p_items: payloadItems,
            p_edit_reason: editReason || null
          });
          closeModal();
          showToast(`Hasil pengiriman ${del.delivery_number} berhasil dikonfirmasi.`, 'success');
          await loadTabContent(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}
