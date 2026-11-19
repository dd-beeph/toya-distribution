-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 002
-- Master Data: Gudang, Pelanggan, Supplier, Produk, Konversi Satuan, Bank, Pajak
-- ============================================================================

-- 1. Tabel Gudang (Mendukung Multi-Gudang)
CREATE TABLE IF NOT EXISTS public.warehouses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  address TEXT,
  phone TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_warehouses_updated_at ON public.warehouses;
CREATE TRIGGER trg_warehouses_updated_at
  BEFORE UPDATE ON public.warehouses
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.warehouses (code, name, address, is_active)
VALUES ('GDG-UTAMA', 'Gudang Utama', 'Cileungsi, Kabupaten Bogor', true)
ON CONFLICT (code) DO NOTHING;

-- 2. Tabel Pelanggan
CREATE TABLE IF NOT EXISTS public.customers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  customer_type TEXT NOT NULL DEFAULT 'retail' CHECK (
    customer_type IN ('retail', 'grosir', 'horeca', 'modern_trade', 'lainnya')
  ),
  contact_person TEXT,
  phone TEXT,
  email TEXT,
  address TEXT,
  city TEXT,
  npwp TEXT,
  payment_term_days INTEGER NOT NULL DEFAULT 0 CHECK (payment_term_days >= 0),
  credit_limit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit_limit >= 0),
  assigned_sales_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_customers_name ON public.customers (name);
CREATE INDEX IF NOT EXISTS idx_customers_sales ON public.customers (assigned_sales_id);

CREATE OR REPLACE FUNCTION public.trg_auto_customer_code()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.code IS NULL OR TRIM(NEW.code) = '' THEN
    NEW.code := public.generate_document_number('CUST', public.jakarta_today());
  ELSE
    NEW.code := UPPER(TRIM(NEW.code));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customers_auto_code ON public.customers;
CREATE TRIGGER trg_customers_auto_code
  BEFORE INSERT ON public.customers
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_customer_code();

DROP TRIGGER IF EXISTS trg_customers_updated_at ON public.customers;
CREATE TRIGGER trg_customers_updated_at
  BEFORE UPDATE ON public.customers
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 3. Tabel Supplier dan Principal
CREATE TABLE IF NOT EXISTS public.suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  contact_person TEXT,
  phone TEXT,
  email TEXT,
  address TEXT,
  npwp TEXT,
  payment_term_days INTEGER NOT NULL DEFAULT 0 CHECK (payment_term_days >= 0),
  is_principal BOOLEAN NOT NULL DEFAULT false,
  is_active BOOLEAN NOT NULL DEFAULT true,
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_suppliers_name ON public.suppliers (name);

CREATE OR REPLACE FUNCTION public.trg_auto_supplier_code()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.code IS NULL OR TRIM(NEW.code) = '' THEN
    NEW.code := public.generate_document_number('SUPP', public.jakarta_today());
  ELSE
    NEW.code := UPPER(TRIM(NEW.code));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_suppliers_auto_code ON public.suppliers;
CREATE TRIGGER trg_suppliers_auto_code
  BEFORE INSERT ON public.suppliers
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_supplier_code();

DROP TRIGGER IF EXISTS trg_suppliers_updated_at ON public.suppliers;
CREATE TRIGGER trg_suppliers_updated_at
  BEFORE UPDATE ON public.suppliers
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 4. Tabel Kode Pajak dan Tarif Pajak Berbasis Tanggal Efektif
-- Kolom account_id akan dihubungkan ke chart_of_accounts pada migrasi 008
CREATE TABLE IF NOT EXISTS public.tax_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  tax_type TEXT NOT NULL CHECK (
    tax_type IN ('ppn_keluaran', 'ppn_masukan', 'non_ppn')
  ),
  description TEXT,
  account_id UUID,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_tax_codes_updated_at ON public.tax_codes;
CREATE TRIGGER trg_tax_codes_updated_at
  BEFORE UPDATE ON public.tax_codes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.tax_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_code_id UUID NOT NULL REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  rate_percent NUMERIC(6,4) NOT NULL CHECK (rate_percent >= 0 AND rate_percent <= 100),
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000 CHECK (dpp_multiplier > 0),
  effective_from DATE NOT NULL,
  effective_to DATE,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_tax_rate_date_range CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS idx_tax_rates_code_date ON public.tax_rates (tax_code_id, effective_from DESC);

