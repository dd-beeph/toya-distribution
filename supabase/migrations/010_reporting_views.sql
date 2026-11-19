-- ============================================================================
-- TOYA DISTRIBUTION - MIGRATION 010
-- Mesin Laporan Operasional, Kinerja Sales, Keuangan, Pajak, & Dashboard
-- ============================================================================

-- 1. View Nilai Persediaan & Status Stok per Gudang dan Produk
CREATE OR REPLACE VIEW public.view_inventory_valuation
WITH (security_invoker = true)
AS
SELECT
  sb.id,
  sb.warehouse_id,
  w.code AS warehouse_code,
  w.name AS warehouse_name,
  sb.product_id,
  p.sku,
  p.name AS product_name,
  p.brand,
  p.category,
  u.code AS unit_code,
  u.name AS unit_name,
  sb.qty_on_hand,
  sb.avg_unit_cost,
  sb.total_value,
  p.min_stock_alert,
  (sb.qty_on_hand <= p.min_stock_alert) AS is_low_stock,
  sb.last_movement_at,
  sb.updated_at
FROM public.stock_balances sb
JOIN public.warehouses w ON w.id = sb.warehouse_id
JOIN public.products p ON p.id = sb.product_id
JOIN public.units u ON u.id = p.base_unit_id;

-- 2. View Piutang Pelanggan & Umur Piutang (Aging)
CREATE OR REPLACE VIEW public.view_customer_receivables
WITH (security_invoker = true)
AS
SELECT
  si.id AS invoice_id,
  si.invoice_number,
  si.invoice_date,
  si.due_date,
  si.customer_id,
  c.code AS customer_code,
  c.name AS customer_name,
  c.phone AS customer_phone,
  si.sales_user_id,
  pr.full_name AS sales_name,
  si.warehouse_id,
  w.name AS warehouse_name,
  si.payment_type,
  si.grand_total,
  si.paid_amount,
  si.credit_note_amount,
  si.balance_due,
  si.status,
  GREATEST(0, (public.jakarta_today() - si.due_date))::INTEGER AS days_overdue,
  CASE
    WHEN si.balance_due <= 0 THEN 'Lunas'
    WHEN public.jakarta_today() <= si.due_date THEN 'Belum Jatuh Tempo'
    WHEN (public.jakarta_today() - si.due_date) BETWEEN 1 AND 30 THEN '1 - 30 Hari'
    WHEN (public.jakarta_today() - si.due_date) BETWEEN 31 AND 60 THEN '31 - 60 Hari'
    ELSE 'Lebih dari 60 Hari'
  END AS aging_bucket
FROM public.sales_invoices si
JOIN public.customers c ON c.id = si.customer_id
JOIN public.profiles pr ON pr.id = si.sales_user_id
JOIN public.warehouses w ON w.id = si.warehouse_id
WHERE si.status IN ('issued', 'partial', 'paid');

-- 3. View Utang Supplier & Umur Utang (Aging)
CREATE OR REPLACE VIEW public.view_supplier_payables
WITH (security_invoker = true)
AS
SELECT
  pinv.id AS supplier_invoice_id,
  pinv.invoice_number,
  pinv.supplier_invoice_number,
  pinv.invoice_date,
  pinv.due_date,
  pinv.supplier_id,
  s.code AS supplier_code,
  s.name AS supplier_name,
  pinv.warehouse_id,
  w.name AS warehouse_name,
  pinv.grand_total,
  pinv.paid_amount,
  pinv.voucher_offset_amount,
  pinv.balance_due,
  pinv.status,
  GREATEST(0, (public.jakarta_today() - pinv.due_date))::INTEGER AS days_overdue,
  CASE
    WHEN pinv.balance_due <= 0 THEN 'Lunas'
    WHEN public.jakarta_today() <= pinv.due_date THEN 'Belum Jatuh Tempo'
    WHEN (public.jakarta_today() - pinv.due_date) BETWEEN 1 AND 30 THEN '1 - 30 Hari'
    WHEN (public.jakarta_today() - pinv.due_date) BETWEEN 31 AND 60 THEN '31 - 60 Hari'
    ELSE 'Lebih dari 60 Hari'
  END AS aging_bucket
FROM public.supplier_invoices pinv
JOIN public.suppliers s ON s.id = pinv.supplier_id
JOIN public.warehouses w ON w.id = pinv.warehouse_id
WHERE pinv.status IN ('issued', 'partial', 'paid');

