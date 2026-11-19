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
$$;

-- B4. Koreksi Identitas Sales Pembuat SO Khusus Owner
CREATE OR REPLACE FUNCTION public.rpc_owner_reattribute_so_sales(
  p_sales_order_id UUID,
  p_new_sales_user_id UUID,
  p_reason TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

-- B5. Proses Pengeluaran Barang Gudang (1 SO = Maksimal 1 Pengiriman)
CREATE OR REPLACE FUNCTION public.rpc_dispatch_sales_order(
  p_sales_order_id UUID,
  p_delivery_date DATE DEFAULT NULL,
  p_driver_name TEXT DEFAULT NULL,
  p_vehicle_number TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
$$;

-- B6. Pencatatan / Koreksi Hasil Pengiriman oleh Kasir Sebelum Faktur Dibuat
CREATE OR REPLACE FUNCTION public.rpc_confirm_delivery_result(
  p_delivery_id UUID,
  p_driver_name TEXT,
  p_vehicle_number TEXT DEFAULT NULL,
  p_delivery_date DATE DEFAULT NULL,
  p_items JSONB DEFAULT '[]'::jsonb,
  p_edit_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan mencatat hasil pengiriman.';
  END IF;

  SELECT * INTO v_del
  FROM public.deliveries
  WHERE id = p_delivery_id
  FOR UPDATE;

  IF v_del IS NULL THEN
    RAISE EXCEPTION 'Dokumen Surat Jalan tidak ditemukan.';
  END IF;

  IF v_del.status = 'invoiced' THEN
    RAISE EXCEPTION 'Hasil pengiriman tidak dapat diubah setelah faktur penjualan dibuat.';
  END IF;

  IF p_driver_name IS NULL OR TRIM(p_driver_name) = '' THEN
    RAISE EXCEPTION 'Nama pengemudi wajib diisi.';
  END IF;

  SELECT jsonb_agg(row_to_json(di)) INTO v_old_snapshot
  FROM public.delivery_items di
  WHERE di.delivery_id = p_delivery_id;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    SELECT * INTO v_item
    FROM public.delivery_items
    WHERE id = (v_elem ->> 'delivery_item_id')::UUID
      AND delivery_id = p_delivery_id
    FOR UPDATE;

    IF v_item IS NULL THEN
      RAISE EXCEPTION 'Rincian barang pengiriman tidak ditemukan.';
    END IF;

    v_qty_del := COALESCE((v_elem ->> 'qty_delivered')::NUMERIC, 0);
    v_qty_dmg := COALESCE((v_elem ->> 'qty_damaged')::NUMERIC, 0);
    v_qty_ret := COALESCE((v_elem ->> 'qty_returned_undelivered')::NUMERIC, 0);

    IF (v_qty_del + v_qty_dmg + v_qty_ret) <> v_item.qty_dispatched THEN
      RAISE EXCEPTION 'Jumlah diterima (%), rusak (%), dan batal kirim (%) harus sama dengan jumlah keluar gudang (%).',
        v_qty_del, v_qty_dmg, v_qty_ret, v_item.qty_dispatched;
    END IF;

    UPDATE public.delivery_items
    SET
      qty_delivered = v_qty_del,
      qty_damaged = v_qty_dmg,
      qty_returned_undelivered = v_qty_ret,
      notes = COALESCE(v_elem ->> 'notes', notes)
    WHERE id = v_item.id;
  END LOOP;

  UPDATE public.deliveries
  SET
    driver_name = TRIM(p_driver_name),
    vehicle_number = COALESCE(NULLIF(TRIM(p_vehicle_number), ''), vehicle_number),
    delivery_date = COALESCE(p_delivery_date, delivery_date),
    status = 'delivered',
    delivered_at = COALESCE(delivered_at, now()),
    confirmed_by = auth.uid()
  WHERE id = p_delivery_id;

  IF v_del.status = 'delivered' THEN
    PERFORM public.write_audit_log(
      'deliveries',
      p_delivery_id,
      'UPDATE',
      COALESCE(NULLIF(TRIM(p_edit_reason), ''), 'Koreksi hasil pengiriman sebelum penerbitan faktur'),
      jsonb_build_object('driver_name', v_del.driver_name, 'items', v_old_snapshot),
      jsonb_build_object('driver_name', TRIM(p_driver_name), 'items', p_items)
    );
  END IF;

  RETURN p_delivery_id;
END;
$$;

-- ============================================================================
-- BAGIAN C: FAKTUR PENJUALAN, RETUR, & PEMBAYARAN PELANGGAN
-- ============================================================================

-- C1. Penerbitan Faktur Penjualan dari Hasil Pengiriman + Jurnal & Klaim Voucher
CREATE OR REPLACE FUNCTION public.rpc_issue_sales_invoice(
  p_delivery_id UUID,
  p_invoice_date DATE DEFAULT NULL,
  p_voucher_supplier_id UUID DEFAULT NULL,
  p_voucher_program_name TEXT DEFAULT NULL,
  p_voucher_code TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_del RECORD;
  v_so RECORD;
  v_cust RECORD;
  v_item RECORD;
  v_inv_id UUID;
  v_inv_no TEXT;
  v_inv_date DATE;
  v_due_date DATE;
  v_subtotal NUMERIC(18,2) := 0;
  v_discount_total NUMERIC(18,2) := 0;
  v_dpp_total NUMERIC(18,2) := 0;
  v_tax_total NUMERIC(18,2) := 0;
  v_voucher_total NUMERIC(18,2) := 0;
  v_grand_total NUMERIC(18,2) := 0;
  v_total_cogs_sold NUMERIC(18,2) := 0;
  v_total_transit_damage NUMERIC(18,2) := 0;
  v_total_inv_credit NUMERIC(18,2) := 0;
  v_ratio NUMERIC(18,8);
  v_line_gross NUMERIC(18,2);
  v_line_disc NUMERIC(18,2);
  v_line_net NUMERIC(18,2);
  v_line_dpp NUMERIC(18,2);
  v_line_tax NUMERIC(18,2);
  v_line_total NUMERIC(18,2);
  v_line_cogs NUMERIC(18,2);
  v_dmg_cost NUMERIC(18,2);
  v_dmg_id UUID;
  v_billed_count INTEGER := 0;
  v_journal_lines JSONB := '[]'::jsonb;
  v_journal_id UUID;
  v_tax_code_id UUID;
  v_tax_rate NUMERIC(6,4) := 0;
  v_dpp_mult NUMERIC(10,6) := 1.000000;
BEGIN
  IF NOT public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan menerbitkan faktur penjualan.';
  END IF;

  SELECT * INTO v_del
  FROM public.deliveries
  WHERE id = p_delivery_id
  FOR UPDATE;

  IF v_del IS NULL THEN
    RAISE EXCEPTION 'Surat Jalan tidak ditemukan.';
  END IF;

  IF v_del.status <> 'delivered' THEN
    RAISE EXCEPTION 'Faktur hanya dapat dibuat dari pengiriman berstatus delivered (status saat ini: %).', v_del.status;
  END IF;

  IF EXISTS (SELECT 1 FROM public.sales_invoices WHERE delivery_id = p_delivery_id) THEN
    RAISE EXCEPTION 'Surat Jalan ini sudah memiliki faktur penjualan.';
  END IF;

  SELECT * INTO v_so FROM public.sales_orders WHERE id = v_del.sales_order_id FOR UPDATE;
  SELECT * INTO v_cust FROM public.customers WHERE id = v_del.customer_id;

  v_inv_date := COALESCE(p_invoice_date, v_del.delivery_date, public.jakarta_today());
  v_due_date := v_inv_date + COALESCE(v_so.payment_term_days, 0);
  v_voucher_total := COALESCE(v_so.voucher_discount_total, 0);

  INSERT INTO public.sales_invoices (
    invoice_date,
    due_date,
    sales_order_id,
    delivery_id,
    customer_id,
    warehouse_id,
    sales_user_id,
    payment_type,
    ppn_mode_snapshot,
    rounding_method_snapshot,
    voucher_discount_total,
    status,
    issued_by,
    issued_at,
    created_by
  )
  VALUES (
    v_inv_date,
    v_due_date,
    v_so.id,
    v_del.id,
    v_del.customer_id,
    v_del.warehouse_id,
    v_so.sales_user_id,
    v_so.payment_type,
    v_so.ppn_mode_snapshot,
    v_so.rounding_method_snapshot,
    v_voucher_total,
    'issued',
    auth.uid(),
    now(),
    auth.uid()
  )
  RETURNING id, invoice_number INTO v_inv_id, v_inv_no;

  FOR v_item IN
    SELECT * FROM public.delivery_items WHERE delivery_id = p_delivery_id
  LOOP
    -- 1. Kembalikan barang batal kirim yang masih layak jual ke stok gudang
    IF v_item.qty_returned_undelivered > 0 THEN
      PERFORM public.record_stock_movement(
        v_inv_date,
        v_del.warehouse_id,
        v_item.product_id,
        'SALES_RETURN_IN',
        'DELIVERY_UNDELIVERED',
        v_del.id,
        v_del.delivery_number,
        v_item.unit_id,
        v_item.qty_returned_undelivered,
        1::SMALLINT,
        v_item.unit_cost,
        v_item.id,
        'Barang batal terkirim kembali ke gudang',
        false,
        auth.uid()
      );
    END IF;

    -- 2. Catat barang rusak selama pengiriman secara terpisah (tanpa potong stok ganda & tanpa ditagih)
    IF v_item.qty_damaged > 0 THEN
      v_dmg_cost := ROUND(v_item.qty_damaged * v_item.unit_cost, 2);
      v_total_transit_damage := v_total_transit_damage + v_dmg_cost;
      v_total_inv_credit := v_total_inv_credit + v_dmg_cost;

      INSERT INTO public.damaged_goods (
        damage_date,
        warehouse_id,
        product_id,
        unit_id,
        qty,
        unit_cost,
        total_cost,
        source_type,
        source_id,
        source_number,
        deduct_from_good_stock,
        reason,
        reported_by
      )
      VALUES (
        v_inv_date,
        v_del.warehouse_id,
        v_item.product_id,
        v_item.unit_id,
        v_item.qty_damaged,
        v_item.unit_cost,
        v_dmg_cost,
        'DELIVERY',
        v_del.id,
        v_del.delivery_number,
        false,
        COALESCE(v_item.notes, 'Barang rusak saat pengiriman ' || v_del.delivery_number),
        auth.uid()
      )
      RETURNING id INTO v_dmg_id;

      INSERT INTO public.delivery_damage_reports (
        delivery_id,
        delivery_item_id,
        product_id,
        unit_id,
        qty_damaged,
        reason,
        damaged_goods_id,
        reported_by
      )
      VALUES (
        v_del.id,
        v_item.id,
        v_item.product_id,
        v_item.unit_id,
        v_item.qty_damaged,
        COALESCE(v_item.notes, 'Barang rusak saat pengiriman'),
        v_dmg_id,
        auth.uid()
      );
    END IF;

    -- 3. Tagihkan hanya barang yang benar-benar diterima pelanggan
    IF v_item.qty_delivered > 0 THEN
      v_billed_count := v_billed_count + 1;
      v_ratio := v_item.qty_delivered / v_item.qty_ordered;
      v_line_gross := ROUND(v_item.qty_delivered * v_item.unit_price, 2);
      v_line_disc := ROUND(v_item.discount_amount * v_ratio, 2);
      v_line_net := GREATEST(0, v_line_gross - v_line_disc);

      IF v_so.ppn_mode_snapshot = 'exclude_ppn' AND v_item.tax_rate_percent > 0 THEN
        v_line_dpp := ROUND(v_line_net * v_item.dpp_multiplier, 2);
        v_line_tax := ROUND(v_line_dpp * (v_item.tax_rate_percent / 100.0), 2);
        v_line_total := v_line_net + v_line_tax;
        v_tax_code_id := v_item.tax_code_id;
        v_tax_rate := v_item.tax_rate_percent;
        v_dpp_mult := v_item.dpp_multiplier;
      ELSIF v_so.ppn_mode_snapshot = 'include_ppn' AND v_item.tax_rate_percent > 0 THEN
        v_line_dpp := ROUND(v_line_net / (1 + (v_item.dpp_multiplier * v_item.tax_rate_percent / 100.0)), 2);
        v_line_tax := v_line_net - v_line_dpp;
        v_line_total := v_line_net;
        v_tax_code_id := v_item.tax_code_id;
        v_tax_rate := v_item.tax_rate_percent;
        v_dpp_mult := v_item.dpp_multiplier;
      ELSE
        v_line_dpp := v_line_net;
        v_line_tax := 0;
        v_line_total := v_line_net;
      END IF;

      v_line_cogs := ROUND(v_item.qty_delivered * v_item.unit_cost, 2);

      INSERT INTO public.sales_invoice_items (
        sales_invoice_id,
        delivery_item_id,
        product_id,
        unit_id,
        qty_billed,
        unit_price,
        discount_amount,
        tax_code_id,
        tax_rate_percent,
        dpp_multiplier,
        dpp_amount,
        tax_amount,
        line_total,
        unit_cost,
        cogs_total,
        notes
      )
      VALUES (
        v_inv_id,
        v_item.id,
        v_item.product_id,
        v_item.unit_id,
        v_item.qty_delivered,
        v_item.unit_price,
        v_line_disc,
        v_item.tax_code_id,
        v_item.tax_rate_percent,
        v_item.dpp_multiplier,
        v_line_dpp,
        v_line_tax,
        v_line_total,
        v_item.unit_cost,
        v_line_cogs,
        v_item.notes
      );

      v_subtotal := v_subtotal + v_line_gross;
      v_discount_total := v_discount_total + v_line_disc;
      v_dpp_total := v_dpp_total + v_line_dpp;
      v_tax_total := v_tax_total + v_line_tax;
      v_grand_total := v_grand_total + v_line_total;
      v_total_cogs_sold := v_total_cogs_sold + v_line_cogs;
      v_total_inv_credit := v_total_inv_credit + v_line_cogs;
    END IF;
  END LOOP;

  IF v_billed_count = 0 THEN
    RAISE EXCEPTION 'Tidak ada barang yang diterima pelanggan untuk diterbitkan faktur.';
  END IF;

  -- Potongan voucher promosi langsung mengurangi tagihan pelanggan & membentuk piutang klaim principal
  v_grand_total := GREATEST(0, v_grand_total - v_voucher_total);

  UPDATE public.sales_invoices
  SET
    subtotal = v_subtotal,
    discount_total = v_discount_total,
    dpp_total = v_dpp_total,
    tax_total = v_tax_total,
    grand_total = v_grand_total
  WHERE id = v_inv_id;

  IF v_voucher_total > 0 THEN
    IF p_voucher_supplier_id IS NULL THEN
      RAISE EXCEPTION 'Principal atau supplier penanggung klaim voucher wajib dipilih.';
    END IF;

    INSERT INTO public.voucher_claims (
      claim_date,
      supplier_id,
      sales_invoice_id,
      program_name,
      voucher_code,
      claim_amount,
      created_by
    )
    VALUES (
      v_inv_date,
      p_voucher_supplier_id,
      v_inv_id,
      COALESCE(NULLIF(TRIM(p_voucher_program_name), ''), 'Program Voucher Promosi'),
      p_voucher_code,
      v_voucher_total,
      auth.uid()
    );
  END IF;

  -- Bentuk Jurnal Otomatis Penjualan, Klaim Voucher, PPN Keluaran, HPP, & Kerugian Rusak Kirim
  IF v_grand_total > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '1103', 'debit', v_grand_total, 'credit', 0, 'customer_id', v_del.customer_id, 'sales_user_id', v_so.sales_user_id)
    );
  END IF;

  IF v_voucher_total > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '1104', 'debit', v_voucher_total, 'credit', 0, 'supplier_id', p_voucher_supplier_id)
    );
  END IF;

  IF (v_grand_total + v_voucher_total - v_tax_total) > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '4101', 'debit', 0, 'credit', (v_grand_total + v_voucher_total - v_tax_total), 'customer_id', v_del.customer_id, 'sales_user_id', v_so.sales_user_id)
    );
  END IF;

  IF v_tax_total > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '2102', 'debit', 0, 'credit', v_tax_total, 'customer_id', v_del.customer_id)
    );
  END IF;

  IF v_total_cogs_sold > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '5101', 'debit', v_total_cogs_sold, 'credit', 0, 'warehouse_id', v_del.warehouse_id, 'sales_user_id', v_so.sales_user_id)
    );
  END IF;

  IF v_total_transit_damage > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '5103', 'debit', v_total_transit_damage, 'credit', 0, 'warehouse_id', v_del.warehouse_id)
    );
  END IF;

  IF v_total_inv_credit > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '1105', 'debit', 0, 'credit', v_total_inv_credit, 'warehouse_id', v_del.warehouse_id)
    );
  END IF;

  v_journal_id := public.post_automated_journal(
    v_inv_date,
    'SALES_INVOICE',
    v_inv_id,
    v_inv_no,
    'Faktur penjualan ' || v_inv_no || ' - ' || v_cust.name,
    v_journal_lines,
    auth.uid()
  );

  UPDATE public.sales_invoices
  SET journal_entry_id = v_journal_id
  WHERE id = v_inv_id;

  IF v_tax_total > 0 AND v_tax_code_id IS NOT NULL THEN
    INSERT INTO public.tax_transactions (
      tax_date,
      tax_direction,
      tax_code_id,
      rate_percent,
      dpp_multiplier,
      dpp_amount,
      tax_amount,
      source_type,
      source_id,
      source_number,
      counterparty_name,
      counterparty_npwp,
      journal_entry_id
    )
    VALUES (
      v_inv_date,
      'output',
      v_tax_code_id,
      v_tax_rate,
      v_dpp_mult,
      v_dpp_total,
      v_tax_total,
      'SALES_INVOICE',
      v_inv_id,
      v_inv_no,
      v_cust.name,
      v_cust.npwp,
      v_journal_id
    );
  END IF;

  UPDATE public.deliveries SET status = 'invoiced' WHERE id = p_delivery_id;
  UPDATE public.sales_orders SET status = 'invoiced' WHERE id = v_so.id;

  RETURN v_inv_id;
