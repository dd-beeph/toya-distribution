-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 004
-- Penjualan & Pengiriman: Sales Order, Kunci Identitas Sales, Surat Jalan
-- ============================================================================

-- 1. Tabel Sales Order
CREATE TABLE IF NOT EXISTS public.sales_orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  so_number TEXT NOT NULL UNIQUE,
  order_date DATE NOT NULL DEFAULT public.jakarta_today(),
  expected_delivery_date DATE,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  sales_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  payment_type TEXT NOT NULL DEFAULT 'credit' CHECK (
    payment_type IN ('cash', 'credit')
  ),
  payment_term_days INTEGER NOT NULL DEFAULT 0 CHECK (payment_term_days >= 0),
  ppn_mode_snapshot TEXT NOT NULL DEFAULT 'non_ppn' CHECK (
    ppn_mode_snapshot IN ('non_ppn', 'exclude_ppn', 'include_ppn')
  ),
  rounding_method_snapshot TEXT NOT NULL DEFAULT 'per_invoice' CHECK (
    rounding_method_snapshot IN ('per_invoice', 'per_line')
  ),
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN (
      'draft',
      'pending_approval',
      'approved',
      'ready_for_delivery',
      'delivered',
      'invoiced',
      'cancelled'
    )
  ),
  subtotal NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
  discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
  dpp_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_total >= 0),
  tax_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
  voucher_discount_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (voucher_discount_total >= 0),
  grand_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
  has_discount_request BOOLEAN NOT NULL DEFAULT false,
  discount_reason TEXT,
  notes TEXT,
  cancelled_reason TEXT,
  cancelled_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  cancelled_at TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sales_orders_order_date ON public.sales_orders (order_date DESC);
CREATE INDEX IF NOT EXISTS idx_sales_orders_customer ON public.sales_orders (customer_id);
CREATE INDEX IF NOT EXISTS idx_sales_orders_sales_user ON public.sales_orders (sales_user_id);
CREATE INDEX IF NOT EXISTS idx_sales_orders_status ON public.sales_orders (status);

-- Trigger pengaman pembuatan & penguncian identitas Sales pembuat SO
CREATE OR REPLACE FUNCTION public.trg_guard_sales_order_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_ppn_setting JSONB;
  v_round_setting JSONB;
BEGIN
  IF NEW.so_number IS NULL OR TRIM(NEW.so_number) = '' THEN
    NEW.so_number := public.generate_document_number('SO', NEW.order_date);
  END IF;

  -- Kunci otomatis pembuat SO berdasarkan akun yang sedang login (anti-pemalsuan)
  IF auth.uid() IS NOT NULL THEN
    NEW.created_by := auth.uid();
    IF public.get_my_role() = 'sales' OR NEW.sales_user_id IS NULL THEN
      NEW.sales_user_id := auth.uid();
    END IF;
  END IF;

  -- Simpan salinan aturan PPN & pembulatan yang berlaku saat SO dibuat
  v_ppn_setting := public.get_system_setting('ppn_sales_price_mode');
  IF COALESCE((v_ppn_setting ->> 'enabled')::boolean, false) THEN
    NEW.ppn_mode_snapshot := COALESCE(v_ppn_setting ->> 'mode', 'exclude_ppn');
  ELSE
    NEW.ppn_mode_snapshot := 'non_ppn';
  END IF;

  v_round_setting := public.get_system_setting('rupiah_rounding_rule');
  NEW.rounding_method_snapshot := COALESCE(v_round_setting ->> 'method', 'per_invoice');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_orders_before_insert ON public.sales_orders;
CREATE TRIGGER trg_sales_orders_before_insert
  BEFORE INSERT ON public.sales_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_sales_order_insert();

CREATE OR REPLACE FUNCTION public.trg_guard_sales_order_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Cegah perubahan identitas pembuat SO kecuali melalui prosedur koreksi Owner
  IF OLD.sales_user_id IS DISTINCT FROM NEW.sales_user_id THEN
    IF public.get_my_role() IS DISTINCT FROM 'owner'
       OR current_setting('app.allow_sales_reattribution', true) IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'Identitas Sales pembuat SO tidak dapat diubah setelah disimpan.';
    END IF;
  END IF;

  IF OLD.created_by IS DISTINCT FROM NEW.created_by THEN
    RAISE EXCEPTION 'Identitas pembuat dokumen tidak dapat diubah.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_orders_before_update ON public.sales_orders;