-- 4. View Rincian Buku Besar & Jurnal Umum Terpadu
CREATE OR REPLACE VIEW public.view_general_ledger_lines
WITH (security_invoker = true)
AS
SELECT
  jl.id AS line_id,
  je.id AS journal_entry_id,
  je.journal_number,
  je.journal_date,
  je.source_type,
  je.source_id,
  je.source_number,
  je.description AS journal_description,
  je.status AS journal_status,
  jl.line_no,
  jl.account_id,
  coa.code AS account_code,
  coa.name AS account_name,
  coa.account_type,
  coa.normal_balance,
  jl.description AS line_description,
  jl.debit,
  jl.credit,
  jl.customer_id,
  c.name AS customer_name,
  jl.supplier_id,
  s.name AS supplier_name,
  jl.sales_user_id,
  pr.full_name AS sales_name,
  jl.warehouse_id,
  w.name AS warehouse_name
FROM public.journal_lines jl
JOIN public.journal_entries je ON je.id = jl.journal_entry_id
JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
LEFT JOIN public.customers c ON c.id = jl.customer_id
LEFT JOIN public.suppliers s ON s.id = jl.supplier_id
LEFT JOIN public.profiles pr ON pr.id = jl.sales_user_id
LEFT JOIN public.warehouses w ON w.id = jl.warehouse_id;

