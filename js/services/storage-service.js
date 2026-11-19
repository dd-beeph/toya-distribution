/**
 * Layanan Penyimpanan Privat Bukti Transaksi (Supabase Storage)
 */

import { APP_CONFIG } from '../config/app-config.js';
import { supabase } from '../config/supabase-client.js';
import { getJakartaToday } from '../utils/date-utils.js';
import { translateDbError } from './base-service.js';

const MAX_FILE_SIZE_BYTES = 5 * 1024 * 1024; // 5 MB
const ALLOWED_MIME_TYPES = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'application/pdf'
];

function sanitizeFileName(name) {
  return String(name || 'dokumen')
    .toLowerCase()
    .replace(/[^a-z0-9._-]/g, '_')
    .replace(/_+/g, '_');
}

/**
 * Mengunggah berkas bukti transaksi ke bucket privat transaction-proofs.
 * Mengembalikan path penyimpanan untuk disimpan pada kolom proof_file_path.
 */
export async function uploadTransactionProof(file, folder = 'general') {
  if (!file) return null;

  if (!ALLOWED_MIME_TYPES.includes(file.type)) {
    throw new Error('Format berkas tidak didukung. Gunakan gambar JPG, PNG, WEBP, atau dokumen PDF.');
  }

  if (file.size > MAX_FILE_SIZE_BYTES) {
    throw new Error('Ukuran berkas melebihi batas maksimal 5 MB.');
  }

  const today = getJakartaToday();
  const yearMonth = today.slice(0, 7);
  const safeName = sanitizeFileName(file.name);
  const uniquePrefix = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  const storagePath = `${folder}/${yearMonth}/${uniquePrefix}_${safeName}`;

  const { data, error } = await supabase.storage
    .from(APP_CONFIG.STORAGE_BUCKET_PROOFS)
    .upload(storagePath, file, {
      cacheControl: '3600',
      upsert: false,
      contentType: file.type
    });

  if (error) {
    throw new Error(translateDbError(error));
  }

  return data.path;
}

/**
 * Membuat tautan baca sementara (berlaku 1 jam) untuk melihat berkas bukti transaksi privat.
 */
export async function getProofSignedUrl(filePath, expiresInSeconds = 3600) {
  if (!filePath) return null;

  const { data, error } = await supabase.storage
    .from(APP_CONFIG.STORAGE_BUCKET_PROOFS)
    .createSignedUrl(filePath, expiresInSeconds);

  if (error) {
    throw new Error(translateDbError(error));
  }

  return data.signedUrl;
}
