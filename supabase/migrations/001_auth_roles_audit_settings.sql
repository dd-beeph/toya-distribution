-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 001
-- Fondasi Pengguna, 5 Role, Pengaturan Sistem, Audit Log, dan Nomor Dokumen
-- ============================================================================

-- 1. Aktifkan ekstensi pembuatan UUID acak yang aman
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 2. Fungsi bantu zona waktu bisnis (Asia/Jakarta)
CREATE OR REPLACE FUNCTION public.jakarta_today()
RETURNS DATE
LANGUAGE sql
STABLE
AS $$
  SELECT (now() AT TIME ZONE 'Asia/Jakarta')::date;
$$;

CREATE OR REPLACE FUNCTION public.to_jakarta_date(p_ts TIMESTAMPTZ)
RETURNS DATE
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (p_ts AT TIME ZONE 'Asia/Jakarta')::date;
$$;

-- 3. Fungsi trigger otomatis untuk memperbarui kolom updated_at
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- 4. Tabel Profil Karyawan (terhubung ke Supabase Auth)
-- Menggunakan ON DELETE RESTRICT agar riwayat transaksi Sales/karyawan tidak hilang
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  employee_code TEXT UNIQUE,
  full_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  phone TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  deactivated_at TIMESTAMPTZ,
  deactivated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 5. Tabel Role Pengguna (5 Role Wajib)
CREATE TABLE IF NOT EXISTS public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE RESTRICT,
  role TEXT NOT NULL CHECK (
    role IN ('sales', 'warehouse', 'cashier', 'finance_admin', 'owner')
  ),
  assigned_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  assigned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_user_roles_updated_at ON public.user_roles;
CREATE TRIGGER trg_user_roles_updated_at
  BEFORE UPDATE ON public.user_roles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 6. Trigger Otomatis Saat Akun Baru Dibuat di Supabase Auth
-- Akun pertama otomatis menjadi 'owner'; akun berikutnya menunggu penetapan role oleh Owner
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_full_name TEXT;
  v_role_count INTEGER;
BEGIN
  v_full_name := COALESCE(
    NULLIF(TRIM(NEW.raw_user_meta_data ->> 'full_name'), ''),
    split_part(COALESCE(NEW.email, 'Pengguna'), '@', 1)
  );

  INSERT INTO public.profiles (id, full_name, email, is_active)
  VALUES (NEW.id, v_full_name, COALESCE(NEW.email, ''), true)
  ON CONFLICT (id) DO NOTHING;

  SELECT COUNT(*) INTO v_role_count FROM public.user_roles;

  IF v_role_count = 0 THEN
    INSERT INTO public.user_roles (user_id, role, assigned_by)
    VALUES (NEW.id, 'owner', NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_auth_user();

-- 7. Fungsi Pemeriksaan Hak Akses di Sisi Database (Anti-Manipulasi Browser)
CREATE OR REPLACE FUNCTION public.is_active_user()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = auth.uid()
      AND p.is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT ur.role
  FROM public.user_roles ur
  JOIN public.profiles p ON p.id = ur.user_id
  WHERE ur.user_id = auth.uid()
    AND p.is_active = true
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.has_any_role(p_roles TEXT[])
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.get_my_role() = ANY(p_roles), false);
$$;