END;
$$;

-- C2. Pencatatan Pembayaran Pelanggan & Alokasi Faktur
CREATE OR REPLACE FUNCTION public.rpc_record_customer_payment(
  p_payment_date DATE,
  p_customer_id UUID,
  p_payment_method_id UUID,
  p_bank_id UUID DEFAULT NULL,
  p_amount NUMERIC DEFAULT 0,
  p_reference_number TEXT DEFAULT NULL,
  p_proof_file_path TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_allocations JSONB DEFAULT '[]'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pay_id UUID;
  v_alloc JSONB;
BEGIN
  IF NOT public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan mencatat pembayaran pelanggan.';
  END IF;

  INSERT INTO public.customer_payments (
    payment_date,
    customer_id,
    payment_method_id,
    bank_id,
    amount,
    reference_number,
    proof_file_path,
    recorded_by,
    notes
  )
  VALUES (
    COALESCE(p_payment_date, public.jakarta_today()),
    p_customer_id,
    p_payment_method_id,
    p_bank_id,
    p_amount,
    p_reference_number,
    p_proof_file_path,
    auth.uid(),
    p_notes
  )
  RETURNING id INTO v_pay_id;

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
  LOOP
    IF COALESCE((v_alloc ->> 'allocated_amount')::NUMERIC, 0) > 0 THEN
      INSERT INTO public.customer_payment_allocations (
        customer_payment_id,
        sales_invoice_id,
        allocated_amount,
        allocated_date,
        created_by
      )
      VALUES (
        v_pay_id,
        (v_alloc ->> 'sales_invoice_id')::UUID,
        (v_alloc ->> 'allocated_amount')::NUMERIC,
        COALESCE(p_payment_date, public.jakarta_today()),
        auth.uid()
      );
    END IF;
  END LOOP;

  RETURN v_pay_id;
END;
$$;

-- C3. Verifikasi Pembayaran Pelanggan oleh Finance Admin / Owner (Anti Self-Verify)
CREATE OR REPLACE FUNCTION public.rpc_verify_customer_payment(
  p_payment_id UUID,
  p_decision TEXT,
  p_rejection_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pay RECORD;
  v_cust_name TEXT;
  v_cash_bank_code TEXT;
  v_journal_id UUID;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat memverifikasi pembayaran.';
  END IF;

  IF p_decision NOT IN ('verified', 'rejected') THEN
    RAISE EXCEPTION 'Status verifikasi pembayaran tidak valid.';
  END IF;

  SELECT * INTO v_pay
  FROM public.customer_payments
  WHERE id = p_payment_id
  FOR UPDATE;

  IF v_pay IS NULL OR v_pay.verification_status <> 'pending' THEN
    RAISE EXCEPTION 'Pembayaran tidak ditemukan atau sudah diverifikasi sebelumnya.';
  END IF;

  IF v_pay.recorded_by = auth.uid() THEN
    RAISE EXCEPTION 'Pembuat pembayaran tidak boleh memverifikasi pembayarannya sendiri.';
  END IF;

  UPDATE public.customer_payments
  SET
    verification_status = p_decision,
    rejection_reason = CASE WHEN p_decision = 'rejected' THEN p_rejection_reason ELSE NULL END,
    verified_by = auth.uid(),
    verified_at = now()
  WHERE id = p_payment_id;

  IF p_decision = 'verified' THEN
    SELECT name INTO v_cust_name FROM public.customers WHERE id = v_pay.customer_id;
    v_cash_bank_code := public.get_payment_account_code(v_pay.payment_method_id, v_pay.bank_id);

    v_journal_id := public.post_automated_journal(
      v_pay.payment_date,
      'CUSTOMER_PAYMENT',
      v_pay.id,
      v_pay.payment_number,
      'Penerimaan pembayaran ' || v_pay.payment_number || ' - ' || COALESCE(v_cust_name, ''),
      jsonb_build_array(
        jsonb_build_object('account_code', v_cash_bank_code, 'debit', v_pay.amount, 'credit', 0, 'customer_id', v_pay.customer_id),
        jsonb_build_object('account_code', '1103', 'debit', 0, 'credit', v_pay.amount, 'customer_id', v_pay.customer_id)
      ),
      auth.uid()
    );

    UPDATE public.customer_payments
    SET journal_entry_id = v_journal_id
    WHERE id = p_payment_id;
  END IF;

  RETURN p_payment_id;
END;
$$;

-- C4. Pemrosesan Retur Penjualan & Nota Kredit (Layak Jual vs Rusak)
CREATE OR REPLACE FUNCTION public.rpc_process_sales_return(
  p_return_date DATE,
  p_sales_invoice_id UUID,
  p_reason TEXT,
  p_items JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_inv RECORD;
  v_cust RECORD;
  v_ret_id UUID;
  v_ret_no TEXT;
  v_cn_id UUID;
  v_cn_no TEXT;
  v_elem JSONB;
  v_inv_item RECORD;
  v_already_ret NUMERIC(18,4);
  v_qty_ret NUMERIC(18,4);
  v_cond TEXT;
  v_ratio NUMERIC(18,8);
  v_line_dpp NUMERIC(18,2);
  v_line_tax NUMERIC(18,2);
  v_line_total NUMERIC(18,2);
  v_line_cost NUMERIC(18,2);
  v_sub_total NUMERIC(18,2) := 0;
  v_dpp_total NUMERIC(18,2) := 0;
  v_tax_total NUMERIC(18,2) := 0;
  v_grand_total NUMERIC(18,2) := 0;
  v_good_cost NUMERIC(18,2) := 0;
  v_dmg_cost NUMERIC(18,2) := 0;
  v_ret_date DATE;
  v_journal_lines JSONB := '[]'::jsonb;
  v_journal_id UUID;
  v_tax_code_id UUID;
  v_tax_rate NUMERIC(6,4) := 0;
  v_dpp_mult NUMERIC(10,6) := 1.000000;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat memproses retur penjualan.';
  END IF;

  SELECT * INTO v_inv
  FROM public.sales_invoices
  WHERE id = p_sales_invoice_id
  FOR UPDATE;

  IF v_inv IS NULL OR v_inv.status IN ('draft', 'void') THEN
    RAISE EXCEPTION 'Faktur penjualan tidak valid untuk diretur.';
  END IF;

  SELECT * INTO v_cust FROM public.customers WHERE id = v_inv.customer_id;
  v_ret_date := COALESCE(p_return_date, public.jakarta_today());

  INSERT INTO public.sales_returns (
    return_date,
    sales_invoice_id,
    customer_id,
    warehouse_id,
    sales_user_id,
    status,
    reason,
    created_by,
    approved_by
  )
  VALUES (
    v_ret_date,
    v_inv.id,
    v_inv.customer_id,
    v_inv.warehouse_id,
    v_inv.sales_user_id,
    'completed',
    p_reason,
    auth.uid(),
    auth.uid()
  )
  RETURNING id, return_number INTO v_ret_id, v_ret_no;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_qty_ret := COALESCE((v_elem ->> 'qty_returned')::NUMERIC, 0);
    v_cond := COALESCE(v_elem ->> 'item_condition', 'good');

    IF v_qty_ret <= 0 THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_inv_item
    FROM public.sales_invoice_items
    WHERE id = (v_elem ->> 'sales_invoice_item_id')::UUID
      AND sales_invoice_id = p_sales_invoice_id;

    IF v_inv_item IS NULL THEN
      RAISE EXCEPTION 'Baris produk faktur tidak ditemukan.';
    END IF;

    SELECT COALESCE(SUM(sri.qty_returned), 0) INTO v_already_ret
    FROM public.sales_return_items sri
    JOIN public.sales_returns sr ON sr.id = sri.sales_return_id
    WHERE sri.sales_invoice_item_id = v_inv_item.id
      AND sr.status = 'completed';

    IF (v_already_ret + v_qty_ret) > v_inv_item.qty_billed THEN
      RAISE EXCEPTION 'Kuantitas retur melebihi jumlah barang pada faktur asal.';
    END IF;

    v_ratio := v_qty_ret / v_inv_item.qty_billed;
    v_line_dpp := ROUND(v_inv_item.dpp_amount * v_ratio, 2);
    v_line_tax := ROUND(v_inv_item.tax_amount * v_ratio, 2);
    v_line_total := ROUND(v_inv_item.line_total * v_ratio, 2);
    v_line_cost := ROUND(v_qty_ret * v_inv_item.unit_cost, 2);

    IF v_line_tax > 0 THEN
      v_tax_code_id := v_inv_item.tax_code_id;
      v_tax_rate := v_inv_item.tax_rate_percent;
      v_dpp_mult := v_inv_item.dpp_multiplier;
    END IF;

    INSERT INTO public.sales_return_items (
      sales_return_id,
      sales_invoice_item_id,
      product_id,
      unit_id,
      qty_returned,
      item_condition,
      unit_price,
      tax_rate_percent,
      dpp_multiplier,
      dpp_amount,
      tax_amount,
      line_total,
      unit_cost,
      notes
    )
    VALUES (
      v_ret_id,
      v_inv_item.id,
      v_inv_item.product_id,
      v_inv_item.unit_id,
      v_qty_ret,
      v_cond,
      v_inv_item.unit_price,
      v_inv_item.tax_rate_percent,
      v_inv_item.dpp_multiplier,
      v_line_dpp,
      v_line_tax,
      v_line_total,
      v_inv_item.unit_cost,
      v_elem ->> 'notes'
    );

    IF v_cond = 'good' THEN
      PERFORM public.record_stock_movement(
        v_ret_date,
        v_inv.warehouse_id,
        v_inv_item.product_id,
        'SALES_RETURN_IN',
        'SALES_RETURN',
        v_ret_id,
        v_ret_no,
        v_inv_item.unit_id,
        v_qty_ret,
        1::SMALLINT,
        v_inv_item.unit_cost,
        v_inv_item.id,
        'Retur barang layak jual - ' || v_ret_no,
        false,
        auth.uid()
      );
      v_good_cost := v_good_cost + v_line_cost;
    ELSE
      INSERT INTO public.damaged_goods (
        damage_date,
        warehouse_id,
        product_id,
        unit_id,
        qty,
        unit_cost,
        total_cost,
        source_type,
        source_id,
        source_number,
        deduct_from_good_stock,
        reason,
        reported_by
      )
      VALUES (
        v_ret_date,
        v_inv.warehouse_id,
        v_inv_item.product_id,
        v_inv_item.unit_id,
        v_qty_ret,
        v_inv_item.unit_cost,
        v_line_cost,
        'SALES_RETURN',
        v_ret_id,
        v_ret_no,
        false,
        'Barang rusak hasil retur penjualan ' || v_ret_no,
        auth.uid()
      );
      v_dmg_cost := v_dmg_cost + v_line_cost;
    END IF;

    v_sub_total := v_sub_total + ROUND(v_qty_ret * v_inv_item.unit_price, 2);
    v_dpp_total := v_dpp_total + v_line_dpp;
    v_tax_total := v_tax_total + v_line_tax;
    v_grand_total := v_grand_total + v_line_total;
  END LOOP;

  IF v_grand_total <= 0 THEN
    RAISE EXCEPTION 'Nominal retur harus lebih besar dari nol.';
  END IF;

  UPDATE public.sales_returns
  SET
    subtotal = v_sub_total,
    dpp_total = v_dpp_total,
    tax_total = v_tax_total,
    grand_total = v_grand_total
  WHERE id = v_ret_id;

  INSERT INTO public.credit_notes (
    credit_note_date,
    sales_return_id,
    sales_invoice_id,
    customer_id,
    sales_user_id,
    amount,
    status,
    reason,
    created_by
  )
  VALUES (
    v_ret_date,
    v_ret_id,
    v_inv.id,
    v_inv.customer_id,
    v_inv.sales_user_id,
    v_grand_total,
    'applied',
    p_reason,
    auth.uid()
  )
  RETURNING id, credit_note_number INTO v_cn_id, v_cn_no;

  -- Bentuk Jurnal Pembalik Pendapatan, PPN, Piutang, serta Penyesuaian Persediaan / Kerugian Rusak
  v_journal_lines := v_journal_lines || jsonb_build_array(
    jsonb_build_object('account_code', '4102', 'debit', (v_grand_total - v_tax_total), 'credit', 0, 'customer_id', v_inv.customer_id, 'sales_user_id', v_inv.sales_user_id)
  );

  IF v_tax_total > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '2102', 'debit', v_tax_total, 'credit', 0, 'customer_id', v_inv.customer_id)
    );
  END IF;

  v_journal_lines := v_journal_lines || jsonb_build_array(
    jsonb_build_object('account_code', '1103', 'debit', 0, 'credit', v_grand_total, 'customer_id', v_inv.customer_id, 'sales_user_id', v_inv.sales_user_id)
  );

  IF v_good_cost > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '1105', 'debit', v_good_cost, 'credit', 0, 'warehouse_id', v_inv.warehouse_id)
    );
  END IF;

  IF v_dmg_cost > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '5103', 'debit', v_dmg_cost, 'credit', 0, 'warehouse_id', v_inv.warehouse_id)
    );
  END IF;

  IF (v_good_cost + v_dmg_cost) > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '5101', 'debit', 0, 'credit', (v_good_cost + v_dmg_cost), 'warehouse_id', v_inv.warehouse_id, 'sales_user_id', v_inv.sales_user_id)
    );
  END IF;

  v_journal_id := public.post_automated_journal(
    v_ret_date,
    'SALES_RETURN',
    v_ret_id,
    v_ret_no,
    'Retur penjualan ' || v_ret_no || ' (' || v_cn_no || ')',
    v_journal_lines,
    auth.uid()
  );

  UPDATE public.sales_returns SET journal_entry_id = v_journal_id WHERE id = v_ret_id;
  UPDATE public.credit_notes SET journal_entry_id = v_journal_id WHERE id = v_cn_id;

  IF v_tax_total > 0 AND v_tax_code_id IS NOT NULL THEN
    INSERT INTO public.tax_transactions (
      tax_date,
      tax_direction,
      tax_code_id,
      rate_percent,
      dpp_multiplier,
      dpp_amount,
      tax_amount,
      source_type,
      source_id,
      source_number,
      counterparty_name,
      counterparty_npwp,
      journal_entry_id
    )
    VALUES (
      v_ret_date,
      'output',
      v_tax_code_id,
      v_tax_rate,
      v_dpp_mult,
      -v_dpp_total,
      -v_tax_total,
      'CREDIT_NOTE',
      v_cn_id,
      v_cn_no,
      v_cust.name,
      v_cust.npwp,
      v_journal_id
    );
  END IF;

  RETURN v_ret_id;