CREATE TRIGGER trg_sales_orders_before_update
  BEFORE UPDATE ON public.sales_orders
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_sales_order_update();

-- 2. Tabel Rincian Barang Sales Order
CREATE TABLE IF NOT EXISTS public.sales_order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_order_id UUID NOT NULL REFERENCES public.sales_orders(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount_percent NUMERIC(6,2) NOT NULL DEFAULT 0 CHECK (discount_percent >= 0 AND discount_percent <= 100),
  discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_code_id UUID REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  tax_rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0 CHECK (tax_rate_percent >= 0),
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000 CHECK (dpp_multiplier > 0),
  dpp_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (dpp_amount >= 0),
  tax_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
  line_total NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (line_total >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (sales_order_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_sales_order_items_so ON public.sales_order_items (sales_order_id);

-- Trigger pengaman harga jual (Kasir/Gudang dilarang ubah harga; setelah diproses hanya Owner)
CREATE OR REPLACE FUNCTION public.trg_guard_sales_order_item_price()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_so_status TEXT;
  v_so_sales_id UUID;
BEGIN
  SELECT status, sales_user_id
  INTO v_so_status, v_so_sales_id
  FROM public.sales_orders
  WHERE id = NEW.sales_order_id;

  IF OLD.unit_price IS DISTINCT FROM NEW.unit_price THEN
    IF v_so_status = 'draft' AND auth.uid() = v_so_sales_id THEN
      -- Sales masih boleh mengoreksi harga selama SO berstatus draft
      NULL;
    ELSIF public.get_my_role() = 'owner'
       AND current_setting('app.allow_owner_price_override', true) = 'true' THEN
      -- Owner mengubah harga melalui fungsi resmi dengan alasan & audit log
      NULL;
    ELSE
      RAISE EXCEPTION 'Harga jual yang sudah dicatat hanya boleh diubah oleh Owner.';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sales_order_items_before_update ON public.sales_order_items;
CREATE TRIGGER trg_sales_order_items_before_update
  BEFORE UPDATE ON public.sales_order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_sales_order_item_price();

-- 3. Tabel Persetujuan Diskon, Koreksi Harga Owner, dan Perubahan Sales
CREATE TABLE IF NOT EXISTS public.sales_order_approvals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sales_order_id UUID NOT NULL REFERENCES public.sales_orders(id) ON DELETE CASCADE,
  approval_type TEXT NOT NULL CHECK (
    approval_type IN ('discount', 'price_override', 'negative_stock', 'sales_attribution_change')
  ),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'approved', 'rejected')
  ),
  requested_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  request_reason TEXT,
  old_value JSONB,
  new_value JSONB,
  decided_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  decided_at TIMESTAMPTZ,
  decision_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_so_approvals_so ON public.sales_order_approvals (sales_order_id);
CREATE INDEX IF NOT EXISTS idx_so_approvals_status ON public.sales_order_approvals (status);

-- 4. Tabel Pengiriman / Surat Jalan (1 SO = Maksimal 1 Pengiriman)
CREATE TABLE IF NOT EXISTS public.deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_number TEXT NOT NULL UNIQUE,
  sales_order_id UUID NOT NULL UNIQUE REFERENCES public.sales_orders(id) ON DELETE RESTRICT,
  customer_id UUID NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  sales_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  delivery_date DATE NOT NULL DEFAULT public.jakarta_today(),
  driver_name TEXT,
  vehicle_number TEXT,
  status TEXT NOT NULL DEFAULT 'preparing' CHECK (
    status IN ('preparing', 'dispatched', 'delivered', 'invoiced', 'cancelled')
  ),
  dispatched_at TIMESTAMPTZ,
  dispatched_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  delivered_at TIMESTAMPTZ,
  confirmed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_deliveries_date ON public.deliveries (delivery_date DESC);
CREATE INDEX IF NOT EXISTS idx_deliveries_customer ON public.deliveries (customer_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_status ON public.deliveries (status);

CREATE OR REPLACE FUNCTION public.trg_auto_delivery_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.delivery_number IS NULL OR TRIM(NEW.delivery_number) = '' THEN
    NEW.delivery_number := public.generate_document_number('SJ', NEW.delivery_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliveries_before_insert ON public.deliveries;
CREATE TRIGGER trg_deliveries_before_insert
  BEFORE INSERT ON public.deliveries
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_delivery_number();

CREATE OR REPLACE FUNCTION public.trg_guard_delivery_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  -- Jika surat jalan sudah menjadi faktur, blokir perubahan data utama pengiriman
  IF OLD.status = 'invoiced' AND (
    OLD.delivery_date IS DISTINCT FROM NEW.delivery_date OR
    OLD.driver_name IS DISTINCT FROM NEW.driver_name OR
    OLD.warehouse_id IS DISTINCT FROM NEW.warehouse_id OR
    OLD.customer_id IS DISTINCT FROM NEW.customer_id
  ) THEN
    RAISE EXCEPTION 'Surat Jalan yang sudah diterbitkan faktur tidak dapat diubah lagi.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliveries_before_update ON public.deliveries;
CREATE TRIGGER trg_deliveries_before_update
  BEFORE UPDATE ON public.deliveries
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_delivery_update();

-- 5. Tabel Rincian Pengiriman Barang
CREATE TABLE IF NOT EXISTS public.delivery_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE CASCADE,
  sales_order_item_id UUID NOT NULL UNIQUE REFERENCES public.sales_order_items(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_ordered NUMERIC(18,4) NOT NULL CHECK (qty_ordered > 0),
  qty_dispatched NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_dispatched >= 0),
  qty_delivered NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_delivered >= 0),
  qty_damaged NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_damaged >= 0),
  qty_returned_undelivered NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (qty_returned_undelivered >= 0),
  unit_price NUMERIC(18,2) NOT NULL CHECK (unit_price >= 0),
  discount_amount NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
  tax_code_id UUID REFERENCES public.tax_codes(id) ON DELETE RESTRICT,
  tax_rate_percent NUMERIC(6,4) NOT NULL DEFAULT 0,
  dpp_multiplier NUMERIC(10,6) NOT NULL DEFAULT 1.000000,
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_delivery_qty_balance CHECK (
    qty_dispatched = 0 OR (qty_delivered + qty_damaged + qty_returned_undelivered) <= qty_dispatched
  )
);

