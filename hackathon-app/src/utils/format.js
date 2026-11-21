import { format, formatDistanceToNow, parseISO } from 'date-fns';

// Display helpers (dates via date-fns, numbers/currency via Intl). Import what you need:
//   import { formatDate, formatCurrency } from '@/utils/format';
const toDate = (d) => (typeof d === 'string' ? parseISO(d) : new Date(d));

export const formatDate = (d, pattern = 'dd MMM yyyy') => (d ? format(toDate(d), pattern) : '-');
export const formatDateTime = (d) => formatDate(d, 'dd MMM yyyy, HH:mm');
export const timeAgo = (d) => (d ? formatDistanceToNow(toDate(d), { addSuffix: true }) : '-');

export const formatNumber = (n, opts) => new Intl.NumberFormat(undefined, opts).format(n ?? 0);
export const formatCompact = (n) =>
  formatNumber(n, { notation: 'compact', maximumFractionDigits: 1 });
export const formatCurrency = (n, currency = 'USD') =>
  formatNumber(n, { style: 'currency', currency });
export const formatPercent = (n, digits = 0) =>
  formatNumber(n, { style: 'percent', maximumFractionDigits: digits });
