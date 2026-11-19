/**
 * Pustaka Komponen Antarmuka Terpadu (Toast, Modal, Badge, Period Filter)
 */

import { PERIOD_PRESETS } from '../config/app-config.js';
import { getPeriodRange } from '../utils/date-utils.js';
import { escapeHtml, formatStatusBadge } from '../utils/formatter.js';

/**
 * Menampilkan notifikasi singkat di pojok kanan atas layar.
 */
export function showToast(message, type = 'info', durationMs = 4200) {
  const container = document.getElementById('toast-container');
  if (!container) return;

  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.innerHTML = `
    <span>${escapeHtml(message)}</span>
    <button type="button" class="btn-ghost" style="color:#fff;padding:0;min-height:auto;" aria-label="Tutup">&times;</button>
  `;

  const closeBtn = toast.querySelector('button');
  const removeToast = () => {
    if (toast.parentNode) toast.parentNode.removeChild(toast);
  };

  closeBtn.addEventListener('click', removeToast);
  container.appendChild(toast);

  if (durationMs > 0) {
    setTimeout(removeToast, durationMs);
  }
}

/**
 * Membuka jendela modal dialog yang dapat diisi formulir atau detail dokumen.
 */
export function openModal({ title, bodyHtml, footerHtml = '', size = 'md', onMount = null }) {
  closeModal();

  const root = document.getElementById('modal-root');
  if (!root) return;

  const sizeClass = size === 'lg' ? 'modal-lg' : '';
  root.innerHTML = `
    <div class="modal-backdrop" id="active-modal-backdrop">
      <div class="modal-dialog ${sizeClass}" role="dialog" aria-modal="true">
        <div class="modal-header">
          <h3 class="modal-title">${escapeHtml(title)}</h3>
          <button type="button" class="btn btn-ghost btn-sm" id="modal-close-x" aria-label="Tutup">&times;</button>
        </div>
        <div class="modal-body" id="modal-body-content">
          ${bodyHtml}
        </div>
        ${footerHtml ? `<div class="modal-footer">${footerHtml}</div>` : ''}
      </div>
    </div>
  `;

  const closeX = document.getElementById('modal-close-x');
  const backdrop = document.getElementById('active-modal-backdrop');

  closeX?.addEventListener('click', closeModal);
  backdrop?.addEventListener('click', (e) => {
    if (e.target === backdrop) closeModal();
  });

  if (typeof onMount === 'function') {
    onMount(root.querySelector('.modal-dialog'));
  }
}

/**
 * Menutup modal dialog yang sedang terbuka.
 */
export function closeModal() {
  const root = document.getElementById('modal-root');
  if (root) root.innerHTML = '';
}

/**
 * Menghasilkan HTML badge status berwarna sesuai kode status database.
 */
export function renderStatusBadge(status) {
  const { label, variant } = formatStatusBadge(status);
  return `<span class="badge badge-${variant}">${escapeHtml(label)}</span>`;
}

/**
 * Menghasilkan tampilan indikator sedang memuat data.
 */
export function renderLoadingState(text = 'Memuat data dari server...') {
  return `
    <div class="empty-state">
      <div class="spinner"></div>
      <p style="margin-top:0.75rem;">${escapeHtml(text)}</p>
    </div>
  `;
}

/**
 * Menghasilkan tampilan keadaan kosong saat belum ada data transaksi.
 */
export function renderEmptyState(message = 'Belum ada data untuk ditampilkan.', icon = 'inbox') {
  return `
    <div class="empty-state">
      <span class="material-symbols-outlined">${escapeHtml(icon)}</span>
      <p>${escapeHtml(message)}</p>
    </div>
  `;
}

/**
 * Merender dan menghubungkan bilah filter periode standar (Hari Ini, Minggu Ini, Bulan Ini, Khusus).
 */
export function renderPeriodFilterBar(containerId, initialState, onApply) {
  const host = document.getElementById(containerId);
  if (!host) return;

  const state = {
    preset: initialState?.preset || 'this_month',
    startDate: initialState?.startDate || '',
    endDate: initialState?.endDate || ''
  };

  const optionsHtml = PERIOD_PRESETS.map(
    (p) => `<option value="${p.value}" ${state.preset === p.value ? 'selected' : ''}>${escapeHtml(p.label)}</option>`
  ).join('');

  host.innerHTML = `
    <div class="filter-bar no-print">
      <div class="filter-item">
        <label for="${containerId}-preset">Periode Waktu</label>
        <select id="${containerId}-preset" class="form-control">${optionsHtml}</select>
      </div>
      <div class="filter-item ${state.preset === 'custom' ? '' : 'hidden'}" id="${containerId}-start-wrap">
        <label for="${containerId}-start">Dari Tanggal</label>
        <input type="date" id="${containerId}-start" class="form-control" value="${escapeHtml(state.startDate)}" />
      </div>
      <div class="filter-item ${state.preset === 'custom' ? '' : 'hidden'}" id="${containerId}-end-wrap">
        <label for="${containerId}-end">Sampai Tanggal</label>
        <input type="date" id="${containerId}-end" class="form-control" value="${escapeHtml(state.endDate)}" />
      </div>
      <div class="filter-item" style="min-width:auto;">
        <button type="button" id="${containerId}-apply" class="btn btn-primary">
          <span class="material-symbols-outlined">filter_alt</span>
          Terapkan
        </button>
      </div>
    </div>
  `;

  const presetEl = document.getElementById(`${containerId}-preset`);
  const startWrap = document.getElementById(`${containerId}-start-wrap`);
  const endWrap = document.getElementById(`${containerId}-end-wrap`);
  const startEl = document.getElementById(`${containerId}-start`);
  const endEl = document.getElementById(`${containerId}-end`);
  const applyBtn = document.getElementById(`${containerId}-apply`);

  presetEl.addEventListener('change', () => {
    const isCustom = presetEl.value === 'custom';
    startWrap.classList.toggle('hidden', !isCustom);
    endWrap.classList.toggle('hidden', !isCustom);
  });

  applyBtn.addEventListener('click', () => {
    const range = getPeriodRange(presetEl.value, startEl.value, endEl.value);
    onApply({
      preset: presetEl.value,
      startDate: range.startDate,
      endDate: range.endDate
    });
  });
}
