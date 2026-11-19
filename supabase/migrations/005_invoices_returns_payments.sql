-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 005
-- Faktur Penjualan, Retur, Nota Kredit, Pembayaran Pelanggan & Alokasi
-- ============================================================================

-- 1. Tabel Faktur Penjualan (1 Surat Jalan = Maksimal 1 Faktur)
CREATE TABLE IF NOT EXISTS public.sales_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number TEXT NOT NULL UNIQUE,
  invoice_date DATE NOT NULL DEFAULT public.jakarta_today(),
  due_date DATE NOT NULL DEFAULT public.jakarta_today(),
  sales_order_id UUID NOT NULL REFERENCES public.sales_orders(id) ON DELETE RESTRICT,
  delivery_id UUID NOT NULL UNIQUE REFERENCES public.deliveries(id) ON DELETE RESTRICT,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  sales_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  payment_type TEXT NOT NULL DEFAULT 'credit' CHECK (
    payment_type IN ('cash', 'credit')
  ),
  ppn_mode_snapshot TEXT NOT NULL DEFAULT 'non_ppn' CHECK (
    ppn_mode_snapshot IN ('non_ppn', 'exclude_ppn', 'include_ppn')
  ),
  rounding_method_snapshot TEXT NOT NULL DEFAULT 'per_invoice' CHECK (
    rounding_method_snapshot IN ('per_invoice', 'per_line')
  ),
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  dpp_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  voucher_discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (voucher_discount_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  paid_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  credit_note_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit_note_amount >= 0),
  balance_due NUMERIC(18,2) GENERATED ALWAYS AS (
    GREATEST(0, grand_total - paid_amount - credit_note_amount)
  ) STORED,
  overpaid_credit_balance NUMERIC(18,2) GENERATED ALWAYS AS (
    GREATEST(0, (paid_amount + credit_note_amount) - grand_total)
  ) STORED,
  status TEXT NOT NULL DEFAULT 'issued' CHECK (
    status IN ('draft', 'issued', 'partial', 'paid', 'void')
  ),
  journal_entry_id UUID,
  notes TEXT,
  issued_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  issued_at TIMESTAMPTZ DEFAULT now(),
  void_reason TEXT,
  voided_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  voided_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_invoices_date ON public.sales_invoices (invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_invoices_due_date ON public.sales_invoices (due_date);
CREATE INDEX IF NOT EXISTS idx_sales_invoices_customer ON public.sales_invoices (customer_id);
CREATE INDEX IF NOT EXISTS idx_sales_invoices_sales_user ON public.sales_invoices (sales_user_id);
CREATE INDEX IF NOT EXISTS idx_sales_invoices_status ON public.sales_invoices (status);

CREATE OR REPLACE FUNCTION public.trg_auto_invoice_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.invoice_number IS NULL OR TRIM(NEW.invoice_number) = '' THEN
    NEW.invoice_number := public.generate_document_number('INV', NEW.invoice_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_invoices_before_insert ON public.sales_invoices;
CREATE TRIGGER trg_sales_invoices_before_insert
  BEFORE INSERT ON public.sales_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_invoice_number();

CREATE OR REPLACE FUNCTION public.trg_guard_sales_invoice_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Atribusi Sales pembuat SO awal tidak boleh diubah pada faktur
  IF OLD.sales_user_id IS DISTINCT FROM NEW.sales_user_id THEN
    IF public.get_my_role() IS DISTINCT FROM 'owner'
       OR current_setting('app.allow_sales_reattribution', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'Atribusi Sales pada faktur penjualan tidak dapat diubah.';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_invoices_before_update ON public.sales_invoices;
CREATE TRIGGER trg_sales_invoices_before_update
  BEFORE UPDATE ON public.sales_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_sales_invoice_update();

-- 2. Tabel Rincian Faktur Penjualan (Berdasarkan Kuantitas Diterima Pelanggan)
CREATE TABLE IF NOT EXISTS public.sales_invoice_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id) ON DELETE CASCADE,
  delivery_item_id UUID NOT NULL UNIQUE REFERENCES public.delivery_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_billed NUMERIC(18,4) NOT NULL CHECK (qty_billed > 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_code_id UUID REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  tax_rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0,
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000,
  dpp_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_amount >= 0),
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (line_total >= 0),
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  cogs_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (cogs_total >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_invoice_items_inv ON public.sales_invoice_items (sales_invoice_id);

-- 3. Tabel Retur Penjualan
CREATE TABLE IF NOT EXISTS public.sales_returns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  return_number TEXT NOT NULL UNIQUE,
  return_date DATE NOT NULL DEFAULT public.jakarta_today(),
  sales_invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  sales_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'completed' CHECK (
    status IN ('draft', 'completed', 'void')
  ),
  reason TEXT NOT NULL,
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  dpp_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  journal_entry_id UUID,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_returns_date ON public.sales_returns (return_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_returns_invoice ON public.sales_returns (sales_invoice_id);
CREATE INDEX IF NOT EXISTS idx_sales_returns_sales_user ON public.sales_returns (sales_user_id);

CREATE OR REPLACE FUNCTION public.trg_auto_sales_return_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.return_number IS NULL OR TRIM(NEW.return_number) = '' THEN
    NEW.return_number := public.generate_document_number('RET', NEW.return_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_returns_before_insert ON public.sales_returns;
CREATE TRIGGER trg_sales_returns_before_insert
  BEFORE INSERT ON public.sales_returns
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_sales_return_number();

DROP TRIGGER IF EXISTS trg_sales_returns_updated_at ON public.sales_returns;
CREATE TRIGGER trg_sales_returns_updated_at
  BEFORE UPDATE ON public.sales_returns
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 4. Tabel Rincian Retur Penjualan (Memisahkan Barang Layak Jual vs Barang Rusak)
CREATE TABLE IF NOT EXISTS public.sales_return_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_return_id UUID NOT NULL REFERENCES public.sales_returns(id) ON DELETE CASCADE,
  sales_invoice_item_id UUID NOT NULL REFERENCES public.sales_invoice_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_returned NUMERIC(18,4) NOT NULL CHECK (qty_returned > 0),
  item_condition TEXT NOT NULL CHECK (
    item_condition IN ('good', 'damaged')
  ),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  tax_rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0,
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000,
  dpp_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_amount >= 0),
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (line_total >= 0),
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_return_items_ret ON public.sales_return_items (sales_return_id);

-- 5. Tabel Nota Kredit (Pengurang Piutang & Omzet Bersih Sales)
CREATE TABLE IF NOT EXISTS public.credit_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  credit_note_number TEXT NOT NULL UNIQUE,
  credit_note_date DATE NOT NULL DEFAULT public.jakarta_today(),
  sales_return_id UUID UNIQUE REFERENCES public.sales_returns(id) ON DELETE RESTRICT,
  sales_invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  sales_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'applied' CHECK (
    status IN ('applied', 'void')
  ),
  reason TEXT,
  journal_entry_id UUID,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_credit_notes_date ON public.credit_notes (credit_note_date DESC);
CREATE INDEX IF NOT EXISTS idx_credit_notes_invoice ON public.credit_notes (sales_invoice_id);
CREATE INDEX IF NOT EXISTS idx_credit_notes_sales_user ON public.credit_notes (sales_user_id);

CREATE OR REPLACE FUNCTION public.trg_auto_credit_note_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.credit_note_number IS NULL OR TRIM(NEW.credit_note_number) = '' THEN
    NEW.credit_note_number := public.generate_document_number('CN', NEW.credit_note_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_credit_notes_before_insert ON public.credit_notes;
CREATE TRIGGER trg_credit_notes_before_insert
  BEFORE INSERT ON public.credit_notes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_credit_note_number();

DROP TRIGGER IF EXISTS trg_credit_notes_updated_at ON public.credit_notes;
CREATE TRIGGER trg_credit_notes_updated_at
  BEFORE UPDATE ON public.credit_notes
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 6. Tabel Pembayaran Pelanggan
CREATE TABLE IF NOT EXISTS public.customer_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_number TEXT NOT NULL UNIQUE,
  payment_date DATE NOT NULL DEFAULT public.jakarta_today(),
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  payment_method_id UUID NOT NULL REFERENCES public.payment_methods(id) ON DELETE RESTRICT,
  bank_id UUID REFERENCES public.banks(id) ON DELETE RESTRICT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  allocated_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (allocated_amount >= 0),
  unallocated_amount NUMERIC(18,2) GENERATED ALWAYS AS (
    amount - allocated_amount
  ) STORED,
  reference_number TEXT,
  proof_file_path TEXT,
  verification_status TEXT NOT NULL DEFAULT 'pending' CHECK (
    verification_status IN ('pending', 'verified', 'rejected')
  ),
  rejection_reason TEXT,
  journal_entry_id UUID,
  recorded_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_payment_allocation_limit CHECK (allocated_amount <= amount),
  CONSTRAINT chk_payment_self_verify_forbidden CHECK (
    verified_by IS NULL OR verified_by <> recorded_by
  )
);

CREATE INDEX IF NOT EXISTS idx_customer_payments_date ON public.customer_payments (payment_date DESC);
CREATE INDEX IF NOT EXISTS idx_customer_payments_customer ON public.customer_payments (customer_id);
CREATE INDEX IF NOT EXISTS idx_customer_payments_status ON public.customer_payments (verification_status);

CREATE OR REPLACE FUNCTION public.trg_guard_customer_payment_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.payment_number IS NULL OR TRIM(NEW.payment_number) = '' THEN
    NEW.payment_number := public.generate_document_number('PAY', NEW.payment_date);
  END IF;

  IF auth.uid() IS NOT NULL THEN
    NEW.recorded_by := auth.uid();
  END IF;

  -- Pembayaran baru selalu mulai dari status menunggu verifikasi
  NEW.verification_status := 'pending';
  NEW.verified_by := NULL;
  NEW.verified_at := NULL;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_payments_before_insert ON public.customer_payments;
CREATE TRIGGER trg_customer_payments_before_insert
  BEFORE INSERT ON public.customer_payments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_customer_payment_insert();

CREATE OR REPLACE FUNCTION public.trg_guard_customer_payment_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_role TEXT;
BEGIN
  IF OLD.recorded_by IS DISTINCT FROM NEW.recorded_by THEN
    RAISE EXCEPTION 'Pembuat catatan pembayaran tidak dapat diubah.';
  END IF;

  IF OLD.verification_status IS DISTINCT FROM NEW.verification_status THEN
    v_role := public.get_my_role();
    IF v_role NOT IN ('finance_admin', 'owner') THEN
      RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat memverifikasi pembayaran.';
    END IF;

    IF NEW.verification_status IN ('verified', 'rejected') THEN
      NEW.verified_by := COALESCE(auth.uid(), NEW.verified_by);
      NEW.verified_at := now();

      IF NEW.verified_by = OLD.recorded_by THEN
        RAISE EXCEPTION 'Pembuat pembayaran tidak boleh memverifikasi pembayarannya sendiri.';
      END IF;
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_payments_before_update ON public.customer_payments;
CREATE TRIGGER trg_customer_payments_before_update
  BEFORE UPDATE ON public.customer_payments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_customer_payment_update();

-- 7. Tabel Alokasi Pembayaran ke Faktur Penjualan
CREATE TABLE IF NOT EXISTS public.customer_payment_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_payment_id UUID NOT NULL REFERENCES public.customer_payments(id) ON DELETE CASCADE,
  sales_invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  allocated_amount NUMERIC(18,2) NOT NULL CHECK (allocated_amount > 0),
  allocated_date DATE NOT NULL DEFAULT public.jakarta_today(),
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_cust_pay_alloc_payment ON public.customer_payment_allocations (customer_payment_id);
CREATE INDEX IF NOT EXISTS idx_cust_pay_alloc_invoice ON public.customer_payment_allocations (sales_invoice_id);

-- 8. Tabel Pengembalian Dana (Refund) Terpisah untuk Kelebihan Kredit Retur
CREATE TABLE IF NOT EXISTS public.customer_refunds (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  refund_number TEXT NOT NULL UNIQUE,
  refund_date DATE NOT NULL DEFAULT public.jakarta_today(),
  sales_invoice_id UUID NOT NULL REFERENCES public.sales_invoices(id) ON DELETE RESTRICT,
  credit_note_id UUID REFERENCES public.credit_notes(id) ON DELETE RESTRICT,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  payment_method_id UUID NOT NULL REFERENCES public.payment_methods(id) ON DELETE RESTRICT,
  bank_id UUID REFERENCES public.banks(id) ON DELETE RESTRICT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  reference_number TEXT,
  proof_file_path TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'verified', 'rejected')
  ),
  journal_entry_id UUID,
  recorded_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_refund_self_verify_forbidden CHECK (
    verified_by IS NULL OR verified_by <> recorded_by
  )
);

CREATE INDEX IF NOT EXISTS idx_customer_refunds_date ON public.customer_refunds (refund_date DESC);
CREATE INDEX IF NOT EXISTS idx_customer_refunds_invoice ON public.customer_refunds (sales_invoice_id);

CREATE OR REPLACE FUNCTION public.trg_auto_refund_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_overpaid NUMERIC(18,2);
  v_existing_refunds NUMERIC(18,2);
BEGIN
  IF NEW.refund_number IS NULL OR TRIM(NEW.refund_number) = '' THEN
    NEW.refund_number := public.generate_document_number('RFD', NEW.refund_date);
  END IF;

  IF auth.uid() IS NOT NULL THEN
    NEW.recorded_by := auth.uid();
  END IF;

  -- Validasi agar refund tidak melebihi saldo kelebihan kredit faktur
  SELECT overpaid_credit_balance INTO v_overpaid
  FROM public.sales_invoices
  WHERE id = NEW.sales_invoice_id;

  SELECT COALESCE(SUM(amount), 0) INTO v_existing_refunds
  FROM public.customer_refunds
  WHERE sales_invoice_id = NEW.sales_invoice_id
    AND status IN ('pending', 'verified');

  IF NEW.amount > (COALESCE(v_overpaid, 0) - v_existing_refunds) THEN
    RAISE EXCEPTION 'Nominal refund melebihi saldo kelebihan kredit yang berhak dikembalikan.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_refunds_before_insert ON public.customer_refunds;
CREATE TRIGGER trg_customer_refunds_before_insert
  BEFORE INSERT ON public.customer_refunds
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_refund_number();

DROP TRIGGER IF EXISTS trg_customer_refunds_updated_at ON public.customer_refunds;
CREATE TRIGGER trg_customer_refunds_updated_at
  BEFORE UPDATE ON public.customer_refunds
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 9. Mesin Sinkronisasi Saldo Faktur & Alokasi Pembayaran Otomatis
CREATE OR REPLACE FUNCTION public.refresh_sales_invoice_totals(p_invoice_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_verified_paid NUMERIC(18,2);
  v_credit_total NUMERIC(18,2);
  v_grand_total NUMERIC(18,2);
  v_current_status TEXT;
  v_new_status TEXT;
BEGIN
  SELECT grand_total, status
  INTO v_grand_total, v_current_status
  FROM public.sales_invoices
  WHERE id = p_invoice_id;

  IF v_grand_total IS NULL OR v_current_status IN ('draft', 'void') THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(a.allocated_amount), 0)
  INTO v_verified_paid
  FROM public.customer_payment_allocations a
  JOIN public.customer_payments p ON p.id = a.customer_payment_id
  WHERE a.sales_invoice_id = p_invoice_id
    AND p.verification_status = 'verified';

  SELECT COALESCE(SUM(cn.amount), 0)
  INTO v_credit_total
  FROM public.credit_notes cn
  WHERE cn.sales_invoice_id = p_invoice_id
    AND cn.status = 'applied';

  IF (v_verified_paid + v_credit_total) >= v_grand_total THEN
    v_new_status := 'paid';
  ELSIF (v_verified_paid + v_credit_total) > 0 THEN
    v_new_status := 'partial';
  ELSE
    v_new_status := 'issued';
  END IF;

  UPDATE public.sales_invoices
  SET
    paid_amount = v_verified_paid,
    credit_note_amount = v_credit_total,
    status = v_new_status
  WHERE id = p_invoice_id;
END;
$$;

-- Trigger validasi alokasi agar tidak melebihi nilai pembayaran maupun sisa piutang faktur
CREATE OR REPLACE FUNCTION public.trg_sync_customer_payment_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_payment_id UUID;
  v_invoice_id UUID;
  v_pay_amount NUMERIC(18,2);
  v_pay_status TEXT;
  v_total_pay_alloc NUMERIC(18,2);
  v_inv_net_due NUMERIC(18,2);
  v_total_inv_alloc NUMERIC(18,2);
BEGIN
  v_payment_id := COALESCE(NEW.customer_payment_id, OLD.customer_payment_id);
  v_invoice_id := COALESCE(NEW.sales_invoice_id, OLD.sales_invoice_id);

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    SELECT amount, verification_status
    INTO v_pay_amount, v_pay_status
    FROM public.customer_payments
    WHERE id = v_payment_id
    FOR UPDATE;

    IF v_pay_status = 'rejected' THEN
      RAISE EXCEPTION 'Pembayaran yang sudah ditolak tidak dapat dialokasikan.';
    END IF;

    SELECT COALESCE(SUM(allocated_amount), 0)
    INTO v_total_pay_alloc
    FROM public.customer_payment_allocations
    WHERE customer_payment_id = v_payment_id;

    IF v_total_pay_alloc > v_pay_amount THEN
      RAISE EXCEPTION 'Total alokasi (%) melebihi nominal pembayaran (%).', v_total_pay_alloc, v_pay_amount;
    END IF;

    SELECT GREATEST(0, grand_total - credit_note_amount)
    INTO v_inv_net_due
    FROM public.sales_invoices
    WHERE id = v_invoice_id
    FOR UPDATE;

    SELECT COALESCE(SUM(a.allocated_amount), 0)
    INTO v_total_inv_alloc
    FROM public.customer_payment_allocations a
    JOIN public.customer_payments p ON p.id = a.customer_payment_id
    WHERE a.sales_invoice_id = v_invoice_id
      AND p.verification_status IN ('pending', 'verified');

    IF v_total_inv_alloc > v_inv_net_due THEN
      RAISE EXCEPTION 'Total alokasi (%) melebihi sisa tagihan faktur (%).', v_total_inv_alloc, v_inv_net_due;
    END IF;
  END IF;

  SELECT COALESCE(SUM(allocated_amount), 0)
  INTO v_total_pay_alloc
  FROM public.customer_payment_allocations
  WHERE customer_payment_id = v_payment_id;

  UPDATE public.customer_payments
  SET allocated_amount = v_total_pay_alloc
  WHERE id = v_payment_id;

  PERFORM public.refresh_sales_invoice_totals(v_invoice_id);

  IF TG_OP = 'UPDATE' AND OLD.sales_invoice_id IS DISTINCT FROM NEW.sales_invoice_id THEN
    PERFORM public.refresh_sales_invoice_totals(OLD.sales_invoice_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_payment_allocations_sync ON public.customer_payment_allocations;
CREATE TRIGGER trg_customer_payment_allocations_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.customer_payment_allocations
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_customer_payment_allocation();

-- Trigger saat status verifikasi pembayaran berubah -> perbarui status lunas faktur
CREATE OR REPLACE FUNCTION public.trg_on_payment_verification_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv RECORD;
BEGIN
  IF OLD.verification_status IS DISTINCT FROM NEW.verification_status THEN
    FOR v_inv IN
      SELECT DISTINCT sales_invoice_id
      FROM public.customer_payment_allocations
      WHERE customer_payment_id = NEW.id
    LOOP
      PERFORM public.refresh_sales_invoice_totals(v_inv.sales_invoice_id);
    END LOOP;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_customer_payments_after_verify ON public.customer_payments;
CREATE TRIGGER trg_customer_payments_after_verify
  AFTER UPDATE OF verification_status ON public.customer_payments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_on_payment_verification_change();

-- Trigger saat Nota Kredit dibuat/diubah -> perbarui piutang faktur asal
CREATE OR REPLACE FUNCTION public.trg_on_credit_note_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.refresh_sales_invoice_totals(COALESCE(NEW.sales_invoice_id, OLD.sales_invoice_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_credit_notes_sync_invoice ON public.credit_notes;
CREATE TRIGGER trg_credit_notes_sync_invoice
  AFTER INSERT OR UPDATE OR DELETE ON public.credit_notes
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_on_credit_note_change();