DROP TRIGGER IF EXISTS trg_tax_rates_updated_at ON public.tax_rates;
CREATE TRIGGER trg_tax_rates_updated_at
  BEFORE UPDATE ON public.tax_rates
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Data awal kode dan tarif pajak Indonesia
INSERT INTO public.tax_codes (code, name, tax_type, description)
VALUES
  ('NON_PPN', 'Tanpa PPN', 'non_ppn', 'Transaksi tidak dikenakan PPN'),
  ('PPN11', 'PPN 11%', 'ppn_keluaran', 'PPN tarif 11 persen'),
  ('PPN12_NL', 'PPN 12% DPP Nilai Lain', 'ppn_keluaran', 'PPN 12 persen dengan dasar pengenaan pajak 11/12'),
  ('PPN_MASUKAN', 'PPN Masukan', 'ppn_masukan', 'PPN atas pembelian barang atau jasa kena pajak')
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.tax_rates (tax_code_id, rate_percent, dpp_multiplier, effective_from)
SELECT id, 0.0000, 1.000000, DATE '2020-01-01'
FROM public.tax_codes WHERE code = 'NON_PPN'
AND NOT EXISTS (SELECT 1 FROM public.tax_rates tr WHERE tr.tax_code_id = tax_codes.id);

INSERT INTO public.tax_rates (tax_code_id, rate_percent, dpp_multiplier, effective_from)
SELECT id, 11.0000, 1.000000, DATE '2022-04-01'
FROM public.tax_codes WHERE code = 'PPN11'
AND NOT EXISTS (SELECT 1 FROM public.tax_rates tr WHERE tr.tax_code_id = tax_codes.id);

INSERT INTO public.tax_rates (tax_code_id, rate_percent, dpp_multiplier, effective_from)
SELECT id, 12.0000, 0.916667, DATE '2025-01-01'
FROM public.tax_codes WHERE code = 'PPN12_NL'
AND NOT EXISTS (SELECT 1 FROM public.tax_rates tr WHERE tr.tax_code_id = tax_codes.id);

INSERT INTO public.tax_rates (tax_code_id, rate_percent, dpp_multiplier, effective_from)
SELECT id, 12.0000, 0.916667, DATE '2025-01-01'
FROM public.tax_codes WHERE code = 'PPN_MASUKAN'
AND NOT EXISTS (SELECT 1 FROM public.tax_rates tr WHERE tr.tax_code_id = tax_codes.id);

