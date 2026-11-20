/**
 * Modul Pengiriman & Surat Jalan (Dispatch Gudang, Konfirmasi Hasil Kirim, & Cetak Surat Jalan)
 */

import { APP_CONFIG } from '../config/app-config.js';
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
  const [custRes, whRes, soRes, prodRes, unitRes] = await Promise.all([
    supabase.from('customers').select('id, name, address, city, phone, contact_person'),
    supabase.from('warehouses').select('id, name, address, phone'),
    supabase.from('sales_orders').select('id, so_number, payment_type, payment_term_days, ppn_mode_snapshot'),
    supabase.from('products').select('id, sku, name'),
    supabase.from('units').select('id, code')
  ]);

  const customers = unwrapResponse(custRes) || [];
  const warehouses = unwrapResponse(whRes) || [];
  const salesOrders = unwrapResponse(soRes) || [];
  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];

  const custMap = new Map(customers.map((c) => [c.id, c]));
  const whMap = new Map(warehouses.map((w) => [w.id, w]));
  const soMap = new Map(salesOrders.map((s) => [s.id, s]));
  const prodMap = new Map(products.map((p) => [p.id, p]));
  const unitMap = new Map(units.map((u) => [u.id, u.code]));

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
      const wh = whMap.get(d.warehouse_id);
      const so = soMap.get(d.sales_order_id);
      return `
        <tr>
          <td>
            <strong>${escapeHtml(d.delivery_number)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">SO: ${escapeHtml(so?.so_number || '-')}</div>
          </td>
          <td>${formatDateID(d.delivery_date)}</td>
          <td>
            <strong>${escapeHtml(cust?.name || '-')}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(wh?.name || '-')}</div>
          </td>
          <td>
            <div>${escapeHtml(d.driver_name || '-')}</div>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(d.vehicle_number || '')}</div>
          </td>
          <td>${renderStatusBadge(d.status)}</td>
          <td class="text-right" style="white-space:nowrap;">
            <button type="button" class="btn btn-secondary btn-sm" data-open-del="${d.id}">
              ${d.status === 'dispatched' ? 'Konfirmasi' : 'Detail'}
            </button>
            <button type="button" class="btn btn-primary btn-sm" data-print-del="${d.id}">
              Cetak
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
        openDeliveryDetailModal(del, custMap, whMap, soMap, prodMap, unitMap, ctx);
      }
    });
  });

  bodyEl.querySelectorAll('[data-print-del]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const del = deliveries.find((item) => item.id === btn.getAttribute('data-print-del'));
      if (!del) return;

      const origText = btn.textContent;
      btn.disabled = true;
      btn.textContent = 'Memuat...';

      try {
        const items =
          unwrapResponse(
            await supabase.from('delivery_items').select('*').eq('delivery_id', del.id)
          ) || [];

        const printRows = items.map((it) => {
          const prod = prodMap.get(it.product_id);
          const disp = Number(it.qty_dispatched || 0);
          const qDel = Number(it.qty_delivered ?? disp);
          const activeQty = del.status === 'dispatched' ? disp : qDel;

          return {
            item: it,
            sku: prod?.sku || '-',
            productName: prod?.name || '-',
            unitCode: unitMap.get(it.unit_id) || '',
            activeQty,
            qtyDamaged: Number(it.qty_damaged || 0),
            qtyReturned: Number(it.qty_returned_undelivered || 0)
          };
        });

        triggerPrintDeliveryNote({
          del,
          so: soMap.get(del.sales_order_id),
          cust: custMap.get(del.customer_id),
          wh: whMap.get(del.warehouse_id),
          rows: printRows
        });
      } catch (err) {
        showToast(err.message, 'danger');
      } finally {
        btn.disabled = false;
        btn.textContent = origText;
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
   HELPER HITUNG NILAI BARIS & CETAK SURAT JALAN (PRINT SHEET)
   ============================================================================ */
function computeDeliveryLineFinance(item, activeQty, ppnMode) {
  const orderedQty = Number(item.qty_ordered || activeQty || 1);
  const price = Number(item.unit_price || 0);
  const gross = Math.round(activeQty * price * 100) / 100;

  const fullDisc = Number(item.discount_amount || 0);
  const ratio = orderedQty > 0 ? activeQty / orderedQty : 1;
  const disc = Math.round(fullDisc * ratio * 100) / 100;
  const net = Math.max(0, gross - disc);

  const rate = Number(item.tax_rate_percent || 0);
  const mult = Number(item.dpp_multiplier || 1);

  if (ppnMode === 'exclude_ppn' && rate > 0) {
    const dpp = Math.round(net * mult * 100) / 100;
    const tax = Math.round(dpp * (rate / 100) * 100) / 100;
    return { gross, disc, dpp, tax, total: net + tax };
  }
  if (ppnMode === 'include_ppn' && rate > 0) {
    const divisor = 1 + (mult * rate) / 100;
    const dpp = Math.round((net / divisor) * 100) / 100;
    const tax = Math.round((net - dpp) * 100) / 100;
    return { gross, disc, dpp, tax, total: net };
  }
  return { gross, disc, dpp: net, tax: 0, total: net };
}

function triggerPrintDeliveryNote({ del, so, cust, wh, rows }) {
  const existingStyle = document.getElementById('tjd-print-style');
  if (existingStyle) existingStyle.remove();

  const existingSheet = document.getElementById('tjd-print-sheet');
  if (existingSheet) existingSheet.remove();

  const styleEl = document.createElement('style');
  styleEl.id = 'tjd-print-style';
  styleEl.textContent = `
    #tjd-print-sheet {
      display: none;
    }
    @media print {
      @page {
        size: A4 portrait;
        margin: 12mm;
      }
      html, body {
        background: #ffffff !important;
        color: #111827 !important;
        margin: 0 !important;
        padding: 0 !important;
        height: auto !important;
        overflow: visible !important;
      }
      body > *:not(#tjd-print-sheet) {
        display: none !important;
      }
      #tjd-print-sheet {
        display: block !important;
        position: static !important;
        width: 100% !important;
        font-family: Arial, Helvetica, sans-serif;
        font-size: 11pt;
        line-height: 1.4;
        color: #111827 !important;
      }
      #tjd-print-sheet table {
        width: 100%;
        border-collapse: collapse;
        margin-top: 10px;
      }
      #tjd-print-sheet th,
      #tjd-print-sheet td {
        border: 1px solid #374151;
        padding: 6px 8px;
        vertical-align: top;
      }
      #tjd-print-sheet th {
        background: #f3f4f6 !important;
        font-weight: bold;
        text-align: left;
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
      }
      #tjd-print-sheet .num {
        text-align: right;
        white-space: nowrap;
      }
      #tjd-print-sheet .center {
        text-align: center;
      }
    }
  `;
  document.head.appendChild(styleEl);

  const ppnMode = so?.ppn_mode_snapshot || 'non_ppn';
  let subtotal = 0;
  let totalDisc = 0;
  let totalDpp = 0;
  let totalTax = 0;
  let grandTotal = 0;

  const tableRowsHtml = rows
    .map((r, i) => {
      const calc = computeDeliveryLineFinance(r.item, r.activeQty, ppnMode);
      subtotal += calc.gross;
      totalDisc += calc.disc;
      totalDpp += calc.dpp;
      totalTax += calc.tax;
      grandTotal += calc.total;

      const noteParts = [];
      if (r.qtyDamaged > 0) noteParts.push(`Rusak: ${formatNumber(r.qtyDamaged)}`);
      if (r.qtyReturned > 0) noteParts.push(`Batal: ${formatNumber(r.qtyReturned)}`);

      return `
        <tr>
          <td class="center">${i + 1}</td>
          <td>${escapeHtml(r.sku)}</td>
          <td>
            <strong>${escapeHtml(r.productName)}</strong>
            ${noteParts.length > 0 ? `<div style="font-size:9pt;color:#4b5563;">(${escapeHtml(noteParts.join(', '))})</div>` : ''}
          </td>
          <td class="num"><strong>${formatNumber(r.activeQty)} ${escapeHtml(r.unitCode)}</strong></td>
          <td class="num">${formatRupiah(r.item.unit_price)}</td>
          <td class="num">${calc.disc > 0 ? formatRupiah(calc.disc) : '-'}</td>
          <td class="num"><strong>${formatRupiah(calc.total)}</strong></td>
        </tr>
      `;
    })
    .join('');

  const payTermLabel =
    so?.payment_type === 'credit'
      ? `Kredit / Tempo (${Number(so.payment_term_days || 0)} Hari)`
      : 'Tunai / COD';

  const sheetEl = document.createElement('div');
  sheetEl.id = 'tjd-print-sheet';
  sheetEl.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:flex-start;border-bottom:2px solid #111827;padding-bottom:8px;margin-bottom:12px;">
      <div>
        <div style="font-size:15pt;font-weight:bold;letter-spacing:0.3px;">${escapeHtml(APP_CONFIG.COMPANY_LEGAL_NAME)}</div>
        <div style="font-size:9.5pt;color:#374151;">Distributor Resmi Air Minum Dalam Kemasan (AMDK) & Minuman</div>
        <div style="font-size:9.5pt;color:#374151;">Gudang Asal: ${escapeHtml(wh?.name || '-')} ${wh?.address ? '— ' + escapeHtml(wh.address) : ''}</div>
      </div>
      <div style="text-align:right;">
        <div style="font-size:14pt;font-weight:bold;">SURAT JALAN</div>
        <div style="font-size:10.5pt;font-weight:bold;">${escapeHtml(del.delivery_number)}</div>
        <div style="font-size:9.5pt;">Ref. SO: ${escapeHtml(so?.so_number || '-')}</div>
      </div>
    </div>

    <div style="display:flex;justify-content:space-between;gap:20px;margin-bottom:10px;font-size:10pt;">
      <div style="flex:1;">
        <div style="font-weight:bold;margin-bottom:2px;">Kepada Yth:</div>
        <div style="font-size:11pt;font-weight:bold;">${escapeHtml(cust?.name || '-')}</div>
        <div>${escapeHtml(cust?.address || '-')}</div>
        ${cust?.city ? `<div>${escapeHtml(cust.city)}</div>` : ''}
        ${cust?.contact_person || cust?.phone ? `<div>PIC/Telp: ${escapeHtml(cust.contact_person || '')} ${cust.phone ? '(' + escapeHtml(cust.phone) + ')' : ''}</div>` : ''}
      </div>
      <div style="min-width:230px;">
        <div><strong>Tanggal Kirim:</strong> ${formatDateID(del.delivery_date)}</div>
        <div><strong>Pengemudi:</strong> ${escapeHtml(del.driver_name || '-')}</div>
        <div><strong>No. Kendaraan:</strong> ${escapeHtml(del.vehicle_number || '-')}</div>
        <div><strong>Pembayaran:</strong> ${escapeHtml(payTermLabel)}</div>
      </div>
    </div>

    <table>
      <thead>
        <tr>
          <th class="center" style="width:36px;">No</th>
          <th style="width:95px;">SKU</th>
          <th>Nama Produk</th>
          <th class="num" style="width:95px;">Qty Kirim</th>
          <th class="num" style="width:110px;">Harga Satuan</th>
          <th class="num" style="width:95px;">Diskon</th>
          <th class="num" style="width:120px;">Jumlah</th>
        </tr>
      </thead>
      <tbody>
        ${tableRowsHtml}
      </tbody>
      <tfoot>
        <tr>
          <td colspan="6" class="num"><strong>Subtotal</strong></td>
          <td class="num"><strong>${formatRupiah(subtotal)}</strong></td>
        </tr>
        ${
          totalDisc > 0
            ? `<tr>
                <td colspan="6" class="num">Total Diskon</td>
                <td class="num">-${formatRupiah(totalDisc)}</td>
              </tr>`
            : ''
        }
        ${
          totalTax > 0
            ? `<tr>
                <td colspan="6" class="num">DPP (${formatRupiah(totalDpp)}) + PPN</td>
                <td class="num">${formatRupiah(totalTax)}</td>
              </tr>`
            : ''
        }
        <tr>
          <td colspan="6" class="num" style="font-size:11.5pt;"><strong>TOTAL TAGIHAN</strong></td>
          <td class="num" style="font-size:11.5pt;"><strong>${formatRupiah(grandTotal)}</strong></td>
        </tr>
      </tfoot>
    </table>

    ${del.notes ? `<div style="margin-top:8px;font-size:9.5pt;"><strong>Catatan:</strong> ${escapeHtml(del.notes)}</div>` : ''}

    <div style="display:flex;justify-content:space-between;text-align:center;margin-top:34px;font-size:10pt;">
      <div style="width:30%;">
        <div>Hormat Kami / Gudang,</div>
        <div style="height:55px;"></div>
        <div>( _______________________ )</div>
      </div>
      <div style="width:30%;">
        <div>Pengemudi / Sopir,</div>
        <div style="height:55px;"></div>
        <div>( ${escapeHtml(del.driver_name || '_______________________')} )</div>
      </div>
      <div style="width:30%;">
        <div>Diterima Oleh (Cap & TTD Toko),</div>
        <div style="height:55px;"></div>
        <div>( _______________________ )</div>
      </div>
    </div>
  `;

  document.body.appendChild(sheetEl);

  setTimeout(() => {
    window.print();
  }, 150);
}

