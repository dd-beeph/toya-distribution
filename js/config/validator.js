/**
 * Utilitas Validasi Input Formulir
 */

export function validateRequired(fields) {
  for (const field of fields) {
    const val = field.value;
    if (val === null || val === undefined || String(val).trim() === '') {
      return {
        valid: false,
        message: `Kolom "${field.label}" wajib diisi.`
      };
    }
  }
  return { valid: true, message: '' };
}

export function validatePositiveNumber(value, label) {
  const num = Number(value);
  if (!Number.isFinite(num) || num <= 0) {
    return {
      valid: false,
      message: `Nilai "${label}" harus lebih besar dari nol.`
    };
  }
  return { valid: true, message: '' };
}

export function validateNonNegativeNumber(value, label) {
  const num = Number(value);
  if (!Number.isFinite(num) || num < 0) {
    return {
      valid: false,
      message: `Nilai "${label}" tidak boleh negatif.`
    };
  }
  return { valid: true, message: '' };
}

export function validateDateRange(startDate, endDate) {
  if (startDate && endDate && startDate > endDate) {
    return {
      valid: false,
      message: 'Tanggal awal tidak boleh lebih besar dari tanggal akhir.'
    };
  }
  return { valid: true, message: '' };
}

export function validateItemsArray(items, minCount = 1) {
  if (!Array.isArray(items) || items.length < minCount) {
    return {
      valid: false,
      message: `Minimal harus terdapat ${minCount} baris barang dalam transaksi.`
    };
  }
  return { valid: true, message: '' };
}
