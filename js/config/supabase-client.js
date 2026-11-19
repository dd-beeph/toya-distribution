/**
 * Koneksi Tunggal Supabase Client
 * Seluruh modul aplikasi wajib mengimpor instance `supabase` dari file ini.
 */

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { APP_CONFIG } from './app-config.js';

export function isSupabaseConfigured() {
  return Boolean(
    APP_CONFIG.SUPABASE_URL &&
    APP_CONFIG.SUPABASE_ANON_KEY &&
    !APP_CONFIG.SUPABASE_URL.includes('TEMPEL_PROJECT_URL') &&
    !APP_CONFIG.SUPABASE_ANON_KEY.includes('TEMPEL_ANON_KEY')
  );
}

if (!isSupabaseConfigured()) {
  console.warn(
    'Konfigurasi Supabase belum diisi pada js/config/app-config.js. Harap masukkan Project URL dan anon key Anda.'
  );
}

export const supabase = createClient(
  APP_CONFIG.SUPABASE_URL,
  APP_CONFIG.SUPABASE_ANON_KEY,
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      storageKey: 'toya_distribution_auth_token'
    }
  }
);
