/**
 * Pengatur Hak Akses Menu & Tindakan Pengguna per Role
 */

import { MENU_DEFINITIONS, ROLES } from '../config/app-config.js';

/**
 * Mengembalikan daftar grup menu yang diizinkan untuk role tertentu.
 */
export function getVisibleMenus(role) {
  if (!role) return [];

  return MENU_DEFINITIONS
    .map((group) => ({
      group: group.group,
      items: group.items.filter((item) => item.roles.includes(role))
    }))
    .filter((group) => group.items.length > 0);
}

/**
 * Memeriksa apakah role tertentu berhak membuka halaman modul berdasarkan menu ID.
 */
export function canAccessMenu(role, menuId) {
  if (!role || !menuId) return false;

  for (const group of MENU_DEFINITIONS) {
    const found = group.items.find((item) => item.id === menuId);
    if (found) {
      return found.roles.includes(role);
    }
  }
  return false;
}

/**
 * Matriks kewenangan tombol tindakan di antarmuka.
 * Pengamanan akhir tetap divalidasi oleh database RLS dan RPC.
 */
const ACTION_PERMISSIONS = Object.freeze({
  create_sales_order: [ROLES.SALES, ROLES.OWNER],
  approve_discount: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  override_so_price: [ROLES.OWNER],
  reattribute_so_sales: [ROLES.OWNER],
  dispatch_delivery: [ROLES.WAREHOUSE, ROLES.OWNER],
  confirm_delivery_result: [ROLES.CASHIER, ROLES.WAREHOUSE, ROLES.OWNER],
  issue_sales_invoice: [ROLES.CASHIER, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  process_sales_return: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  record_customer_payment: [ROLES.CASHIER, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  verify_customer_payment: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  create_purchase_order: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  receive_goods: [ROLES.WAREHOUSE, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  post_supplier_invoice: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  record_supplier_payment: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  transfer_stock: [ROLES.WAREHOUSE, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  request_stock_adjustment: [ROLES.WAREHOUSE, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  approve_stock_adjustment: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  record_warehouse_damage: [ROLES.WAREHOUSE, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  record_operational_expense: [ROLES.CASHIER, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  verify_operational_expense: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  settle_voucher_claim: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  manage_master_data: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  manage_customer_data: [ROLES.SALES, ROLES.FINANCE_ADMIN, ROLES.OWNER],
  manage_accounting: [ROLES.FINANCE_ADMIN, ROLES.OWNER],
  manage_users_and_settings: [ROLES.OWNER],
  view_cogs_and_profit: [ROLES.FINANCE_ADMIN, ROLES.OWNER]
});

/**
 * Memeriksa apakah role pengguna berhak menjalankan suatu tindakan spesifik.
 */
export function canPerformAction(role, actionKey) {
  if (!role || !actionKey) return false;
  const allowedRoles = ACTION_PERMISSIONS[actionKey];
  if (!allowedRoles) return false;
  return allowedRoles.includes(role);
}
