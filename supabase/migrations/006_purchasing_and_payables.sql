-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 006
-- Pembelian & Utang: PO, Penerimaan Barang, Faktur Supplier, Pembayaran Utang
-- ============================================================================

-- 1. Tabel Purchase Order (Pesanan Pembelian ke Supplier)
CREATE TABLE IF NOT EXISTS public.purchase_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  po_number TEXT NOT NULL UNIQUE,
  order_date DATE NOT NULL DEFAULT public.jakarta_today(),
  expected_date DATE,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  payment_type TEXT NOT NULL DEFAULT 'credit' CHECK (
    payment_type IN ('cash', 'credit')
  ),
  payment_term_days INTEGER NOT NULL DEFAULT 0 CHECK (payment_term_days >= 0),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN ('draft', 'approved', 'partially_received', 'received', 'cancelled')
  ),
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  dpp_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_date ON public.purchase_orders (order_date DESC);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier ON public.purchase_orders (supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_orders_status ON public.purchase_orders (status);

CREATE OR REPLACE FUNCTION public.trg_auto_po_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.po_number IS NULL OR TRIM(NEW.po_number) = '' THEN
    NEW.po_number := public.generate_document_number('PO', NEW.order_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_purchase_orders_before_insert ON public.purchase_orders;
CREATE TRIGGER trg_purchase_orders_before_insert
  BEFORE INSERT ON public.purchase_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_po_number();

DROP TRIGGER IF EXISTS trg_purchase_orders_updated_at ON public.purchase_orders;
CREATE TRIGGER trg_purchase_orders_updated_at
  BEFORE UPDATE ON public.purchase_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 2. Tabel Rincian Purchase Order
CREATE TABLE IF NOT EXISTS public.purchase_order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  purchase_order_id UUID NOT NULL REFERENCES public.purchase_orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_ordered NUMERIC(18,4) NOT NULL CHECK (qty_ordered > 0),
  qty_received NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_received >= 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_code_id UUID REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  tax_rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0,
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000,
  dpp_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_amount >= 0),
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (line_total >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (purchase_order_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_po_items_po ON public.purchase_order_items (purchase_order_id);

DROP TRIGGER IF EXISTS trg_po_items_updated_at ON public.purchase_order_items;
CREATE TRIGGER trg_po_items_updated_at
  BEFORE UPDATE ON public.purchase_order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 3. Tabel Penerimaan Barang Fisik di Gudang (Mendukung PO maupun Pembelian Langsung)
CREATE TABLE IF NOT EXISTS public.goods_receipts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_number TEXT NOT NULL UNIQUE,
  receipt_date DATE NOT NULL DEFAULT public.jakarta_today(),
  purchase_order_id UUID REFERENCES public.purchase_orders(id) ON DELETE RESTRICT,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  supplier_delivery_note TEXT,
  status TEXT NOT NULL DEFAULT 'received' CHECK (
    status IN ('draft', 'received', 'invoiced', 'void')
  ),
  notes TEXT,
  received_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_goods_receipts_date ON public.goods_receipts (receipt_date DESC);
CREATE INDEX IF NOT EXISTS idx_goods_receipts_po ON public.goods_receipts (purchase_order_id);
CREATE INDEX IF NOT EXISTS idx_goods_receipts_supplier ON public.goods_receipts (supplier_id);

CREATE OR REPLACE FUNCTION public.trg_auto_grn_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.receipt_number IS NULL OR TRIM(NEW.receipt_number) = '' THEN
    NEW.receipt_number := public.generate_document_number('GRN', NEW.receipt_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_goods_receipts_before_insert ON public.goods_receipts;
CREATE TRIGGER trg_goods_receipts_before_insert
  BEFORE INSERT ON public.goods_receipts
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_grn_number();

DROP TRIGGER IF EXISTS trg_goods_receipts_updated_at ON public.goods_receipts;
CREATE TRIGGER trg_goods_receipts_updated_at
  BEFORE UPDATE ON public.goods_receipts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 4. Tabel Rincian Penerimaan Barang (Dasar Penambahan Stok Gudang)
CREATE TABLE IF NOT EXISTS public.goods_receipt_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  goods_receipt_id UUID NOT NULL REFERENCES public.goods_receipts(id) ON DELETE CASCADE,
  purchase_order_item_id UUID REFERENCES public.purchase_order_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_received NUMERIC(18,4) NOT NULL CHECK (qty_received > 0),
  estimated_unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (estimated_unit_cost >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_grn_items_grn ON public.goods_receipt_items (goods_receipt_id);

-- 5. Tabel Faktur Pembelian Supplier (Terpisah dari Penerimaan Barang + Potongan Nota)
CREATE TABLE IF NOT EXISTS public.supplier_invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number TEXT NOT NULL UNIQUE,
  supplier_invoice_number TEXT NOT NULL,
  invoice_date DATE NOT NULL DEFAULT public.jakarta_today(),
  due_date DATE NOT NULL DEFAULT public.jakarta_today(),
  purchase_order_id UUID REFERENCES public.purchase_orders(id) ON DELETE RESTRICT,
  goods_receipt_id UUID REFERENCES public.goods_receipts(id) ON DELETE RESTRICT,
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  payment_type TEXT NOT NULL DEFAULT 'credit' CHECK (
    payment_type IN ('cash', 'credit')
  ),
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  line_discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (line_discount_total >= 0),
  header_discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (header_discount_amount >= 0),
  discount_notes TEXT,
  dpp_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  paid_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (paid_amount >= 0),
  voucher_offset_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (voucher_offset_amount >= 0),
  balance_due NUMERIC(18,2) GENERATED ALWAYS AS (
    GREATEST(0, grand_total - paid_amount - voucher_offset_amount)
  ) STORED,
  status TEXT NOT NULL DEFAULT 'issued' CHECK (
    status IN ('draft', 'issued', 'partial', 'paid', 'void')
  ),
  journal_entry_id UUID,
  proof_file_path TEXT,
  notes TEXT,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (supplier_id, supplier_invoice_number)
);

CREATE INDEX IF NOT EXISTS idx_supplier_invoices_date ON public.supplier_invoices (invoice_date DESC);
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_due_date ON public.supplier_invoices (due_date);
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_supplier ON public.supplier_invoices (supplier_id);
CREATE INDEX IF NOT EXISTS idx_supplier_invoices_status ON public.supplier_invoices (status);

CREATE OR REPLACE FUNCTION public.trg_auto_supplier_invoice_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.invoice_number IS NULL OR TRIM(NEW.invoice_number) = '' THEN
    NEW.invoice_number := public.generate_document_number('PINV', NEW.invoice_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_invoices_before_insert ON public.supplier_invoices;
CREATE TRIGGER trg_supplier_invoices_before_insert
  BEFORE INSERT ON public.supplier_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_supplier_invoice_number();

DROP TRIGGER IF EXISTS trg_supplier_invoices_updated_at ON public.supplier_invoices;
CREATE TRIGGER trg_supplier_invoices_updated_at
  BEFORE UPDATE ON public.supplier_invoices
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 6. Tabel Rincian Faktur Pembelian (Menyimpan Potongan Langsung & Harga Pokok Bersih HPP)
CREATE TABLE IF NOT EXISTS public.supplier_invoice_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_invoice_id UUID NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE CASCADE,
  goods_receipt_item_id UUID REFERENCES public.goods_receipt_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  gross_unit_price NUMERIC(18,2) NOT NULL CHECK (gross_unit_price >= 0),
  discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  net_unit_cost NUMERIC(18,4) NOT NULL CHECK (net_unit_cost >= 0),
  tax_code_id UUID REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  tax_rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0,
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000,
  dpp_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_amount >= 0),
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (line_total >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_supplier_invoice_items_inv ON public.supplier_invoice_items (supplier_invoice_id);

-- 7. Tabel Pembayaran Utang ke Supplier
CREATE TABLE IF NOT EXISTS public.supplier_payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_number TEXT NOT NULL UNIQUE,
  payment_date DATE NOT NULL DEFAULT public.jakarta_today(),
  supplier_id UUID NOT NULL REFERENCES public.suppliers(id) ON DELETE RESTRICT,
  payment_method_id UUID NOT NULL REFERENCES public.payment_methods(id) ON DELETE RESTRICT,
  bank_id UUID REFERENCES public.banks(id) ON DELETE RESTRICT,
  amount NUMERIC(18,2) NOT NULL CHECK (amount > 0),
  allocated_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (allocated_amount >= 0),
  unallocated_amount NUMERIC(18,2) GENERATED ALWAYS AS (
    amount - allocated_amount
  ) STORED,
  reference_number TEXT,
  proof_file_path TEXT,
  status TEXT NOT NULL DEFAULT 'posted' CHECK (
    status IN ('draft', 'posted', 'void')
  ),
  journal_entry_id UUID,
  paid_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_supplier_payment_alloc_limit CHECK (allocated_amount <= amount)
);

CREATE INDEX IF NOT EXISTS idx_supplier_payments_date ON public.supplier_payments (payment_date DESC);
CREATE INDEX IF NOT EXISTS idx_supplier_payments_supplier ON public.supplier_payments (supplier_id);

CREATE OR REPLACE FUNCTION public.trg_auto_supplier_payment_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.payment_number IS NULL OR TRIM(NEW.payment_number) = '' THEN
    NEW.payment_number := public.generate_document_number('SPAY', NEW.payment_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_payments_before_insert ON public.supplier_payments;
CREATE TRIGGER trg_supplier_payments_before_insert
  BEFORE INSERT ON public.supplier_payments
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_supplier_payment_number();

DROP TRIGGER IF EXISTS trg_supplier_payments_updated_at ON public.supplier_payments;
CREATE TRIGGER trg_supplier_payments_updated_at
  BEFORE UPDATE ON public.supplier_payments
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- 8. Tabel Alokasi Pembayaran ke Faktur Supplier
CREATE TABLE IF NOT EXISTS public.supplier_payment_allocations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  supplier_payment_id UUID NOT NULL REFERENCES public.supplier_payments(id) ON DELETE CASCADE,
  supplier_invoice_id UUID NOT NULL REFERENCES public.supplier_invoices(id) ON DELETE RESTRICT,
  allocated_amount NUMERIC(18,2) NOT NULL CHECK (allocated_amount > 0),
  allocated_date DATE NOT NULL DEFAULT public.jakarta_today(),
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_supp_pay_alloc_payment ON public.supplier_payment_allocations (supplier_payment_id);
CREATE INDEX IF NOT EXISTS idx_supp_pay_alloc_invoice ON public.supplier_payment_allocations (supplier_invoice_id);

-- 9. Mesin Sinkronisasi Saldo Utang Faktur Supplier
CREATE OR REPLACE FUNCTION public.refresh_supplier_invoice_totals(p_invoice_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_paid_total NUMERIC(18,2);
  v_offset_total NUMERIC(18,2);
  v_grand_total NUMERIC(18,2);
  v_current_status TEXT;
  v_new_status TEXT;
BEGIN
  SELECT grand_total, voucher_offset_amount, status
  INTO v_grand_total, v_offset_total, v_current_status
  FROM public.supplier_invoices
  WHERE id = p_invoice_id;

  IF v_grand_total IS NULL OR v_current_status IN ('draft', 'void') THEN
    RETURN;
  END IF;

  SELECT COALESCE(SUM(a.allocated_amount), 0)
  INTO v_paid_total
  FROM public.supplier_payment_allocations a
  JOIN public.supplier_payments p ON p.id = a.supplier_payment_id
  WHERE a.supplier_invoice_id = p_invoice_id
    AND p.status = 'posted';

  IF (v_paid_total + v_offset_total) >= v_grand_total THEN
    v_new_status := 'paid';
  ELSIF (v_paid_total + v_offset_total) > 0 THEN
    v_new_status := 'partial';
  ELSE
    v_new_status := 'issued';
  END IF;

  UPDATE public.supplier_invoices
  SET
    paid_amount = v_paid_total,
    status = v_new_status
  WHERE id = p_invoice_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.trg_sync_supplier_payment_allocation()
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
  v_payment_id := COALESCE(NEW.supplier_payment_id, OLD.supplier_payment_id);
  v_invoice_id := COALESCE(NEW.supplier_invoice_id, OLD.supplier_invoice_id);

  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    SELECT amount, status
    INTO v_pay_amount, v_pay_status
    FROM public.supplier_payments
    WHERE id = v_payment_id
    FOR UPDATE;

    IF v_pay_status = 'void' THEN
      RAISE EXCEPTION 'Pembayaran supplier yang sudah dibatalkan tidak dapat dialokasikan.';
    END IF;

    SELECT COALESCE(SUM(allocated_amount), 0)
    INTO v_total_pay_alloc
    FROM public.supplier_payment_allocations
    WHERE supplier_payment_id = v_payment_id;

    IF v_total_pay_alloc > v_pay_amount THEN
      RAISE EXCEPTION 'Total alokasi (%) melebihi nominal pembayaran supplier (%).', v_total_pay_alloc, v_pay_amount;
    END IF;

    SELECT GREATEST(0, grand_total - voucher_offset_amount)
    INTO v_inv_net_due
    FROM public.supplier_invoices
    WHERE id = v_invoice_id
    FOR UPDATE;

    SELECT COALESCE(SUM(a.allocated_amount), 0)
    INTO v_total_inv_alloc
    FROM public.supplier_payment_allocations a
    JOIN public.supplier_payments p ON p.id = a.supplier_payment_id
    WHERE a.supplier_invoice_id = v_invoice_id
      AND p.status IN ('draft', 'posted');

    IF v_total_inv_alloc > v_inv_net_due THEN
      RAISE EXCEPTION 'Total alokasi (%) melebihi sisa utang faktur supplier (%).', v_total_inv_alloc, v_inv_net_due;
    END IF;
  END IF;

  SELECT COALESCE(SUM(allocated_amount), 0)
  INTO v_total_pay_alloc
  FROM public.supplier_payment_allocations
  WHERE supplier_payment_id = v_payment_id;

  UPDATE public.supplier_payments
  SET allocated_amount = v_total_pay_alloc
  WHERE id = v_payment_id;

  PERFORM public.refresh_supplier_invoice_totals(v_invoice_id);

  IF TG_OP = 'UPDATE' AND OLD.supplier_invoice_id IS DISTINCT FROM NEW.supplier_invoice_id THEN
    PERFORM public.refresh_supplier_invoice_totals(OLD.supplier_invoice_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_supplier_payment_allocations_sync ON public.supplier_payment_allocations;
CREATE TRIGGER trg_supplier_payment_allocations_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.supplier_payment_allocations
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_sync_supplier_payment_allocation();
