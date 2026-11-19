-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 011
-- Penguncian Keamanan Database (RLS), Storage Bukti Transaksi, & Kontrol Owner
-- ============================================================================

-- 1. Fungsi Khusus Owner: Kelola Role & Status Aktif Karyawan (Riwayat Tetap Aman)
CREATE OR REPLACE FUNCTION public.rpc_owner_manage_user(
  p_target_user_id UUID,
  p_role TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL,
  p_employee_code TEXT DEFAULT NULL,
  p_full_name TEXT DEFAULT NULL,
  p_phone TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_profile RECORD;
  v_old_role TEXT;
BEGIN
  IF public.get_my_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Hanya Owner yang berwenang mengelola pengguna dan role.';
  END IF;

  SELECT * INTO v_old_profile FROM public.profiles WHERE id = p_target_user_id FOR UPDATE;
  IF v_old_profile IS NULL THEN
    RAISE EXCEPTION 'Profil pengguna tidak ditemukan.';
  END IF;

  IF p_target_user_id = auth.uid() AND p_is_active = false THEN
    RAISE EXCEPTION 'Owner tidak dapat menonaktifkan akunnya sendiri.';
  END IF;

  SELECT role INTO v_old_role FROM public.user_roles WHERE user_id = p_target_user_id;

  UPDATE public.profiles
  SET
    employee_code = COALESCE(NULLIF(TRIM(p_employee_code), ''), employee_code),
    full_name = COALESCE(NULLIF(TRIM(p_full_name), ''), full_name),
    phone = COALESCE(p_phone, phone),
    is_active = COALESCE(p_is_active, is_active),
    deactivated_at = CASE
      WHEN p_is_active = false AND is_active = true THEN now()
      WHEN p_is_active = true THEN NULL
      ELSE deactivated_at
    END,
    deactivated_by = CASE
      WHEN p_is_active = false AND is_active = true THEN auth.uid()
      WHEN p_is_active = true THEN NULL
      ELSE deactivated_by
    END
  WHERE id = p_target_user_id;

  IF p_role IS NOT NULL THEN
    IF p_role NOT IN ('sales', 'warehouse', 'cashier', 'finance_admin', 'owner') THEN
      RAISE EXCEPTION 'Role pengguna tidak valid.';
    END IF;

    INSERT INTO public.user_roles (user_id, role, assigned_by, assigned_at)
    VALUES (p_target_user_id, p_role, auth.uid(), now())
    ON CONFLICT (user_id)
    DO UPDATE SET
      role = EXCLUDED.role,
      assigned_by = auth.uid(),
      assigned_at = now();
  END IF;

  PERFORM public.write_audit_log(
    'profiles',
    p_target_user_id,
    'UPDATE',
    'Pembaruan data pengguna atau role oleh Owner',
    jsonb_build_object('role', v_old_role, 'is_active', v_old_profile.is_active),
    jsonb_build_object('role', COALESCE(p_role, v_old_role), 'is_active', COALESCE(p_is_active, v_old_profile.is_active))
  );

  RETURN p_target_user_id;
END;
$$;

-- 2. Fungsi Khusus Owner: Ubah Pengaturan Sistem Fleksibel (PPN, Stok Negatif, Pembulatan)
CREATE OR REPLACE FUNCTION public.rpc_owner_update_setting(
  p_setting_key TEXT,
  p_setting_value JSONB
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_val JSONB;
BEGIN
  IF public.get_my_role() IS DISTINCT FROM 'owner' THEN
    RAISE EXCEPTION 'Hanya Owner yang berwenang mengubah pengaturan sistem.';
  END IF;

  SELECT setting_value INTO v_old_val
  FROM public.system_settings
  WHERE setting_key = p_setting_key
  FOR UPDATE;

  IF v_old_val IS NULL THEN
    RAISE EXCEPTION 'Kunci pengaturan % tidak ditemukan.', p_setting_key;
  END IF;

  UPDATE public.system_settings
  SET
    setting_value = p_setting_value,
    updated_by = auth.uid()
  WHERE setting_key = p_setting_key;

  PERFORM public.write_audit_log(
    'system_settings',
    NULL,
    'SETTING_CHANGE',
    'Perubahan pengaturan ' || p_setting_key,
    v_old_val,
    p_setting_value
  );

  RETURN p_setting_key;
END;
$$;

-- 3. Fungsi Cek Jumlah Stok Tersedia untuk Sales (Tanpa Membuka Nilai HPP Modal)
CREATE OR REPLACE FUNCTION public.rpc_get_available_stock(
  p_warehouse_id UUID DEFAULT NULL
)
RETURNS TABLE (
  warehouse_id UUID,
  warehouse_name TEXT,
  product_id UUID,
  sku TEXT,
  product_name TEXT,
  unit_id UUID,
  unit_name TEXT,
  qty_on_hand NUMERIC,
  standard_sell_price NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_active_user() THEN
    RAISE EXCEPTION 'Akun pengguna tidak aktif.';
  END IF;

  RETURN QUERY
  SELECT
    w.id,
    w.name,
    p.id,
    p.sku,
    p.name,
    u.id,
    u.name,
    COALESCE(sb.qty_on_hand, 0),
    p.standard_sell_price
  FROM public.products p
  CROSS JOIN public.warehouses w
  JOIN public.units u ON u.id = p.base_unit_id
  LEFT JOIN public.stock_balances sb
    ON sb.product_id = p.id AND sb.warehouse_id = w.id
  WHERE p.is_active = true
    AND w.is_active = true
    AND (p_warehouse_id IS NULL OR w.id = p_warehouse_id)
  ORDER BY w.name ASC, p.name ASC;
END;
$$;

-- 4. Aktifkan Row Level Security (RLS) pada Seluruh 55 Tabel
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_sequences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_units ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.banks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_transfer_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_adjustment_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.damaged_goods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_order_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_damage_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales_return_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_refunds ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.goods_receipt_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_invoice_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_payment_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operational_expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voucher_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.voucher_claim_settlements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounting_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tax_document_references ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 5. KEBIJAKAN AKSES PER KELOMPOK TABEL
-- ============================================================================

-- A. Profiles, User Roles, System Settings, Audit Logs, Document Sequences
DROP POLICY IF EXISTS p_profiles_select ON public.profiles;
CREATE POLICY p_profiles_select ON public.profiles
  FOR SELECT USING (id = auth.uid() OR public.is_active_user());

DROP POLICY IF EXISTS p_profiles_update_self ON public.profiles;
CREATE POLICY p_profiles_update_self ON public.profiles
  FOR UPDATE USING (id = auth.uid() AND public.is_active_user())
  WITH CHECK (id = auth.uid());

DROP POLICY IF EXISTS p_user_roles_select ON public.user_roles;
CREATE POLICY p_user_roles_select ON public.user_roles
  FOR SELECT USING (user_id = auth.uid() OR public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_system_settings_select ON public.system_settings;
CREATE POLICY p_system_settings_select ON public.system_settings
  FOR SELECT USING (public.is_active_user());

DROP POLICY IF EXISTS p_audit_logs_select ON public.audit_logs;
CREATE POLICY p_audit_logs_select ON public.audit_logs
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_audit_logs_insert ON public.audit_logs;
CREATE POLICY p_audit_logs_insert ON public.audit_logs
  FOR INSERT WITH CHECK (public.is_active_user());

-- B. Master Data (Dibaca seluruh user aktif; dikelola Finance Admin & Owner)
DROP POLICY IF EXISTS p_warehouses_select ON public.warehouses;
CREATE POLICY p_warehouses_select ON public.warehouses FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_warehouses_write ON public.warehouses;
CREATE POLICY p_warehouses_write ON public.warehouses FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_customers_select ON public.customers;
CREATE POLICY p_customers_select ON public.customers FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_customers_insert ON public.customers;
CREATE POLICY p_customers_insert ON public.customers FOR INSERT
  WITH CHECK (public.has_any_role(ARRAY['sales', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_customers_update ON public.customers;
CREATE POLICY p_customers_update ON public.customers FOR UPDATE
  USING (public.has_any_role(ARRAY['sales', 'finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['sales', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_suppliers_select ON public.suppliers;
CREATE POLICY p_suppliers_select ON public.suppliers FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_suppliers_write ON public.suppliers;
CREATE POLICY p_suppliers_write ON public.suppliers FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_units_select ON public.units;
CREATE POLICY p_units_select ON public.units FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_units_write ON public.units;
CREATE POLICY p_units_write ON public.units FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_products_select ON public.products;
CREATE POLICY p_products_select ON public.products FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_products_write ON public.products;
CREATE POLICY p_products_write ON public.products FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_product_units_select ON public.product_units;
CREATE POLICY p_product_units_select ON public.product_units FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_product_units_write ON public.product_units;
CREATE POLICY p_product_units_write ON public.product_units FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_banks_select ON public.banks;
CREATE POLICY p_banks_select ON public.banks FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_banks_write ON public.banks;
CREATE POLICY p_banks_write ON public.banks FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_payment_methods_select ON public.payment_methods;
CREATE POLICY p_payment_methods_select ON public.payment_methods FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_payment_methods_write ON public.payment_methods;
CREATE POLICY p_payment_methods_write ON public.payment_methods FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_tax_codes_select ON public.tax_codes;
CREATE POLICY p_tax_codes_select ON public.tax_codes FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_tax_codes_write ON public.tax_codes;
CREATE POLICY p_tax_codes_write ON public.tax_codes FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_tax_rates_select ON public.tax_rates;
CREATE POLICY p_tax_rates_select ON public.tax_rates FOR SELECT USING (public.is_active_user());
DROP POLICY IF EXISTS p_tax_rates_write ON public.tax_rates;
CREATE POLICY p_tax_rates_write ON public.tax_rates FOR ALL
  USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

-- C. Persediaan & Pergerakan Stok (HPP hanya terlihat oleh Gudang, Finance, Owner)
DROP POLICY IF EXISTS p_stock_balances_select ON public.stock_balances;
CREATE POLICY p_stock_balances_select ON public.stock_balances
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_stock_movements_select ON public.stock_movements;
CREATE POLICY p_stock_movements_select ON public.stock_movements
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_stock_transfers_select ON public.stock_transfers;
CREATE POLICY p_stock_transfers_select ON public.stock_transfers
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_stock_transfers_write ON public.stock_transfers;
CREATE POLICY p_stock_transfers_write ON public.stock_transfers
  FOR ALL USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_stock_transfer_items_select ON public.stock_transfer_items;
CREATE POLICY p_stock_transfer_items_select ON public.stock_transfer_items
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_stock_transfer_items_write ON public.stock_transfer_items;
CREATE POLICY p_stock_transfer_items_write ON public.stock_transfer_items
  FOR ALL USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_stock_adj_select ON public.stock_adjustment_requests;
CREATE POLICY p_stock_adj_select ON public.stock_adjustment_requests
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_stock_adj_insert ON public.stock_adjustment_requests;
CREATE POLICY p_stock_adj_insert ON public.stock_adjustment_requests
  FOR INSERT WITH CHECK (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_stock_adj_update ON public.stock_adjustment_requests;
CREATE POLICY p_stock_adj_update ON public.stock_adjustment_requests
  FOR UPDATE USING (
    (status = 'draft' AND requested_by = auth.uid())
    OR public.has_any_role(ARRAY['finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_stock_adj_items_select ON public.stock_adjustment_items;
CREATE POLICY p_stock_adj_items_select ON public.stock_adjustment_items
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_stock_adj_items_write ON public.stock_adjustment_items;
CREATE POLICY p_stock_adj_items_write ON public.stock_adjustment_items
  FOR ALL USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_damaged_goods_select ON public.damaged_goods;
CREATE POLICY p_damaged_goods_select ON public.damaged_goods
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_damaged_goods_update ON public.damaged_goods;
CREATE POLICY p_damaged_goods_update ON public.damaged_goods
  FOR UPDATE USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

-- D. Sales Order & Pengiriman (Sales hanya melihat miliknya sendiri)
DROP POLICY IF EXISTS p_sales_orders_select ON public.sales_orders;
CREATE POLICY p_sales_orders_select ON public.sales_orders
  FOR SELECT USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid())
    OR (public.get_my_role() IN ('warehouse', 'cashier') AND status <> 'draft')
    OR public.has_any_role(ARRAY['finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_sales_orders_insert ON public.sales_orders;
CREATE POLICY p_sales_orders_insert ON public.sales_orders
  FOR INSERT WITH CHECK (
    public.has_any_role(ARRAY['sales', 'owner'])
    AND (public.get_my_role() <> 'sales' OR sales_user_id = auth.uid())
  );

DROP POLICY IF EXISTS p_sales_orders_update ON public.sales_orders;
CREATE POLICY p_sales_orders_update ON public.sales_orders
  FOR UPDATE USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid() AND status = 'draft')
    OR public.has_any_role(ARRAY['finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_sales_orders_delete ON public.sales_orders;
CREATE POLICY p_sales_orders_delete ON public.sales_orders
  FOR DELETE USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid() AND status = 'draft')
    OR (public.get_my_role() = 'owner' AND status = 'draft')
  );

DROP POLICY IF EXISTS p_so_items_select ON public.sales_order_items;
CREATE POLICY p_so_items_select ON public.sales_order_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.sales_orders so
      WHERE so.id = sales_order_items.sales_order_id
        AND (
          (public.get_my_role() = 'sales' AND so.sales_user_id = auth.uid())
          OR (public.get_my_role() IN ('warehouse', 'cashier') AND so.status <> 'draft')
          OR public.has_any_role(ARRAY['finance_admin', 'owner'])
        )
    )
  );

DROP POLICY IF EXISTS p_so_items_write ON public.sales_order_items;
CREATE POLICY p_so_items_write ON public.sales_order_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.sales_orders so
      WHERE so.id = sales_order_items.sales_order_id
        AND (
          (so.status = 'draft' AND (so.sales_user_id = auth.uid() OR public.get_my_role() = 'owner'))
          OR public.get_my_role() = 'owner'
        )
    )
  );

DROP POLICY IF EXISTS p_so_approvals_select ON public.sales_order_approvals;
CREATE POLICY p_so_approvals_select ON public.sales_order_approvals
  FOR SELECT USING (
    public.has_any_role(ARRAY['finance_admin', 'owner'])
    OR EXISTS (
      SELECT 1 FROM public.sales_orders so
      WHERE so.id = sales_order_approvals.sales_order_id
        AND so.sales_user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS p_deliveries_select ON public.deliveries;
CREATE POLICY p_deliveries_select ON public.deliveries
  FOR SELECT USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid())
    OR public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_delivery_items_select ON public.delivery_items;
CREATE POLICY p_delivery_items_select ON public.delivery_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.deliveries d
      WHERE d.id = delivery_items.delivery_id
        AND (
          (public.get_my_role() = 'sales' AND d.sales_user_id = auth.uid())
          OR public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner'])
        )
    )
  );

DROP POLICY IF EXISTS p_delivery_damage_select ON public.delivery_damage_reports;
CREATE POLICY p_delivery_damage_select ON public.delivery_damage_reports
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner']));

-- E. Faktur Penjualan, Retur, Nota Kredit, Pembayaran & Refund Pelanggan
DROP POLICY IF EXISTS p_sales_invoices_select ON public.sales_invoices;
CREATE POLICY p_sales_invoices_select ON public.sales_invoices
  FOR SELECT USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid())
    OR public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_sales_invoice_items_select ON public.sales_invoice_items;
CREATE POLICY p_sales_invoice_items_select ON public.sales_invoice_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.sales_invoices si
      WHERE si.id = sales_invoice_items.sales_invoice_id
        AND (
          (public.get_my_role() = 'sales' AND si.sales_user_id = auth.uid())
          OR public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner'])
        )
    )
  );

DROP POLICY IF EXISTS p_sales_returns_select ON public.sales_returns;
CREATE POLICY p_sales_returns_select ON public.sales_returns
  FOR SELECT USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid())
    OR public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_sales_return_items_select ON public.sales_return_items;
CREATE POLICY p_sales_return_items_select ON public.sales_return_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.sales_returns sr
      WHERE sr.id = sales_return_items.sales_return_id
        AND (
          (public.get_my_role() = 'sales' AND sr.sales_user_id = auth.uid())
          OR public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner'])
        )
    )
  );

DROP POLICY IF EXISTS p_credit_notes_select ON public.credit_notes;
CREATE POLICY p_credit_notes_select ON public.credit_notes
  FOR SELECT USING (
    (public.get_my_role() = 'sales' AND sales_user_id = auth.uid())
    OR public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_cust_payments_select ON public.customer_payments;
CREATE POLICY p_cust_payments_select ON public.customer_payments
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_cust_pay_alloc_select ON public.customer_payment_allocations;
CREATE POLICY p_cust_pay_alloc_select ON public.customer_payment_allocations
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_cust_refunds_select ON public.customer_refunds;
CREATE POLICY p_cust_refunds_select ON public.customer_refunds
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_cust_refunds_insert ON public.customer_refunds;
CREATE POLICY p_cust_refunds_insert ON public.customer_refunds
  FOR INSERT WITH CHECK (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_cust_refunds_update ON public.customer_refunds;
CREATE POLICY p_cust_refunds_update ON public.customer_refunds
  FOR UPDATE USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

-- F. Pembelian & Utang Supplier
DROP POLICY IF EXISTS p_po_select ON public.purchase_orders;
CREATE POLICY p_po_select ON public.purchase_orders
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_po_write ON public.purchase_orders;
CREATE POLICY p_po_write ON public.purchase_orders
  FOR ALL USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_po_items_select ON public.purchase_order_items;
CREATE POLICY p_po_items_select ON public.purchase_order_items
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_po_items_write ON public.purchase_order_items;
CREATE POLICY p_po_items_write ON public.purchase_order_items
  FOR ALL USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_grn_select ON public.goods_receipts;
CREATE POLICY p_grn_select ON public.goods_receipts
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_grn_items_select ON public.goods_receipt_items;
CREATE POLICY p_grn_items_select ON public.goods_receipt_items
  FOR SELECT USING (public.has_any_role(ARRAY['warehouse', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_supp_inv_select ON public.supplier_invoices;
CREATE POLICY p_supp_inv_select ON public.supplier_invoices
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_supp_inv_items_select ON public.supplier_invoice_items;
CREATE POLICY p_supp_inv_items_select ON public.supplier_invoice_items
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_supp_pay_select ON public.supplier_payments;
CREATE POLICY p_supp_pay_select ON public.supplier_payments
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_supp_pay_alloc_select ON public.supplier_payment_allocations;
CREATE POLICY p_supp_pay_alloc_select ON public.supplier_payment_allocations
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

-- G. Biaya Operasional & Klaim Voucher Promosi
DROP POLICY IF EXISTS p_exp_cat_select ON public.expense_categories;
CREATE POLICY p_exp_cat_select ON public.expense_categories
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_exp_cat_write ON public.expense_categories;
CREATE POLICY p_exp_cat_write ON public.expense_categories
  FOR ALL USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_op_exp_select ON public.operational_expenses;
CREATE POLICY p_op_exp_select ON public.operational_expenses
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_op_exp_insert ON public.operational_expenses;
CREATE POLICY p_op_exp_insert ON public.operational_expenses
  FOR INSERT WITH CHECK (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_exp_app_select ON public.expense_approvals;
CREATE POLICY p_exp_app_select ON public.expense_approvals
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));

DROP POLICY IF EXISTS p_voucher_claims_select ON public.voucher_claims;
CREATE POLICY p_voucher_claims_select ON public.voucher_claims
  FOR SELECT USING (public.has_any_role(ARRAY['cashier', 'finance_admin', 'owner']));
DROP POLICY IF EXISTS p_voucher_claims_write ON public.voucher_claims;
CREATE POLICY p_voucher_claims_write ON public.voucher_claims
  FOR ALL USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_vcs_select ON public.voucher_claim_settlements;
CREATE POLICY p_vcs_select ON public.voucher_claim_settlements
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

-- H. Akuntansi & Pajak (Hanya Finance Admin & Owner)
DROP POLICY IF EXISTS p_coa_select ON public.chart_of_accounts;
CREATE POLICY p_coa_select ON public.chart_of_accounts
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));
DROP POLICY IF EXISTS p_coa_write ON public.chart_of_accounts;
CREATE POLICY p_coa_write ON public.chart_of_accounts
  FOR ALL USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_acc_periods_select ON public.accounting_periods;
CREATE POLICY p_acc_periods_select ON public.accounting_periods
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));
DROP POLICY IF EXISTS p_acc_periods_update ON public.accounting_periods;
CREATE POLICY p_acc_periods_update ON public.accounting_periods
  FOR UPDATE USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_journal_entries_select ON public.journal_entries;
CREATE POLICY p_journal_entries_select ON public.journal_entries
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_journal_lines_select ON public.journal_lines;
CREATE POLICY p_journal_lines_select ON public.journal_lines
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_tax_tx_select ON public.tax_transactions;
CREATE POLICY p_tax_tx_select ON public.tax_transactions
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));

DROP POLICY IF EXISTS p_tax_doc_refs_select ON public.tax_document_references;
CREATE POLICY p_tax_doc_refs_select ON public.tax_document_references
  FOR SELECT USING (public.has_any_role(ARRAY['finance_admin', 'owner']));
DROP POLICY IF EXISTS p_tax_doc_refs_write ON public.tax_document_references;
CREATE POLICY p_tax_doc_refs_write ON public.tax_document_references
  FOR ALL USING (public.has_any_role(ARRAY['finance_admin', 'owner']))
  WITH CHECK (public.has_any_role(ARRAY['finance_admin', 'owner']));

-- ============================================================================
-- 6. SUPABASE STORAGE PRIVAT UNTUK BUKTI TRANSAKSI & DOKUMEN
-- ============================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'transaction-proofs',
  'transaction-proofs',
  false,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS p_storage_proofs_select ON storage.objects;
CREATE POLICY p_storage_proofs_select ON storage.objects
  FOR SELECT USING (
    bucket_id = 'transaction-proofs'
    AND public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_storage_proofs_insert ON storage.objects;
CREATE POLICY p_storage_proofs_insert ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'transaction-proofs'
    AND public.has_any_role(ARRAY['warehouse', 'cashier', 'finance_admin', 'owner'])
  );

DROP POLICY IF EXISTS p_storage_proofs_delete ON storage.objects;
CREATE POLICY p_storage_proofs_delete ON storage.objects
  FOR DELETE USING (
    bucket_id = 'transaction-proofs'
    AND public.has_any_role(ARRAY['finance_admin', 'owner'])
  );

-- ============================================================================
-- 7. IZINKAN EKSEKUSI FUNGSI RPC UNTUK PENGGUNA TERAUTENTIKASI
-- ============================================================================
GRANT EXECUTE ON FUNCTION public.is_active_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_any_role(TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_system_setting(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_effective_tax_rate(UUID, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_available_stock(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_opening_stock(DATE, UUID, UUID, NUMERIC, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_complete_stock_transfer(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_decide_so_approval(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_owner_override_so_price(UUID, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_owner_reattribute_so_sales(UUID, UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_dispatch_sales_order(UUID, DATE, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_delivery_result(UUID, TEXT, TEXT, DATE, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_issue_sales_invoice(UUID, DATE, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_customer_payment(DATE, UUID, UUID, UUID, NUMERIC, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_verify_customer_payment(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_process_sales_return(DATE, UUID, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_receive_goods(DATE, UUID, UUID, UUID, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_post_supplier_invoice(TEXT, DATE, UUID, UUID, UUID, TEXT, INTEGER, NUMERIC, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_supplier_payment(DATE, UUID, UUID, UUID, NUMERIC, TEXT, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_verify_operational_expense(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_settle_voucher_claim(DATE, UUID, TEXT, NUMERIC, UUID, UUID, UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_decide_stock_adjustment(UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_warehouse_damage(DATE, UUID, UUID, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_sales_performance(DATE, DATE, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_trial_balance(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_profit_and_loss(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_balance_sheet(DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_cash_flow(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_tax_summary(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_dashboard_summary(DATE, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_owner_manage_user(UUID, TEXT, BOOLEAN, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_owner_update_setting(TEXT, JSONB) TO authenticated;
