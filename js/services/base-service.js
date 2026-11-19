/**
 * Layanan Dasar Penghubung Database & RPC Supabase
 */

import { supabase } from '../config/supabase-client.js';

/**
 * Menerjemahkan kode kesalahan PostgreSQL atau Supabase menjadi pesan bahasa Indonesia yang jelas.
 */
export function translateDbError(error) {
  if (!error) return 'Terjadi kesalahan yang tidak diketahui.';

  const code = String(error.code || '');
  const rawMessage = String(error.message || '');

  if (code === '23505') {
    return 'Data dengan kode, nomor, atau identitas tersebut sudah terdaftar di sistem.';
  }
  if (code === '23503') {
    return 'Data ini masih terhubung dengan catatan transaksi lain sehingga tidak dapat diubah atau dihapus.';
  }
  if (code === '23514') {
    return 'Nilai yang dimasukkan melanggar batasan aturan data yang berlaku.';
  }
  if (code === '42501') {
    return 'Anda tidak memiliki kewenangan akses untuk melakukan tindakan ini.';
  }
  if (code === 'PGRST116') {
    return 'Data yang dicari tidak ditemukan.';
  }
  if (rawMessage.includes('Failed to fetch') || rawMessage.includes('NetworkError')) {
    return 'Koneksi internet terputus. Periksa jaringan Anda lalu coba kembali.';
  }
  if (rawMessage.includes('Invalid login credentials')) {
    return 'Email atau kata sandi yang Anda masukkan tidak sesuai.';
  }
  if (rawMessage.includes('User already registered')) {
    return 'Alamat email ini sudah terdaftar. Silakan gunakan halaman Masuk.';
  }

  return rawMessage || 'Gagal memproses permintaan ke server.';
}

/**
 * Memeriksa hasil respons kueri Supabase dan melempar pesan galat yang sudah diterjemahkan.
 */
export function unwrapResponse({ data, error }) {
  if (error) {
    throw new Error(translateDbError(error));
  }
  return data;
}

/**
 * Memanggil fungsi RPC server-side di Supabase secara aman.
 */
export async function callRpc(functionName, params = {}) {
  const { data, error } = await supabase.rpc(functionName, params);
  if (error) {
    throw new Error(translateDbError(error));
  }
  return data;
}