CREATE INDEX IF NOT EXISTS idx_delivery_items_delivery ON public.delivery_items (delivery_id);

CREATE OR REPLACE FUNCTION public.trg_guard_delivery_item_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_delivery_status TEXT;
BEGIN
  SELECT status INTO v_delivery_status
  FROM public.deliveries
  WHERE id = NEW.delivery_id;

  IF v_delivery_status = 'invoiced' THEN
    RAISE EXCEPTION 'Rincian pengiriman tidak dapat diubah setelah faktur penjualan dibuat.';
  END IF;

  -- Kasir maupun siapa pun tidak boleh mengubah harga satuan di rincian pengiriman
  IF OLD.unit_price IS DISTINCT FROM NEW.unit_price THEN
    RAISE EXCEPTION 'Harga jual pada rincian pengiriman tidak dapat diubah.';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_delivery_items_before_update ON public.delivery_items;
CREATE TRIGGER trg_delivery_items_before_update
  BEFORE UPDATE ON public.delivery_items
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_guard_delivery_item_update();

-- 6. Tabel Laporan Barang Rusak Selama Pengiriman
CREATE TABLE IF NOT EXISTS public.delivery_damage_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE CASCADE,
  delivery_item_id UUID NOT NULL REFERENCES public.delivery_items(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_damaged NUMERIC(18,4) NOT NULL CHECK (qty_damaged > 0),
  reason TEXT NOT NULL,
  damaged_goods_id UUID REFERENCES public.damaged_goods(id) ON DELETE RESTRICT,
  reported_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_delivery_damage_delivery ON public.delivery_damage_reports (delivery_id);
