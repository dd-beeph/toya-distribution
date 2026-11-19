/**
 * Konfigurasi Utama Aplikasi Toya Distribution
 * Catatan Keamanan: Hanya gunakan Supabase anon/publishable key di file ini.
 * Jangan pernah memasukkan service_role key atau password database ke frontend.
 */

export const APP_CONFIG = Object.freeze({
  APP_NAME: 'Toya Distribution',
  COMPANY_LEGAL_NAME: 'PT Toya Jaya Darma',
  APP_VERSION: '1.0.0',
  TIMEZONE: 'Asia/Jakarta',
  LOCALE: 'id-ID',
  CURRENCY: 'IDR',
  DEFAULT_PAGE_SIZE: 20,

  // Ganti dua nilai di bawah ini dengan Project URL dan anon public key dari Supabase Anda
  SUPABASE_URL: 'https://eqcezucscxedgxmuojnb.supabase.co/rest/v1/',
  SUPABASE_ANON_KEY: 'sb_publishable_7EUTCB1oxF4wKgfQ4fIEog_2nVxhOeZ',

  STORAGE_BUCKET_PROOFS: 'transaction-proofs'
});

export const ROLES = Object.freeze({
  SALES: 'sales',
  WAREHOUSE: 'warehouse',
  CASHIER: 'cashier',
  FINANCE_ADMIN: 'finance_admin',
  OWNER: 'owner'
});

export const ROLE_LABELS = Object.freeze({
  sales: 'Sales',
  warehouse: 'Warehouse / Delivery',
  cashier: 'Cashier (Kasir)',
  finance_admin: 'Finance Admin',
  owner: 'Owner'
});

export const PERIOD_PRESETS = Object.freeze([
  { value: 'today', label: 'Hari Ini' },
  { value: 'this_week', label: 'Minggu Ini' },
  { value: 'this_month', label: 'Bulan Ini' },
  { value: 'last_month', label: 'Bulan Lalu' },
  { value: 'this_year', label: 'Tahun Ini' },
  { value: 'custom', label: 'Rentang Tanggal Khusus' },
  { value: 'all', label: 'Semua Periode' }
]);

/**
 * Daftar menu navigasi beserta role yang diizinkan melihatnya di antarmuka.
 * Penguncian hak akses sesungguhnya tetap dijaga oleh RLS dan RPC di database Supabase.
 */
export const MENU_DEFINITIONS = Object.freeze([
  {
    group: 'Utama',
    items: [
      { id: 'dashboard', label: 'Dashboard', icon: 'dashboard', roles: ['sales', 'warehouse', 'cashier', 'finance_admin', 'owner'] },
      { id: 'approvals', label: 'Persetujuan & Verifikasi', icon: 'check_circle', roles: ['finance_admin', 'owner'] }
    ]
  },
  {
    group: 'Penjualan & Piutang',
    items: [
      { id: 'sales-orders', label: 'Sales Order (SO)', icon: 'shopping_cart', roles: ['sales', 'warehouse', 'cashier', 'finance_admin', 'owner'] },
      { id: 'deliveries', label: 'Pengiriman & Surat Jalan', icon: 'local_shipping', roles: ['sales', 'warehouse', 'cashier', 'finance_admin', 'owner'] },
      { id: 'sales-invoices', label: 'Faktur Penjualan', icon: 'receipt_long', roles: ['sales', 'cashier', 'finance_admin', 'owner'] },
      { id: 'sales-returns', label: 'Retur & Nota Kredit', icon: 'assignment_return', roles: ['sales', 'warehouse', 'cashier', 'finance_admin', 'owner'] },
      { id: 'customer-payments', label: 'Pembayaran & Piutang', icon: 'payments', roles: ['cashier', 'finance_admin', 'owner'] }
    ]
  },
  {
    group: 'Pembelian & Utang',
    items: [
      { id: 'purchase-orders', label: 'Purchase Order (PO)', icon: 'shopping_bag', roles: ['warehouse', 'finance_admin', 'owner'] },
      { id: 'goods-receipts', label: 'Penerimaan Barang', icon: 'inventory', roles: ['warehouse', 'finance_admin', 'owner'] },
      { id: 'supplier-invoices', label: 'Faktur & Utang Supplier', icon: 'request_quote', roles: ['finance_admin', 'owner'] },
      { id: 'supplier-payments', label: 'Pembayaran Supplier', icon: 'account_balance_wallet', roles: ['finance_admin', 'owner'] }
    ]
  },
  {
    group: 'Persediaan Gudang',
    items: [
      { id: 'inventory-ledger', label: 'Stok & Kartu Stok', icon: 'warehouse', roles: ['sales', 'warehouse', 'cashier', 'finance_admin', 'owner'] },
      { id: 'stock-transfers', label: 'Transfer Gudang', icon: 'swap_horiz', roles: ['warehouse', 'finance_admin', 'owner'] },
      { id: 'stock-adjustments', label: 'Penyesuaian Stok', icon: 'tune', roles: ['warehouse', 'finance_admin', 'owner'] },
      { id: 'damaged-goods', label: 'Barang Rusak', icon: 'broken_image', roles: ['warehouse', 'cashier', 'finance_admin', 'owner'] }
    ]
  },
  {
    group: 'Keuangan & Pajak',
    items: [
      { id: 'operational-expenses', label: 'Biaya Operasional', icon: 'receipt', roles: ['cashier', 'finance_admin', 'owner'] },
      { id: 'voucher-claims', label: 'Klaim Voucher Promosi', icon: 'local_offer', roles: ['cashier', 'finance_admin', 'owner'] },
      { id: 'accounting', label: 'Akuntansi & Buku Besar', icon: 'account_balance', roles: ['finance_admin', 'owner'] },
      { id: 'tax-management', label: 'Pajak (PPN)', icon: 'percent', roles: ['finance_admin', 'owner'] }
    ]
  },
  {
    group: 'Laporan & Pengaturan',
    items: [
      { id: 'sales-performance', label: 'Kinerja & Omzet Sales', icon: 'leaderboard', roles: ['sales', 'finance_admin', 'owner'] },
      { id: 'master-data', label: 'Data Master', icon: 'database', roles: ['sales', 'warehouse', 'cashier', 'finance_admin', 'owner'] },
      { id: 'settings', label: 'Pengaturan & Pengguna', icon: 'settings', roles: ['owner'] }
    ]
  }
]);
