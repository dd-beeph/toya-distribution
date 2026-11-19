/**
 * Modul Pengaturan Sistem, Manajemen Pengguna & Role, serta Log Audit (Khusus Owner)
 */

import { ROLES, ROLE_LABELS } from '../config/app-config.js';
import { supabase } from '../config/supabase-client.js';
import { callRpc, unwrapResponse } from '../services/base-service.js';
import { formatDateID, formatDateTimeID, getJakartaToday } from '../utils/date-utils.js';
import { escapeHtml, formatNumber } from '../utils/formatter.js';
import {
  closeModal,
  openModal,
  renderEmptyState,
  renderLoadingState,
  renderStatusBadge,
  showToast
} from '../ui/ui-components.js';

let activeTab = 'users';

export async function renderModule(container, ctx) {
  if (ctx.role !== ROLES.OWNER) {
    container.innerHTML = `<div class="alert alert-danger">Halaman ini hanya dapat diakses oleh Owner.</div>`;
    return;
  }

  container.innerHTML = `
    <div class="page-header">
      <div class="page-header-title">
        <h2>Pengaturan Perusahaan & Manajemen Pengguna</h2>
        <p>Kelola akun karyawan, role akses, kebijakan pajak PPN, stok negatif, dan pembulatan</p>
      </div>
    </div>

    <div class="tabs no-print">
      <button type="button" class="tab-btn ${activeTab === 'users' ? 'active' : ''}" data-tab="users">Pengguna & Role</button>
      <button type="button" class="tab-btn ${activeTab === 'settings' ? 'active' : ''}" data-tab="settings">Pengaturan Sistem & PPN</button>
      <button type="button" class="tab-btn ${activeTab === 'audit' ? 'active' : ''}" data-tab="audit">Log Audit Aktivitas</button>
    </div>

    <div id="settings-tab-body">${renderLoadingState()}</div>
  `;

  container.querySelectorAll('.tab-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      activeTab = btn.getAttribute('data-tab');
      container.querySelectorAll('.tab-btn').forEach((b) => b.classList.toggle('active', b === btn));
      loadActiveTab(ctx);
    });
  });

  await loadActiveTab(ctx);
}

async function loadActiveTab(ctx) {
  const bodyEl = document.getElementById('settings-tab-body');
  if (!bodyEl) return;
  bodyEl.innerHTML = renderLoadingState();

  try {
    if (activeTab === 'users') {
      await renderUsersTab(bodyEl, ctx);
    } else if (activeTab === 'settings') {
      await renderSystemSettingsTab(bodyEl, ctx);
    } else {
      await renderAuditLogsTab(bodyEl);
    }
  } catch (err) {
    bodyEl.innerHTML = `<div class="alert alert-danger">${escapeHtml(err.message)}</div>`;
    showToast(err.message, 'danger');
  }
}

