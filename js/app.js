/**
 * Pengendali Utama Aplikasi Toya Distribution (SPA Router & Session Controller)
 */

import { APP_CONFIG, ROLE_LABELS } from './config/app-config.js';
import { isSupabaseConfigured } from './config/supabase-client.js';
import {
  loadUserContext,
  onAuthStateChange,
  signInWithEmail,
  signOutUser,
  signUpWithEmail
} from './auth/auth-service.js';
import { canAccessMenu, getVisibleMenus } from './auth/permission-guard.js';
import { escapeHtml } from './utils/formatter.js';
import { renderLoadingState, showToast } from './ui/ui-components.js';

const MODULE_LOADERS = {
  dashboard: () => import('./modules/dashboard-module.js'),
  approvals: () => import('./modules/approvals-module.js'),
  'sales-orders': () => import('./modules/sales-orders-module.js'),
  deliveries: () => import('./modules/deliveries-module.js'),
  'sales-invoices': () => import('./modules/sales-invoices-module.js'),
  'sales-returns': () => import('./modules/sales-returns-module.js'),
  'customer-payments': () => import('./modules/customer-payments-module.js'),
  'purchase-orders': () => import('./modules/purchase-orders-module.js'),
  'goods-receipts': () => import('./modules/goods-receipts-module.js'),
  'supplier-invoices': () => import('./modules/supplier-invoices-module.js'),
  'supplier-payments': () => import('./modules/supplier-payments-module.js'),
  'inventory-ledger': () => import('./modules/inventory-ledger-module.js'),
  'stock-transfers': () => import('./modules/stock-transfers-module.js'),
  'stock-adjustments': () => import('./modules/stock-adjustments-module.js'),
  'damaged-goods': () => import('./modules/damaged-goods-module.js'),
  'operational-expenses': () => import('./modules/operational-expenses-module.js'),
  'voucher-claims': () => import('./modules/voucher-claims-module.js'),
  accounting: () => import('./modules/accounting-module.js'),
  'tax-management': () => import('./modules/tax-management-module.js'),
  'sales-performance': () => import('./modules/sales-performance-module.js'),
  'master-data': () => import('./modules/master-data-module.js'),
  settings: () => import('./modules/settings-module.js')
};

let currentContext = null;
let activeMenuId = 'dashboard';

function getAppRoot() {
  return document.getElementById('app-root');
}

/**
 * Layar peringatan jika Project URL / anon key Supabase belum diisi pada app-config.js.
 */
function renderUnconfiguredScreen() {
  getAppRoot().innerHTML = `
    <div class="auth-wrapper">
      <div class="auth-card">
        <div class="auth-brand">
          <div class="auth-brand-badge">
            <span class="material-symbols-outlined">settings_ethernet</span>
          </div>
          <h1>Konfigurasi Supabase Diperlukan</h1>
          <p>${escapeHtml(APP_CONFIG.COMPANY_LEGAL_NAME)}</p>
        </div>
        <div class="alert alert-warning">
          Kunci koneksi Supabase belum diisi pada file <strong>js/config/app-config.js</strong>.
          Silakan masukkan <code>SUPABASE_URL</code> dan <code>SUPABASE_ANON_KEY</code> Anda lalu muat ulang halaman ini.
        </div>
      </div>
    </div>
  `;
}

/**
 * Halaman Login & Pendaftaran Akun Baru.
 */