END;
$$;

-- ============================================================================
-- BAGIAN D: PEMBELIAN & PEMBAYARAN SUPPLIER
-- ============================================================================

-- D1. Penerimaan Fisik Barang dari Supplier (Menambah Stok Gudang)
CREATE OR REPLACE FUNCTION public.rpc_receive_goods(
  p_receipt_date DATE,
  p_supplier_id UUID,
  p_warehouse_id UUID,
  p_purchase_order_id UUID DEFAULT NULL,
  p_supplier_delivery_note TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_items JSONB DEFAULT '[]'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_grn_id UUID;
  v_grn_no TEXT;
  v_elem JSONB;
  v_grn_item_id UUID;
  v_prod_id UUID;
  v_unit_id UUID;
  v_qty NUMERIC(18,4);
  v_est_cost NUMERIC(18,4);
  v_po_item_id UUID;
  v_total_accrual NUMERIC(18,2) := 0;
BEGIN
  IF NOT public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan mencatat penerimaan barang.';
  END IF;

  INSERT INTO public.goods_receipts (
    receipt_date,
    purchase_order_id,
    supplier_id,
    warehouse_id,
    supplier_delivery_note,
    status,
    notes,
    received_by
  )
  VALUES (
    COALESCE(p_receipt_date, public.jakarta_today()),
    p_purchase_order_id,
    p_supplier_id,
    p_warehouse_id,
    p_supplier_delivery_note,
    'received',
    p_notes,
    auth.uid()
  )
  RETURNING id, receipt_number INTO v_grn_id, v_grn_no;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_prod_id := (v_elem ->> 'product_id')::UUID;
    v_qty := COALESCE((v_elem ->> 'qty_received')::NUMERIC, 0);
    v_est_cost := COALESCE((v_elem ->> 'estimated_unit_cost')::NUMERIC, 0);
    v_po_item_id := NULLIF(v_elem ->> 'purchase_order_item_id', '')::UUID;

    IF v_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT base_unit_id INTO v_unit_id FROM public.products WHERE id = v_prod_id;

    INSERT INTO public.goods_receipt_items (
      goods_receipt_id,
      purchase_order_item_id,
      product_id,
      unit_id,
      qty_received,
      estimated_unit_cost,
      notes
    )
    VALUES (
      v_grn_id,
      v_po_item_id,
      v_prod_id,
      v_unit_id,
      v_qty,
      v_est_cost,
      v_elem ->> 'notes'
    )
    RETURNING id INTO v_grn_item_id;

    PERFORM public.record_stock_movement(
      COALESCE(p_receipt_date, public.jakarta_today()),
      p_warehouse_id,
      v_prod_id,
      'PURCHASE_IN',
      'GOODS_RECEIPT',
      v_grn_id,
      v_grn_no,
      v_unit_id,
      v_qty,
      1::SMALLINT,
      v_est_cost,
      v_grn_item_id,
      p_notes,
      false,
      auth.uid()
    );

    IF v_po_item_id IS NOT NULL THEN
      UPDATE public.purchase_order_items
      SET qty_received = qty_received + v_qty
      WHERE id = v_po_item_id;
    END IF;

    v_total_accrual := v_total_accrual + ROUND(v_qty * v_est_cost, 2);
  END LOOP;

  IF v_total_accrual > 0 THEN
    PERFORM public.post_automated_journal(
      COALESCE(p_receipt_date, public.jakarta_today()),
      'GOODS_RECEIPT',
      v_grn_id,
      v_grn_no,
      'Penerimaan barang gudang - ' || v_grn_no,
      jsonb_build_array(
        jsonb_build_object('account_code', '1105', 'debit', v_total_accrual, 'credit', 0, 'warehouse_id', p_warehouse_id, 'supplier_id', p_supplier_id),
        jsonb_build_object('account_code', '2103', 'debit', 0, 'credit', v_total_accrual, 'warehouse_id', p_warehouse_id, 'supplier_id', p_supplier_id)
      ),
      auth.uid()
    );
  END IF;

  RETURN v_grn_id;
END;
$$;

-- D2. Pencatatan Faktur Pembelian Supplier + Potongan Nota & Jurnal Utang
CREATE OR REPLACE FUNCTION public.rpc_post_supplier_invoice(
  p_supplier_invoice_number TEXT,
  p_invoice_date DATE,
  p_supplier_id UUID,
  p_warehouse_id UUID,
  p_goods_receipt_id UUID DEFAULT NULL,
  p_payment_type TEXT DEFAULT 'credit',
  p_payment_term_days INTEGER DEFAULT 0,
  p_header_discount_amount NUMERIC DEFAULT 0,
  p_discount_notes TEXT DEFAULT NULL,
  p_proof_file_path TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_items JSONB DEFAULT '[]'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pinv_id UUID;
  v_pinv_no TEXT;
  v_supp RECORD;
  v_elem JSONB;
  v_prod_id UUID;
  v_unit_id UUID;
  v_qty NUMERIC(18,4);
  v_gross_price NUMERIC(18,2);
  v_line_disc NUMERIC(18,2);
  v_net_unit_cost NUMERIC(18,4);
  v_tax_code_id UUID;
  v_tax_rate NUMERIC(6,4);
  v_dpp_mult NUMERIC(10,6);
  v_line_net NUMERIC(18,2);
  v_line_dpp NUMERIC(18,2);
  v_line_tax NUMERIC(18,2);
  v_line_total NUMERIC(18,2);
  v_subtotal NUMERIC(18,2) := 0;
  v_line_disc_total NUMERIC(18,2) := 0;
  v_dpp_total NUMERIC(18,2) := 0;
  v_tax_total NUMERIC(18,2) := 0;
  v_grand_total NUMERIC(18,2) := 0;
  v_grn_accrual NUMERIC(18,2) := 0;
  v_net_goods_cost NUMERIC(18,2) := 0;
  v_journal_lines JSONB := '[]'::jsonb;
  v_journal_id UUID;
  v_last_tax_code UUID;
  v_last_tax_rate NUMERIC(6,4) := 0;
  v_last_dpp_mult NUMERIC(10,6) := 1.000000;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mencatat faktur pembelian supplier.';
  END IF;

  SELECT * INTO v_supp FROM public.suppliers WHERE id = p_supplier_id;

  INSERT INTO public.supplier_invoices (
    supplier_invoice_number,
    invoice_date,
    due_date,
    goods_receipt_id,
    supplier_id,
    warehouse_id,
    payment_type,
    header_discount_amount,
    discount_notes,
    status,
    proof_file_path,
    notes,
    created_by,
    approved_by
  )
  VALUES (
    TRIM(p_supplier_invoice_number),
    COALESCE(p_invoice_date, public.jakarta_today()),
    COALESCE(p_invoice_date, public.jakarta_today()) + COALESCE(p_payment_term_days, 0),
    p_goods_receipt_id,
    p_supplier_id,
    p_warehouse_id,
    COALESCE(p_payment_type, 'credit'),
    COALESCE(p_header_discount_amount, 0),
    p_discount_notes,
    'issued',
    p_proof_file_path,
    p_notes,
    auth.uid(),
    auth.uid()
  )
  RETURNING id, invoice_number INTO v_pinv_id, v_pinv_no;

  FOR v_elem IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_prod_id := (v_elem ->> 'product_id')::UUID;
    v_qty := COALESCE((v_elem ->> 'qty')::NUMERIC, 0);
    v_gross_price := COALESCE((v_elem ->> 'gross_unit_price')::NUMERIC, 0);
    v_line_disc := COALESCE((v_elem ->> 'discount_amount')::NUMERIC, 0);
    v_tax_code_id := NULLIF(v_elem ->> 'tax_code_id', '')::UUID;
    v_tax_rate := COALESCE((v_elem ->> 'tax_rate_percent')::NUMERIC, 0);
    v_dpp_mult := COALESCE((v_elem ->> 'dpp_multiplier')::NUMERIC, 1.000000);

    IF v_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT base_unit_id INTO v_unit_id FROM public.products WHERE id = v_prod_id;

    v_line_net := GREATEST(0, ROUND(v_qty * v_gross_price, 2) - v_line_disc);
    v_net_unit_cost := ROUND(v_line_net / v_qty, 4);
    v_line_dpp := ROUND(v_line_net * v_dpp_mult, 2);
    v_line_tax := CASE WHEN v_tax_rate > 0 THEN ROUND(v_line_dpp * (v_tax_rate / 100.0), 2) ELSE 0 END;
    v_line_total := v_line_net + v_line_tax;

    IF v_line_tax > 0 THEN
      v_last_tax_code := v_tax_code_id;
      v_last_tax_rate := v_tax_rate;
      v_last_dpp_mult := v_dpp_mult;
    END IF;

    INSERT INTO public.supplier_invoice_items (
      supplier_invoice_id,
      product_id,
      unit_id,
      qty,
      gross_unit_price,
      discount_amount,
      net_unit_cost,
      tax_code_id,
      tax_rate_percent,
      dpp_multiplier,
      dpp_amount,
      tax_amount,
      line_total,
      notes
    )
    VALUES (
      v_pinv_id,
      v_prod_id,
      v_unit_id,
      v_qty,
      v_gross_price,
      v_line_disc,
      v_net_unit_cost,
      v_tax_code_id,
      v_tax_rate,
      v_dpp_mult,
      v_line_dpp,
      v_line_tax,
      v_line_total,
      v_elem ->> 'notes'
    );

    -- Jika pembelian langsung tanpa GRN sebelumnya, tambah stok saat faktur diposting
    IF p_goods_receipt_id IS NULL THEN
      PERFORM public.record_stock_movement(
        COALESCE(p_invoice_date, public.jakarta_today()),
        p_warehouse_id,
        v_prod_id,
        'PURCHASE_IN',
        'SUPPLIER_INVOICE',
        v_pinv_id,
        v_pinv_no,
        v_unit_id,
        v_qty,
        1::SMALLINT,
        v_net_unit_cost,
        NULL,
        p_notes,
        false,
        auth.uid()
      );
    END IF;

    v_subtotal := v_subtotal + ROUND(v_qty * v_gross_price, 2);
    v_line_disc_total := v_line_disc_total + v_line_disc;
    v_dpp_total := v_dpp_total + v_line_dpp;
    v_tax_total := v_tax_total + v_line_tax;
    v_grand_total := v_grand_total + v_line_total;
  END LOOP;

  v_grand_total := GREATEST(0, v_grand_total - COALESCE(p_header_discount_amount, 0));
  v_net_goods_cost := GREATEST(0, v_grand_total - v_tax_total);

  UPDATE public.supplier_invoices
  SET
    subtotal = v_subtotal,
    line_discount_total = v_line_disc_total,
    dpp_total = v_dpp_total,
    tax_total = v_tax_total,
    grand_total = v_grand_total
  WHERE id = v_pinv_id;

  IF p_goods_receipt_id IS NOT NULL THEN
    SELECT COALESCE(SUM(qty_received * estimated_unit_cost), 0) INTO v_grn_accrual
    FROM public.goods_receipt_items
    WHERE goods_receipt_id = p_goods_receipt_id;

    UPDATE public.goods_receipts SET status = 'invoiced' WHERE id = p_goods_receipt_id;

    IF v_grn_accrual > 0 THEN
      v_journal_lines := v_journal_lines || jsonb_build_array(
        jsonb_build_object('account_code', '2103', 'debit', v_grn_accrual, 'credit', 0, 'supplier_id', p_supplier_id)
      );
    END IF;

    IF v_net_goods_cost > v_grn_accrual THEN
      v_journal_lines := v_journal_lines || jsonb_build_array(
        jsonb_build_object('account_code', '5101', 'debit', (v_net_goods_cost - v_grn_accrual), 'credit', 0, 'supplier_id', p_supplier_id)
      );
    ELSIF v_grn_accrual > v_net_goods_cost THEN
      v_journal_lines := v_journal_lines || jsonb_build_array(
        jsonb_build_object('account_code', '5101', 'debit', 0, 'credit', (v_grn_accrual - v_net_goods_cost), 'supplier_id', p_supplier_id)
      );
    END IF;
  ELSE
    IF v_net_goods_cost > 0 THEN
      v_journal_lines := v_journal_lines || jsonb_build_array(
        jsonb_build_object('account_code', '1105', 'debit', v_net_goods_cost, 'credit', 0, 'warehouse_id', p_warehouse_id, 'supplier_id', p_supplier_id)
      );
    END IF;
  END IF;

  IF v_tax_total > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '1106', 'debit', v_tax_total, 'credit', 0, 'supplier_id', p_supplier_id)
    );
  END IF;

  IF v_grand_total > 0 THEN
    v_journal_lines := v_journal_lines || jsonb_build_array(
      jsonb_build_object('account_code', '2101', 'debit', 0, 'credit', v_grand_total, 'supplier_id', p_supplier_id)
    );
  END IF;

  v_journal_id := public.post_automated_journal(
    COALESCE(p_invoice_date, public.jakarta_today()),
    'SUPPLIER_INVOICE',
    v_pinv_id,
    v_pinv_no,
    'Faktur pembelian ' || v_pinv_no || ' - ' || COALESCE(v_supp.name, ''),
    v_journal_lines,
    auth.uid()
  );

  UPDATE public.supplier_invoices SET journal_entry_id = v_journal_id WHERE id = v_pinv_id;

  IF v_tax_total > 0 AND v_last_tax_code IS NOT NULL THEN
    INSERT INTO public.tax_transactions (
      tax_date,
      tax_direction,
      tax_code_id,
      rate_percent,
      dpp_multiplier,
      dpp_amount,
      tax_amount,
      source_type,
      source_id,
      source_number,
      counterparty_name,
      counterparty_npwp,
      journal_entry_id
    )
    VALUES (
      COALESCE(p_invoice_date, public.jakarta_today()),
      'input',
      v_last_tax_code,
      v_last_tax_rate,
      v_last_dpp_mult,
      v_dpp_total,
      v_tax_total,
      'SUPPLIER_INVOICE',
      v_pinv_id,
      v_pinv_no,
      COALESCE(v_supp.name, ''),
      v_supp.npwp,
      v_journal_id
    );
  END IF;

  RETURN v_pinv_id;