-- 8. Tabel Pengaturan Bisnis Fleksibel (Dapat Diubah Owner di Menu Pengaturan)
CREATE TABLE IF NOT EXISTS public.system_settings (
  setting_key TEXT PRIMARY KEY,
  setting_value JSONB NOT NULL,
  description TEXT NOT NULL,
  updated_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_system_settings_updated_at ON public.system_settings;
CREATE TRIGGER trg_system_settings_updated_at
  BEFORE UPDATE ON public.system_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.system_settings (setting_key, setting_value, description)
VALUES
  (
    'company_profile',
    '{"name": "Toya Distribution", "legal_name": "PT Toya Jaya Darma", "npwp": "", "address": "", "phone": "", "timezone": "Asia/Jakarta", "currency": "IDR"}'::jsonb,
    'Identitas perusahaan, zona waktu, dan mata uang dasar'
  ),
  (
    'ppn_sales_price_mode',
    '{"enabled": false, "mode": "non_ppn", "default_tax_code": "PPN11"}'::jsonb,
    'Pengaturan PPN harga jual: non_ppn (nonaktif), exclude_ppn (harga belum termasuk PPN), atau include_ppn (harga sudah termasuk PPN)'
  ),
  (
    'allow_negative_stock',
    '{"enabled": false, "require_owner_approval": true}'::jsonb,
    'Mengizinkan atau mengunci transaksi jika saldo stok gudang tidak mencukupi'
  ),
  (
    'rupiah_rounding_rule',
    '{"enabled": false, "method": "per_invoice", "precision": 0}'::jsonb,
    'Aturan pembulatan Rupiah untuk DPP dan PPN: per_invoice (per faktur) atau per_line (per baris barang)'
  ),
  (
    'voucher_claim_mode',
    '{"mode": "deduct_invoice_and_create_claim"}'::jsonb,
    'Potongan voucher promosi langsung mengurangi tagihan pelanggan dan membentuk piutang klaim ke principal/supplier'
  )
ON CONFLICT (setting_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_system_setting(p_key TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT setting_value
  FROM public.system_settings
  WHERE setting_key = p_key
  LIMIT 1;
$$;

-- 9. Tabel Audit Log (Rekam Jejak Perubahan dan Koreksi)
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  table_name TEXT NOT NULL,
  record_id UUID,
  action TEXT NOT NULL CHECK (
    action IN ('INSERT', 'UPDATE', 'DELETE', 'APPROVE', 'REJECT', 'OVERRIDE', 'VOID', 'SETTING_CHANGE')
  ),
  actor_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  actor_role TEXT,
  reason TEXT,
  old_data JSONB,
  new_data JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_logs_table_record ON public.audit_logs (table_name, record_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON public.audit_logs (actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs (created_at DESC);

CREATE OR REPLACE FUNCTION public.write_audit_log(
  p_table_name TEXT,
  p_record_id UUID,
  p_action TEXT,
  p_reason TEXT DEFAULT NULL,
  p_old_data JSONB DEFAULT NULL,
  p_new_data JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_log_id UUID;
BEGIN
  INSERT INTO public.audit_logs (
    table_name,
    record_id,
    action,
    actor_id,
    actor_role,
    reason,
    old_data,
    new_data
  )
  VALUES (
    p_table_name,
    p_record_id,
    p_action,
    auth.uid(),
    public.get_my_role(),
    p_reason,
    p_old_data,
    p_new_data
  )
  RETURNING id INTO v_log_id;

  RETURN v_log_id;
END;
$$;

-- 10. Mesin Pembuat Nomor Dokumen Unik di Server (Reset Tahunan Asia/Jakarta)
CREATE TABLE IF NOT EXISTS public.document_sequences (
  doc_type TEXT NOT NULL,
  doc_year INTEGER NOT NULL,
  last_number INTEGER NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (doc_type, doc_year)
);

CREATE OR REPLACE FUNCTION public.generate_document_number(
  p_doc_type TEXT,
  p_business_date DATE DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_date DATE;
  v_year INTEGER;
  v_next_num INTEGER;
BEGIN
  v_date := COALESCE(p_business_date, public.jakarta_today());
  v_year := EXTRACT(YEAR FROM v_date)::INTEGER;

  INSERT INTO public.document_sequences (doc_type, doc_year, last_number, updated_at)
  VALUES (UPPER(TRIM(p_doc_type)), v_year, 1, now())
  ON CONFLICT (doc_type, doc_year)
  DO UPDATE SET
    last_number = public.document_sequences.last_number + 1,
    updated_at = now()
  RETURNING last_number INTO v_next_num;

  RETURN UPPER(TRIM(p_doc_type)) || '-' || v_year::TEXT || '-' || LPAD(v_next_num::TEXT, 5, '0');
END;
$$;