-- 5. Laporan Omzet dan Kinerja per Sales (Mendukung Filter Tanggal SO / Faktur)
CREATE OR REPLACE FUNCTION public.rpc_get_sales_performance(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL,
  p_date_basis TEXT DEFAULT 'invoice_date'
)
RETURNS TABLE (
  sales_user_id UUID,
  employee_code TEXT,
  sales_name TEXT,
  is_active BOOLEAN,
  total_so_count BIGINT,
  cancelled_so_count BIGINT,
  issued_invoice_count BIGINT,
  total_order_value NUMERIC,
  gross_realized_revenue NUMERIC,
  total_returns NUMERIC,
  total_credit_notes NUMERIC,
  net_realized_revenue NUMERIC,
  collected_amount NUMERIC,
  outstanding_receivable NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_uid UUID;
  v_start DATE;
  v_end DATE;
BEGIN
  v_role := public.get_my_role();
  v_uid := auth.uid();

  IF v_role NOT IN ('sales', 'finance_admin', 'owner') THEN
    RAISE EXCEPTION 'Anda tidak memiliki kewenangan mengakses laporan kinerja Sales.';
  END IF;

  v_start := COALESCE(p_start_date, DATE '2000-01-01');
  v_end := COALESCE(p_end_date, DATE '2099-12-31');

  RETURN QUERY
  WITH sales_users AS (
    SELECT DISTINCT p.id, p.employee_code, p.full_name, p.is_active
    FROM public.profiles p
    LEFT JOIN public.user_roles ur ON ur.user_id = p.id
    WHERE (
      ur.role = 'sales'
      OR EXISTS (SELECT 1 FROM public.sales_orders so WHERE so.sales_user_id = p.id)
      OR EXISTS (SELECT 1 FROM public.sales_invoices si WHERE si.sales_user_id = p.id)
    )
    AND (v_role <> 'sales' OR p.id = v_uid)
  ),
  so_agg AS (
    SELECT
      so.sales_user_id,
      COUNT(*) FILTER (WHERE so.status <> 'cancelled') AS active_so_count,
      COUNT(*) FILTER (WHERE so.status = 'cancelled') AS cancel_so_count,
      COALESCE(SUM(so.grand_total) FILTER (WHERE so.status <> 'cancelled'), 0) AS order_val
    FROM public.sales_orders so
    WHERE so.order_date BETWEEN v_start AND v_end
    GROUP BY so.sales_user_id
  ),
  inv_agg AS (
    SELECT
      si.sales_user_id,
      COUNT(*) AS inv_count,
      COALESCE(SUM(si.grand_total), 0) AS gross_rev,
      COALESCE(SUM(si.paid_amount), 0) AS paid_val,
      COALESCE(SUM(si.balance_due), 0) AS due_val
    FROM public.sales_invoices si
    JOIN public.sales_orders so ON so.id = si.sales_order_id
    WHERE si.status IN ('issued', 'partial', 'paid')
      AND (
        CASE WHEN p_date_basis = 'order_date' THEN so.order_date ELSE si.invoice_date END
      ) BETWEEN v_start AND v_end
    GROUP BY si.sales_user_id
  ),
  ret_agg AS (
    SELECT
      sr.sales_user_id,
      COALESCE(SUM(sr.grand_total), 0) AS ret_val
    FROM public.sales_returns sr
    JOIN public.sales_invoices si ON si.id = sr.sales_invoice_id
    JOIN public.sales_orders so ON so.id = si.sales_order_id
    WHERE sr.status = 'completed'
      AND (
        CASE WHEN p_date_basis = 'order_date' THEN so.order_date ELSE sr.return_date END
      ) BETWEEN v_start AND v_end
    GROUP BY sr.sales_user_id
  ),
  cn_agg AS (
    SELECT
      cn.sales_user_id,
      COALESCE(SUM(cn.amount), 0) AS cn_val
    FROM public.credit_notes cn
    JOIN public.sales_invoices si ON si.id = cn.sales_invoice_id
    JOIN public.sales_orders so ON so.id = si.sales_order_id
    WHERE cn.status = 'applied'
      AND (
        CASE WHEN p_date_basis = 'order_date' THEN so.order_date ELSE cn.credit_note_date END
      ) BETWEEN v_start AND v_end
    GROUP BY cn.sales_user_id
  )
  SELECT
    su.id,
    su.employee_code,
    su.full_name,
    su.is_active,
    COALESCE(sa.active_so_count, 0),
    COALESCE(sa.cancel_so_count, 0),
    COALESCE(ia.inv_count, 0),
    COALESCE(sa.order_val, 0),
    COALESCE(ia.gross_rev, 0),
    COALESCE(ra.ret_val, 0),
    COALESCE(ca.cn_val, 0),
    (COALESCE(ia.gross_rev, 0) - COALESCE(ca.cn_val, 0)) AS net_rev,
    COALESCE(ia.paid_val, 0),
    COALESCE(ia.due_val, 0)
  FROM sales_users su
  LEFT JOIN so_agg sa ON sa.sales_user_id = su.id
  LEFT JOIN inv_agg ia ON ia.sales_user_id = su.id
  LEFT JOIN ret_agg ra ON ra.sales_user_id = su.id
  LEFT JOIN cn_agg ca ON ca.sales_user_id = su.id
  ORDER BY net_rev DESC, su.full_name ASC;
END;
$$;

-- 6. Laporan Neraca Saldo (Trial Balance)
CREATE OR REPLACE FUNCTION public.rpc_get_trial_balance(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
  account_id UUID,
  account_code TEXT,
  account_name TEXT,
  account_type TEXT,
  normal_balance TEXT,
  opening_debit NUMERIC,
  opening_credit NUMERIC,
  period_debit NUMERIC,
  period_credit NUMERIC,
  ending_debit NUMERIC,
  ending_credit NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start DATE;
  v_end DATE;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mengakses Neraca Saldo.';
  END IF;

  v_start := COALESCE(p_start_date, DATE '2000-01-01');
  v_end := COALESCE(p_end_date, DATE '2099-12-31');

  RETURN QUERY
  WITH line_sums AS (
    SELECT
      jl.account_id,
      COALESCE(SUM(jl.debit) FILTER (WHERE je.journal_date < v_start), 0) AS op_dr,
      COALESCE(SUM(jl.credit) FILTER (WHERE je.journal_date < v_start), 0) AS op_cr,
      COALESCE(SUM(jl.debit) FILTER (WHERE je.journal_date BETWEEN v_start AND v_end), 0) AS pr_dr,
      COALESCE(SUM(jl.credit) FILTER (WHERE je.journal_date BETWEEN v_start AND v_end), 0) AS pr_cr
    FROM public.journal_lines jl
    JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    WHERE je.status = 'posted'
    GROUP BY jl.account_id
  ),
  calc AS (
    SELECT
      coa.id,
      coa.code,
      coa.name,
      coa.account_type,
      coa.normal_balance,
      GREATEST(0, COALESCE(ls.op_dr, 0) - COALESCE(ls.op_cr, 0)) AS open_dr,
      GREATEST(0, COALESCE(ls.op_cr, 0) - COALESCE(ls.op_dr, 0)) AS open_cr,
      COALESCE(ls.pr_dr, 0) AS per_dr,
      COALESCE(ls.pr_cr, 0) AS per_cr,
      (COALESCE(ls.op_dr, 0) + COALESCE(ls.pr_dr, 0)) - (COALESCE(ls.op_cr, 0) + COALESCE(ls.pr_cr, 0)) AS net_end
    FROM public.chart_of_accounts coa
    LEFT JOIN line_sums ls ON ls.account_id = coa.id
    WHERE coa.is_header = false
  )
  SELECT
    c.id,
    c.code,
    c.name,
    c.account_type,
    c.normal_balance,
    c.open_dr,
    c.open_cr,
    c.per_dr,
    c.per_cr,
    GREATEST(0, c.net_end) AS end_dr,
    GREATEST(0, -c.net_end) AS end_cr
  FROM calc c
  WHERE c.open_dr <> 0 OR c.open_cr <> 0 OR c.per_dr <> 0 OR c.per_cr <> 0
  ORDER BY c.code ASC;
END;
$$;

-- 7. Laporan Laba Rugi (Profit & Loss Statement)
CREATE OR REPLACE FUNCTION public.rpc_get_profit_and_loss(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
  account_id UUID,
  account_code TEXT,
  account_name TEXT,
  account_type TEXT,
  amount NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start DATE;
  v_end DATE;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mengakses Laporan Laba Rugi.';
  END IF;

  v_start := COALESCE(p_start_date, DATE '2000-01-01');
  v_end := COALESCE(p_end_date, DATE '2099-12-31');

  RETURN QUERY
  SELECT
    coa.id,
    coa.code,
    coa.name,
    coa.account_type,
    CASE
      WHEN coa.account_type = 'revenue' THEN COALESCE(SUM(jl.credit - jl.debit), 0)
      ELSE COALESCE(SUM(jl.debit - jl.credit), 0)
    END AS net_amount
  FROM public.chart_of_accounts coa
  LEFT JOIN public.journal_lines jl ON jl.account_id = coa.id
  LEFT JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    AND je.status = 'posted'
    AND je.journal_date BETWEEN v_start AND v_end
  WHERE coa.account_type IN ('revenue', 'cogs', 'expense')
    AND coa.is_header = false
  GROUP BY coa.id, coa.code, coa.name, coa.account_type
  HAVING COALESCE(SUM(jl.debit + jl.credit), 0) <> 0
  ORDER BY coa.code ASC;
END;
$$;

-- 8. Laporan Neraca (Balance Sheet per Tanggal Posisi)
CREATE OR REPLACE FUNCTION public.rpc_get_balance_sheet(
  p_as_of_date DATE DEFAULT NULL
)
RETURNS TABLE (
  account_code TEXT,
  account_name TEXT,
  account_type TEXT,
  balance NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_as_of DATE;
  v_current_earnings NUMERIC(18,2);
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mengakses Laporan Neraca.';
  END IF;

  v_as_of := COALESCE(p_as_of_date, public.jakarta_today());

  SELECT COALESCE(SUM(
    CASE
      WHEN coa.account_type = 'revenue' THEN (jl.credit - jl.debit)
      ELSE -(jl.debit - jl.credit)
    END
  ), 0)
  INTO v_current_earnings
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.status = 'posted'
    AND je.journal_date <= v_as_of
    AND coa.account_type IN ('revenue', 'cogs', 'expense');

  RETURN QUERY
  SELECT
    coa.code,
    coa.name,
    coa.account_type,
    CASE
      WHEN coa.account_type = 'asset' THEN COALESCE(SUM(jl.debit - jl.credit), 0)
      ELSE COALESCE(SUM(jl.credit - jl.debit), 0)
    END AS bal
  FROM public.chart_of_accounts coa
  LEFT JOIN public.journal_lines jl ON jl.account_id = coa.id
  LEFT JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    AND je.status = 'posted'
    AND je.journal_date <= v_as_of
  WHERE coa.account_type IN ('asset', 'liability', 'equity')
    AND coa.is_header = false
  GROUP BY coa.code, coa.name, coa.account_type
  HAVING COALESCE(SUM(jl.debit + jl.credit), 0) <> 0

  UNION ALL

  SELECT
    '3999'::TEXT,
    'Laba / (Rugi) Periode Berjalan'::TEXT,
    'equity'::TEXT,
    COALESCE(v_current_earnings, 0)
  WHERE COALESCE(v_current_earnings, 0) <> 0

  ORDER BY 1 ASC;
END;
$$;

-- 9. Laporan Arus Kas (Cash Flow Statement)
CREATE OR REPLACE FUNCTION public.rpc_get_cash_flow(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
  activity_group TEXT,
  source_type TEXT,
  cash_in NUMERIC,
  cash_out NUMERIC,
  net_cash NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start DATE;
  v_end DATE;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mengakses Laporan Arus Kas.';
  END IF;

  v_start := COALESCE(p_start_date, DATE '2000-01-01');
  v_end := COALESCE(p_end_date, DATE '2099-12-31');

  RETURN QUERY
  SELECT
    CASE
      WHEN je.source_type IN ('CUSTOMER_PAYMENT', 'SUPPLIER_PAYMENT', 'OPERATIONAL_EXPENSE', 'VOUCHER_SETTLEMENT', 'CUSTOMER_REFUND') THEN 'Aktivitas Operasional'
      WHEN je.source_type IN ('OPENING_STOCK', 'CAPITAL_INJECTION') THEN 'Aktivitas Pendanaan'
      ELSE 'Aktivitas Lainnya'
    END AS act_group,
    je.source_type,
    COALESCE(SUM(jl.debit), 0) AS total_in,
    COALESCE(SUM(jl.credit), 0) AS total_out,
    COALESCE(SUM(jl.debit - jl.credit), 0) AS net_val
  FROM public.journal_lines jl
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
  WHERE je.status = 'posted'
    AND je.journal_date BETWEEN v_start AND v_end
    AND coa.code IN ('1101', '1102')
  GROUP BY 1, je.source_type
  ORDER BY 1, je.source_type;
END;
$$;

-- 10. Laporan Rekapitulasi Pajak PPN Keluaran vs PPN Masukan
CREATE OR REPLACE FUNCTION public.rpc_get_tax_summary(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS TABLE (
  tax_direction TEXT,
  tax_code TEXT,
  tax_name TEXT,
  transaction_count BIGINT,
  total_dpp NUMERIC,
  total_tax NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start DATE;
  v_end DATE;
BEGIN
  IF NOT public.has_any_role(ARRAY['finance_admin', 'owner']) THEN
    RAISE EXCEPTION 'Hanya Finance Admin atau Owner yang dapat mengakses laporan pajak.';
  END IF;

  v_start := COALESCE(p_start_date, DATE '2000-01-01');
  v_end := COALESCE(p_end_date, DATE '2099-12-31');

  RETURN QUERY
  SELECT
    tt.tax_direction,
    tc.code,
    tc.name,
    COUNT(*),
    COALESCE(SUM(tt.dpp_amount), 0),
    COALESCE(SUM(tt.tax_amount), 0)
  FROM public.tax_transactions tt
  JOIN public.tax_codes tc ON tc.id = tt.tax_code_id
  WHERE tt.status = 'active'
    AND tt.tax_date BETWEEN v_start AND v_end
  GROUP BY tt.tax_direction, tc.code, tc.name
  ORDER BY tt.tax_direction DESC, tc.code ASC;
END;
$$;

-- 11. Ringkasan Dashboard Terpadu (Konsisten 100% dengan Seluruh Laporan)
CREATE OR REPLACE FUNCTION public.rpc_get_dashboard_summary(
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT;
  v_uid UUID;
  v_start DATE;
  v_end DATE;
  v_so_count BIGINT := 0;
  v_so_value NUMERIC(18,2) := 0;
  v_inv_count BIGINT := 0;
  v_gross_sales NUMERIC(18,2) := 0;
  v_credit_notes NUMERIC(18,2) := 0;
  v_net_sales NUMERIC(18,2) := 0;
  v_total_receivables NUMERIC(18,2) := 0;
  v_overdue_receivables NUMERIC(18,2) := 0;
  v_total_payables NUMERIC(18,2) := 0;
  v_inventory_value NUMERIC(18,2) := 0;
  v_low_stock_count BIGINT := 0;
  v_verified_expenses NUMERIC(18,2) := 0;
  v_open_voucher_claims NUMERIC(18,2) := 0;
  v_pending_approvals BIGINT := 0;
BEGIN
  IF NOT public.is_active_user() THEN
    RAISE EXCEPTION 'Akun pengguna tidak aktif.';
  END IF;

  v_role := public.get_my_role();
  v_uid := auth.uid();
  v_start := COALESCE(p_start_date, date_trunc('month', public.jakarta_today())::DATE);
  v_end := COALESCE(p_end_date, public.jakarta_today());

  -- Kinerja Penjualan (Dibatasi milik sendiri jika role = sales)
  SELECT
    COUNT(*),
    COALESCE(SUM(grand_total), 0)
  INTO v_so_count, v_so_value
  FROM public.sales_orders
  WHERE status <> 'cancelled'
    AND order_date BETWEEN v_start AND v_end
    AND (v_role <> 'sales' OR sales_user_id = v_uid);

  SELECT
    COUNT(*),
    COALESCE(SUM(grand_total), 0)
  INTO v_inv_count, v_gross_sales
  FROM public.sales_invoices
  WHERE status IN ('issued', 'partial', 'paid')
    AND invoice_date BETWEEN v_start AND v_end
    AND (v_role <> 'sales' OR sales_user_id = v_uid);

  SELECT
    COALESCE(SUM(amount), 0)
  INTO v_credit_notes
  FROM public.credit_notes
  WHERE status = 'applied'
    AND credit_note_date BETWEEN v_start AND v_end
    AND (v_role <> 'sales' OR sales_user_id = v_uid);

  v_net_sales := v_gross_sales - v_credit_notes;

  -- Piutang Aktif
  SELECT
    COALESCE(SUM(balance_due), 0),
    COALESCE(SUM(balance_due) FILTER (WHERE due_date < public.jakarta_today()), 0)
  INTO v_total_receivables, v_overdue_receivables
  FROM public.sales_invoices
  WHERE status IN ('issued', 'partial')
    AND (v_role <> 'sales' OR sales_user_id = v_uid);

  -- Nilai Stok & Stok Kritis (Untuk Gudang, Finance, Owner)
  IF v_role IN ('warehouse', 'cashier', 'finance_admin', 'owner') THEN
    SELECT
      COALESCE(SUM(sb.total_value), 0),
      COUNT(*) FILTER (WHERE sb.qty_on_hand <= p.min_stock_alert)
    INTO v_inventory_value, v_low_stock_count
    FROM public.stock_balances sb
    JOIN public.products p ON p.id = sb.product_id
    WHERE p.is_active = true;
  END IF;

  -- Utang Supplier, Biaya, & Klaim Voucher (Untuk Finance & Owner)
  IF v_role IN ('finance_admin', 'owner') THEN
    SELECT COALESCE(SUM(balance_due), 0)
    INTO v_total_payables
    FROM public.supplier_invoices
    WHERE status IN ('issued', 'partial');

    SELECT COALESCE(SUM(amount), 0)
    INTO v_verified_expenses
    FROM public.operational_expenses
    WHERE verification_status = 'verified'
      AND expense_date BETWEEN v_start AND v_end;

    SELECT COALESCE(SUM(balance_due), 0)
    INTO v_open_voucher_claims
    FROM public.voucher_claims
    WHERE status IN ('open', 'partial');

    SELECT
      (SELECT COUNT(*) FROM public.sales_order_approvals WHERE status = 'pending') +
      (SELECT COUNT(*) FROM public.customer_payments WHERE verification_status = 'pending') +
      (SELECT COUNT(*) FROM public.operational_expenses WHERE verification_status = 'pending') +
      (SELECT COUNT(*) FROM public.stock_adjustment_requests WHERE status = 'pending_approval')
    INTO v_pending_approvals;
  END IF;

  RETURN jsonb_build_object(
    'start_date', v_start,
    'end_date', v_end,
    'so_count', v_so_count,
    'so_value', v_so_value,
    'invoice_count', v_inv_count,
    'gross_sales', v_gross_sales,
    'credit_notes', v_credit_notes,
    'net_sales', v_net_sales,
    'total_receivables', v_total_receivables,
    'overdue_receivables', v_overdue_receivables,
    'total_payables', v_total_payables,
    'inventory_value', CASE WHEN v_role IN ('finance_admin', 'owner') THEN v_inventory_value ELSE NULL END,
    'low_stock_count', v_low_stock_count,
    'verified_expenses', v_verified_expenses,
    'open_voucher_claims', v_open_voucher_claims,
    'pending_approvals', v_pending_approvals
  );
END;
$$;
