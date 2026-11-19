/**
 * Modul Dashboard Utama Toya Distribution
 */

import { ROLES, ROLE_LABELS } from '../config/app-config.js';
import { supabase } from '../config/supabase-client.js';
import { canAccessMenu } from '../auth/permission-guard.js';
import { callRpc } from '../services/base-service.js';
import { formatDateID, getPeriodRange } from '../utils/date-utils.js';
import { escapeHtml, formatNumber, formatRupiah } from '../utils/formatter.js';
import {
  renderEmptyState,
  renderLoadingState,
  renderPeriodFilterBar,
  showToast
} from '../ui/ui-components.js';

let filterState = {
  preset: 'this_month',
  ...getPeriodRange('this_month')
};

export async function renderModule(container, ctx, helpers) {
  const roleLabel = ROLE_LABELS[ctx.role] || ctx.role;

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Ringkasan Operasional & Keuangan</h2>
        <p>Halo, <strong>${escapeHtml(ctx.profile.full_name)}</strong> (${escapeHtml(roleLabel)})</p>
      </div>
      <div class="page-actions no-print">
        <button type="button" class="btn btn-secondary" id="btn-dash-refresh">
          <span class="material-symbols-outlined">refresh</span>
          Muat Ulang
        </button>
      </div>
    </div>

    <div id="dash-period-filter"></div>
    <div id="dash-content">${renderLoadingState('Menghitung ringkasan data...')}</div>
  `;

  renderPeriodFilterBar('dash-period-filter', filterState, async (nextFilter) => {
    filterState = nextFilter;
    await loadDashboardData(ctx, helpers);
  });

  document.getElementById('btn-dash-refresh')?.addEventListener('click', () => {
    loadDashboardData(ctx, helpers);
  });

  await loadDashboardData(ctx, helpers);
}

async function loadDashboardData(ctx, helpers) {
  const contentEl = document.getElementById('dash-content');
  if (!contentEl) return;

  contentEl.innerHTML = renderLoadingState('Menghitung ringkasan data...');

  try {
    const summary = await callRpc('rpc_get_dashboard_summary', {
      p_start_date: filterState.startDate,
      p_end_date: filterState.endDate
    });

    const isFinanceOrOwner = [ROLES.FINANCE_ADMIN, ROLES.OWNER].includes(ctx.role);
    const isSales = ctx.role === ROLES.SALES;
    const isWarehouseOrCashier = [ROLES.WAREHOUSE, ROLES.CASHIER].includes(ctx.role);

    const periodInfo =
      summary.start_date && summary.end_date
        ? `${formatDateID(summary.start_date)} – ${formatDateID(summary.end_date)}`
        : 'Semua Periode';

    let kpiCardsHtml = '';

    if (isSales) {
      kpiCardsHtml = `
        <div class="kpi-card">
          <span class="kpi-label">Pesanan (SO) Saya</span>
          <span class="kpi-value">${formatNumber(summary.so_count, 0)} SO</span>
          <span class="kpi-sub">Nilai pesanan: ${formatRupiah(summary.so_value)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Faktur Terbit</span>
          <span class="kpi-value">${formatNumber(summary.invoice_count, 0)} Faktur</span>
          <span class="kpi-sub">Omzet kotor: ${formatRupiah(summary.gross_sales)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Omzet Bersih Saya</span>
          <span class="kpi-value text-success">${formatRupiah(summary.net_sales)}</span>
          <span class="kpi-sub">Potongan retur/nota kredit: ${formatRupiah(summary.credit_notes)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Piutang Belum Lunas</span>
          <span class="kpi-value text-warning">${formatRupiah(summary.total_receivables)}</span>
          <span class="kpi-sub">Jatuh tempo: ${formatRupiah(summary.overdue_receivables)}</span>
        </div>
      `;
    } else if (isWarehouseOrCashier) {
      kpiCardsHtml = `
        <div class="kpi-card">
          <span class="kpi-label">Pesanan (SO) Periode Ini</span>
          <span class="kpi-value">${formatNumber(summary.so_count, 0)} SO</span>
          <span class="kpi-sub">${escapeHtml(periodInfo)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Faktur Penjualan Terbit</span>
          <span class="kpi-value">${formatNumber(summary.invoice_count, 0)} Faktur</span>
          <span class="kpi-sub">Nilai bersih: ${formatRupiah(summary.net_sales)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Piutang Pelanggan Aktif</span>
          <span class="kpi-value">${formatRupiah(summary.total_receivables)}</span>
          <span class="kpi-sub">Lewat jatuh tempo: ${formatRupiah(summary.overdue_receivables)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Peringatan Stok Menipis</span>
          <span class="kpi-value ${Number(summary.low_stock_count) > 0 ? 'text-danger' : 'text-success'}">
            ${formatNumber(summary.low_stock_count, 0)} Item
          </span>
          <span class="kpi-sub">Perlu pengecekan persediaan gudang</span>
        </div>
      `;
    } else {
      kpiCardsHtml = `
        <div class="kpi-card">
          <span class="kpi-label">Omzet Bersih Penjualan</span>
          <span class="kpi-value text-success">${formatRupiah(summary.net_sales)}</span>
          <span class="kpi-sub">${formatNumber(summary.invoice_count, 0)} faktur • Retur: ${formatRupiah(summary.credit_notes)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Total Piutang Pelanggan</span>
          <span class="kpi-value">${formatRupiah(summary.total_receivables)}</span>
          <span class="kpi-sub">Jatuh tempo: ${formatRupiah(summary.overdue_receivables)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Total Utang Supplier</span>
          <span class="kpi-value text-warning">${formatRupiah(summary.total_payables)}</span>
          <span class="kpi-sub">Klaim voucher terbuka: ${formatRupiah(summary.open_voucher_claims)}</span>
        </div>
        <div class="kpi-card">
          <span class="kpi-label">Nilai Persediaan Gudang</span>
          <span class="kpi-value">${formatRupiah(summary.inventory_value)}</span>
          <span class="kpi-sub">Stok menipis: ${formatNumber(summary.low_stock_count, 0)} item</span>
        </div>
      `;
    }

    let secondaryRowHtml = '';
    if (isFinanceOrOwner) {
      secondaryRowHtml = `
        <div class="grid-3" style="margin-bottom:1.25rem;">
          <div class="kpi-card">
            <span class="kpi-label">Total Pesanan Masuk (SO)</span>
            <span class="kpi-value">${formatRupiah(summary.so_value)}</span>
            <span class="kpi-sub">${formatNumber(summary.so_count, 0)} pesanan (${escapeHtml(periodInfo)})</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Biaya Operasional Terverifikasi</span>
            <span class="kpi-value">${formatRupiah(summary.verified_expenses)}</span>
            <span class="kpi-sub">Periode ${escapeHtml(periodInfo)}</span>
          </div>
          <div class="kpi-card">
            <span class="kpi-label">Antrean Persetujuan & Verifikasi</span>
            <span class="kpi-value ${Number(summary.pending_approvals) > 0 ? 'text-warning' : ''}">
              ${formatNumber(summary.pending_approvals, 0)} Dokumen
            </span>
            <span class="kpi-sub">Diskon SO, pembayaran, biaya, & opname</span>
          </div>
        </div>
      `;
    }

    let lowStockHtml = '';
    if (!isSales) {
      const { data: lowStockItems } = await supabase
        .from('view_inventory_valuation')
        .select('warehouse_name, sku, product_name, unit_name, qty_on_hand, min_stock_alert')
        .eq('is_low_stock', true)
        .order('qty_on_hand', { ascending: true })
        .limit(10);

      if (Array.isArray(lowStockItems) && lowStockItems.length > 0) {
        const rows = lowStockItems
          .map(
            (item) => `
            <tr>
              <td>${escapeHtml(item.warehouse_name)}</td>
              <td><strong>${escapeHtml(item.sku)}</strong> - ${escapeHtml(item.product_name)}</td>
              <td class="num text-danger font-semibold">${formatNumber(item.qty_on_hand)} ${escapeHtml(item.unit_name)}</td>
              <td class="num">${formatNumber(item.min_stock_alert)} ${escapeHtml(item.unit_name)}</td>
            </tr>
          `
          )
          .join('');

        lowStockHtml = `
          <div class="card">
            <div class="card-header">
              <h3 class="card-title">Peringatan Stok Menipis di Gudang</h3>
              ${
                canAccessMenu(ctx.role, 'inventory-ledger')
                  ? `<button type="button" class="btn btn-secondary btn-sm" id="btn-dash-to-stock">Lihat Semua Stok</button>`
                  : ''
              }
            </div>
            <div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Gudang</th>
                    <th>Produk</th>
                    <th class="num">Stok Tersedia</th>
                    <th class="num">Batas Minimum</th>
                  </tr>
                </thead>
                <tbody>${rows}</tbody>
              </table>
            </div>
          </div>
        `;
      } else {
        lowStockHtml = `
          <div class="card">
            <div class="card-header">
              <h3 class="card-title">Status Persediaan Gudang</h3>
            </div>
            <div class="card-body">
              ${renderEmptyState('Seluruh produk berada di atas batas minimum stok.', 'check_circle')}
            </div>
          </div>
        `;
      }
    }

    const quickButtons = [
      { menu: 'sales-orders', label: 'Sales Order', icon: 'shopping_cart' },
      { menu: 'deliveries', label: 'Pengiriman', icon: 'local_shipping' },
      { menu: 'sales-invoices', label: 'Faktur Jual', icon: 'receipt_long' },
      { menu: 'approvals', label: 'Persetujuan', icon: 'check_circle' },
      { menu: 'sales-performance', label: 'Kinerja Sales', icon: 'leaderboard' },
      { menu: 'accounting', label: 'Laporan Keuangan', icon: 'account_balance' }
    ].filter((b) => canAccessMenu(ctx.role, b.menu));

    const quickNavHtml = `
      <div class="card no-print">
        <div class="card-header">
          <h3 class="card-title">Akses Cepat Modul</h3>
        </div>
        <div class="card-body" style="display:flex;flex-wrap:wrap;gap:0.65rem;">
          ${quickButtons
            .map(
              (b) => `
            <button type="button" class="btn btn-secondary" data-quick-menu="${b.menu}">
              <span class="material-symbols-outlined">${b.icon}</span>
              ${escapeHtml(b.label)}
            </button>
          `
            )
            .join('')}
        </div>
      </div>
    `;

    contentEl.innerHTML = `
      <div class="grid-kpi">${kpiCardsHtml}</div>
      ${secondaryRowHtml}
      ${quickNavHtml}
      ${lowStockHtml}
    `;

    contentEl.querySelectorAll('[data-quick-menu]').forEach((btn) => {
      btn.addEventListener('click', () => {
        helpers.navigateToMenu(btn.getAttribute('data-quick-menu'));
      });
    });

    document.getElementById('btn-dash-to-stock')?.addEventListener('click', () => {
      helpers.navigateToMenu('inventory-ledger');
    });
  } catch (err) {
    contentEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}
