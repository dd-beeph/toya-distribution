-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 008
-- Akuntansi Double-Entry (COA, Jurnal Otomatis, Periode) & Pajak PPN
-- ============================================================================

-- 1. Tabel Chart of Accounts (Daftar Kode Akun)
CREATE TABLE IF NOT EXISTS public.chart_of_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  account_type TEXT NOT NULL CHECK (
    account_type IN ('asset', 'liability', 'equity', 'revenue', 'cogs', 'expense')
  ),
  normal_balance TEXT NOT NULL CHECK (
    normal_balance IN ('debit', 'credit')
  ),
  parent_id UUID REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT,
  is_header BOOLEAN NOT NULL DEFAULT false,
  is_system BOOLEAN NOT NULL DEFAULT true,
  is_active BOOLEAN NOT NULL DEFAULT true,
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_coa_type ON public.chart_of_accounts (account_type);

DROP TRIGGER IF EXISTS trg_coa_updated_at ON public.chart_of_accounts;
CREATE TRIGGER trg_coa_updated_at
  BEFORE UPDATE ON public.chart_of_accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Data Awal Daftar Akun Standar Distributor Minuman
INSERT INTO public.chart_of_accounts (code, name, account_type, normal_balance, is_header, is_system, description)
VALUES
  -- ASET (1xxx)
  ('1101', 'Kas Tunai', 'asset', 'debit', false, true, 'Kas tunai di kasir dan kantor'),
  ('1102', 'Bank & Rekening Operasional', 'asset', 'debit', false, true, 'Saldo rekening bank perusahaan'),
  ('1103', 'Piutang Usaha Pelanggan', 'asset', 'debit', false, true, 'Tagihan penjualan tempo kepada pelanggan'),
  ('1104', 'Piutang Klaim Voucher Promosi', 'asset', 'debit', false, true, 'Tagihan klaim promo voucher kepada principal atau supplier'),
  ('1105', 'Persediaan Barang Dagang', 'asset', 'debit', false, true, 'Nilai stok barang dagang di seluruh gudang'),
  ('1106', 'PPN Masukan', 'asset', 'debit', false, true, 'Pajak pertambahan nilai atas pembelian barang atau jasa'),
  ('1107', 'Uang Muka Pembelian', 'asset', 'debit', false, true, 'Pembayaran dimuka kepada supplier'),

  -- KEWAJIBAN / UTANG (2xxx)
  ('2101', 'Utang Usaha Supplier', 'liability', 'credit', false, true, 'Utang pembelian barang kepada supplier'),
  ('2102', 'PPN Keluaran', 'liability', 'credit', false, true, 'Pajak pertambahan nilai atas penjualan barang kena pajak'),
  ('2103', 'Utang Penerimaan Barang Belum Difaktur', 'liability', 'credit', false, true, 'Akrual persediaan diterima sebelum faktur supplier terbit'),
  ('2104', 'Kelebihan Bayar & Saldo Kredit Pelanggan', 'liability', 'credit', false, true, 'Kewajiban pengembalian dana akibat retur atas faktur lunas'),

  -- EKUITAS / MODAL (3xxx)
  ('3101', 'Modal Disetor', 'equity', 'credit', false, true, 'Modal awal dan tambahan modal pemilik'),
  ('3201', 'Laba Ditahan', 'equity', 'credit', false, true, 'Akumulasi laba bersih tahun berjalan dan sebelumnya'),

  -- PENDAPATAN (4xxx)
  ('4101', 'Penjualan Barang Dagang', 'revenue', 'credit', false, true, 'Pendapatan kotor dari faktur penjualan sah'),
  ('4102', 'Retur Penjualan & Nota Kredit', 'revenue', 'debit', false, true, 'Pengurang pendapatan akibat retur barang dan nota kredit'),
  ('4103', 'Potongan Penjualan', 'revenue', 'debit', false, true, 'Diskon penjualan yang diberikan kepada pelanggan'),

  -- HARGA POKOK PENJUALAN (5xxx)
  ('5101', 'Harga Pokok Penjualan (HPP)', 'cogs', 'debit', false, true, 'Biaya pokok barang yang terjual berdasarkan rata-rata bergerak'),
  ('5102', 'Selisih Stok Opname & Penyesuaian', 'cogs', 'debit', false, true, 'Selisih lebih atau kurang hasil penyesuaian stok gudang'),
  ('5103', 'Kerugian Barang Rusak', 'cogs', 'debit', false, true, 'Beban nilai persediaan barang rusak di gudang atau pengiriman'),

  -- BEBAN OPERASIONAL (6xxx)
  ('6101', 'Beban BBM & Solar Kendaraan', 'expense', 'debit', false, true, 'Pengeluaran bahan bakar armada pengiriman'),
  ('6102', 'Beban Bongkar Muat & Kuli', 'expense', 'debit', false, true, 'Biaya tenaga bongkar muat barang'),
  ('6103', 'Beban Tol, Parkir & Retribusi', 'expense', 'debit', false, true, 'Biaya tol dan parkir pengiriman'),
  ('6104', 'Beban Listrik, Air & Internet', 'expense', 'debit', false, true, 'Utilitas gudang dan kantor'),
  ('6105', 'Beban Perawatan Kendaraan & Gudang', 'expense', 'debit', false, true, 'Pemeliharaan armada dan gudang'),
  ('6106', 'Beban ATK & Perlengkapan Kantor', 'expense', 'debit', false, true, 'Kebutuhan administrasi dan cetak dokumen'),
  ('6107', 'Beban Administrasi Bank', 'expense', 'debit', false, true, 'Biaya transfer dan administrasi bank'),
  ('6108', 'Beban Operasional Lainnya', 'expense', 'debit', false, true, 'Biaya operasional umum lainnya')