-- Fungsi mengambil tarif pajak aktif berdasarkan tanggal transaksi
CREATE OR REPLACE FUNCTION public.get_effective_tax_rate(
  p_tax_code_id UUID,
  p_tx_date DATE DEFAULT NULL
)
RETURNS TABLE (
  tax_rate_id UUID,
  rate_percent NUMERIC,
  dpp_multiplier NUMERIC
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    tr.id,
    tr.rate_percent,
    tr.dpp_multiplier
  FROM public.tax_rates tr
  WHERE tr.tax_code_id = p_tax_code_id
    AND tr.is_active = true
    AND tr.effective_from <= COALESCE(p_tx_date, public.jakarta_today())
    AND (tr.effective_to IS NULL OR tr.effective_to >= COALESCE(p_tx_date, public.jakarta_today()))
  ORDER BY tr.effective_from DESC
  LIMIT 1;
$$;

-- 5. Tabel Satuan Barang
CREATE TABLE IF NOT EXISTS public.units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_units_updated_at ON public.units;
CREATE TRIGGER trg_units_updated_at
  BEFORE UPDATE ON public.units
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.units (code, name, description)
VALUES
  ('PCS', 'Pcs', 'Satuan eceran per buah'),
  ('BTL', 'Botol', 'Satuan kemasan botol'),
  ('CUP', 'Cup', 'Satuan kemasan gelas cup'),
  ('GLN', 'Galon', 'Satuan kemasan galon'),
  ('PCK', 'Pack', 'Satuan kemasan ikat atau pack'),
  ('DUS', 'Dus', 'Satuan kemasan dus atau karton'),
  ('KRT', 'Krat', 'Satuan kemasan krat botol')
ON CONFLICT (code) DO NOTHING;

-- 6. Tabel Produk
CREATE TABLE IF NOT EXISTS public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sku TEXT NOT NULL UNIQUE,
  barcode TEXT UNIQUE,
  name TEXT NOT NULL,
  brand TEXT,
  category TEXT,
  base_unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  default_sales_unit_id UUID REFERENCES public.units(id) ON DELETE RESTRICT,
  default_purchase_unit_id UUID REFERENCES public.units(id) ON DELETE RESTRICT,
  tax_code_id UUID REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  valuation_method TEXT NOT NULL DEFAULT 'moving_average' CHECK (
    valuation_method = 'moving_average'
  ),
  min_stock_alert NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (min_stock_alert >= 0),
  standard_sell_price NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (standard_sell_price >= 0),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_products_name ON public.products (name);
CREATE INDEX IF NOT EXISTS idx_products_brand ON public.products (brand);

CREATE OR REPLACE FUNCTION public.trg_auto_product_sku()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.sku IS NULL OR TRIM(NEW.sku) = '' THEN
    NEW.sku := public.generate_document_number('PRD', public.jakarta_today());
  ELSE
    NEW.sku := UPPER(TRIM(NEW.sku));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_auto_sku ON public.products;
CREATE TRIGGER trg_products_auto_sku
  BEFORE INSERT ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_product_sku();

DROP TRIGGER IF EXISTS trg_products_updated_at ON public.products;
CREATE TRIGGER trg_products_updated_at
  BEFORE UPDATE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 7. Tabel Konversi Satuan per Produk
-- Contoh: Produk Air Mineral 600ml -> satuan dasar BTL, 1 DUS = 24 BTL
CREATE TABLE IF NOT EXISTS public.product_units (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  conversion_to_base NUMERIC(18,6) NOT NULL CHECK (conversion_to_base > 0),
  is_sales_unit BOOLEAN NOT NULL DEFAULT true,
  is_purchase_unit BOOLEAN NOT NULL DEFAULT true,
  barcode TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (product_id, unit_id)
);

CREATE INDEX IF NOT EXISTS idx_product_units_product ON public.product_units (product_id);

DROP TRIGGER IF EXISTS trg_product_units_updated_at ON public.product_units;
CREATE TRIGGER trg_product_units_updated_at
  BEFORE UPDATE ON public.product_units
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Fungsi konversi kuantitas satuan transaksi ke satuan dasar stok
CREATE OR REPLACE FUNCTION public.convert_to_base_qty(
  p_product_id UUID,
  p_unit_id UUID,
  p_qty NUMERIC
)
RETURNS NUMERIC
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_unit_id UUID;
  v_factor NUMERIC(18,6);
BEGIN
  IF p_qty IS NULL THEN
    RAISE EXCEPTION 'Kuantitas produk tidak boleh kosong';
  END IF;

  SELECT base_unit_id INTO v_base_unit_id
  FROM public.products
  WHERE id = p_product_id;

  IF v_base_unit_id IS NULL THEN
    RAISE EXCEPTION 'Produk tidak ditemukan';
  END IF;

  IF p_unit_id = v_base_unit_id THEN
    RETURN ROUND(p_qty, 6);
  END IF;

  SELECT conversion_to_base INTO v_factor
  FROM public.product_units
  WHERE product_id = p_product_id
    AND unit_id = p_unit_id;

  IF v_factor IS NULL THEN
    RAISE EXCEPTION 'Satuan yang dipilih belum terdaftar dalam konversi produk ini';
  END IF;

  RETURN ROUND(p_qty * v_factor, 6);
END;
$$;

-- 8. Tabel Rekening Bank dan Metode Pembayaran
-- Kolom account_id akan dihubungkan ke chart_of_accounts pada migrasi 008
CREATE TABLE IF NOT EXISTS public.banks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  bank_name TEXT NOT NULL,
  account_number TEXT NOT NULL,
  account_holder TEXT NOT NULL,
  account_id UUID,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_banks_updated_at ON public.banks;
CREATE TRIGGER trg_banks_updated_at
  BEFORE UPDATE ON public.banks
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.payment_methods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  method_type TEXT NOT NULL CHECK (
    method_type IN ('cash', 'bank_transfer', 'giro_cek', 'other')
  ),
  bank_id UUID REFERENCES public.banks(id) ON DELETE RESTRICT,
  account_id UUID,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_payment_methods_updated_at ON public.payment_methods;
CREATE TRIGGER trg_payment_methods_updated_at
  BEFORE UPDATE ON public.payment_methods
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.payment_methods (code, name, method_type, is_active)
VALUES
  ('TUNAI', 'Tunai / Kas', 'cash', true),
  ('TRANSFER', 'Transfer Bank', 'bank_transfer', true)
ON CONFLICT (code) DO NOTHING;
