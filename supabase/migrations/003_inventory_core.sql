-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 003
-- Sistem Persediaan: Stock Movement Ledger, Saldo Rata-Rata, Transfer, Rusak
-- ============================================================================

-- 1. Tabel Saldo Stok Terkini per Gudang dan Produk
-- Saldo hanya boleh berubah melalui fungsi resmi mutasi stok
CREATE TABLE IF NOT EXISTS public.stock_balances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  qty_on_hand NUMERIC(18,4) NOT NULL DEFAULT 0,
  avg_unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (avg_unit_cost >= 0),
  total_value NUMERIC(18,2) NOT NULL DEFAULT 0,
  last_movement_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (warehouse_id, product_id)
);

CREATE INDEX IF NOT EXISTS idx_stock_balances_warehouse ON public.stock_balances (warehouse_id);
CREATE INDEX IF NOT EXISTS idx_stock_balances_product ON public.stock_balances (product_id);

-- Trigger pengaman agar saldo stok tidak dapat diubah secara langsung
CREATE OR REPLACE FUNCTION public.guard_stock_balances_direct_write()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('app.allow_stock_balance_write', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Saldo stok tidak boleh diubah langsung. Gunakan transaksi mutasi stok resmi.';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_stock_balances ON public.stock_balances;
CREATE TRIGGER trg_guard_stock_balances
  BEFORE INSERT OR UPDATE OR DELETE ON public.stock_balances
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_stock_balances_direct_write();

-- 2. Tabel Buku Besar Pergerakan Stok (Sumber Utama Kebenaran Stok & Kartu Stok)
CREATE TABLE IF NOT EXISTS public.stock_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  movement_date DATE NOT NULL DEFAULT public.jakarta_today(),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  movement_type TEXT NOT NULL CHECK (
    movement_type IN (
      'OPENING_BALANCE',
      'PURCHASE_IN',
      'SALES_OUT',
      'SALES_RETURN_IN',
      'PURCHASE_RETURN_OUT',
      'TRANSFER_OUT',
      'TRANSFER_IN',
      'ADJUSTMENT_IN',
      'ADJUSTMENT_OUT',
      'DAMAGE_OUT'
    )
  ),
  source_type TEXT NOT NULL,
  source_id UUID NOT NULL,
  source_line_id UUID,
  source_number TEXT NOT NULL,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty_input NUMERIC(18,4) NOT NULL CHECK (qty_input > 0),
  direction SMALLINT NOT NULL CHECK (direction IN (1, -1)),
  qty_base NUMERIC(18,4) NOT NULL CHECK (qty_base > 0),
  signed_qty_base NUMERIC(18,4) GENERATED ALWAYS AS (qty_base * direction) STORED,
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  total_cost NUMERIC(18,2) NOT NULL DEFAULT 0,
  balance_qty_after NUMERIC(18,4) NOT NULL,
  balance_avg_cost_after NUMERIC(18,4) NOT NULL,
  balance_value_after NUMERIC(18,2) NOT NULL,
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stock_movements_date ON public.stock_movements (movement_date DESC);
CREATE INDEX IF NOT EXISTS idx_stock_movements_wh_prod_date ON public.stock_movements (warehouse_id, product_id, movement_date, created_at);
CREATE INDEX IF NOT EXISTS idx_stock_movements_source ON public.stock_movements (source_type, source_id);

-- Pengunci anti-duplikasi pergerakan stok untuk baris dokumen yang sama
CREATE UNIQUE INDEX IF NOT EXISTS uq_stock_movements_idempotency
  ON public.stock_movements (
    source_type,
    source_id,
    COALESCE(source_line_id, '00000000-0000-0000-0000-000000000000'::uuid),
    warehouse_id,
    movement_type
  );

-- 3. Mesin Pencatat Mutasi Stok & Moving Weighted Average (Atomik + Kunci Baris)
CREATE OR REPLACE FUNCTION public.record_stock_movement(
  p_movement_date DATE,
  p_warehouse_id UUID,
  p_product_id UUID,
  p_movement_type TEXT,
  p_source_type TEXT,
  p_source_id UUID,
  p_source_number TEXT,
  p_unit_id UUID,
  p_qty NUMERIC,
  p_direction SMALLINT,
  p_unit_cost NUMERIC DEFAULT NULL,
  p_source_line_id UUID DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_allow_negative_override BOOLEAN DEFAULT false,
  p_actor_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_qty_base NUMERIC(18,4);
  v_old_qty NUMERIC(18,4);
  v_old_avg_cost NUMERIC(18,4);
  v_old_value NUMERIC(18,2);
  v_new_qty NUMERIC(18,4);
  v_new_avg_cost NUMERIC(18,4);
  v_new_value NUMERIC(18,2);
  v_tx_unit_cost NUMERIC(18,4);
  v_tx_total_cost NUMERIC(18,2);
  v_neg_setting JSONB;
  v_allow_neg BOOLEAN;
  v_movement_id UUID;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN
    RAISE EXCEPTION 'Kuantitas mutasi stok harus lebih besar dari nol';
  END IF;

  IF p_direction NOT IN (1, -1) THEN
    RAISE EXCEPTION 'Arah mutasi stok tidak valid';
  END IF;

  -- Konversi ke satuan utama produk (otomatis 1:1 untuk Karton/Galon)
  v_qty_base := public.convert_to_base_qty(p_product_id, p_unit_id, p_qty);

  -- Buka izin sementara hanya di dalam transaksi ini untuk memperbarui saldo stok
  PERFORM set_config('app.allow_stock_balance_write', 'true', true);

  -- Pastikan baris saldo gudang & produk tersedia lalu kunci barisnya (anti race-condition)
  INSERT INTO public.stock_balances (warehouse_id, product_id, qty_on_hand, avg_unit_cost, total_value)
  VALUES (p_warehouse_id, p_product_id, 0, 0, 0)
  ON CONFLICT (warehouse_id, product_id) DO NOTHING;

  SELECT qty_on_hand, avg_unit_cost, total_value
  INTO v_old_qty, v_old_avg_cost, v_old_value
  FROM public.stock_balances
  WHERE warehouse_id = p_warehouse_id
    AND product_id = p_product_id
  FOR UPDATE;

  IF p_direction = 1 THEN
    -- Barang Masuk: perbarui harga pokok rata-rata bergerak (Moving Weighted Average)
    v_tx_unit_cost := COALESCE(p_unit_cost, v_old_avg_cost, 0);
    IF v_tx_unit_cost < 0 THEN
      RAISE EXCEPTION 'Harga pokok satuan tidak boleh negatif';
    END IF;

    v_tx_total_cost := ROUND(v_qty_base * v_tx_unit_cost, 2);
    v_new_qty := v_old_qty + v_qty_base;

    IF v_old_qty <= 0 THEN
      v_new_avg_cost := v_tx_unit_cost;
      v_new_value := ROUND(v_new_qty * v_new_avg_cost, 2);
    ELSE
      v_new_value := ROUND(v_old_value + v_tx_total_cost, 2);
      v_new_avg_cost := ROUND(v_new_value / v_new_qty, 4);
    END IF;
  ELSE
    -- Barang Keluar: periksa kebijakan stok negatif di pengaturan sistem
    v_neg_setting := public.get_system_setting('allow_negative_stock');
    v_allow_neg := COALESCE((v_neg_setting ->> 'enabled')::boolean, false);

    IF v_old_qty < v_qty_base AND NOT (v_allow_neg OR COALESCE(p_allow_negative_override, false)) THEN
      RAISE EXCEPTION 'Stok tidak mencukupi. Tersedia: %, Diminta: %', v_old_qty, v_qty_base;
    END IF;

    v_tx_unit_cost := v_old_avg_cost;
    v_tx_total_cost := ROUND(v_qty_base * v_tx_unit_cost, 2);
    v_new_qty := v_old_qty - v_qty_base;

    IF v_new_qty = 0 THEN
      v_new_value := 0;
      v_new_avg_cost := v_old_avg_cost;
    ELSE
      v_new_value := ROUND(v_old_value - v_tx_total_cost, 2);
      v_new_avg_cost := v_old_avg_cost;
    END IF;
  END IF;

  UPDATE public.stock_balances
  SET
    qty_on_hand = v_new_qty,
    avg_unit_cost = v_new_avg_cost,
    total_value = v_new_value,
    last_movement_at = now()
  WHERE warehouse_id = p_warehouse_id
    AND product_id = p_product_id;

  INSERT INTO public.stock_movements (
    movement_date,
    warehouse_id,
    product_id,
    movement_type,
    source_type,
    source_id,
    source_line_id,
    source_number,
    unit_id,
    qty_input,
    direction,
    qty_base,
    unit_cost,
    total_cost,
    balance_qty_after,
    balance_avg_cost_after,
    balance_value_after,
    notes,
    created_by
  )
  VALUES (
    COALESCE(p_movement_date, public.jakarta_today()),
    p_warehouse_id,
    p_product_id,
    p_movement_type,
    p_source_type,
    p_source_id,
    p_source_line_id,
    p_source_number,
    p_unit_id,
    p_qty,
    p_direction,
    v_qty_base,
    v_tx_unit_cost,
    v_tx_total_cost,
    v_new_qty,
    v_new_avg_cost,
    v_new_value,
    p_notes,
    COALESCE(p_actor_id, auth.uid())
  )
  RETURNING id INTO v_movement_id;

  RETURN v_movement_id;
END;
$$;

-- 4. Tabel Transfer Barang Antar Gudang
CREATE TABLE IF NOT EXISTS public.stock_transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_number TEXT NOT NULL UNIQUE,
  transfer_date DATE NOT NULL DEFAULT public.jakarta_today(),
  from_warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  to_warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'draft' CHECK (
    status IN ('draft', 'completed', 'cancelled')
  ),
  notes TEXT,
  created_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  completed_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_transfer_diff_warehouse CHECK (from_warehouse_id <> to_warehouse_id)
);

CREATE INDEX IF NOT EXISTS idx_stock_transfers_date ON public.stock_transfers (transfer_date DESC);

CREATE OR REPLACE FUNCTION public.trg_auto_transfer_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.transfer_number IS NULL OR TRIM(NEW.transfer_number) = '' THEN
    NEW.transfer_number := public.generate_document_number('TRF', NEW.transfer_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_stock_transfers_number ON public.stock_transfers;
CREATE TRIGGER trg_stock_transfers_number
  BEFORE INSERT ON public.stock_transfers
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_transfer_number();

DROP TRIGGER IF EXISTS trg_stock_transfers_updated_at ON public.stock_transfers;
CREATE TRIGGER trg_stock_transfers_updated_at
  BEFORE UPDATE ON public.stock_transfers
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.stock_transfer_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id UUID NOT NULL REFERENCES public.stock_transfers(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (transfer_id, product_id)
);

-- 5. Tabel Pengajuan Penyesuaian Stok (Stok Opname)
CREATE TABLE IF NOT EXISTS public.stock_adjustment_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  adjustment_number TEXT NOT NULL UNIQUE,
  adjustment_date DATE NOT NULL DEFAULT public.jakarta_today(),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending_approval' CHECK (
    status IN ('draft', 'pending_approval', 'approved', 'rejected')
  ),
  journal_entry_id UUID,
  requested_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  approved_at TIMESTAMPTZ,
  rejection_reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_stock_adjustments_date ON public.stock_adjustment_requests (adjustment_date DESC);

CREATE OR REPLACE FUNCTION public.trg_auto_adjustment_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.adjustment_number IS NULL OR TRIM(NEW.adjustment_number) = '' THEN
    NEW.adjustment_number := public.generate_document_number('ADJ', NEW.adjustment_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_stock_adjustments_number ON public.stock_adjustment_requests;
CREATE TRIGGER trg_stock_adjustments_number
  BEFORE INSERT ON public.stock_adjustment_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_adjustment_number();

DROP TRIGGER IF EXISTS trg_stock_adjustments_updated_at ON public.stock_adjustment_requests;
CREATE TRIGGER trg_stock_adjustments_updated_at
  BEFORE UPDATE ON public.stock_adjustment_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TABLE IF NOT EXISTS public.stock_adjustment_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  adjustment_id UUID NOT NULL REFERENCES public.stock_adjustment_requests(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  system_qty NUMERIC(18,4) NOT NULL DEFAULT 0,
  actual_qty NUMERIC(18,4) NOT NULL CHECK (actual_qty >= 0),
  difference_qty NUMERIC(18,4) GENERATED ALWAYS AS (actual_qty - system_qty) STORED,
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (adjustment_id, product_id)
);

-- 6. Tabel Pencatatan Barang Rusak (Terpisah dari Stok Layak Jual)
CREATE TABLE IF NOT EXISTS public.damaged_goods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  damage_number TEXT NOT NULL UNIQUE,
  damage_date DATE NOT NULL DEFAULT public.jakarta_today(),
  warehouse_id UUID NOT NULL REFERENCES public.warehouses(id) ON DELETE RESTRICT,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  unit_id UUID NOT NULL REFERENCES public.units(id) ON DELETE RESTRICT,
  qty NUMERIC(18,4) NOT NULL CHECK (qty > 0),
  unit_cost NUMERIC(18,4) NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  total_cost NUMERIC(18,2) NOT NULL DEFAULT 0,
  source_type TEXT NOT NULL DEFAULT 'WAREHOUSE' CHECK (
    source_type IN ('WAREHOUSE', 'DELIVERY', 'SALES_RETURN')
  ),
  source_id UUID,
  source_number TEXT,
  deduct_from_good_stock BOOLEAN NOT NULL DEFAULT true,
  disposition TEXT NOT NULL DEFAULT 'pending' CHECK (
    disposition IN ('pending', 'disposed', 'claimed_to_supplier', 'repacked')
  ),
  reason TEXT NOT NULL,
  journal_entry_id UUID,
  reported_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_by UUID REFERENCES public.profiles(id) ON DELETE RESTRICT,
  verified_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_damaged_goods_date ON public.damaged_goods (damage_date DESC);
CREATE INDEX IF NOT EXISTS idx_damaged_goods_warehouse ON public.damaged_goods (warehouse_id, product_id);

CREATE OR REPLACE FUNCTION public.trg_auto_damage_number()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.damage_number IS NULL OR TRIM(NEW.damage_number) = '' THEN
    NEW.damage_number := public.generate_document_number('DMG', NEW.damage_date);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_damaged_goods_number ON public.damaged_goods;
CREATE TRIGGER trg_damaged_goods_number
  BEFORE INSERT ON public.damaged_goods
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_auto_damage_number();

DROP TRIGGER IF EXISTS trg_damaged_goods_updated_at ON public.damaged_goods;
CREATE TRIGGER trg_damaged_goods_updated_at
  BEFORE UPDATE ON public.damaged_goods
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();