ON CONFLICT (code) DO NOTHING;

-- 2. Hubungkan Foreign Key Akun ke Tabel Master & Kategori Biaya dari Migrasi Sebelumnya
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_tax_codes_account') THEN
    ALTER TABLE public.tax_codes
      ADD CONSTRAINT fk_tax_codes_account
      FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_banks_account') THEN
    ALTER TABLE public.banks
      ADD CONSTRAINT fk_banks_account
      FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_payment_methods_account') THEN
    ALTER TABLE public.payment_methods
      ADD CONSTRAINT fk_payment_methods_account
      FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_expense_categories_account') THEN
    ALTER TABLE public.expense_categories
      ADD CONSTRAINT fk_expense_categories_account
      FOREIGN KEY (account_id) REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- Isi Pemetaan Akun Bawaan untuk Pajak, Metode Pembayaran, dan Kategori Biaya
UPDATE public.tax_codes
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE code = '2102')
WHERE code IN ('PPN11', 'PPN12_NL') AND account_id IS NULL;

UPDATE public.tax_codes
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE code = '1106')
WHERE code = 'PPN_MASUKAN' AND account_id IS NULL;

UPDATE public.payment_methods
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE code = '1101')
WHERE code = 'TUNAI' AND account_id IS NULL;

UPDATE public.payment_methods
SET account_id = (SELECT id FROM public.chart_of_accounts WHERE code = '1102')
WHERE code = 'TRANSFER' AND account_id IS NULL;

UPDATE public.expense_categories ec
SET account_id = coa.id
FROM public.chart_of_accounts coa
WHERE ec.account_id IS NULL
  AND (
    (ec.code = 'EXP-BBM' AND coa.code = '6101') OR
    (ec.code = 'EXP-BONGKAR' AND coa.code = '6102') OR
    (ec.code = 'EXP-TOL' AND coa.code = '6103') OR
    (ec.code = 'EXP-UTILITAS' AND coa.code = '6104') OR
    (ec.code = 'EXP-PERAWATAN' AND coa.code = '6105') OR
    (ec.code = 'EXP-ATK' AND coa.code = '6106') OR
    (ec.code = 'EXP-BANK' AND coa.code = '6107') OR
    (ec.code = 'EXP-LAIN' AND coa.code = '6108')
  );

-- 3. Tabel Periode Akuntansi (Kontrol Tutup Buku Bulanan)
CREATE TABLE IF NOT EXISTS public.accounting_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  period_year INTEGER NOT NULL CHECK (period_year >= 2020),
  period_month INTEGER NOT NULL CHECK (period_month BETWEEN 1 AND 12),
  period_name TEXT NOT NULL UNIQUE,
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (
    status IN ('open', 'closed')
  ),
  closed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  closed_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (period_year, period_month)
);

DROP TRIGGER IF EXISTS trg_accounting_periods_updated_at ON public.accounting_periods;
CREATE TRIGGER trg_accounting_periods_updated_at
  BEFORE UPDATE ON public.accounting_periods
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Fungsi mengambil atau membuka otomatis periode akuntansi berdasarkan tanggal transaksi
CREATE OR REPLACE FUNCTION public.ensure_open_accounting_period(p_date DATE)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_year INTEGER;
  v_month INTEGER;
  v_start DATE;
  v_end DATE;
  v_name TEXT;
  v_period_id UUID;
  v_status TEXT;