function renderAuthScreen(defaultTab = 'login') {
  getAppRoot().innerHTML = `
    <div class="auth-wrapper">
      <div class="auth-card">
        <div class="auth-brand">
          <div class="auth-brand-badge">
            <span class="material-symbols-outlined">local_drink</span>
          </div>
          <h1>${escapeHtml(APP_CONFIG.APP_NAME)}</h1>
          <p>${escapeHtml(APP_CONFIG.COMPANY_LEGAL_NAME)}</p>
        </div>

        <div class="tabs" style="justify-content:center;">
          <button type="button" class="tab-btn ${defaultTab === 'login' ? 'active' : ''}" id="tab-login">Masuk Akun</button>
          <button type="button" class="tab-btn ${defaultTab === 'register' ? 'active' : ''}" id="tab-register">Daftar Akun Baru</button>
        </div>

        <form id="form-login" class="${defaultTab === 'login' ? '' : 'hidden'}">
          <div class="form-group">
            <label class="form-label" for="login-email">Alamat Email</label>
            <input type="email" id="login-email" class="form-control" placeholder="nama@perusahaan.com" required />
          </div>
          <div class="form-group">
            <label class="form-label" for="login-password">Kata Sandi</label>
            <input type="password" id="login-password" class="form-control" placeholder="Masukkan kata sandi" required />
          </div>
          <button type="submit" id="btn-submit-login" class="btn btn-primary btn-block">
            <span class="material-symbols-outlined">login</span>
            Masuk ke Sistem
          </button>
        </form>

        <form id="form-register" class="${defaultTab === 'register' ? '' : 'hidden'}">
          <div class="form-group">
            <label class="form-label" for="reg-fullname">Nama Lengkap <span class="req">*</span></label>
            <input type="text" id="reg-fullname" class="form-control" placeholder="Nama lengkap karyawan / pemilik" required />
          </div>
          <div class="form-group">
            <label class="form-label" for="reg-phone">Nomor WhatsApp / Telepon</label>
            <input type="tel" id="reg-phone" class="form-control" placeholder="08xxxxxxxxxx" />
          </div>
          <div class="form-group">
            <label class="form-label" for="reg-email">Alamat Email <span class="req">*</span></label>
            <input type="email" id="reg-email" class="form-control" placeholder="email@domain.com" required />
          </div>
          <div class="form-group">
            <label class="form-label" for="reg-password">Kata Sandi (Minimal 6 karakter) <span class="req">*</span></label>
            <input type="password" id="reg-password" class="form-control" minlength="6" placeholder="Buat kata sandi" required />
          </div>
          <button type="submit" id="btn-submit-register" class="btn btn-primary btn-block">
            <span class="material-symbols-outlined">person_add</span>
            Daftar Akun
          </button>
          <p class="form-help" style="margin-top:0.75rem;text-align:center;">
            Setelah mendaftar, Owner akan menetapkan role akses Anda sebelum mulai bekerja.
          </p>
        </form>
      </div>
    </div>
  `;

  const tabLogin = document.getElementById('tab-login');
  const tabRegister = document.getElementById('tab-register');
  const formLogin = document.getElementById('form-login');
  const formRegister = document.getElementById('form-register');

  tabLogin.addEventListener('click', () => {
    tabLogin.classList.add('active');
    tabRegister.classList.remove('active');
    formLogin.classList.remove('hidden');
    formRegister.classList.add('hidden');
  });

  tabRegister.addEventListener('click', () => {
    tabRegister.classList.add('active');
    tabLogin.classList.remove('active');
    formRegister.classList.remove('hidden');
    formLogin.classList.add('hidden');
  });

  formLogin.addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = document.getElementById('btn-submit-login');
    btn.disabled = true;
    try {
      await signInWithEmail(
        document.getElementById('login-email').value,
        document.getElementById('login-password').value
      );
      showToast('Berhasil masuk ke sistem.', 'success');
      await bootstrapApp();
    } catch (err) {
      showToast(err.message, 'danger');
      btn.disabled = false;
    }
  });

  formRegister.addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = document.getElementById('btn-submit-register');
    btn.disabled = true;
    try {
      await signUpWithEmail({
        fullName: document.getElementById('reg-fullname').value,
        phone: document.getElementById('reg-phone').value,
        email: document.getElementById('reg-email').value,
        password: document.getElementById('reg-password').value
      });
      showToast('Pendaftaran akun berhasil!', 'success');
      await bootstrapApp();
    } catch (err) {
      showToast(err.message, 'danger');
      btn.disabled = false;
    }
  });
}

/**
 * Layar bagi akun yang dinonaktifkan atau belum mendapatkan penetapan role dari Owner.
 */
