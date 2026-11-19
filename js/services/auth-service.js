/**
 * Layanan Autentikasi, Profil Pengguna, & Konteks Sesi
 */

import { supabase } from '../config/supabase-client.js';
import { translateDbError } from '../services/base-service.js';

/**
 * Masuk ke aplikasi menggunakan email dan kata sandi.
 */
export async function signInWithEmail(email, password) {
  const { data, error } = await supabase.auth.signInWithPassword({
    email: String(email || '').trim(),
    password: String(password || '')
  });

  if (error) {
    throw new Error(translateDbError(error));
  }

  return data;
}

/**
 * Mendaftarkan akun pengguna baru.
 * Role akan ditetapkan oleh Owner melalui menu Pengaturan & Pengguna.
 */
export async function signUpWithEmail({ email, password, fullName, phone = '' }) {
  const cleanName = String(fullName || '').trim();
  if (!cleanName) {
    throw new Error('Nama lengkap wajib diisi.');
  }

  const { data, error } = await supabase.auth.signUp({
    email: String(email || '').trim(),
    password: String(password || ''),
    options: {
      data: {
        full_name: cleanName,
        phone: String(phone || '').trim()
      }
    }
  });

  if (error) {
    throw new Error(translateDbError(error));
  }

  return data;
}

/**
 * Keluar dari sesi aplikasi saat ini.
 */
export async function signOutUser() {
  const { error } = await supabase.auth.signOut();
  if (error) {
    throw new Error(translateDbError(error));
  }
}

/**
 * Mengambil sesi autentikasi aktif saat halaman dimuat.
 */
export async function getCurrentSession() {
  const { data, error } = await supabase.auth.getSession();
  if (error) {
    throw new Error(translateDbError(error));
  }
  return data.session;
}

/**
 * Mengambil profil lengkap, role aktif, dan pengaturan sistem bagi pengguna yang sedang masuk.
 */
export async function loadUserContext() {
  const session = await getCurrentSession();
  if (!session || !session.user) {
    return null;
  }

  const user = session.user;

  const [profileRes, roleRes] = await Promise.all([
    supabase
      .from('profiles')
      .select('id, employee_code, full_name, email, phone, is_active, deactivated_at')
      .eq('id', user.id)
      .maybeSingle(),
    supabase
      .from('user_roles')
      .select('role, assigned_at')
      .eq('user_id', user.id)
      .maybeSingle()
  ]);

  if (profileRes.error) {
    throw new Error(translateDbError(profileRes.error));
  }
  if (roleRes.error) {
    throw new Error(translateDbError(roleRes.error));
  }

  const profile = profileRes.data || {
    id: user.id,
    full_name: user.user_metadata?.full_name || user.email,
    email: user.email,
    is_active: true
  };

  const role = roleRes.data?.role || null;
  const isDeactivated = profile.is_active === false;
  const needsRoleAssignment = !isDeactivated && !role;

  let settingsMap = {};
  if (!isDeactivated && role) {
    const { data: settingsRows } = await supabase
      .from('system_settings')
      .select('setting_key, setting_value');

    if (Array.isArray(settingsRows)) {
      settingsMap = settingsRows.reduce((acc, row) => {
        acc[row.setting_key] = row.setting_value;
        return acc;
      }, {});
    }
  }

  return {
    user,
    profile,
    role,
    isDeactivated,
    needsRoleAssignment,
    settings: settingsMap
  };
}

/**
 * Memantau perubahan status login/logout secara real-time.
 */
export function onAuthStateChange(callback) {
  return supabase.auth.onAuthStateChange((event, session) => {
    callback(event, session);
  });
}
