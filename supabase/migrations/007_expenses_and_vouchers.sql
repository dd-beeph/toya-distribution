-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 007
-- Biaya Operasional, Verifikasi Biaya, dan Klaim Voucher Promosi Principal
-- ============================================================================

-- 1. Tabel Kategori Biaya Operasional
-- Kolom account_id akan dihubungkan ke chart_of_accounts pada migrasi 008
CREATE TABLE IF NOT EXISTS public.expense_categories (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  description TEXT,
  account_id UUID,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_expense_categories_updated_at ON public.expense_categories;
CREATE TRIGGER trg_expense_categories_updated_at
  BEFORE UPDATE ON public.expense_categories
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

INSERT INTO public.expense_categories (code, name, description)
VALUES
  ('EXP-BBM', 'BBM & Solar Kendaraan', 'Biaya bahan bakar armada pengiriman'),
  ('EXP-BONGKAR', 'Bongkar Muat & Kuli', 'Biaya tenaga bongkar muat barang di gudang atau toko'),
  ('EXP-TOL', 'Tol, Parkir & Retribusi', 'Biaya perjalanan pengiriman barang'),
  ('EXP-UTILITAS', 'Listrik, Air & Internet', 'Biaya utilitas kantor dan gudang'),
  ('EXP-PERAWATAN', 'Perawatan Kendaraan & Gudang', 'Servis ringan armada dan pemeliharaan fasilitas gudang'),
  ('EXP-ATK', 'ATK & Perlengkapan Kantor', 'Kertas surat jalan, tinta printer, dan kebutuhan administrasi'),
  ('EXP-BANK', 'Biaya Administrasi Bank', 'Biaya transfer dan administrasi rekening bank'),
  ('EXP-LAIN', 'Biaya Operasional Lainnya', 'Pengeluaran operasional lain yang sah')
ON CONFLICT (code) DO NOTHING;

-- 2. Tabel Transaksi Biaya Operasional
CREATE TABLE IF NOT EXISTS public.operational_expenses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_number TEXT NOT NULL UNIQUE,
  expense_date DATE NOT NULL DEFAULT public.jakarta_today(),
  category_id UUID NOT NULL REFERENCES public.expense_categories(id) ON DELETE RESTRICT,
  payment_method_id UUID NOT NULL REFERENCES public.payment_methods(id) ON DELETE RESTRICT,
  bank_id UUID REFERENCES public.banks(id) ON DELETE RESTRICT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  payee_name TEXT,
  description TEXT NOT NULL,
  proof_file_path TEXT,
  verification_status TEXT NOT NULL DEFAULT 'pending' CHECK (
    verification_status IN ('pending', 'verified', 'rejected', 'void')
  ),
  rejection_reason TEXT,
  journal_entry_id UUID,
  recorded_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_expense_self_verify_forbidden CHECK (
    verified_by IS NULL OR verified_by <> recorded_by
  )
);

CREATE INDEX IF NOT EXISTS idx_operational_expenses_date ON public.operational_expenses (expense_date DESC);
CREATE INDEX IF NOT EXISTS idx_operational_expenses_category ON public.operational_expenses (category_id);
CREATE INDEX IF NOT EXISTS idx_operational_expenses_status ON public.operational_expenses (verification_status);

CREATE OR REPLACE FUNCTION public.trg_guard_operational_expense_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.expense_number IS NULL OR TRIM(NEW.expense_number) = '' THEN
    NEW.expense_number := public.generate_document_number('EXP', NEW.expense_date);
  END IF;

  IF auth.uid() IS NOT NULL THEN
    NEW.recorded_by := auth.uid();
  END IF;

  NEW.verification_status := 'pending';
  NEW.verified_by := NULL;
  NEW.verified_at := NULL;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_operational_expenses_before_insert ON public.operational_expenses;
CREATE TRIGGER trg_operational_expenses_before_insert
  BEFORE INSERT ON public.operational_expenses
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_operational_expense_insert();

CREATE OR REPLACE FUNCTION public.trg_guard_operational_expense_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_role TEXT;
BEGIN
  IF OLD.recorded_by IS DISTINCT FROM NEW.recorded_by THEN
    RAISE EXCEPTION 'Pembuat catatan biaya operasional tidak dapat diubah.';
  END IF;

  IF OLD.verification_status = 'verified' AND (
    OLD.amount IS DISTINCT FROM NEW.amount OR
    OLD.category_id IS DISTINCT FROM NEW.category_id OR
    OLD.expense_date IS DISTINCT FROM NEW.expense_date
  ) THEN
    RAISE EXCEPTION 'Biaya operasional yang sudah diverifikasi tidak dapat diubah nominal atau tanggalnya.';
  END IF;

  IF OLD.verification_status IS DISTINCT FROM NEW.verification_status THEN
    v_role := public.get_my_role();
    IF v_role NOT IN ('finance_admin', 'owner') THEN
      RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat memverifikasi biaya operasional.';
    END IF;

    IF NEW.verification_status IN ('verified', 'rejected') THEN
      NEW.verified_by := COALESCE(auth.uid(), NEW.verified_by);
      NEW.verified_at := now();

      IF NEW.verified_by = OLD.recorded_by THEN
        RAISE EXCEPTION 'Pembuat catatan biaya tidak boleh memverifikasi catatannya sendiri.';
      END IF;
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_operational_expenses_before_update ON public.operational_expenses;
CREATE TRIGGER trg_operational_expenses_before_update
  BEFORE UPDATE ON public.operational_expenses
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_operational_expense_update();