function renderRestrictedAccessScreen(ctx) {
  const isDeactivated = ctx.isDeactivated;
  const title = isDeactivated ? 'Akun Dinonaktifkan' : 'Menunggu Penetapan Role oleh Owner';
  const message = isDeactivated
    ? 'Akun Anda telah dinonaktifkan oleh Owner sehingga tidak lagi memiliki akses ke sistem. Seluruh riwayat transaksi lama Anda tetap tersimpan dengan aman.'
    : `Halo ${ctx.profile.full_name}, akun Anda sudah terdaftar. Silakan hubungi Owner (${APP_CONFIG.COMPANY_LEGAL_NAME}) untuk menetapkan role akses Anda (Sales, Warehouse, Cashier, Finance Admin, atau Owner).`;

  getAppRoot().innerHTML = `
    <div class="auth-wrapper">
      <div class="auth-card">
        <div class="auth-brand">
          <div class="auth-brand-badge">
            <span class="material-symbols-outlined">${isDeactivated ? 'block' : 'hourglass_top'}</span>
          </div>
          <h1>${escapeHtml(title)}</h1>
          <p>${escapeHtml(ctx.profile.email || '')}</p>
        </div>
        <div class="alert ${isDeactivated ? 'alert-danger' : 'alert-info'}">
          ${escapeHtml(message)}
        </div>
        <div style="display:flex;gap:0.6rem;">
          <button type="button" id="btn-refresh-role" class="btn btn-primary" style="flex:1;">
            <span class="material-symbols-outlined">refresh</span>
            Periksa Status
          </button>
          <button type="button" id="btn-logout-restricted" class="btn btn-secondary">
            Keluar
          </button>
        </div>
      </div>
    </div>
  `;

  document.getElementById('btn-refresh-role')?.addEventListener('click', () => bootstrapApp());
  document.getElementById('btn-logout-restricted')?.addEventListener('click', async () => {
    await signOutUser();
    renderAuthScreen('login');
  });
}

/**
 * Merender kerangka utama aplikasi beserta sidebar menu sesuai role pengguna.
 */
function renderMainShell(ctx) {
  const menuGroups = getVisibleMenus(ctx.role);
  const roleLabel = ROLE_LABELS[ctx.role] || ctx.role;

  const navHtml = menuGroups
    .map(
      (group) => `
      <div class="sidebar-group">
        <div class="sidebar-group-title">${escapeHtml(group.group)}</div>
        ${group.items
          .map(
            (item) => `
          <button type="button" class="sidebar-item ${item.id === activeMenuId ? 'active' : ''}" data-menu-id="${item.id}">
            <span class="material-symbols-outlined">${escapeHtml(item.icon)}</span>
            <span>${escapeHtml(item.label)}</span>
          </button>
        `
          )
          .join('')}
      </div>
    `
    )
    .join('');

  getAppRoot().innerHTML = `
    <div class="app-shell">
      <div class="sidebar-backdrop" id="sidebar-backdrop"></div>
      <aside class="sidebar" id="app-sidebar">
        <div class="sidebar-header">
          <div class="sidebar-logo">
            <span class="sidebar-logo-icon">
              <span class="material-symbols-outlined">local_drink</span>
            </span>
            <span>${escapeHtml(APP_CONFIG.APP_NAME)}</span>
          </div>
          <button type="button" class="sidebar-close-btn" id="btn-close-sidebar" aria-label="Tutup Menu">
            <span class="material-symbols-outlined">close</span>
          </button>
        </div>

        <nav class="sidebar-nav" id="sidebar-nav">
          ${navHtml}
        </nav>

        <div class="sidebar-footer">
          <div>${escapeHtml(APP_CONFIG.COMPANY_LEGAL_NAME)}</div>
          <div>Versi ${escapeHtml(APP_CONFIG.APP_VERSION)}</div>
        </div>
      </aside>

      <div class="app-main">
        <header class="topbar no-print">
          <div class="topbar-left">
            <button type="button" class="mobile-menu-btn" id="btn-open-sidebar" aria-label="Buka Menu">
              <span class="material-symbols-outlined">menu</span>
            </button>
            <h1 class="topbar-title" id="topbar-page-title">Dashboard</h1>
          </div>

          <div class="topbar-right">
            <div class="user-pill">
              <span class="material-symbols-outlined" style="color:var(--color-primary);">account_circle</span>
              <div class="user-pill-info">
                <span class="user-pill-name">${escapeHtml(ctx.profile.full_name)}</span>
                <span class="user-pill-role">${escapeHtml(roleLabel)}</span>
              </div>
            </div>
            <button type="button" class="btn btn-secondary btn-sm" id="btn-app-logout" title="Keluar dari Sistem">
              <span class="material-symbols-outlined">logout</span>
              <span>Keluar</span>
            </button>
          </div>
        </header>

        <main class="workspace" id="module-workspace">
          ${renderLoadingState('Memuat modul...')}
        </main>
      </div>
    </div>
  `;

  const sidebar = document.getElementById('app-sidebar');
  const backdrop = document.getElementById('sidebar-backdrop');

  const closeSidebar = () => {
    sidebar?.classList.remove('open');
    backdrop?.classList.remove('open');
  };

  document.getElementById('btn-open-sidebar')?.addEventListener('click', () => {
    sidebar?.classList.add('open');
    backdrop?.classList.add('open');
  });

  document.getElementById('btn-close-sidebar')?.addEventListener('click', closeSidebar);
  backdrop?.addEventListener('click', closeSidebar);

  document.getElementById('btn-app-logout')?.addEventListener('click', async () => {
    try {
      await signOutUser();
      currentContext = null;
      showToast('Anda telah keluar dari sistem.', 'info');
      renderAuthScreen('login');
    } catch (err) {
      showToast(err.message, 'danger');
    }
  });

  document.querySelectorAll('.sidebar-item').forEach((btn) => {
    btn.addEventListener('click', () => {
      const targetMenu = btn.getAttribute('data-menu-id');
      closeSidebar();
      navigateToMenu(targetMenu);
    });
  });
}