BEGIN
  v_year := EXTRACT(YEAR FROM p_date)::INTEGER;
  v_month := EXTRACT(MONTH FROM p_date)::INTEGER;
  v_start := make_date(v_year, v_month, 1);
  v_end := (v_start + INTERVAL '1 month - 1 day')::DATE;
  v_name := v_year::TEXT || '-' || LPAD(v_month::TEXT, 2, '0');

  INSERT INTO public.accounting_periods (period_year, period_month, period_name, start_date, end_date, status)
  VALUES (v_year, v_month, v_name, v_start, v_end, 'open')
  ON CONFLICT (period_year, period_month) DO NOTHING;

  SELECT id, status INTO v_period_id, v_status
  FROM public.accounting_periods
  WHERE period_year = v_year AND period_month = v_month;

  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Periode akuntansi % sudah ditutup buku. Transaksi tidak dapat diposting pada tanggal ini.', v_name;
  END IF;

  RETURN v_period_id;
END;
$$;

-- 4. Tabel Kepala Jurnal Umum (Journal Entries)
CREATE TABLE IF NOT EXISTS public.journal_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_number TEXT NOT NULL UNIQUE,
  journal_date DATE NOT NULL DEFAULT public.jakarta_today(),
  accounting_period_id UUID NOT NULL REFERENCES public.accounting_periods(id) ON DELETE RESTRICT,
  source_type TEXT NOT NULL,
  source_id UUID,
  source_number TEXT,
  description TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'posted' CHECK (
    status IN ('draft', 'posted', 'reversed')
  ),
  reversal_of_id UUID REFERENCES public.journal_entries(id) ON DELETE RESTRICT,
  reversed_by_id UUID REFERENCES public.journal_entries(id) ON DELETE RESTRICT,
  total_debit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (total_debit >= 0),
  total_credit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (total_credit >= 0),
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_journal_entries_date ON public.journal_entries (journal_date DESC);
CREATE INDEX IF NOT EXISTS idx_journal_entries_period ON public.journal_entries (accounting_period_id);
CREATE INDEX IF NOT EXISTS idx_journal_entries_source ON public.journal_entries (source_type, source_id);

-- Cegah posting jurnal ganda untuk dokumen sumber yang sama
CREATE UNIQUE INDEX IF NOT EXISTS uq_journal_entries_source_once
  ON public.journal_entries (source_type, source_id)
  WHERE source_id IS NOT NULL AND status <> 'reversed';

CREATE OR REPLACE FUNCTION public.trg_journal_entries_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.journal_number IS NULL OR TRIM(NEW.journal_number) = '' THEN
    NEW.journal_number := public.generate_document_number('JRN', NEW.journal_date);
  END IF;

  IF NEW.accounting_period_id IS NULL THEN
    NEW.accounting_period_id := public.ensure_open_accounting_period(NEW.journal_date);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journal_entries_insert ON public.journal_entries;
CREATE TRIGGER trg_journal_entries_insert
  BEFORE INSERT ON public.journal_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_journal_entries_before_insert();

-- Lindungi jurnal terposting agar tidak dapat dihapus atau diubah tanggal/sumbernya
CREATE OR REPLACE FUNCTION public.trg_guard_journal_entries()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status IN ('posted', 'reversed') THEN
      RAISE EXCEPTION 'Jurnal yang sudah diposting tidak boleh dihapus. Gunakan jurnal pembalik (reversal).';
    END IF;
    RETURN OLD;
  END IF;

  IF OLD.status IN ('posted', 'reversed') THEN
    IF OLD.journal_date IS DISTINCT FROM NEW.journal_date
       OR OLD.source_type IS DISTINCT FROM NEW.source_type
       OR OLD.source_id IS DISTINCT FROM NEW.source_id THEN
      RAISE EXCEPTION 'Tanggal atau referensi dokumen jurnal yang sudah diposting tidak dapat diubah.';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_journal_entries_guard ON public.journal_entries;
CREATE TRIGGER trg_journal_entries_guard
  BEFORE UPDATE OR DELETE ON public.journal_entries
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_journal_entries();

-- 5. Tabel Baris Jurnal Debit & Kredit (Journal Lines)
CREATE TABLE IF NOT EXISTS public.journal_lines (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  journal_entry_id UUID NOT NULL REFERENCES public.journal_entries(id) ON DELETE CASCADE,
  line_no INTEGER NOT NULL DEFAULT 1,
  account_id UUID NOT NULL REFERENCES public.chart_of_accounts(id) ON DELETE RESTRICT,
  description TEXT,
  debit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  customer_id UUID REFERENCES public.customers(id) ON DELETE RESTRICT,
  supplier_id UUID REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  sales_user_id UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_journal_line_single_side CHECK (
    (debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)
  )
);