-- 3. Tabel Riwayat Persetujuan Biaya Operasional
CREATE TABLE IF NOT EXISTS public.expense_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  operational_expense_id UUID NOT NULL REFERENCES public.operational_expenses(id) ON DELETE CASCADE,
  action TEXT NOT NULL CHECK (action IN ('verified', 'rejected', 'void')),
  decided_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_expense_approvals_expense ON public.expense_approvals (operational_expense_id);

-- 4. Tabel Klaim Voucher Promosi ke Principal / Supplier
CREATE TABLE IF NOT EXISTS public.voucher_claims (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_number TEXT NOT NULL UNIQUE,
  claim_date DATE NOT NULL DEFAULT public.jakarta_today(),
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  sales_invoice_id UUID REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  program_name TEXT NOT NULL,
  voucher_code TEXT,
  claim_amount NUMERIC(18,2) NOT NULL CHECK (claim_amount > 0),
  settled_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (settled_amount >= 0),
  balance_due NUMERIC(18,2) GENERATED ALWAYS AS (
    GREATEST(0, claim_amount - settled_amount)
  ) STORED,
  status TEXT NOT NULL DEFAULT 'open' CHECK (
    status IN ('open', 'partial', 'settled', 'rejected', 'void')
  ),
  proof_file_path TEXT,
  journal_entry_id UUID,
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_voucher_claim_settlement_limit CHECK (settled_amount <= claim_amount)
);

CREATE INDEX IF NOT EXISTS idx_voucher_claims_date ON public.voucher_claims (claim_date DESC);
CREATE INDEX IF NOT EXISTS idx_voucher_claims_supplier ON public.voucher_claims (supplier_id);
CREATE INDEX IF NOT EXISTS idx_voucher_claims_status ON public.voucher_claims (status);

-- Cegah pembuatan klaim voucher ganda untuk faktur penjualan yang sama
CREATE UNIQUE INDEX IF NOT EXISTS uq_voucher_claims_sales_invoice
  ON public.voucher_claims (sales_invoice_id)
  WHERE sales_invoice_id IS NOT NULL AND status NOT IN ('rejected', 'void');

