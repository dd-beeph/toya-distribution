/**
 * Utilitas Pemformat Mata Uang Rupiah, Angka, Status, & Keamanan Teks HTML
 */

import { APP_CONFIG } from '../config/app-config.js';

const idrFormatter = new Intl.NumberFormat(APP_CONFIG.LOCALE, {
  style: 'currency',
  currency: APP_CONFIG.CURRENCY,
  minimumFractionDigits: 0,
  maximumFractionDigits: 0
});

const numberFormatter = new Intl.NumberFormat(APP_CONFIG.LOCALE, {
  minimumFractionDigits: 0,
  maximumFractionDigits: 2
});

/**
 * Memformat angka menjadi format Rupiah Indonesia (contoh: Rp 1.500.000).
 */
export function formatRupiah(amount, withPrefix = true) {
  const num = Number(amount || 0);
  if (Number.isNaN(num)) return withPrefix ? 'Rp 0' : '0';
  if (withPrefix) {
    return idrFormatter.format(Math.round(num));
  }
  return numberFormatter.format(Math.round(num));
}

/**
 * Memformat angka kuantitas atau persentase.
 */
export function formatNumber(value, maxDecimals = 2) {
  const num = Number(value || 0);
  if (Number.isNaN(num)) return '0';
  return new Intl.NumberFormat(APP_CONFIG.LOCALE, {
    minimumFractionDigits: 0,
    maximumFractionDigits: maxDecimals
  }).format(num);
}

/**
 * Mengubah input teks angka menjadi nilai numerik yang aman.
 */
export function parseNumericInput(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : 0;
  if (!value) return 0;
  const cleaned = String(value).replace(/[^0-9.-]/g, '');
  const parsed = parseFloat(cleaned);
  return Number.isFinite(parsed) ? parsed : 0;
}

/**
 * Melindungi teks sebelum ditampilkan ke layar HTML agar aman dari skrip berbahaya.
 */
export function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

const STATUS_MAP = Object.freeze({
  draft: { label: 'Draf', variant: 'neutral' },
  pending: { label: 'Menunggu Verifikasi', variant: 'warning' },
  pending_approval: { label: 'Menunggu Persetujuan', variant: 'warning' },
  approved: { label: 'Disetujui', variant: 'info' },
  ready_for_delivery: { label: 'Siap Kirim', variant: 'info' },
  preparing: { label: 'Disiapkan Gudang', variant: 'warning' },
  dispatched: { label: 'Dalam Pengiriman', variant: 'info' },
  delivered: { label: 'Terkirim', variant: 'success' },
  invoiced: { label: 'Sudah Difaktur', variant: 'success' },
  issued: { label: 'Terbit / Belum Lunas', variant: 'warning' },
  partial: { label: 'Dibayar Sebagian', variant: 'info' },
  paid: { label: 'Lunas', variant: 'success' },
  verified: { label: 'Terverifikasi', variant: 'success' },
  completed: { label: 'Selesai', variant: 'success' },
  received: { label: 'Diterima', variant: 'success' },
  partially_received: { label: 'Diterima Sebagian', variant: 'info' },
  open: { label: 'Terbuka', variant: 'warning' },
  settled: { label: 'Selesai Klaim', variant: 'success' },
  posted: { label: 'Terposting', variant: 'success' },
  reversed: { label: 'Dibalik (Reversal)', variant: 'neutral' },
  rejected: { label: 'Ditolak', variant: 'danger' },
  cancelled: { label: 'Dibatalkan', variant: 'danger' },
  void: { label: 'Batal (Void)', variant: 'danger' }
});

/**
 * Mengubah kode status database menjadi label bahasa Indonesia dan warna badge.
 */
export function formatStatusBadge(status) {
  const key = String(status || '').toLowerCase();
  const mapped = STATUS_MAP[key] || { label: status || '-', variant: 'neutral' };
  return mapped;
}