CREATE INDEX IF NOT EXISTS idx_journal_lines_entry ON public.journal_lines (journal_entry_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_account ON public.journal_lines (account_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_customer ON public.journal_lines (customer_id);
CREATE INDEX IF NOT EXISTS idx_journal_lines_supplier ON public.journal_lines (supplier_id);

-- Pengunci Matematis: Total Debit Wajib Sama Dengan Total Kredit Sebelum Transaksi Selesai
CREATE OR REPLACE FUNCTION public.verify_journal_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry_id UUID;
  v_status TEXT;
  v_sum_debit NUMERIC(18,2);
  v_sum_credit NUMERIC(18,2);
  v_line_count INTEGER;
BEGIN
  v_entry_id := COALESCE(NEW.journal_entry_id, OLD.journal_entry_id);

  SELECT status INTO v_status
  FROM public.journal_entries
  WHERE id = v_entry_id;

  IF v_status IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0), COUNT(*)
  INTO v_sum_debit, v_sum_credit, v_line_count
  FROM public.journal_lines
  WHERE journal_entry_id = v_entry_id;

  IF v_status = 'posted' THEN
    IF v_line_count < 2 THEN
      RAISE EXCEPTION 'Jurnal double-entry wajib memiliki minimal dua baris akun.';
    END IF;

    IF v_sum_debit <= 0 OR v_sum_debit <> v_sum_credit THEN
      RAISE EXCEPTION 'Jurnal tidak seimbang! Total Debit (%) tidak sama dengan Total Kredit (%).', v_sum_debit, v_sum_credit;
    END IF;
  END IF;

  UPDATE public.journal_entries
  SET
    total_debit = v_sum_debit,
    total_credit = v_sum_credit
  WHERE id = v_entry_id;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_verify_journal_balanced ON public.journal_lines;
CREATE CONSTRAINT TRIGGER trg_verify_journal_balanced
  AFTER INSERT OR UPDATE OR DELETE ON public.journal_lines
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION public.verify_journal_balanced();

-- 6. Hubungkan Kolom journal_entry_id pada Seluruh Tabel Transaksi
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_stock_adj_journal') THEN
    ALTER TABLE public.stock_adjustment_requests
      ADD CONSTRAINT fk_stock_adj_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_damaged_goods_journal') THEN
    ALTER TABLE public.damaged_goods
      ADD CONSTRAINT fk_damaged_goods_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_invoices_journal') THEN
    ALTER TABLE public.sales_invoices
      ADD CONSTRAINT fk_sales_invoices_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_sales_returns_journal') THEN
    ALTER TABLE public.sales_returns
      ADD CONSTRAINT fk_sales_returns_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_credit_notes_journal') THEN
    ALTER TABLE public.credit_notes
      ADD CONSTRAINT fk_credit_notes_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_payments_journal') THEN
    ALTER TABLE public.customer_payments
      ADD CONSTRAINT fk_customer_payments_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_customer_refunds_journal') THEN
    ALTER TABLE public.customer_refunds
      ADD CONSTRAINT fk_customer_refunds_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_supplier_invoices_journal') THEN
    ALTER TABLE public.supplier_invoices
      ADD CONSTRAINT fk_supplier_invoices_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_supplier_payments_journal') THEN
    ALTER TABLE public.supplier_payments
      ADD CONSTRAINT fk_supplier_payments_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_operational_expenses_journal') THEN
    ALTER TABLE public.operational_expenses
      ADD CONSTRAINT fk_operational_expenses_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_voucher_claims_journal') THEN
    ALTER TABLE public.voucher_claims
      ADD CONSTRAINT fk_voucher_claims_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_vcs_journal') THEN
    ALTER TABLE public.voucher_claim_settlements
      ADD CONSTRAINT fk_vcs_journal FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- 7. Tabel Transaksi Pajak (PPN Keluaran & PPN Masukan)
CREATE TABLE IF NOT EXISTS public.tax_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_date DATE NOT NULL DEFAULT public.jakarta_today(),
  tax_direction TEXT NOT NULL CHECK (
    tax_direction IN ('output', 'input')
  ),
  tax_code_id UUID NOT NULL REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0,
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000,
  dpp_amount NUMERIC(18,2) NOT NULL DEFAULT 0,
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0,
  source_type TEXT NOT NULL CHECK (
    source_type IN ('SALES_INVOICE', 'CREDIT_NOTE', 'SUPPLIER_INVOICE')
  ),
  source_id UUID NOT NULL,
  source_number TEXT NOT NULL,
  counterparty_name TEXT NOT NULL,
  counterparty_npwp TEXT,
  journal_entry_id UUID REFERENCES public.journal_entries(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (
    status IN ('active', 'void')
  ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source_type, source_id, tax_code_id)
);

CREATE INDEX IF NOT EXISTS idx_tax_transactions_date ON public.tax_transactions (tax_date DESC);
CREATE INDEX IF NOT EXISTS idx_tax_transactions_direction ON public.tax_transactions (tax_direction);

-- 8. Tabel Referensi Nomor Seri Faktur Pajak Resmi (Terpisah dari Invoice Komersial)
CREATE TABLE IF NOT EXISTS public.tax_document_references (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tax_transaction_id UUID REFERENCES public.tax_transactions(id) ON DELETE RESTRICT,
  document_direction TEXT NOT NULL CHECK (
    document_direction IN ('output', 'input')
  ),
  source_type TEXT NOT NULL CHECK (
    source_type IN ('SALES_INVOICE', 'CREDIT_NOTE', 'SUPPLIER_INVOICE')
  ),
  source_id UUID NOT NULL,
  faktur_pajak_number TEXT NOT NULL,
  faktur_pajak_date DATE NOT NULL DEFAULT public.jakarta_today(),
  tax_period_month INTEGER NOT NULL CHECK (tax_period_month BETWEEN 1 AND 12),
  tax_period_year INTEGER NOT NULL CHECK (tax_period_year >= 2020),
  replacement_code TEXT NOT NULL DEFAULT '0',
  proof_file_path TEXT,
  notes TEXT,
  recorded_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (document_direction, faktur_pajak_number)
);

CREATE INDEX IF NOT EXISTS idx_tax_doc_refs_period ON public.tax_document_references (tax_period_year, tax_period_month);

DROP TRIGGER IF EXISTS trg_tax_doc_refs_updated_at ON public.tax_document_references;
CREATE TRIGGER trg_tax_doc_refs_updated_at
  BEFORE UPDATE ON public.tax_document_references
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 9. Fungsi Bantu Pembuat Jurnal Otomatis Terstandar untuk Seluruh Transaksi
CREATE OR REPLACE FUNCTION public.post_automated_journal(
  p_journal_date DATE,
  p_source_type TEXT,
  p_source_id UUID,
  p_source_number TEXT,
  p_description TEXT,
  p_lines JSONB,
  p_actor_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_period_id UUID;
  v_journal_id UUID;
  v_line JSONB;
  v_line_no INTEGER := 0;
  v_account_id UUID;
  v_debit NUMERIC(18,2);
  v_credit NUMERIC(18,2);
BEGIN
  v_period_id := public.ensure_open_accounting_period(COALESCE(p_journal_date, public.jakarta_today()));

  INSERT INTO public.journal_entries (
    journal_date,
    accounting_period_id,
    source_type,
    source_id,
    source_number,
    description,
    status,
    created_by
  )
  VALUES (
    COALESCE(p_journal_date, public.jakarta_today()),
    v_period_id,
    p_source_type,
    p_source_id,
    p_source_number,
    p_description,
    'posted',
    COALESCE(p_actor_id, auth.uid())
  )
  RETURNING id INTO v_journal_id;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_debit := ROUND(COALESCE((v_line ->> 'debit')::NUMERIC, 0), 2);
    v_credit := ROUND(COALESCE((v_line ->> 'credit')::NUMERIC, 0), 2);

    IF v_debit = 0 AND v_credit = 0 THEN
      CONTINUE;
    END IF;

    v_line_no := v_line_no + 1;

    SELECT id INTO v_account_id
    FROM public.chart_of_accounts
    WHERE code = (v_line ->> 'account_code')
      AND is_active = true;

    IF v_account_id IS NULL THEN
      RAISE EXCEPTION 'Kode akun akuntansi % tidak ditemukan atau tidak aktif.', (v_line ->> 'account_code');
    END IF;

    INSERT INTO public.journal_lines (
      journal_entry_id,
      line_no,
      account_id,
      description,
      debit,
      credit,
      customer_id,
      supplier_id,
      sales_user_id,
      warehouse_id
    )
    VALUES (
      v_journal_id,
      v_line_no,
      v_account_id,
      COALESCE(v_line ->> 'description', p_description),
      v_debit,
      v_credit,
      NULLIF(v_line ->> 'customer_id', '')::UUID,
      NULLIF(v_line ->> 'supplier_id', '')::UUID,
      NULLIF(v_line ->> 'sales_user_id', '')::UUID,
      NULLIF(v_line ->> 'warehouse_id', '')::UUID
    );
  END LOOP;

  RETURN v_journal_id;
END;
$$;