CREATE OR REPLACE FUNCTION public.trg_auto_voucher_claim_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.claim_number IS NULL OR TRIM(NEW.claim_number) = '' THEN
    NEW.claim_number := public.generate_document_number('VCL', NEW.claim_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_voucher_claims_before_insert ON public.voucher_claims;
CREATE TRIGGER trg_voucher_claims_before_insert
  BEFORE INSERT ON public.voucher_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_voucher_claim_number();

DROP TRIGGER IF EXISTS trg_voucher_claims_updated_at ON public.voucher_claims;
CREATE TRIGGER trg_voucher_claims_updated_at
  BEFORE UPDATE ON public.voucher_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 5. Tabel Penyelesaian Klaim Voucher (Pencairan Uang atau Potong Utang Supplier)
CREATE TABLE IF NOT EXISTS public.voucher_claim_settlements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  settlement_number TEXT NOT NULL UNIQUE,
  settlement_date DATE NOT NULL DEFAULT public.jakarta_today(),
  voucher_claim_id UUID NOT NULL REFERENCES public.voucher_claims(id) ON DELETE RESTRICT,
  settlement_type TEXT NOT NULL CHECK (
    settlement_type IN ('cash_transfer', 'supplier_invoice_offset')
  ),
  payment_method_id UUID REFERENCES public.payment_methods(id) ON DELETE RESTRICT,
  bank_id UUID REFERENCES public.banks(id) ON DELETE RESTRICT,
  supplier_invoice_id UUID REFERENCES public.supplier_invoices(id) ON DELETE RESTRICT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  reference_number TEXT,
  proof_file_path TEXT,
  status TEXT NOT NULL DEFAULT 'verified' CHECK (
    status IN ('verified', 'void')
  ),
  journal_entry_id UUID,
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_vcs_method_required CHECK (
    (settlement_type = 'cash_transfer' AND payment_method_id IS NOT NULL)
    OR
    (settlement_type = 'supplier_invoice_offset' AND supplier_invoice_id IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_vcs_date ON public.voucher_claim_settlements (settlement_date DESC);
CREATE INDEX IF NOT EXISTS idx_vcs_claim ON public.voucher_claim_settlements (voucher_claim_id);
CREATE INDEX IF NOT EXISTS idx_vcs_supplier_inv ON public.voucher_claim_settlements (supplier_invoice_id);

CREATE OR REPLACE FUNCTION public.trg_auto_vcs_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.settlement_number IS NULL OR TRIM(NEW.settlement_number) = '' THEN
    NEW.settlement_number := public.generate_document_number('VCS', NEW.settlement_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vcs_before_insert ON public.voucher_claim_settlements;
CREATE TRIGGER trg_vcs_before_insert
  BEFORE INSERT ON public.voucher_claim_settlements
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_vcs_number();

DROP TRIGGER IF EXISTS trg_vcs_updated_at ON public.voucher_claim_settlements;
CREATE TRIGGER trg_vcs_updated_at
  BEFORE UPDATE ON public.voucher_claim_settlements
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 6. Mesin Sinkronisasi Saldo Klaim Voucher & Potong Utang Faktur Supplier
CREATE OR REPLACE FUNCTION public.trg_sync_voucher_claim_settlement()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claim_id UUID;
  v_claim_amount NUMERIC(18,2);
  v_claim_supplier_id UUID;
  v_claim_status TEXT;
  v_total_settled NUMERIC(18,2);
  v_new_claim_status TEXT;
  v_supp_inv_id UUID;
  v_supp_inv_supplier_id UUID;
  v_supp_inv_max_offset NUMERIC(18,2);
  v_total_inv_offset NUMERIC(18,2);
BEGIN
  v_claim_id := COALESCE(NEW.voucher_claim_id, OLD.voucher_claim_id);

  SELECT claim_amount, supplier_id, status
  INTO v_claim_amount, v_claim_supplier_id, v_claim_status
  FROM public.voucher_claims
  WHERE id = v_claim_id
  FOR UPDATE;

  IF TG_OP IN ('INSERT', 'UPDATE') AND NEW.status = 'verified' THEN
    IF v_claim_status IN ('rejected', 'void') THEN
      RAISE EXCEPTION 'Klaim voucher yang ditolak atau dibatalkan tidak dapat diselesaikan.';
    END IF;

    IF NEW.settlement_type = 'supplier_invoice_offset' THEN
      SELECT supplier_id, GREATEST(0, grand_total - paid_amount)
      INTO v_supp_inv_supplier_id, v_supp_inv_max_offset
      FROM public.supplier_invoices
      WHERE id = NEW.supplier_invoice_id
      FOR UPDATE;

      IF v_supp_inv_supplier_id IS DISTINCT FROM v_claim_supplier_id THEN
        RAISE EXCEPTION 'Faktur supplier harus berasal dari principal atau supplier yang sama dengan klaim voucher.';
      END IF;

      SELECT COALESCE(SUM(amount), 0)
      INTO v_total_inv_offset
      FROM public.voucher_claim_settlements
      WHERE supplier_invoice_id = NEW.supplier_invoice_id
        AND settlement_type = 'supplier_invoice_offset'
        AND status = 'verified';

      IF v_total_inv_offset > v_supp_inv_max_offset THEN
        RAISE EXCEPTION 'Total potongan klaim voucher (%) melebihi sisa utang faktur supplier (%).', v_total_inv_offset, v_supp_inv_max_offset;
      END IF;
    END IF;
  END IF;

  SELECT COALESCE(SUM(amount), 0)
  INTO v_total_settled
  FROM public.voucher_claim_settlements
  WHERE voucher_claim_id = v_claim_id
    AND status = 'verified';

  IF v_total_settled > v_claim_amount THEN
    RAISE EXCEPTION 'Total penyelesaian (%) melebihi nilai klaim voucher (%).', v_total_settled, v_claim_amount;
  END IF;

  IF v_claim_status NOT IN ('rejected', 'void') THEN
    IF v_total_settled >= v_claim_amount THEN
      v_new_claim_status := 'settled';
    ELSIF v_total_settled > 0 THEN
      v_new_claim_status := 'partial';
    ELSE
      v_new_claim_status := 'open';
    END IF;

    UPDATE public.voucher_claims
    SET
      settled_amount = v_total_settled,
      status = v_new_claim_status
    WHERE id = v_claim_id;
  END IF;

  -- Perbarui nilai potongan voucher pada faktur supplier terkait jika ada
  FOR v_supp_inv_id IN
    SELECT DISTINCT x.inv_id
    FROM (
      SELECT NEW.supplier_invoice_id AS inv_id
      UNION
      SELECT OLD.supplier_invoice_id AS inv_id
    ) x
    WHERE x.inv_id IS NOT NULL
  LOOP
    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_inv_offset
    FROM public.voucher_claim_settlements
    WHERE supplier_invoice_id = v_supp_inv_id
      AND settlement_type = 'supplier_invoice_offset'
      AND status = 'verified';

    UPDATE public.supplier_invoices
    SET voucher_offset_amount = v_total_inv_offset
    WHERE id = v_supp_inv_id;

    PERFORM public.refresh_supplier_invoice_totals(v_supp_inv_id);
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_vcs_sync ON public.voucher_claim_settlements;
CREATE TRIGGER trg_vcs_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.voucher_claim_settlements
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_voucher_claim_settlement();