/**
 * Memuat dan menampilkan modul halaman yang dipilih.
 */
export async function navigateToMenu(menuId) {
  if (!currentContext) return;

  const targetId = canAccessMenu(currentContext.role, menuId) ? menuId : 'dashboard';
  activeMenuId = targetId;
  window.location.hash = `#${targetId}`;

  let activeLabel = 'Dashboard';
  document.querySelectorAll('.sidebar-item').forEach((btn) => {
    const isMatch = btn.getAttribute('data-menu-id') === targetId;
    btn.classList.toggle('active', isMatch);
    if (isMatch) {
      activeLabel = btn.querySelector('span:last-child')?.textContent || activeLabel;
    }
  });

  const titleEl = document.getElementById('topbar-page-title');
  if (titleEl) titleEl.textContent = activeLabel;

  const workspace = document.getElementById('module-workspace');
  if (!workspace) return;

  workspace.innerHTML = renderLoadingState(`Memuat halaman ${activeLabel}...`);

  const loader = MODULE_LOADERS[targetId];
  if (!loader) {
    workspace.innerHTML = `<div class="alert alert-warning">Modul tidak ditemukan.</div>`;
    return;
  }

  try {
    const mod = await loader();
    if (typeof mod.renderModule === 'function') {
      await mod.renderModule(workspace, currentContext, { navigateToMenu });
    } else {
      workspace.innerHTML = `<div class="alert alert-info">Modul ${escapeHtml(activeLabel)} siap dikonfigurasi.</div>`;
    }
  } catch (err) {
    console.warn(`Modul ${targetId} belum terpasang:`, err);
    workspace.innerHTML = `
      <div class="card">
        <div class="card-body">
          <div class="alert alert-info" style="margin-bottom:0;">
            <strong>Modul ${escapeHtml(activeLabel)}</strong> sedang dalam antrean pemasangan file.
            Silakan lanjutkan langkah berikutnya untuk memasang file modul ini di GitHub.
          </div>
        </div>
      </div>
    `;
  }
}

/**
 * Inisialisasi sesi aplikasi saat halaman pertama kali dibuka.
 */
async function bootstrapApp() {
  if (!isSupabaseConfigured()) {
    renderUnconfiguredScreen();
    return;
  }

  try {
    const ctx = await loadUserContext();
    if (!ctx) {
      currentContext = null;
      renderAuthScreen('login');
      return;
    }

    currentContext = ctx;

    if (ctx.isDeactivated || ctx.needsRoleAssignment) {
      renderRestrictedAccessScreen(ctx);
      return;
    }

    const hashMenu = window.location.hash.replace('#', '').trim();
    if (hashMenu && canAccessMenu(ctx.role, hashMenu)) {
      activeMenuId = hashMenu;
    } else {
      activeMenuId = 'dashboard';
    }

    renderMainShell(ctx);
    await navigateToMenu(activeMenuId);
  } catch (err) {
    showToast(err.message, 'danger');
    renderAuthScreen('login');
  }
}

onAuthStateChange((event) => {
  if (event === 'SIGNED_OUT') {
    currentContext = null;
    renderAuthScreen('login');
  }
});

bootstrapApp();