async function renderUsersTab(bodyEl, ctx) {
  const [profilesRes, rolesRes] = await Promise.all([
    supabase
      .from('profiles')
      .select('id, employee_code, full_name, email, phone, is_active, created_at')
      .order('created_at', { ascending: true }),
    supabase.from('user_roles').select('user_id, role, assigned_at')
  ]);

  const profiles = unwrapResponse(profilesRes) || [];
  const roles = unwrapResponse(rolesRes) || [];
  const roleMap = new Map(roles.map((r) => [r.user_id, r.role]));

  const rowsHtml = profiles
    .map((p) => {
      const userRole = roleMap.get(p.id) || '';
      const roleText = userRole ? ROLE_LABELS[userRole] || userRole : 'Belum Ditetapkan';
      return `
        <tr>
          <td>${escapeHtml(p.employee_code || '-')}</td>
          <td>
            <strong>${escapeHtml(p.full_name)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(p.email || '')} ${p.phone ? '• ' + escapeHtml(p.phone) : ''}</div>
          </td>
          <td>
            <span class="badge ${userRole ? 'badge-info' : 'badge-warning'}">${escapeHtml(roleText)}</span>
          </td>
          <td>
            <span class="badge ${p.is_active ? 'badge-success' : 'badge-danger'}">
              ${p.is_active ? 'Aktif' : 'Nonaktif'}
            </span>
          </td>
          <td class="text-right">
            <button type="button" class="btn btn-secondary btn-sm" data-edit-user="${p.id}">
              <span class="material-symbols-outlined">edit</span>
              Atur Role / Status
            </button>
          </td>
        </tr>
      `;
    })
    .join('');

  bodyEl.innerHTML = `
    <div class="alert alert-info">
      Karyawan baru mendaftar melalui halaman <strong>Daftar Akun Baru</strong> pada layar masuk. Setelah terdaftar, pilih tombol <strong>Atur Role / Status</strong> di bawah ini untuk memberikan hak aksesnya.
    </div>
    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Daftar Akun Karyawan & Pemilik (${profiles.length} Pengguna)</h3>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Kode</th>
              <th>Nama & Kontak</th>
              <th>Role Akses</th>
              <th>Status Akun</th>
              <th class="text-right">Tindakan</th>
            </tr>
          </thead>
          <tbody>
            ${rowsHtml || '<tr><td colspan="5">Belum ada pengguna terdaftar.</td></tr>'}
          </tbody>
        </table>
      </div>
    </div>
  `;

  bodyEl.querySelectorAll('[data-edit-user]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const targetId = btn.getAttribute('data-edit-user');
      const profile = profiles.find((item) => item.id === targetId);
      const currentRole = roleMap.get(targetId) || '';
      if (profile) {
        openEditUserModal(profile, currentRole, ctx);
      }
    });
  });
}