/* ============================================================================
   MODAL DETAIL SURAT JALAN, CETAK, & KONFIRMASI HASIL PENGIRIMAN
   ============================================================================ */
async function openDeliveryDetailModal(del, custMap, whMap, soMap, prodMap, unitMap, ctx) {
  const canConfirm = canPerformAction(ctx.role, 'confirm_delivery_result');
  const isEditable = canConfirm && del.status !== 'invoiced';

  const items =
    unwrapResponse(
      await supabase.from('delivery_items').select('*').eq('delivery_id', del.id)
    ) || [];

  const cust = custMap.get(del.customer_id);
  const wh = whMap.get(del.warehouse_id);
  const so = soMap.get(del.sales_order_id);
  const ppnMode = so?.ppn_mode_snapshot || 'non_ppn';

  let grandTotalPreview = 0;

  const itemsHtml = items
    .map((it, idx) => {
      const prod = prodMap.get(it.product_id);
      const prodLabel = prod ? `${prod.sku} - ${prod.name}` : '-';
      const unitCode = unitMap.get(it.unit_id) || '';
      const disp = Number(it.qty_dispatched || 0);
      const deliv = Number(it.qty_delivered ?? disp);
      const dmg = Number(it.qty_damaged || 0);
      const ret = Number(it.qty_returned_undelivered || 0);
      const activeQty = del.status === 'dispatched' ? disp : deliv;
      const calc = computeDeliveryLineFinance(it, activeQty, ppnMode);
      grandTotalPreview += calc.total;

      if (!isEditable) {
        return `
          <tr>
            <td><strong>${escapeHtml(prodLabel)}</strong></td>
            <td class="num">${formatNumber(disp)} ${escapeHtml(unitCode)}</td>
            <td class="num text-success font-semibold">${formatNumber(deliv)} ${escapeHtml(unitCode)}</td>
            <td class="num text-danger">${formatNumber(dmg)}</td>
            <td class="num">${formatNumber(ret)}</td>
            <td class="num">${formatRupiah(it.unit_price)}</td>
            <td class="num font-semibold">${formatRupiah(calc.total)}</td>
          </tr>
        `;
      }

      return `
        <tr>
          <td>
            <strong>${escapeHtml(prodLabel)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">Keluar: ${formatNumber(disp)} ${escapeHtml(unitCode)}</div>
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
          <td class="num">${formatRupiah(it.unit_price)}</td>
          <td class="num font-semibold">${formatRupiah(calc.total)}</td>
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
          <strong>${escapeHtml(wh?.name || '-')}</strong>
          <div class="text-muted" style="font-size:0.8rem;">SO: ${escapeHtml(so?.so_number || '-')}</div>
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
              Pastikan jumlah <strong>Diterima + Rusak + Batal</strong> pada setiap baris sama dengan jumlah <strong>Keluar Gudang</strong>.
            </div>`
          : ''
      }

      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Produk</th>
              <th class="num">Keluar</th>
              <th class="num" style="width:95px;">Diterima</th>
              <th class="num" style="width:85px;">Rusak</th>
              <th class="num" style="width:85px;">Batal</th>
              <th class="num">Harga Satuan</th>
              <th class="num">Subtotal</th>
            </tr>
          </thead>
          <tbody>${itemsHtml}</tbody>
        </table>
      </div>

      <div style="display:flex;justify-content:flex-end;margin-top:0.75rem;padding:0.65rem 0.85rem;background:var(--color-bg);border-radius:var(--radius-sm);">
        <div><span class="text-muted">Total Nilai Surat Jalan:</span> <strong class="text-success" style="font-size:1.05rem;">${formatRupiah(grandTotalPreview)}</strong></div>
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

      document.getElementById('ddel-print')?.addEventListener('click', () => {
        const currentDriver = document.getElementById('cf-driver')?.value.trim() || del.driver_name;
        const currentPlate = document.getElementById('cf-plate')?.value.trim() || del.vehicle_number;
        const currentDate = document.getElementById('cf-date')?.value || del.delivery_date;

        const printRows = items.map((it, idx) => {
          const prod = prodMap.get(it.product_id);
          const disp = Number(it.qty_dispatched || 0);
          const qDelInput = document.querySelector(`[data-cf-deliv="${idx}"]`);
          const qDmgInput = document.querySelector(`[data-cf-dmg="${idx}"]`);
          const qRetInput = document.querySelector(`[data-cf-ret="${idx}"]`);

          const qDel = qDelInput ? Number(qDelInput.value || 0) : Number(it.qty_delivered ?? disp);
          const qDmg = qDmgInput ? Number(qDmgInput.value || 0) : Number(it.qty_damaged || 0);
          const qRet = qRetInput ? Number(qRetInput.value || 0) : Number(it.qty_returned_undelivered || 0);

          const activeQty = del.status === 'dispatched' && !qDelInput ? disp : qDel;

          return {
            item: it,
            sku: prod?.sku || '-',
            productName: prod?.name || '-',
            unitCode: unitMap.get(it.unit_id) || '',
            activeQty,
            qtyDamaged: qDmg,
            qtyReturned: qRet
          };
        });

        triggerPrintDeliveryNote({
          del: {
            ...del,
            driver_name: currentDriver,
            vehicle_number: currentPlate,
            delivery_date: currentDate
          },
          so,
          cust,
          wh,
          rows: printRows
        });
      });

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
