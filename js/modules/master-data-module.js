/**
 * Modul Data Master (Produk & Satuan Utuh, Pelanggan, Supplier, Gudang, Bank & Metode Pembayaran)
 */

import { supabase } from '../config/supabase-client.js';
import { canPerformAction } from '../auth/permission-guard.js';
import { unwrapResponse } from '../services/base-service.js';
import { escapeHtml, formatNumber, formatRupiah } from '../utils/formatter.js';
import {
  closeModal,
  openModal,
  renderEmptyState,
  renderLoadingState,
  showToast
} from '../ui/ui-components.js';

let activeTab = 'products';

export async function renderModule(container, ctx) {
  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Data Master Operasional</h2>
        <p>Referensi produk, satuan karton/galon, pelanggan outlet, supplier, gudang, dan rekening bank</p>
      </div>
    </div>

    <div class="tabs no-print">
      <button type="button" class="tab-btn ${activeTab === 'products' ? 'active' : ''}" data-tab="products">Produk & Satuan</button>
      <button type="button" class="tab-btn ${activeTab === 'customers' ? 'active' : ''}" data-tab="customers">Pelanggan (Outlet)</button>
      <button type="button" class="tab-btn ${activeTab === 'suppliers' ? 'active' : ''}" data-tab="suppliers">Supplier / Principal</button>
      <button type="button" class="tab-btn ${activeTab === 'warehouses' ? 'active' : ''}" data-tab="warehouses">Gudang</button>
      <button type="button" class="tab-btn ${activeTab === 'banks' ? 'active' : ''}" data-tab="banks">Bank & Metode Bayar</button>
    </div>

    <div id="master-tab-body">${renderLoadingState()}</div>
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
  const bodyEl = document.getElementById('master-tab-body');
  if (!bodyEl) return;
  bodyEl.innerHTML = renderLoadingState();

  try {
    if (activeTab === 'products') {
      await renderProductsTab(bodyEl, ctx);
    } else if (activeTab === 'customers') {
      await renderCustomersTab(bodyEl, ctx);
    } else if (activeTab === 'suppliers') {
      await renderSuppliersTab(bodyEl, ctx);
    } else if (activeTab === 'warehouses') {
      await renderWarehousesTab(bodyEl, ctx);
    } else {
      await renderBanksTab(bodyEl, ctx);
    }
  } catch (err) {
    bodyEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

/* ============================================================================
   TAB 1: PRODUK & SATUAN (TANPA KONVERSI ECERAN — KARTON & GALON PCS)
   ============================================================================ */
async function renderProductsTab(bodyEl, ctx) {
  const canManage = canPerformAction(ctx.role, 'manage_master_data');

  const [prodRes, unitRes, taxRes] = await Promise.all([
    supabase.from('products').select('*').order('name', { ascending: true }),
    supabase.from('units').select('*').order('name', { ascending: true }),
    supabase.from('tax_codes').select('*').eq('is_active', true).order('code', { ascending: true })
  ]);

  const products = unwrapResponse(prodRes) || [];
  const units = unwrapResponse(unitRes) || [];
  const taxCodes = unwrapResponse(taxRes) || [];

  const unitMap = new Map(units.map((u) => [u.id, u]));
  const taxMap = new Map(taxCodes.map((t) => [t.id, t]));

  const rowsHtml = products
    .map((p) => {
      const u = unitMap.get(p.base_unit_id);
      const t = taxMap.get(p.tax_code_id);
      return `
        <tr>
          <td><strong>${escapeHtml(p.sku)}</strong></td>
          <td>
            <strong>${escapeHtml(p.name)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(p.brand || '-')} • ${escapeHtml(p.category || 'Umum')}</div>
          </td>
          <td>${escapeHtml(u ? `${u.name} (${u.code})` : '-')}</td>
          <td class="num font-semibold">${formatRupiah(p.standard_sell_price)}</td>
          <td>${escapeHtml(t ? t.code : 'Non-PPN')}</td>
          <td class="num">${formatNumber(p.min_stock_alert)}</td>
          <td>
            <span class="badge ${p.is_active ? 'badge-success' : 'badge-neutral'}">
              ${p.is_active ? 'Aktif' : 'Nonaktif'}
            </span>
          </td>
          ${
            canManage
              ? `<td class="text-right">
                  <button type="button" class="btn btn-secondary btn-sm" data-edit-prod="${p.id}">Edit</button>
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
        <h3 class="card-title">Daftar Produk (${products.length} Item)</h3>
        ${
          canManage
            ? `<div style="display:flex;gap:0.5rem;">
                <button type="button" class="btn btn-secondary btn-sm" id="btn-add-unit">+ Satuan Baru</button>
                <button type="button" class="btn btn-primary btn-sm" id="btn-add-product">+ Tambah Produk</button>
              </div>`
            : ''
        }
      </div>
      ${
        products.length === 0
          ? `<div class="card-body">${renderEmptyState('Belum ada master produk. Tambahkan produk pertama Anda.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>SKU</th>
                    <th>Nama Produk & Merek</th>
                    <th>Satuan</th>
                    <th class="num">Harga Jual Standar</th>
                    <th>Pajak</th>
                    <th class="num">Min. Stok</th>
                    <th>Status</th>
                    ${canManage ? '<th class="text-right">Aksi</th>' : ''}
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>`
      }
    </div>
  `;

  if (canManage) {
    document.getElementById('btn-add-unit')?.addEventListener('click', () => openUnitModal(ctx));
    document.getElementById('btn-add-product')?.addEventListener('click', () =>
      openProductModal(null, units, taxCodes, ctx)
    );
    bodyEl.querySelectorAll('[data-edit-prod]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const prod = products.find((item) => item.id === btn.getAttribute('data-edit-prod'));
        if (prod) openProductModal(prod, units, taxCodes, ctx);
      });
    });
  }
}

function openUnitModal(ctx) {
  openModal({
    title: 'Tambah Satuan Barang Baru',
    bodyHtml: `
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="unit-code">Kode Satuan <span class="req">*</span></label>
          <input type="text" id="unit-code" class="form-control" placeholder="Contoh: DUS, GLN, PCS" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="unit-name">Nama Satuan <span class="req">*</span></label>
          <input type="text" id="unit-name" class="form-control" placeholder="Contoh: Karton / Galon Pcs" required />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="unit-desc">Keterangan (Opsional)</label>
        <input type="text" id="unit-desc" class="form-control" placeholder="Contoh: Satuan penjualan per karton utuh" />
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="unit-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="unit-save">Simpan Satuan</button>
    `,
    onMount: () => {
      document.getElementById('unit-cancel')?.addEventListener('click', closeModal);
      document.getElementById('unit-save')?.addEventListener('click', async () => {
        const code = document.getElementById('unit-code').value.trim().toUpperCase();
        const name = document.getElementById('unit-name').value.trim();
        const description = document.getElementById('unit-desc').value.trim() || null;

        if (!code || !name) {
          showToast('Kode dan nama satuan wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('unit-save');
        btn.disabled = true;

        try {
          unwrapResponse(
            await supabase.from('units').insert({ code, name, description, is_active: true })
          );
          closeModal();
          showToast('Satuan baru berhasil disimpan.', 'success');
          await loadTabContent(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

function openProductModal(product, units, taxCodes, ctx) {
  const isEdit = Boolean(product);
  const unitOpts = units
    .map(
      (u) =>
        `<option value="${u.id}" ${product?.base_unit_id === u.id ? 'selected' : ''}>${escapeHtml(u.name)} (${escapeHtml(u.code)})</option>`
    )
    .join('');

  const taxOpts =
    `<option value="">-- Tanpa PPN / Non-PPN --</option>` +
    taxCodes
      .map(
        (t) =>
          `<option value="${t.id}" ${product?.tax_code_id === t.id ? 'selected' : ''}>${escapeHtml(t.code)} - ${escapeHtml(t.name)}</option>`
      )
      .join('');

  openModal({
    title: isEdit ? `Edit Produk: ${product.name}` : 'Tambah Produk Baru',
    bodyHtml: `
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="prod-sku">Kode SKU</label>
          <input type="text" id="prod-sku" class="form-control" value="${escapeHtml(product?.sku || '')}" placeholder="Kosongkan untuk kode otomatis" />
        </div>
        <div class="form-group">
          <label class="form-label" for="prod-brand">Merek / Principal</label>
          <input type="text" id="prod-brand" class="form-control" value="${escapeHtml(product?.brand || '')}" placeholder="Contoh: Aqua, Le Minerale, Teh Pucuk" />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="prod-name">Nama Produk Lengkap <span class="req">*</span></label>
        <input type="text" id="prod-name" class="form-control" value="${escapeHtml(product?.name || '')}" placeholder="Contoh: Aqua Botol 600ml (Karton) / Aqua Galon 19L" required />
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="prod-unit">Satuan Jual & Stok <span class="req">*</span></label>
          <select id="prod-unit" class="form-control" required>${unitOpts}</select>
        </div>
        <div class="form-group">
          <label class="form-label" for="prod-category">Kategori</label>
          <input type="text" id="prod-category" class="form-control" value="${escapeHtml(product?.category || '')}" placeholder="Contoh: AMDK Botol, AMDK Galon, MBDK" />
        </div>
      </div>
      <div class="grid-3">
        <div class="form-group">
          <label class="form-label" for="prod-price">Harga Jual Standar (Rp) <span class="req">*</span></label>
          <input type="number" step="1" min="0" id="prod-price" class="form-control" value="${Number(product?.standard_sell_price || 0)}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="prod-tax">Kode Pajak PPN</label>
          <select id="prod-tax" class="form-control">${taxOpts}</select>
        </div>
        <div class="form-group">
          <label class="form-label" for="prod-min-stock">Batas Stok Minimum</label>
          <input type="number" step="1" min="0" id="prod-min-stock" class="form-control" value="${Number(product?.min_stock_alert || 10)}" />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="prod-active">Status Produk</label>
        <select id="prod-active" class="form-control">
          <option value="true" ${product?.is_active !== false ? 'selected' : ''}>Aktif</option>
          <option value="false" ${product?.is_active === false ? 'selected' : ''}>Nonaktif</option>
        </select>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="prod-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="prod-save">Simpan Produk</button>
    `,
    onMount: () => {
      document.getElementById('prod-cancel')?.addEventListener('click', closeModal);
      document.getElementById('prod-save')?.addEventListener('click', async () => {
        const selectedUnitId = document.getElementById('prod-unit').value;
        const payload = {
          sku: document.getElementById('prod-sku').value.trim().toUpperCase(),
          name: document.getElementById('prod-name').value.trim(),
          brand: document.getElementById('prod-brand').value.trim() || null,
          category: document.getElementById('prod-category').value.trim() || null,
          base_unit_id: selectedUnitId,
          default_sales_unit_id: selectedUnitId,
          default_purchase_unit_id: selectedUnitId,
          standard_sell_price: Number(document.getElementById('prod-price').value || 0),
          tax_code_id: document.getElementById('prod-tax').value || null,
          min_stock_alert: Number(document.getElementById('prod-min-stock').value || 0),
          is_active: document.getElementById('prod-active').value === 'true'
        };

        if (!payload.name || !payload.base_unit_id) {
          showToast('Nama produk dan satuan wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('prod-save');
        btn.disabled = true;

        try {
          if (isEdit) {
            unwrapResponse(await supabase.from('products').update(payload).eq('id', product.id));
          } else {
            unwrapResponse(
              await supabase.from('products').insert({ ...payload, created_by: ctx.user.id })
            );
          }
          closeModal();
          showToast('Data produk berhasil disimpan.', 'success');
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
   TAB 2: PELANGGAN (OUTLET / TOKO)
   ============================================================================ */
async function renderCustomersTab(bodyEl, ctx) {
  const canManage = canPerformAction(ctx.role, 'manage_customer_data');
  const res = await supabase.from('customers').select('*').order('name', { ascending: true });
  const customers = unwrapResponse(res) || [];

  const rowsHtml = customers
    .map((c) => {
      const termDays = Number(c.payment_term_days || 0);
      const terminText = termDays > 0 ? `Tempo (${termDays} Hari)` : 'Tunai (COD)';
      return `
        <tr>
          <td><strong>${escapeHtml(c.code)}</strong></td>
          <td>
            <strong>${escapeHtml(c.name)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(c.address || '-')}</div>
          </td>
          <td>${escapeHtml(c.contact_person || '-')} ${c.phone ? '(' + escapeHtml(c.phone) + ')' : ''}</td>
          <td>${escapeHtml(terminText)}</td>
          <td class="num">${formatRupiah(c.credit_limit)}</td>
          <td>
            <span class="badge ${c.is_active ? 'badge-success' : 'badge-neutral'}">
              ${c.is_active ? 'Aktif' : 'Nonaktif'}
            </span>
          </td>
          ${
            canManage
              ? `<td class="text-right">
                  <button type="button" class="btn btn-secondary btn-sm" data-edit-cust="${c.id}">Edit</button>
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
        <h3 class="card-title">Daftar Pelanggan & Toko Outlet (${customers.length})</h3>
        ${
          canManage
            ? `<button type="button" class="btn btn-primary btn-sm" id="btn-add-cust">+ Tambah Pelanggan</button>`
            : ''
        }
      </div>
      ${
        customers.length === 0
          ? `<div class="card-body">${renderEmptyState('Belum ada data pelanggan terdaftar.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Kode</th>
                    <th>Nama Toko & Alamat</th>
                    <th>Kontak</th>
                    <th>Termin Default</th>
                    <th class="num">Limit Kredit</th>
                    <th>Status</th>
                    ${canManage ? '<th class="text-right">Aksi</th>' : ''}
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>`
      }
    </div>
  `;

  if (canManage) {
    document.getElementById('btn-add-cust')?.addEventListener('click', () => openCustomerModal(null, ctx));
    bodyEl.querySelectorAll('[data-edit-cust]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const cust = customers.find((item) => item.id === btn.getAttribute('data-edit-cust'));
        if (cust) openCustomerModal(cust, ctx);
      });
    });
  }
}

function openCustomerModal(customer, ctx) {
  const isEdit = Boolean(customer);
  openModal({
    title: isEdit ? `Edit Pelanggan: ${customer.name}` : 'Tambah Pelanggan / Outlet Baru',
    bodyHtml: `
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="cust-code">Kode Pelanggan</label>
          <input type="text" id="cust-code" class="form-control" value="${escapeHtml(customer?.code || '')}" placeholder="Kosongkan untuk kode otomatis" />
        </div>
        <div class="form-group">
          <label class="form-label" for="cust-npwp">NPWP Pelanggan</label>
          <input type="text" id="cust-npwp" class="form-control" value="${escapeHtml(customer?.npwp || '')}" placeholder="Opsional" />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="cust-name">Nama Toko / Perusahaan <span class="req">*</span></label>
        <input type="text" id="cust-name" class="form-control" value="${escapeHtml(customer?.name || '')}" placeholder="Contoh: Toko Sumber Rejeki" required />
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="cust-contact">Nama Pemilik / PIC</label>
          <input type="text" id="cust-contact" class="form-control" value="${escapeHtml(customer?.contact_person || '')}" />
        </div>
        <div class="form-group">
          <label class="form-label" for="cust-phone">Nomor WhatsApp / Telepon</label>
          <input type="text" id="cust-phone" class="form-control" value="${escapeHtml(customer?.phone || '')}" />
        </div>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="cust-city">Kota / Wilayah</label>
          <input type="text" id="cust-city" class="form-control" value="${escapeHtml(customer?.city || '')}" placeholder="Contoh: Cileungsi, Kab. Bogor" />
        </div>
        <div class="form-group">
          <label class="form-label" for="cust-active">Status Pelanggan</label>
          <select id="cust-active" class="form-control">
            <option value="true" ${customer?.is_active !== false ? 'selected' : ''}>Aktif</option>
            <option value="false" ${customer?.is_active === false ? 'selected' : ''}>Nonaktif</option>
          </select>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="cust-address">Alamat Pengiriman Lengkap</label>
        <textarea id="cust-address" class="form-control">${escapeHtml(customer?.address || '')}</textarea>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="cust-term">Termin Kredit (Hari)</label>
          <input type="number" min="0" id="cust-term" class="form-control" value="${Number(customer?.payment_term_days || 0)}" />
          <span class="form-help">Isi 0 untuk Tunai/COD, atau jumlah hari tempo (misal: 7, 14, 30).</span>
        </div>
        <div class="form-group">
          <label class="form-label" for="cust-limit">Batas Kredit / Piutang (Rp)</label>
          <input type="number" min="0" id="cust-limit" class="form-control" value="${Number(customer?.credit_limit || 0)}" />
        </div>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="cust-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="cust-save">Simpan Pelanggan</button>
    `,
    onMount: () => {
      document.getElementById('cust-cancel')?.addEventListener('click', closeModal);
      document.getElementById('cust-save')?.addEventListener('click', async () => {
        const payload = {
          code: document.getElementById('cust-code').value.trim().toUpperCase(),
          name: document.getElementById('cust-name').value.trim(),
          npwp: document.getElementById('cust-npwp').value.trim() || null,
          contact_person: document.getElementById('cust-contact').value.trim() || null,
          phone: document.getElementById('cust-phone').value.trim() || null,
          city: document.getElementById('cust-city').value.trim() || null,
          address: document.getElementById('cust-address').value.trim() || null,
          payment_term_days: Number(document.getElementById('cust-term').value || 0),
          credit_limit: Number(document.getElementById('cust-limit').value || 0),
          is_active: document.getElementById('cust-active').value === 'true'
        };

        if (!payload.name) {
          showToast('Nama toko pelanggan wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('cust-save');
        btn.disabled = true;

        try {
          if (isEdit) {
            unwrapResponse(await supabase.from('customers').update(payload).eq('id', customer.id));
          } else {
            unwrapResponse(
              await supabase.from('customers').insert({ ...payload, created_by: ctx.user.id })
            );
          }
          closeModal();
          showToast('Data pelanggan berhasil disimpan.', 'success');
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
   TAB 3: SUPPLIER / PRINCIPAL
   ============================================================================ */
async function renderSuppliersTab(bodyEl, ctx) {
  const canManage = canPerformAction(ctx.role, 'manage_master_data');
  const res = await supabase.from('suppliers').select('*').order('name', { ascending: true });
  const suppliers = unwrapResponse(res) || [];

  const rowsHtml = suppliers
    .map(
      (s) => `
      <tr>
        <td><strong>${escapeHtml(s.code)}</strong></td>
        <td>
          <strong>${escapeHtml(s.name)}</strong>
          <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(s.address || '-')}</div>
        </td>
        <td>${escapeHtml(s.contact_person || '-')} ${s.phone ? '(' + escapeHtml(s.phone) + ')' : ''}</td>
        <td>${escapeHtml(s.npwp || '-')}</td>
        <td class="num">${Number(s.payment_term_days || 0)} Hari</td>
        <td>
          <span class="badge ${s.is_active ? 'badge-success' : 'badge-neutral'}">
            ${s.is_active ? 'Aktif' : 'Nonaktif'}
          </span>
        </td>
        ${
          canManage
            ? `<td class="text-right">
                <button type="button" class="btn btn-secondary btn-sm" data-edit-supp="${s.id}">Edit</button>
              </td>`
            : ''
        }
      </tr>
    `
    )
    .join('');

  bodyEl.innerHTML = `
    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Daftar Supplier & Principal (${suppliers.length})</h3>
        ${
          canManage
            ? `<button type="button" class="btn btn-primary btn-sm" id="btn-add-supp">+ Tambah Supplier</button>`
            : ''
        }
      </div>
      ${
        suppliers.length === 0
          ? `<div class="card-body">${renderEmptyState('Belum ada data supplier atau principal.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Kode</th>
                    <th>Nama Supplier / Principal</th>
                    <th>Kontak</th>
                    <th>NPWP</th>
                    <th class="num">Termin</th>
                    <th>Status</th>
                    ${canManage ? '<th class="text-right">Aksi</th>' : ''}
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>`
      }
    </div>
  `;

  if (canManage) {
    document.getElementById('btn-add-supp')?.addEventListener('click', () => openSupplierModal(null, ctx));
    bodyEl.querySelectorAll('[data-edit-supp]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const supp = suppliers.find((item) => item.id === btn.getAttribute('data-edit-supp'));
        if (supp) openSupplierModal(supp, ctx);
      });
    });
  }
}

function openSupplierModal(supplier, ctx) {
  const isEdit = Boolean(supplier);
  openModal({
    title: isEdit ? `Edit Supplier: ${supplier.name}` : 'Tambah Supplier / Principal Baru',
    bodyHtml: `
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="supp-code">Kode Supplier</label>
          <input type="text" id="supp-code" class="form-control" value="${escapeHtml(supplier?.code || '')}" placeholder="Kosongkan untuk kode otomatis" />
        </div>
        <div class="form-group">
          <label class="form-label" for="supp-npwp">NPWP Supplier</label>
          <input type="text" id="supp-npwp" class="form-control" value="${escapeHtml(supplier?.npwp || '')}" />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="supp-name">Nama Perusahaan Supplier <span class="req">*</span></label>
        <input type="text" id="supp-name" class="form-control" value="${escapeHtml(supplier?.name || '')}" placeholder="Contoh: PT Tirta Investama" required />
      </div>
      <div class="grid-3">
        <div class="form-group">
          <label class="form-label" for="supp-contact">Nama PIC</label>
          <input type="text" id="supp-contact" class="form-control" value="${escapeHtml(supplier?.contact_person || '')}" />
        </div>
        <div class="form-group">
          <label class="form-label" for="supp-phone">Telepon</label>
          <input type="text" id="supp-phone" class="form-control" value="${escapeHtml(supplier?.phone || '')}" />
        </div>
        <div class="form-group">
          <label class="form-label" for="supp-term">Termin Bayar (Hari)</label>
          <input type="number" min="0" id="supp-term" class="form-control" value="${Number(supplier?.payment_term_days || 14)}" />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="supp-address">Alamat</label>
        <textarea id="supp-address" class="form-control">${escapeHtml(supplier?.address || '')}</textarea>
      </div>
      <div class="form-group">
        <label class="form-label" for="supp-active">Status Supplier</label>
        <select id="supp-active" class="form-control">
          <option value="true" ${supplier?.is_active !== false ? 'selected' : ''}>Aktif</option>
          <option value="false" ${supplier?.is_active === false ? 'selected' : ''}>Nonaktif</option>
        </select>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="supp-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="supp-save">Simpan Supplier</button>
    `,
    onMount: () => {
      document.getElementById('supp-cancel')?.addEventListener('click', closeModal);
      document.getElementById('supp-save')?.addEventListener('click', async () => {
        const payload = {
          code: document.getElementById('supp-code').value.trim().toUpperCase(),
          name: document.getElementById('supp-name').value.trim(),
          npwp: document.getElementById('supp-npwp').value.trim() || null,
          contact_person: document.getElementById('supp-contact').value.trim() || null,
          phone: document.getElementById('supp-phone').value.trim() || null,
          payment_term_days: Number(document.getElementById('supp-term').value || 0),
          address: document.getElementById('supp-address').value.trim() || null,
          is_active: document.getElementById('supp-active').value === 'true'
        };

        if (!payload.name) {
          showToast('Nama supplier wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('supp-save');
        btn.disabled = true;

        try {
          if (isEdit) {
            unwrapResponse(await supabase.from('suppliers').update(payload).eq('id', supplier.id));
          } else {
            unwrapResponse(
              await supabase.from('suppliers').insert({ ...payload, created_by: ctx.user.id })
            );
          }
          closeModal();
          showToast('Data supplier berhasil disimpan.', 'success');
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
   TAB 4: GUDANG
   ============================================================================ */
async function renderWarehousesTab(bodyEl, ctx) {
  const canManage = canPerformAction(ctx.role, 'manage_master_data');
  const res = await supabase.from('warehouses').select('*').order('code', { ascending: true });
  const warehouses = unwrapResponse(res) || [];

  const rowsHtml = warehouses
    .map(
      (w) => `
      <tr>
        <td><strong>${escapeHtml(w.code)}</strong></td>
        <td><strong>${escapeHtml(w.name)}</strong></td>
        <td>${escapeHtml(w.address || '-')}</td>
        <td>${escapeHtml(w.phone || '-')}</td>
        <td>
          <span class="badge ${w.is_active ? 'badge-success' : 'badge-neutral'}">
            ${w.is_active ? 'Aktif' : 'Nonaktif'}
          </span>
        </td>
        ${
          canManage
            ? `<td class="text-right">
                <button type="button" class="btn btn-secondary btn-sm" data-edit-wh="${w.id}">Edit</button>
              </td>`
            : ''
        }
      </tr>
    `
    )
    .join('');

  bodyEl.innerHTML = `
    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Daftar Lokasi Gudang (${warehouses.length})</h3>
        ${
          canManage
            ? `<button type="button" class="btn btn-primary btn-sm" id="btn-add-wh">+ Tambah Gudang</button>`
            : ''
        }
      </div>
      ${
        warehouses.length === 0
          ? `<div class="card-body">${renderEmptyState('Belum ada lokasi gudang terdaftar.')}</div>`
          : `<div class="table-responsive">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Kode</th>
                    <th>Nama Gudang</th>
                    <th>Alamat Lokasi</th>
                    <th>Telepon</th>
                    <th>Status</th>
                    ${canManage ? '<th class="text-right">Aksi</th>' : ''}
                  </tr>
                </thead>
                <tbody>${rowsHtml}</tbody>
              </table>
            </div>`
      }
    </div>
  `;

  if (canManage) {
    document.getElementById('btn-add-wh')?.addEventListener('click', () => openWarehouseModal(null, ctx));
    bodyEl.querySelectorAll('[data-edit-wh]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const wh = warehouses.find((item) => item.id === btn.getAttribute('data-edit-wh'));
        if (wh) openWarehouseModal(wh, ctx);
      });
    });
  }
}

function openWarehouseModal(warehouse, ctx) {
  const isEdit = Boolean(warehouse);
  openModal({
    title: isEdit ? `Edit Gudang: ${warehouse.name}` : 'Tambah Lokasi Gudang Baru',
    bodyHtml: `
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="wh-code">Kode Gudang <span class="req">*</span></label>
          <input type="text" id="wh-code" class="form-control" value="${escapeHtml(warehouse?.code || '')}" placeholder="Contoh: GDG-CLG" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="wh-active">Status</label>
          <select id="wh-active" class="form-control">
            <option value="true" ${warehouse?.is_active !== false ? 'selected' : ''}>Aktif</option>
            <option value="false" ${warehouse?.is_active === false ? 'selected' : ''}>Nonaktif</option>
          </select>
        </div>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="wh-name">Nama Gudang <span class="req">*</span></label>
          <input type="text" id="wh-name" class="form-control" value="${escapeHtml(warehouse?.name || '')}" placeholder="Contoh: Gudang Utama Cileungsi" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="wh-phone">Telepon Gudang</label>
          <input type="text" id="wh-phone" class="form-control" value="${escapeHtml(warehouse?.phone || '')}" />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="wh-address">Alamat Gudang</label>
        <textarea id="wh-address" class="form-control">${escapeHtml(warehouse?.address || '')}</textarea>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="wh-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="wh-save">Simpan Gudang</button>
    `,
    onMount: () => {
      document.getElementById('wh-cancel')?.addEventListener('click', closeModal);
      document.getElementById('wh-save')?.addEventListener('click', async () => {
        const payload = {
          code: document.getElementById('wh-code').value.trim().toUpperCase(),
          name: document.getElementById('wh-name').value.trim(),
          phone: document.getElementById('wh-phone').value.trim() || null,
          address: document.getElementById('wh-address').value.trim() || null,
          is_active: document.getElementById('wh-active').value === 'true'
        };

        if (!payload.code || !payload.name) {
          showToast('Kode dan nama gudang wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('wh-save');
        btn.disabled = true;

        try {
          if (isEdit) {
            unwrapResponse(await supabase.from('warehouses').update(payload).eq('id', warehouse.id));
          } else {
            unwrapResponse(
              await supabase.from('warehouses').insert({ ...payload, created_by: ctx.user.id })
            );
          }
          closeModal();
          showToast('Data gudang berhasil disimpan.', 'success');
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
   TAB 5: BANK & METODE PEMBAYARAN
   ============================================================================ */
async function renderBanksTab(bodyEl, ctx) {
  const canManage = canPerformAction(ctx.role, 'manage_master_data');

  const [banksRes, methodsRes] = await Promise.all([
    supabase.from('banks').select('*').order('bank_name', { ascending: true }),
    supabase.from('payment_methods').select('*').order('name', { ascending: true })
  ]);

  const banks = unwrapResponse(banksRes) || [];
  const methods = unwrapResponse(methodsRes) || [];

  const bankRows = banks
    .map(
      (b) => `
      <tr>
        <td><strong>${escapeHtml(b.code)}</strong></td>
        <td><strong>${escapeHtml(b.bank_name)}</strong></td>
        <td>${escapeHtml(b.account_number || '-')}</td>
        <td>${escapeHtml(b.account_holder || '-')}</td>
        <td>
          <span class="badge ${b.is_active ? 'badge-success' : 'badge-neutral'}">
            ${b.is_active ? 'Aktif' : 'Nonaktif'}
          </span>
        </td>
        ${
          canManage
            ? `<td class="text-right">
                <button type="button" class="btn btn-secondary btn-sm" data-edit-bank="${b.id}">Edit</button>
              </td>`
            : ''
        }
      </tr>
    `
    )
    .join('');

  const methodRows = methods
    .map(
      (m) => `
      <tr>
        <td><strong>${escapeHtml(m.code)}</strong></td>
        <td>${escapeHtml(m.name)}</td>
        <td>${escapeHtml(m.method_type)}</td>
        <td>
          <span class="badge ${m.is_active ? 'badge-success' : 'badge-neutral'}">
            ${m.is_active ? 'Aktif' : 'Nonaktif'}
          </span>
        </td>
      </tr>
    `
    )
    .join('');

  bodyEl.innerHTML = `
    <div class="grid-2">
      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Rekening Bank Perusahaan (${banks.length})</h3>
          ${
            canManage
              ? `<button type="button" class="btn btn-primary btn-sm" id="btn-add-bank">+ Tambah Bank</button>`
              : ''
          }
        </div>
        ${
          banks.length === 0
            ? `<div class="card-body">${renderEmptyState('Belum ada rekening bank terdaftar.')}</div>`
            : `<div class="table-responsive">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>Kode</th>
                      <th>Nama Bank</th>
                      <th>No. Rekening</th>
                      <th>Atas Nama</th>
                      <th>Status</th>
                      ${canManage ? '<th class="text-right">Aksi</th>' : ''}
                    </tr>
                  </thead>
                  <tbody>${bankRows}</tbody>
                </table>
              </div>`
        }
      </div>

      <div class="card">
        <div class="card-header">
          <h3 class="card-title">Metode Pembayaran Aktif (${methods.length})</h3>
        </div>
        ${
          methods.length === 0
            ? `<div class="card-body">${renderEmptyState('Belum ada metode pembayaran terdaftar.')}</div>`
            : `<div class="table-responsive">
                <table class="data-table">
                  <thead>
                    <tr>
                      <th>Kode</th>
                      <th>Nama Metode</th>
                      <th>Tipe</th>
                      <th>Status</th>
                    </tr>
                  </thead>
                  <tbody>${methodRows}</tbody>
                </table>
              </div>`
        }
      </div>
    </div>
  `;

  if (canManage) {
    document.getElementById('btn-add-bank')?.addEventListener('click', () => openBankModal(null, ctx));
    bodyEl.querySelectorAll('[data-edit-bank]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const bank = banks.find((item) => item.id === btn.getAttribute('data-edit-bank'));
        if (bank) openBankModal(bank, ctx);
      });
    });
  }
}

function openBankModal(bank, ctx) {
  const isEdit = Boolean(bank);
  openModal({
    title: isEdit ? `Edit Rekening: ${bank.bank_name}` : 'Tambah Rekening Bank Perusahaan',
    bodyHtml: `
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="bk-code">Kode Bank <span class="req">*</span></label>
          <input type="text" id="bk-code" class="form-control" value="${escapeHtml(bank?.code || '')}" placeholder="Contoh: BCA-01" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="bk-name">Nama Bank <span class="req">*</span></label>
          <input type="text" id="bk-name" class="form-control" value="${escapeHtml(bank?.bank_name || '')}" placeholder="Contoh: Bank BCA" required />
        </div>
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="bk-num">Nomor Rekening <span class="req">*</span></label>
          <input type="text" id="bk-num" class="form-control" value="${escapeHtml(bank?.account_number || '')}" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="bk-holder">Nama Pemilik Rekening <span class="req">*</span></label>
          <input type="text" id="bk-holder" class="form-control" value="${escapeHtml(bank?.account_holder || 'PT Toya Jaya Darma')}" required />
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="bk-active">Status Rekening</label>
        <select id="bk-active" class="form-control">
          <option value="true" ${bank?.is_active !== false ? 'selected' : ''}>Aktif</option>
          <option value="false" ${bank?.is_active === false ? 'selected' : ''}>Nonaktif</option>
        </select>
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="bk-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="bk-save">Simpan Rekening</button>
    `,
    onMount: () => {
      document.getElementById('bk-cancel')?.addEventListener('click', closeModal);
      document.getElementById('bk-save')?.addEventListener('click', async () => {
        const { data: bankCoa } = await supabase
          .from('chart_of_accounts')
          .select('id')
          .eq('code', '1102')
          .maybeSingle();

        const payload = {
          code: document.getElementById('bk-code').value.trim().toUpperCase(),
          bank_name: document.getElementById('bk-name').value.trim(),
          account_number: document.getElementById('bk-num').value.trim(),
          account_holder: document.getElementById('bk-holder').value.trim(),
          account_id: bankCoa?.id || null,
          is_active: document.getElementById('bk-active').value === 'true'
        };

        if (!payload.code || !payload.bank_name || !payload.account_number || !payload.account_holder) {
          showToast('Kode, nama bank, nomor rekening, dan pemilik rekening wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('bk-save');
        btn.disabled = true;

        try {
          if (isEdit) {
            unwrapResponse(await supabase.from('banks').update(payload).eq('id', bank.id));
          } else {
            unwrapResponse(await supabase.from('banks').insert(payload));
          }
          closeModal();
          showToast('Rekening bank berhasil disimpan.', 'success');
          await loadTabContent(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}
