/**
 * Utilitas Tanggal & Periode Zona Waktu Asia/Jakarta
 */

import { APP_CONFIG } from '../config/app-config.js';

/**
 * Mengembalikan tanggal hari ini dalam format YYYY-MM-DD sesuai zona waktu Asia/Jakarta.
 */
export function getJakartaToday() {
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: APP_CONFIG.TIMEZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  });
  return formatter.format(new Date());
}

/**
 * Memecah string YYYY-MM-DD menjadi objek tahun, bulan, dan tanggal murni tanpa pergeseran jam lokal.
 */
function parseDateParts(dateStr) {
  const [y, m, d] = String(dateStr).split('-').map(Number);
  return { year: y, month: m, day: d };
}

function formatPartsToISO(year, month, day) {
  const dt = new Date(Date.UTC(year, month - 1, day));
  const y = dt.getUTCFullYear();
  const m = String(dt.getUTCMonth() + 1).padStart(2, '0');
  const d = String(dt.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/**
 * Menambah atau mengurangi jumlah hari dari tanggal YYYY-MM-DD.
 */
export function addDays(dateStr, days) {
  const base = dateStr || getJakartaToday();
  const { year, month, day } = parseDateParts(base);
  return formatPartsToISO(year, month, day + Number(days || 0));
}

/**
 * Memformat tanggal YYYY-MM-DD menjadi tampilan Indonesia (contoh: 19 Nov 2026).
 */
export function formatDateID(dateStr) {
  if (!dateStr) return '-';
  const cleanDate = String(dateStr).slice(0, 10);
  const { year, month, day } = parseDateParts(cleanDate);
  if (!year || !month || !day) return String(dateStr);

  const dt = new Date(Date.UTC(year, month - 1, day, 12, 0, 0));
  return new Intl.DateTimeFormat(APP_CONFIG.LOCALE, {
    timeZone: APP_CONFIG.TIMEZONE,
    day: '2-digit',
    month: 'short',
    year: 'numeric'
  }).format(dt);
}

/**
 * Memformat stempel waktu lengkap menjadi waktu WIB (contoh: 19 Nov 2026, 14:20 WIB).
 */
export function formatDateTimeID(isoString) {
  if (!isoString) return '-';
  const dt = new Date(isoString);
  if (Number.isNaN(dt.getTime())) return String(isoString);

  const formatted = new Intl.DateTimeFormat(APP_CONFIG.LOCALE, {
    timeZone: APP_CONFIG.TIMEZONE,
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false
  }).format(dt);

  return `${formatted} WIB`;
}

/**
 * Menghitung rentang tanggal awal dan akhir berdasarkan pilihan filter periode.
 */
export function getPeriodRange(preset, customStart = '', customEnd = '') {
  const today = getJakartaToday();
  const { year, month, day } = parseDateParts(today);

  switch (preset) {
    case 'today':
      return { startDate: today, endDate: today };

    case 'this_week': {
      const dt = new Date(Date.UTC(year, month - 1, day));
      const dayOfWeek = dt.getUTCDay(); // 0 = Minggu, 1 = Senin
      const diffToMonday = dayOfWeek === 0 ? -6 : 1 - dayOfWeek;
      const monday = formatPartsToISO(year, month, day + diffToMonday);
      const sunday = formatPartsToISO(year, month, day + diffToMonday + 6);
      return { startDate: monday, endDate: sunday };
    }

    case 'this_month': {
      const start = formatPartsToISO(year, month, 1);
      const end = formatPartsToISO(year, month + 1, 0);
      return { startDate: start, endDate: end };
    }

    case 'last_month': {
      const start = formatPartsToISO(year, month - 1, 1);
      const end = formatPartsToISO(year, month, 0);
      return { startDate: start, endDate: end };
    }

    case 'this_year': {
      const start = `${year}-01-01`;
      const end = `${year}-12-31`;
      return { startDate: start, endDate: end };
    }

    case 'custom': {
      const s = customStart || today;
      const e = customEnd || s;
      return s <= e ? { startDate: s, endDate: e } : { startDate: e, endDate: s };
    }

    case 'all':
    default:
      return { startDate: null, endDate: null };
  }
}
