-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 009
-- Mesin Transaksi Bisnis Atomik (RPC Server-Side)
-- ============================================================================

-- 1. Fungsi Bantu Pengambil Kode Akun Kas/Bank & Kategori Biaya
CREATE OR REPLACE FUNCTION public.get_payment_account_code(
  p_payment_method_id UUID,
  p_bank_id UUID DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
  v_method_type TEXT;
BEGIN
  IF p_bank_id IS NOT NULL THEN
    SELECT coa.code INTO v_code
    FROM public.banks b
    JOIN public.chart_of_accounts coa ON coa.id = b.account_id
    WHERE b.id = p_bank_id;

    IF v_code IS NOT NULL THEN
      RETURN v_code;
    END IF;
  END IF;

  SELECT coa.code, pm.method_type
  INTO v_code, v_method_type
  FROM public.payment_methods pm
  LEFT JOIN public.chart_of_accounts coa ON coa.id = pm.account_id
  WHERE pm.id = p_payment_method_id;

  IF v_code IS NOT NULL THEN
    RETURN v_code;
  END IF;

  IF v_method_type = 'cash' THEN
    RETURN '1101';
  END IF;

  RETURN '1102';
END;
$$;

CREATE OR REPLACE FUNCTION public.get_expense_account_code(p_category_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code TEXT;
BEGIN
  SELECT coa.code INTO v_code
  FROM public.expense_categories ec
  JOIN public.chart_of_accounts coa ON coa.id = ec.account_id
  WHERE ec.id = p_category_id;

  RETURN COALESCE(v_code, '6108');
END;
$$;

-- ============================================================================
-- BAGIAN A: TRANSAKSI PERSEDIAAN
-- ============================================================================

-- A1. Pencatatan Saldo Awal Persediaan + Jurnal Modal Disetor
CREATE OR REPLACE FUNCTION public.rpc_record_opening_stock(
  p_movement_date DATE,
  p_warehouse_id UUID,
  p_product_id UUID,
  p_qty NUMERIC,
  p_unit_cost NUMERIC,
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unit_id UUID;
  v_doc_no TEXT;
  v_mov_id UUID;
  v_total_val NUMERIC(18,2);
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mencatat saldo awal stok.';
  END IF;

  IF p_qty <= 0 OR p_unit_cost < 0 THEN
    RAISE EXCEPTION 'Kuantitas harus lebih dari nol dan harga pokok tidak boleh negatif.';
  END IF;

  SELECT base_unit_id INTO v_unit_id
  FROM public.products
  WHERE id = p_product_id AND is_active = true;

  IF v_unit_id IS NULL THEN
    RAISE EXCEPTION 'Produk tidak ditemukan atau tidak aktif.';
  END IF;

  v_doc_no := public.generate_document_number('OPN', COALESCE(p_movement_date, public.jakarta_today()));
  v_total_val := ROUND(p_qty * p_unit_cost, 2);

  v_mov_id := public.record_stock_movement(
    COALESCE(p_movement_date, public.jakarta_today()),
    p_warehouse_id,
    p_product_id,
    'OPENING_BALANCE',
    'OPENING_STOCK',
    gen_random_uuid(),
    v_doc_no,
    v_unit_id,
    p_qty,
    1::SMALLINT,
    p_unit_cost,
    NULL,
    COALESCE(p_notes, 'Saldo awal persediaan'),
    false,
    auth.uid()
  );

  IF v_total_val > 0 THEN
    PERFORM public.post_automated_journal(
      COALESCE(p_movement_date, public.jakarta_today()),
      'OPENING_STOCK',
      v_mov_id,
      v_doc_no,
      'Saldo awal persediaan - ' || v_doc_no,
      jsonb_build_array(
        jsonb_build_object('account_code', '1105', 'debit', v_total_val, 'credit', 0, 'warehouse_id', p_warehouse_id),
        jsonb_build_object('account_code', '3101', 'debit', 0, 'credit', v_total_val, 'warehouse_id', p_warehouse_id)
      ),
      auth.uid()
    );
  END IF;

  RETURN v_mov_id;
END;
$$;

-- A2. Penyelesaian Transfer Barang Antar Gudang
CREATE OR REPLACE FUNCTION public.rpc_complete_stock_transfer(p_transfer_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trf RECORD;
  v_item RECORD;
  v_avg_cost NUMERIC(18,4);
BEGIN
  IF NOT public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan memproses transfer gudang.';
  END IF;

  SELECT * INTO v_trf
  FROM public.stock_transfers
  WHERE id = p_transfer_id
  FOR UPDATE;

  IF v_trf IS NULL THEN
    RAISE EXCEPTION 'Dokumen transfer gudang tidak ditemukan.';
  END IF;

  IF v_trf.status <> 'draft' THEN
    RAISE EXCEPTION 'Transfer gudang sudah berstatus % dan tidak dapat diproses ulang.', v_trf.status;
  END IF;

  FOR v_item IN
    SELECT * FROM public.stock_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    SELECT COALESCE(avg_unit_cost, 0) INTO v_avg_cost
    FROM public.stock_balances
    WHERE warehouse_id = v_trf.from_warehouse_id
      AND product_id = v_item.product_id;

    UPDATE public.stock_transfer_items
    SET unit_cost = COALESCE(v_avg_cost, 0)
    WHERE id = v_item.id;

    -- Keluar dari gudang asal
    PERFORM public.record_stock_movement(
      v_trf.transfer_date,
      v_trf.from_warehouse_id,
      v_item.product_id,
      'TRANSFER_OUT',
      'STOCK_TRANSFER',
      v_trf.id,
      v_trf.transfer_number,
      v_item.unit_id,
      v_item.qty,
      (-1)::SMALLINT,
      NULL,
      v_item.id,
      v_trf.notes,
      false,
      auth.uid()
    );

    -- Masuk ke gudang tujuan dengan harga pokok yang sama
    PERFORM public.record_stock_movement(
      v_trf.transfer_date,
      v_trf.to_warehouse_id,
      v_item.product_id,
      'TRANSFER_IN',
      'STOCK_TRANSFER',
      v_trf.id,
      v_trf.transfer_number,
      v_item.unit_id,
      v_item.qty,
      1::SMALLINT,
      COALESCE(v_avg_cost, 0),
      v_item.id,
      v_trf.notes,
      false,
      auth.uid()
    );
  END LOOP;

  UPDATE public.stock_transfers
  SET
    status = 'completed',
    completed_by = auth.uid(),
    completed_at = now()
  WHERE id = p_transfer_id;

  RETURN p_transfer_id;
END;
$$;

-- A3. Persetujuan / Penolakan Penyesuaian Stok Opname
CREATE OR REPLACE FUNCTION public.rpc_decide_stock_adjustment(
  p_adjustment_id UUID,
  p_decision TEXT,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_adj RECORD;
  v_item RECORD;
  v_diff NUMERIC(18,4);
  v_cost NUMERIC(18,4);
  v_total_gain NUMERIC(18,2) := 0;
  v_total_loss NUMERIC(18,2) := 0;
  v_journal_id UUID;
  v_lines JSONB := '[]'::jsonb;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat menyetujui penyesuaian stok.';
  END IF;

  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Keputusan penyesuaian stok tidak valid.';
  END IF;

  SELECT * INTO v_adj
  FROM public.stock_adjustment_requests
  WHERE id = p_adjustment_id
  FOR UPDATE;

  IF v_adj IS NULL THEN
    RAISE EXCEPTION 'Dokumen penyesuaian stok tidak ditemukan.';
  END IF;

  IF v_adj.status <> 'pending_approval' THEN
    RAISE EXCEPTION 'Penyesuaian stok sudah diproses sebelumnya.';
  END IF;

  IF p_decision = 'rejected' THEN
    UPDATE public.stock_adjustment_requests
    SET
      status = 'rejected',
      approved_by = auth.uid(),
      approved_at = now(),
      rejection_reason = p_rejection_reason
    WHERE id = p_adjustment_id;

    RETURN p_adjustment_id;
  END IF;

  FOR v_item IN
    SELECT * FROM public.stock_adjustment_items WHERE adjustment_id = p_adjustment_id
  LOOP
    v_diff := v_item.actual_qty - v_item.system_qty;
    IF v_diff = 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(NULLIF(v_item.unit_cost, 0), sb.avg_unit_cost, 0)
    INTO v_cost
    FROM public.stock_balances sb
    WHERE sb.warehouse_id = v_adj.warehouse_id
      AND sb.product_id = v_item.product_id;

    v_cost := COALESCE(v_cost, v_item.unit_cost, 0);

    IF v_diff > 0 THEN
      PERFORM public.record_stock_movement(
        v_adj.adjustment_date,
        v_adj.warehouse_id,
        v_item.product_id,
        'ADJUSTMENT_IN',
        'STOCK_ADJUSTMENT',
        v_adj.id,
        v_adj.adjustment_number,
        v_item.unit_id,
        v_diff,
        1::SMALLINT,
        v_cost,
        v_item.id,
        v_adj.reason,
        false,
        auth.uid()
      );
      v_total_gain := v_total_gain + ROUND(v_diff * v_cost, 2);
    ELSE
      PERFORM public.record_stock_movement(
        v_adj.adjustment_date,
        v_adj.warehouse_id,
        v_item.product_id,
        'ADJUSTMENT_OUT',
        'STOCK_ADJUSTMENT',
        v_adj.id,
        v_adj.adjustment_number,
        v_item.unit_id,
        ABS(v_diff),
        (-1)::SMALLINT,
        NULL,
        v_item.id,
        v_adj.reason,
        false,
        auth.uid()
      );
      v_total_loss := v_total_loss + ROUND(ABS(v_diff) * v_cost, 2);
    END IF;
  END LOOP;

  IF v_total_gain > 0 THEN
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_code', '1105', 'debit', v_total_gain, 'credit', 0, 'warehouse_id', v_adj.warehouse_id),
      jsonb_build_object('account_code', '5102', 'debit', 0, 'credit', v_total_gain, 'warehouse_id', v_adj.warehouse_id)
    );
  END IF;

  IF v_total_loss > 0 THEN
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_code', '5102', 'debit', v_total_loss, 'credit', 0, 'warehouse_id', v_adj.warehouse_id),
      jsonb_build_object('account_code', '1105', 'debit', 0, 'credit', v_total_loss, 'warehouse_id', v_adj.warehouse_id)
    );
  END IF;

  IF jsonb_array_length(v_lines) > 0 THEN
    v_journal_id := public.post_automated_journal(
      v_adj.adjustment_date,
      'STOCK_ADJUSTMENT',
      v_adj.id,
      v_adj.adjustment_number,
      'Penyesuaian stok opname - ' || v_adj.adjustment_number,
      v_lines,
      auth.uid()
    );
  END IF;

  UPDATE public.stock_adjustment_requests
  SET
    status = 'approved',
    journal_entry_id = v_journal_id,
    approved_by = auth.uid(),
    approved_at = now()
  WHERE id = p_adjustment_id;

  RETURN p_adjustment_id;
END;
$$;

-- A4. Pencatatan Barang Rusak di Gudang + Potong Stok & Jurnal Kerugian
CREATE OR REPLACE FUNCTION public.rpc_record_warehouse_damage(
  p_damage_date DATE,
  p_warehouse_id UUID,
  p_product_id UUID,
  p_qty NUMERIC,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unit_id UUID;
  v_avg_cost NUMERIC(18,4);
  v_total_cost NUMERIC(18,2);
  v_dmg_id UUID;
  v_dmg_no TEXT;
  v_journal_id UUID;
BEGIN
  IF NOT public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan mencatat barang rusak gudang.';
  END IF;

  SELECT base_unit_id INTO v_unit_id
  FROM public.products
  WHERE id = p_product_id;

  SELECT COALESCE(avg_unit_cost, 0) INTO v_avg_cost
  FROM public.stock_balances
  WHERE warehouse_id = p_warehouse_id
    AND product_id = p_product_id;

  v_avg_cost := COALESCE(v_avg_cost, 0);
  v_total_cost := ROUND(p_qty * v_avg_cost, 2);

  INSERT INTO public.damaged_goods (
    damage_date,
    warehouse_id,
    product_id,
    unit_id,
    qty,
    unit_cost,
    total_cost,
    source_type,
    deduct_from_good_stock,
    reason,
    reported_by
  )
  VALUES (
    COALESCE(p_damage_date, public.jakarta_today()),
    p_warehouse_id,
    p_product_id,
    v_unit_id,
    p_qty,
    v_avg_cost,
    v_total_cost,
    'WAREHOUSE',
    true,
    p_reason,
    auth.uid()
  )
  RETURNING id, damage_number INTO v_dmg_id, v_dmg_no;

  PERFORM public.record_stock_movement(
    COALESCE(p_damage_date, public.jakarta_today()),
    p_warehouse_id,
    p_product_id,
    'DAMAGE_OUT',
    'DAMAGED_GOODS',
    v_dmg_id,
    v_dmg_no,
    v_unit_id,
    p_qty,
    (-1)::SMALLINT,
    NULL,
    NULL,
    p_reason,
    false,
    auth.uid()
  );

  IF v_total_cost > 0 THEN
    v_journal_id := public.post_automated_journal(
      COALESCE(p_damage_date, public.jakarta_today()),
      'DAMAGED_GOODS',
      v_dmg_id,
      v_dmg_no,
      'Barang rusak gudang - ' || v_dmg_no,
      jsonb_build_array(
        jsonb_build_object('account_code', '5103', 'debit', v_total_cost, 'credit', 0, 'warehouse_id', p_warehouse_id),
        jsonb_build_object('account_code', '1105', 'debit', 0, 'credit', v_total_cost, 'warehouse_id', p_warehouse_id)
      ),
      auth.uid()
    );

    UPDATE public.damaged_goods
    SET journal_entry_id = v_journal_id
    WHERE id = v_dmg_id;
  END IF;

  RETURN v_dmg_id;
END;
$$;

-- ============================================================================
-- BAGIAN B: PENJUALAN (SO), PERSETUJUAN, & PENGIRIMAN TUNGGAL
-- ============================================================================

-- B1. Hitung Ulang & Ajukan Sales Order (Deteksi Otomatis Permintaan Diskon)
CREATE OR REPLACE FUNCTION public.rpc_submit_sales_order(p_sales_order_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_so RECORD;
  v_item RECORD;
  v_subtotal NUMERIC(18,2) := 0;
  v_discount_total NUMERIC(18,2) := 0;
  v_dpp_total NUMERIC(18,2) := 0;
  v_tax_total NUMERIC(18,2) := 0;
  v_grand_total NUMERIC(18,2) := 0;
  v_line_gross NUMERIC(18,2);
  v_line_disc NUMERIC(18,2);
  v_line_net NUMERIC(18,2);
  v_line_dpp NUMERIC(18,2);
  v_line_tax NUMERIC(18,2);
  v_has_discount BOOLEAN := false;
  v_item_count INTEGER := 0;
  v_new_status TEXT;
BEGIN
  IF NOT public.has_any_role(ARRAY['sales', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Sales atau Owner yang dapat mengajukan Sales Order.';
  END IF;

  SELECT * INTO v_so
  FROM public.sales_orders
  WHERE id = p_sales_order_id
  FOR UPDATE;

  IF v_so IS NULL THEN
    RAISE EXCEPTION 'Sales Order tidak ditemukan.';
  END IF;

  IF public.get_my_role() = 'sales' AND v_so.sales_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Anda hanya dapat mengajukan Sales Order milik Anda sendiri.';
  END IF;

  IF v_so.status <> 'draft' THEN
    RAISE EXCEPTION 'Hanya Sales Order berstatus draft yang dapat diajukan.';
  END IF;

  FOR v_item IN
    SELECT * FROM public.sales_order_items WHERE sales_order_id = p_sales_order_id
  LOOP
    v_item_count := v_item_count + 1;
    v_line_gross := ROUND(v_item.qty * v_item.unit_price, 2);

    IF v_item.discount_percent > 0 THEN
      v_line_disc := ROUND(v_line_gross * (v_item.discount_percent / 100.0), 2);
    ELSE
      v_line_disc := ROUND(COALESCE(v_item.discount_amount, 0), 2);
    END IF;

    IF v_line_disc > 0 THEN
      v_has_discount := true;
    END IF;

    v_line_net := GREATEST(0, v_line_gross - v_line_disc);

    IF v_so.ppn_mode_snapshot = 'exclude_ppn' AND v_item.tax_rate_percent > 0 THEN
      v_line_dpp := ROUND(v_line_net * v_item.dpp_multiplier, 2);
      v_line_tax := ROUND(v_line_dpp * (v_item.tax_rate_percent / 100.0), 2);
      UPDATE public.sales_order_items
      SET
        discount_amount = v_line_disc,
        dpp_amount = v_line_dpp,
        tax_amount = v_line_tax,
        line_total = v_line_net + v_line_tax
      WHERE id = v_item.id;
      v_grand_total := v_grand_total + v_line_net + v_line_tax;
    ELSIF v_so.ppn_mode_snapshot = 'include_ppn' AND v_item.tax_rate_percent > 0 THEN
      v_line_dpp := ROUND(v_line_net / (1 + (v_item.dpp_multiplier * v_item.tax_rate_percent / 100.0)), 2);
      v_line_tax := v_line_net - v_line_dpp;
      UPDATE public.sales_order_items
      SET
        discount_amount = v_line_disc,
        dpp_amount = v_line_dpp,
        tax_amount = v_line_tax,
        line_total = v_line_net
      WHERE id = v_item.id;
      v_grand_total := v_grand_total + v_line_net;
    ELSE
      v_line_dpp := v_line_net;
      v_line_tax := 0;
      UPDATE public.sales_order_items
      SET
        discount_amount = v_line_disc,
        dpp_amount = v_line_dpp,
        tax_amount = 0,
        line_total = v_line_net
      WHERE id = v_item.id;
      v_grand_total := v_grand_total + v_line_net;
    END IF;

    v_subtotal := v_subtotal + v_line_gross;
    v_discount_total := v_discount_total + v_line_disc;
    v_dpp_total := v_dpp_total + v_line_dpp;
    v_tax_total := v_tax_total + v_line_tax;
  END LOOP;

  IF v_item_count = 0 THEN
    RAISE EXCEPTION 'Sales Order wajib memiliki minimal satu produk.';
  END IF;

  v_grand_total := GREATEST(0, v_grand_total - COALESCE(v_so.voucher_discount_total, 0));

  IF v_has_discount THEN
    v_new_status := 'pending_approval';
    INSERT INTO public.sales_order_approvals (
      sales_order_id,
      approval_type,
      status,
      requested_by,
      request_reason,
      new_value
    )
    VALUES (
      p_sales_order_id,
      'discount',
      'pending',
      auth.uid(),
      COALESCE(v_so.discount_reason, 'Pengajuan potongan harga penjualan'),
      jsonb_build_object('discount_total', v_discount_total, 'grand_total', v_grand_total)
    );
  ELSE
    v_new_status := 'approved';
  END IF;

  UPDATE public.sales_orders
  SET
    subtotal = v_subtotal,
    discount_total = v_discount_total,
    dpp_total = v_dpp_total,
    tax_total = v_tax_total,
    grand_total = v_grand_total,
    has_discount_request = v_has_discount,
    status = v_new_status
  WHERE id = p_sales_order_id;

  RETURN p_sales_order_id;
END;
$$;

-- B2. Persetujuan / Penolakan Diskon Sales Order oleh Owner atau Finance Admin
CREATE OR REPLACE FUNCTION public.rpc_decide_so_approval(
  p_approval_id UUID,
  p_decision TEXT,
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_app RECORD;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat memutus persetujuan SO.';
  END IF;

  IF p_decision NOT IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'Keputusan persetujuan tidak valid.';
  END IF;

  SELECT * INTO v_app
  FROM public.sales_order_approvals
  WHERE id = p_approval_id
  FOR UPDATE;

  IF v_app IS NULL OR v_app.status <> 'pending' THEN
    RAISE EXCEPTION 'Permintaan persetujuan tidak ditemukan atau sudah diproses.';
  END IF;

  UPDATE public.sales_order_approvals
  SET
    status = p_decision,
    decided_by = auth.uid(),
    decided_at = now(),
    decision_notes = p_notes
  WHERE id = p_approval_id;

  UPDATE public.sales_orders
  SET status = CASE WHEN p_decision = 'approved' THEN 'approved' ELSE 'draft' END
  WHERE id = v_app.sales_order_id
    AND status = 'pending_approval';

  PERFORM public.write_audit_log(
    'sales_order_approvals',
    p_approval_id,
    CASE WHEN p_decision = 'approved' THEN 'APPROVE' ELSE 'REJECT' END,
    p_notes,
    jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', p_decision)
  );

  RETURN p_approval_id;
END;
$$;

-- B3. Koreksi Harga Jual Khusus Owner (Wajib Alasan & Audit Log)
CREATE OR REPLACE FUNCTION public.rpc_owner_override_so_price(
  p_so_item_id UUID,
  p_new_unit_price NUMERIC,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_so RECORD;
BEGIN
  IF public.get_my_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Hanya Owner yang berwenang mengubah harga jual setelah dicatat.';
  END IF;

  IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
    RAISE EXCEPTION 'Alasan perubahan harga wajib diisi.';
  END IF;

  IF p_new_unit_price < 0 THEN
    RAISE EXCEPTION 'Harga jual baru tidak boleh negatif.';
  END IF;

  SELECT * INTO v_item FROM public.sales_order_items WHERE id = p_so_item_id FOR UPDATE;
  IF v_item IS NULL THEN
    RAISE EXCEPTION 'Baris produk SO tidak ditemukan.';
  END IF;

  SELECT * INTO v_so FROM public.sales_orders WHERE id = v_item.sales_order_id FOR UPDATE;
  IF v_so.status = 'invoiced' THEN
    RAISE EXCEPTION 'Harga pada Sales Order yang sudah menjadi faktur tidak dapat diubah.';
  END IF;

  PERFORM set_config('app.allow_owner_price_override', 'true', true);

  UPDATE public.sales_order_items
  SET unit_price = p_new_unit_price
  WHERE id = p_so_item_id;

  INSERT INTO public.sales_order_approvals (
    sales_order_id,
    approval_type,
    status,
    requested_by,
    request_reason,
    old_value,
    new_value,
    decided_by,
    decided_at,
    decision_notes
  )
  VALUES (
    v_so.id,
    'price_override',
    'approved',
    auth.uid(),
    p_reason,
    jsonb_build_object('item_id', p_so_item_id, 'unit_price', v_item.unit_price),
    jsonb_build_object('item_id', p_so_item_id, 'unit_price', p_new_unit_price),
    auth.uid(),
    now(),
    p_reason
  );

  PERFORM public.write_audit_log(
    'sales_order_items',
    p_so_item_id,
    'OVERRIDE',
    p_reason,
    jsonb_build_object('unit_price', v_item.unit_price),
    jsonb_build_object('unit_price', p_new_unit_price)
  );

  RETURN p_so_item_id;
END;
$$;  -- B4. Koreksi Identitas Sales Pembuat SO Khusus Owner CREATE OR REPLACE FUNCTION public.rpc_owner_reattribute_so_sales( p_sales_order_id UUID, p_new_sales_user_id UUID, p_reason TEXT ) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_so RECORD;
BEGIN
  IF public.get_my_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Hanya Owner yang berwenang mengoreksi identitas Sales pada SO.';
  END IF;

  IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
    RAISE EXCEPTION 'Alasan perubahan identitas Sales wajib diisi.';
  END IF;

  SELECT * INTO v_so FROM public.sales_orders WHERE id = p_sales_order_id FOR UPDATE;
  IF v_so IS NULL THEN
    RAISE EXCEPTION 'Sales Order tidak ditemukan.';
  END IF;

  PERFORM set_config('app.allow_sales_reattribution', 'true', true);

  UPDATE public.sales_orders
  SET sales_user_id = p_new_sales_user_id
  WHERE id = p_sales_order_id;

  UPDATE public.deliveries
  SET sales_user_id = p_new_sales_user_id
  WHERE sales_order_id = p_sales_order_id;

  UPDATE public.sales_invoices
  SET sales_user_id = p_new_sales_user_id
  WHERE sales_order_id = p_sales_order_id;

  PERFORM public.write_audit_log(
    'sales_orders',
    p_sales_order_id,
    'OVERRIDE',
    p_reason,
    jsonb_build_object('sales_user_id', v_so.sales_user_id),
    jsonb_build_object('sales_user_id', p_new_sales_user_id)
  );

  RETURN p_sales_order_id;
END;
$$;  -- B5. Proses Pengeluaran Barang Gudang (1 SO = Maksimal 1 Pengiriman) CREATE OR REPLACE FUNCTION public.rpc_dispatch_sales_order( p_sales_order_id UUID, p_delivery_date DATE DEFAULT NULL, p_driver_name TEXT DEFAULT NULL, p_vehicle_number TEXT DEFAULT NULL, p_notes TEXT DEFAULT NULL ) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_so RECORD;
  v_item RECORD;
  v_del_id UUID;
  v_del_no TEXT;
  v_avg_cost NUMERIC(18,4);
  v_del_item_id UUID;
BEGIN
  IF NOT public.has_any_role(ARRAY['warehouse', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Warehouse/Delivery atau Owner yang dapat memproses pengeluaran barang.';
  END IF;

  SELECT * INTO v_so
  FROM public.sales_orders
  WHERE id = p_sales_order_id
  FOR UPDATE;

  IF v_so IS NULL THEN
    RAISE EXCEPTION 'Sales Order tidak ditemukan.';
  END IF;

  IF v_so.status NOT IN ('approved', 'ready_for_delivery') THEN
    RAISE EXCEPTION 'Sales Order berstatus % tidak dapat dikirim.', v_so.status;
  END IF;

  IF EXISTS (SELECT 1 FROM public.deliveries WHERE sales_order_id = p_sales_order_id) THEN
    RAISE EXCEPTION 'Sales Order ini sudah memiliki dokumen pengiriman dan tidak boleh dikirim dua kali.';
  END IF;

  INSERT INTO public.deliveries (
    sales_order_id,
    customer_id,
    warehouse_id,
    sales_user_id,
    delivery_date,
    driver_name,
    vehicle_number,
    status,
    dispatched_at,
    dispatched_by,
    notes,
    created_by
  )
  VALUES (
    v_so.id,
    v_so.customer_id,
    v_so.warehouse_id,
    v_so.sales_user_id,
    COALESCE(p_delivery_date, public.jakarta_today()),
    p_driver_name,
    p_vehicle_number,
    'dispatched',
    now(),
    auth.uid(),
    p_notes,
    auth.uid()
  )
  RETURNING id, delivery_number INTO v_del_id, v_del_no;

  FOR v_item IN
    SELECT * FROM public.sales_order_items WHERE sales_order_id = p_sales_order_id
  LOOP
    SELECT COALESCE(avg_unit_cost, 0) INTO v_avg_cost
    FROM public.stock_balances
    WHERE warehouse_id = v_so.warehouse_id
      AND product_id = v_item.product_id;

    v_avg_cost := COALESCE(v_avg_cost, 0);

    INSERT INTO public.delivery_items (
      delivery_id,
      sales_order_item_id,
      product_id,
      unit_id,
      qty_ordered,
      qty_dispatched,
      qty_delivered,
      qty_damaged,
      qty_returned_undelivered,
      unit_price,
      discount_amount,
      tax_code_id,
      tax_rate_percent,
      dpp_multiplier,
      unit_cost
    )
    VALUES (
      v_del_id,
      v_item.id,
      v_item.product_id,
      v_item.unit_id,
      v_item.qty,
      v_item.qty,
      v_item.qty,
      0,
      0,
      v_item.unit_price,
      v_item.discount_amount,
      v_item.tax_code_id,
      v_item.tax_rate_percent,
      v_item.dpp_multiplier,
      v_avg_cost
    )
    RETURNING id INTO v_del_item_id;

    -- Potong stok satu kali saat barang benar-benar keluar dari gudang
    PERFORM public.record_stock_movement(
      COALESCE(p_delivery_date, public.jakarta_today()),
      v_so.warehouse_id,
      v_item.product_id,
      'SALES_OUT',
      'DELIVERY',
      v_del_id,
      v_del_no,
      v_item.unit_id,
      v_item.qty,
      (-1)::SMALLINT,
      NULL,
      v_del_item_id,
      'Pengeluaran barang untuk ' || v_so.so_number,
      false,
      auth.uid()
    );
  END LOOP;

  UPDATE public.sales_orders
  SET status = 'delivered'
  WHERE id = p_sales_order_id;

  RETURN v_del_id;
END;
$$;  -- B6. Pencatatan / Koreksi Hasil Pengiriman oleh Kasir Sebelum Faktur Dibuat CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_result( p_delivery_id UUID, p_driver_name TEXT, p_vehicle_number TEXT DEFAULT NULL, p_delivery_date DATE DEFAULT NULL, p_items JSONB DEFAULT '[]'::jsonb, p_edit_reason TEXT DEFAULT NULL ) RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_del RECORD;
  v_elem JSONB;
  v_item RECORD;
  v_qty_del NUMERIC(18,4);
  v_qty_dmg NUMERIC(18,4);
  v_qty_ret NUMERIC(18,4);
  v_old_snapshot JSONB;
BEGIN
  IF NOT public.has_any_role(ARRAY['cashier', 'warehouse', 'owner']) THEN
    RAISE EXCEPTION