END;
$$;

-- D3. Pembayaran Utang ke Supplier + Alokasi & Jurnal Otomatis
CREATE OR REPLACE FUNCTION public.rpc_record_supplier_payment(
  p_payment_date DATE,
  p_supplier_id UUID,
  p_payment_method_id UUID,
  p_bank_id UUID DEFAULT NULL,
  p_amount NUMERIC DEFAULT 0,
  p_reference_number TEXT DEFAULT NULL,
  p_proof_file_path TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL,
  p_allocations JSONB DEFAULT '[]'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_spay_id UUID;
  v_spay_no TEXT;
  v_supp_name TEXT;
  v_cash_bank_code TEXT;
  v_journal_id UUID;
  v_alloc JSONB;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mencatat pembayaran supplier.';
  END IF;

  SELECT name INTO v_supp_name FROM public.suppliers WHERE id = p_supplier_id;

  INSERT INTO public.supplier_payments (
    payment_date,
    supplier_id,
    payment_method_id,
    bank_id,
    amount,
    reference_number,
    proof_file_path,
    status,
    paid_by,
    approved_by,
    notes
  )
  VALUES (
    COALESCE(p_payment_date, public.jakarta_today()),
    p_supplier_id,
    p_payment_method_id,
    p_bank_id,
    p_amount,
    p_reference_number,
    p_proof_file_path,
    'posted',
    auth.uid(),
    auth.uid(),
    p_notes
  )
  RETURNING id, payment_number INTO v_spay_id, v_spay_no;

  FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
  LOOP
    IF COALESCE((v_alloc ->> 'allocated_amount')::NUMERIC, 0) > 0 THEN
      INSERT INTO public.supplier_payment_allocations (
        supplier_payment_id,
        supplier_invoice_id,
        allocated_amount,
        allocated_date,
        created_by
      )
      VALUES (
        v_spay_id,
        (v_alloc ->> 'supplier_invoice_id')::UUID,
        (v_alloc ->> 'allocated_amount')::NUMERIC,
        COALESCE(p_payment_date, public.jakarta_today()),
        auth.uid()
      );
    END IF;
  END LOOP;

  v_cash_bank_code := public.get_payment_account_code(p_payment_method_id, p_bank_id);

  v_journal_id := public.post_automated_journal(
    COALESCE(p_payment_date, public.jakarta_today()),
    'SUPPLIER_PAYMENT',
    v_spay_id,
    v_spay_no,
    'Pembayaran supplier ' || v_spay_no || ' - ' || COALESCE(v_supp_name, ''),
    jsonb_build_array(
      jsonb_build_object('account_code', '2101', 'debit', p_amount, 'credit', 0, 'supplier_id', p_supplier_id),
      jsonb_build_object('account_code', v_cash_bank_code, 'debit', 0, 'credit', p_amount, 'supplier_id', p_supplier_id)
    ),
    auth.uid()
  );

  UPDATE public.supplier_payments SET journal_entry_id = v_journal_id WHERE id = v_spay_id;

  RETURN v_spay_id;
END;
$$;

-- ============================================================================
-- BAGIAN E: VERIFIKASI BIAYA OPERASIONAL & PENYELESAIAN KLAIM VOUCHER
-- ============================================================================

-- E1. Verifikasi Biaya Operasional oleh Finance Admin / Owner
CREATE OR REPLACE FUNCTION public.rpc_verify_operational_expense(
  p_expense_id UUID,
  p_decision TEXT,
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exp RECORD;
  v_exp_code TEXT;
  v_cash_bank_code TEXT;
  v_journal_id UUID;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat memverifikasi biaya operasional.';
  END IF;

  IF p_decision NOT IN ('verified', 'rejected') THEN
    RAISE EXCEPTION 'Keputusan verifikasi biaya tidak valid.';
  END IF;

  SELECT * INTO v_exp
  FROM public.operational_expenses
  WHERE id = p_expense_id
  FOR UPDATE;

  IF v_exp IS NULL OR v_exp.verification_status <> 'pending' THEN
    RAISE EXCEPTION 'Biaya operasional tidak ditemukan atau sudah diverifikasi.';
  END IF;

  IF v_exp.recorded_by = auth.uid() THEN
    RAISE EXCEPTION 'Pembuat catatan biaya tidak boleh memverifikasi catatannya sendiri.';
  END IF;

  UPDATE public.operational_expenses
  SET
    verification_status = p_decision,
    rejection_reason = CASE WHEN p_decision = 'rejected' THEN p_notes ELSE NULL END,
    verified_by = auth.uid(),
    verified_at = now()
  WHERE id = p_expense_id;

  INSERT INTO public.expense_approvals (
    operational_expense_id,
    action,
    decided_by,
    notes
  )
  VALUES (
    p_expense_id,
    p_decision,
    auth.uid(),
    p_notes
  );

  IF p_decision = 'verified' THEN
    v_exp_code := public.get_expense_account_code(v_exp.category_id);
    v_cash_bank_code := public.get_payment_account_code(v_exp.payment_method_id, v_exp.bank_id);

    v_journal_id := public.post_automated_journal(
      v_exp.expense_date,
      'OPERATIONAL_EXPENSE',
      v_exp.id,
      v_exp.expense_number,
      'Biaya operasional ' || v_exp.expense_number || ' - ' || v_exp.description,
      jsonb_build_array(
        jsonb_build_object('account_code', v_exp_code, 'debit', v_exp.amount, 'credit', 0),
        jsonb_build_object('account_code', v_cash_bank_code, 'debit', 0, 'credit', v_exp.amount)
      ),
      auth.uid()
    );

    UPDATE public.operational_expenses SET journal_entry_id = v_journal_id WHERE id = p_expense_id;
  END IF;

  RETURN p_expense_id;
END;
$$;

-- E2. Penyelesaian Klaim Voucher Promosi (Tunai/Transfer atau Potong Utang Supplier)
CREATE OR REPLACE FUNCTION public.rpc_settle_voucher_claim(
  p_settlement_date DATE,
  p_voucher_claim_id UUID,
  p_settlement_type TEXT,
  p_amount NUMERIC,
  p_payment_method_id UUID DEFAULT NULL,
  p_bank_id UUID DEFAULT NULL,
  p_supplier_invoice_id UUID DEFAULT NULL,
  p_reference_number TEXT DEFAULT NULL,
  p_proof_file_path TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_claim RECORD;
  v_vcs_id UUID;
  v_vcs_no TEXT;
  v_debit_code TEXT;
  v_journal_id UUID;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat menyelesaikan klaim voucher.';
  END IF;

  SELECT * INTO v_claim FROM public.voucher_claims WHERE id = p_voucher_claim_id;
  IF v_claim IS NULL THEN
    RAISE EXCEPTION 'Dokumen klaim voucher tidak ditemukan.';
  END IF;

  INSERT INTO public.voucher_claim_settlements (
    settlement_date,
    voucher_claim_id,
    settlement_type,
    payment_method_id,
    bank_id,
    supplier_invoice_id,
    amount,
    reference_number,
    proof_file_path,
    status,
    notes,
    created_by
  )
  VALUES (
    COALESCE(p_settlement_date, public.jakarta_today()),
    p_voucher_claim_id,
    p_settlement_type,
    p_payment_method_id,
    p_bank_id,
    p_supplier_invoice_id,
    p_amount,
    p_reference_number,
    p_proof_file_path,
    'verified',
    p_notes,
    auth.uid()
  )
  RETURNING id, settlement_number INTO v_vcs_id, v_vcs_no;

  IF p_settlement_type = 'cash_transfer' THEN
    v_debit_code := public.get_payment_account_code(p_payment_method_id, p_bank_id);
  ELSE
    v_debit_code := '2101';
  END IF;

  v_journal_id := public.post_automated_journal(
    COALESCE(p_settlement_date, public.jakarta_today()),
    'VOUCHER_SETTLEMENT',
    v_vcs_id,
    v_vcs_no,
    'Penyelesaian klaim voucher ' || v_claim.claim_number || ' (' || v_vcs_no || ')',
    jsonb_build_array(
      jsonb_build_object('account_code', v_debit_code, 'debit', p_amount, 'credit', 0, 'supplier_id', v_claim.supplier_id),
      jsonb_build_object('account_code', '1104', 'debit', 0, 'credit', p_amount, 'supplier_id', v_claim.supplier_id)
    ),
    auth.uid()
  );

  UPDATE public.voucher_claim_settlements SET journal_entry_id = v_journal_id WHERE id = v_vcs_id;

  RETURN v_vcs_id;
END;
$$;