function openEditUserModal(profile, currentRole, ctx) {
  const roleOptions = Object.entries(ROLE_LABELS)
    .map(
      ([val, label]) =>
        `<option value="${val}" ${currentRole === val ? 'selected' : ''}>${escapeHtml(label)}</option>`
    )
    .join('');

  const isSelf = profile.id === ctx.user.id;

  openModal({
    title: `Pengaturan Pengguna: ${profile.full_name}`,
    bodyHtml: `
      <form id="form-manage-user">
        <div class="grid-2">
          <div class="form-group">
            <label class="form-label" for="mu-emp-code">Kode Karyawan / Sales</label>
            <input type="text" id="mu-emp-code" class="form-control" value="${escapeHtml(profile.employee_code || '')}" placeholder="Contoh: SLS-01" />
          </div>
          <div class="form-group">
            <label class="form-label" for="mu-phone">Nomor Telepon</label>
            <input type="text" id="mu-phone" class="form-control" value="${escapeHtml(profile.phone || '')}" />
          </div>
        </div>
        <div class="form-group">
          <label class="form-label" for="mu-fullname">Nama Lengkap <span class="req">*</span></label>
          <input type="text" id="mu-fullname" class="form-control" value="${escapeHtml(profile.full_name)}" required />
        </div>
        <div class="grid-2">
          <div class="form-group">
            <label class="form-label" for="mu-role">Role Akses Sistem <span class="req">*</span></label>
            <select id="mu-role" class="form-control" required>
              <option value="">-- Pilih Role --</option>
              ${roleOptions}
            </select>
          </div>
          <div class="form-group">
            <label class="form-label" for="mu-status">Status Akun</label>
            <select id="mu-status" class="form-control" ${isSelf ? 'disabled' : ''}>
              <option value="true" ${profile.is_active ? 'selected' : ''}>Aktif (Dapat Login)</option>
              <option value="false" ${!profile.is_active ? 'selected' : ''}>Nonaktif (Cabut Akses)</option>
            </select>
            ${
              isSelf
                ? '<span class="form-help">Akun Owner yang sedang digunakan tidak dapat dinonaktifkan.</span>'
                : '<span class="form-help">Menonaktifkan akun akan memblokir akses login tanpa menghapus riwayat transaksi lama.</span>'
            }
          </div>
        </div>
      </form>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="mu-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="mu-save">Simpan Perubahan</button>
    `,
    onMount: () => {
      document.getElementById('mu-cancel')?.addEventListener('click', closeModal);
      document.getElementById('mu-save')?.addEventListener('click', async () => {
        const selectedRole = document.getElementById('mu-role').value;
        const fullName = document.getElementById('mu-fullname').value.trim();
        if (!selectedRole || !fullName) {
          showToast('Nama lengkap dan role akses wajib diisi.', 'warning');
          return;
        }

        const btn = document.getElementById('mu-save');
        btn.disabled = true;

        try {
          await callRpc('rpc_owner_manage_user', {
            p_target_user_id: profile.id,
            p_role: selectedRole,
            p_is_active: document.getElementById('mu-status').value === 'true',
            p_employee_code: document.getElementById('mu-emp-code').value.trim() || null,
            p_full_name: fullName,
            p_phone: document.getElementById('mu-phone').value.trim() || null
          });
          closeModal();
          showToast('Data pengguna dan role berhasil diperbarui.', 'success');
          await loadActiveTab(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

async function renderSystemSettingsTab(bodyEl, ctx) {
  const [settingsRes, taxCodesRes, taxRatesRes] = await Promise.all([
    supabase.from('system_settings').select('*').order('setting_key', { ascending: true }),
    supabase.from('tax_codes').select('*').order('code', { ascending: true }),
    supabase.from('tax_rates').select('*').order('effective_from', { ascending: false })
  ]);

  const settings = unwrapResponse(settingsRes) || [];
  const taxCodes = unwrapResponse(taxCodesRes) || [];
  const taxRates = unwrapResponse(taxRatesRes) || [];

  const settingsCardsHtml = settings
    .map((s) => {
      const val = s.setting_value;
      const key = s.setting_key;
      let inputControlHtml = '';

      if (key === 'allow_negative_stock') {
        const currentBool = typeof val === 'boolean' ? val : Boolean(val?.enabled ?? val?.value);
        inputControlHtml = `
          <select class="form-control" data-setting-input="${escapeHtml(key)}">
            <option value="false" ${!currentBool ? 'selected' : ''}>Dilarang (Stok Tidak Boleh Minus)</option>
            <option value="true" ${currentBool ? 'selected' : ''}>Diizinkan (Boleh Minus Sementara)</option>
          </select>
        `;
      } else if (key === 'default_ppn_mode') {
        const currentMode = typeof val === 'string' ? val : val?.mode || val?.value || 'exclude_ppn';
        inputControlHtml = `
          <select class="form-control" data-setting-input="${escapeHtml(key)}">
            <option value="exclude_ppn" ${currentMode === 'exclude_ppn' ? 'selected' : ''}>Harga Belum Termasuk PPN (Exclude PPN)</option>
            <option value="include_ppn" ${currentMode === 'include_ppn' ? 'selected' : ''}>Harga Sudah Termasuk PPN (Include PPN)</option>
            <option value="non_ppn" ${currentMode === 'non_ppn' ? 'selected' : ''}>Non-PPN / Tanpa PPN</option>
          </select>
        `;
      } else if (key === 'rounding_method') {
        const currentRound = typeof val === 'string' ? val : val?.method || val?.value || 'none';
        inputControlHtml = `
          <select class="form-control" data-setting-input="${escapeHtml(key)}">
            <option value="none" ${currentRound === 'none' ? 'selected' : ''}>Tanpa Pembulatan Tambahan</option>
            <option value="nearest_1" ${currentRound === 'nearest_1' ? 'selected' : ''}>Bulat ke Satuan Rupiah Terdekat</option>
            <option value="nearest_100" ${currentRound === 'nearest_100' ? 'selected' : ''}>Bulat ke Ratusan Rupiah Terdekat</option>
            <option value="down_100" ${currentRound === 'down_100' ? 'selected' : ''}>Bulat ke Bawah Ratusan Rupiah</option>
          </select>
        `;
      } else {
        const strVal = typeof val === 'object' ? JSON.stringify(val) : String(val ?? '');
        inputControlHtml = `
          <input type="text" class="form-control" data-setting-input="${escapeHtml(key)}" value="${escapeHtml(strVal)}" />
        `;
      }

      return `
        <tr>
          <td>
            <strong>${escapeHtml(key)}</strong>
            <div class="text-muted" style="font-size:0.8rem;">${escapeHtml(s.description || '')}</div>
          </td>
          <td style="min-width:260px;">${inputControlHtml}</td>
          <td class="text-right">
            <button type="button" class="btn btn-primary btn-sm" data-save-setting="${escapeHtml(key)}">
              Simpan
            </button>
          </td>
        </tr>
      `;
    })
    .join('');

  const taxRowsHtml = taxCodes
    .map((tc) => {
      const latestRate = taxRates.find((r) => r.tax_code_id === tc.id);
      return `
        <tr>
          <td><strong>${escapeHtml(tc.code)}</strong></td>
          <td>${escapeHtml(tc.name)}</td>
          <td class="num">${latestRate ? formatNumber(latestRate.rate_percent) + '%' : '-'}</td>
          <td class="num">${latestRate ? formatNumber(latestRate.dpp_multiplier, 6) : '-'}</td>
          <td>${latestRate ? formatDateID(latestRate.effective_from) : '-'}</td>
          <td class="text-right">
            <button type="button" class="btn btn-secondary btn-sm" data-add-tax-rate="${tc.id}" data-tax-name="${escapeHtml(tc.name)}">
              + Tarif Baru
            </button>
          </td>
        </tr>
      `;
    })
    .join('');

  bodyEl.innerHTML = `
    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Kebijakan Operasional & Pajak</h3>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Parameter Sistem</th>
              <th>Nilai Aktif</th>
              <th class="text-right">Aksi</th>
            </tr>
          </thead>
          <tbody>${settingsCardsHtml}</tbody>
        </table>
      </div>
    </div>

    <div class="card">
      <div class="card-header">
        <h3 class="card-title">Master Kode & Tarif PPN Berlaku</h3>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Kode Pajak</th>
              <th>Nama Pajak</th>
              <th class="num">Tarif (%)</th>
              <th class="num">Pengali DPP</th>
              <th>Berlaku Mulai</th>
              <th class="text-right">Tindakan</th>
            </tr>
          </thead>
          <tbody>${taxRowsHtml}</tbody>
        </table>
      </div>
    </div>
  `;

  bodyEl.querySelectorAll('[data-save-setting]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const key = btn.getAttribute('data-save-setting');
      const settingRow = settings.find((item) => item.setting_key === key);
      const inputEl = bodyEl.querySelector(`[data-setting-input="${key}"]`);
      if (!settingRow || !inputEl) return;

      const rawInput = inputEl.value;
      const oldVal = settingRow.setting_value;
      let newJsonVal;

      if (key === 'allow_negative_stock') {
        const boolVal = rawInput === 'true';
        newJsonVal = typeof oldVal === 'object' && oldVal !== null ? { ...oldVal, enabled: boolVal } : boolVal;
      } else if (key === 'default_ppn_mode') {
        newJsonVal = typeof oldVal === 'object' && oldVal !== null ? { ...oldVal, mode: rawInput } : rawInput;
      } else if (key === 'rounding_method') {
        newJsonVal = typeof oldVal === 'object' && oldVal !== null ? { ...oldVal, method: rawInput } : rawInput;
      } else {
        try {
          newJsonVal = JSON.parse(rawInput);
        } catch {
          newJsonVal = rawInput;
        }
      }

      btn.disabled = true;
      try {
        await callRpc('rpc_owner_update_setting', {
          p_setting_key: key,
          p_setting_value: newJsonVal
        });
        showToast(`Pengaturan "${key}" berhasil diperbarui.`, 'success');
        await loadActiveTab(ctx);
      } catch (err) {
        showToast(err.message, 'danger');
        btn.disabled = false;
      }
    });
  });

  bodyEl.querySelectorAll('[data-add-tax-rate]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const taxCodeId = btn.getAttribute('data-add-tax-rate');
      const taxName = btn.getAttribute('data-tax-name');
      openNewTaxRateModal(taxCodeId, taxName, ctx);
    });
  });
}

function openNewTaxRateModal(taxCodeId, taxName, ctx) {
  openModal({
    title: `Tambah Tarif Baru: ${taxName}`,
    bodyHtml: `
      <div class="form-group">
        <label class="form-label" for="tr-effective">Tanggal Mulai Berlaku <span class="req">*</span></label>
        <input type="date" id="tr-effective" class="form-control" value="${getJakartaToday()}" required />
      </div>
      <div class="grid-2">
        <div class="form-group">
          <label class="form-label" for="tr-rate">Tarif PPN (%) <span class="req">*</span></label>
          <input type="number" step="0.01" id="tr-rate" class="form-control" value="12" required />
        </div>
        <div class="form-group">
          <label class="form-label" for="tr-mult">Pengali DPP <span class="req">*</span></label>
          <input type="number" step="0.000001" id="tr-mult" class="form-control" value="0.916667" required />
          <span class="form-help">Contoh: 11/12 = 0.916667, atau 1.000000 untuk DPP penuh.</span>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" for="tr-notes">Keterangan Dasar Peraturan</label>
        <input type="text" id="tr-notes" class="form-control" placeholder="Contoh: Penyesuaian tarif PPN terbaru" />
      </div>
    `,
    footerHtml: `
      <button type="button" class="btn btn-secondary" id="tr-cancel">Batal</button>
      <button type="button" class="btn btn-primary" id="tr-save">Simpan Tarif</button>
    `,
    onMount: () => {
      document.getElementById('tr-cancel')?.addEventListener('click', closeModal);
      document.getElementById('tr-save')?.addEventListener('click', async () => {
        const btn = document.getElementById('tr-save');
        btn.disabled = true;
        try {
          const res = await supabase.from('tax_rates').insert({
            tax_code_id: taxCodeId,
            effective_from: document.getElementById('tr-effective').value,
            rate_percent: Number(document.getElementById('tr-rate').value),
            dpp_multiplier: Number(document.getElementById('tr-mult').value),
            notes: document.getElementById('tr-notes').value.trim() || null
          });
          unwrapResponse(res);
          closeModal();
          showToast('Tarif pajak baru berhasil ditambahkan.', 'success');
          await loadActiveTab(ctx);
        } catch (err) {
          showToast(err.message, 'danger');
          btn.disabled = false;
        }
      });
    }
  });
}

async function renderAuditLogsTab(bodyEl) {
  const res = await supabase
    .from('audit_logs')
    .select('id, created_at, table_name, action, reason, actor_role')
    .order('created_at', { ascending: false })
    .limit(50);

  const logs = unwrapResponse(res) || [];

  if (logs.length === 0) {
    bodyEl.innerHTML = renderEmptyState('Belum ada catatan log audit sensitif.', 'history');
    return;
  }

  const rowsHtml = logs
    .map(
      (log) => `
      <tr>
        <td>${formatDateTimeID(log.created_at)}</td>
        <td><code>${escapeHtml(log.table_name)}</code></td>
        <td>${renderStatusBadge(log.action)}</td>
        <td>${escapeHtml(ROLE_LABELS[log.actor_role] || log.actor_role || '-')}</td>
        <td>${escapeHtml(log.reason || '-')}</td>
      </tr>
    `
    )
    .join('');

  bodyEl.innerHTML = `
    <div class="card">
      <div class="card-header">
        <h3 class="card-title">50 Aktivitas Audit Sensitif Terbaru</h3>
      </div>
      <div class="table-responsive">
        <table class="data-table">
          <thead>
            <tr>
              <th>Waktu (WIB)</th>
              <th>Tabel / Modul</th>
              <th>Aksi</th>
              <th>Role Pelaku</th>
              <th>Alasan / Catatan</th>
            </tr>
          </thead>
          <tbody>${rowsHtml}</tbody>
        </table>
      </div>
    </div>
  `;
}
