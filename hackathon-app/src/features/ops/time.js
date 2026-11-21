export const MIN = 60000;
const dubai = { timeZone: 'Asia/Dubai' };
const tf = new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', ...dubai });
const df = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', ...dubai });
const dfz = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', timeZone: 'UTC' });
const zf = new Intl.DateTimeFormat('en-GB', {
  hour: '2-digit',
  minute: '2-digit',
  timeZone: 'UTC',
});
const zsf = new Intl.DateTimeFormat('en-GB', {
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  timeZone: 'UTC',
});

// Every time in the data is UTC (organizers' rule). SHJ local = UTC+4, always shown next to it.
export const fmtTime = (ms) => (ms == null ? '-' : tf.format(ms)); // SHJ local HH:MM
export const fmtDate = (ms) => (ms == null ? '-' : df.format(ms));
export const fmtDateTime = (ms) => `${fmtDate(ms)} ${fmtTime(ms)}`;
export const fmtZ = (ms) => (ms == null ? '-' : `${zf.format(ms)}Z`);
export const fmtZs = (ms) => (ms == null ? '-' : `${zsf.format(ms)}Z`);
// Day helpers so a flight's date is always visible. Day = UTC date (same basis as the Z times).
export const fmtDay = (ms) => (ms == null ? '-' : dfz.format(ms)); // "21 Nov"
export const fmtZD = (ms) => (ms == null ? '-' : `${fmtDay(ms)} ${fmtZ(ms)}`); // "21 Nov 01:55Z"
// "21 Nov 01:55Z / 05:55 SHJ" (adds the SHJ date only when it differs from the UTC date, e.g. 22:00Z = 02:00 next day)
export const fmtZLD = (ms) => {
  if (ms == null) return '-';
  const sameDay = df.format(ms) === dfz.format(ms);
  return `${fmtDay(ms)} ${fmtZ(ms)} / ${sameDay ? '' : `${df.format(ms)} `}${fmtTime(ms)} SHJ`;
};
// The date a flight belongs to: scheduled arrival (else departure)
export const flightDay = (f) => fmtDay(Date.parse(f?.sta_utc ?? f?.std_utc ?? '') || null);

export const fmtZL = (ms) => (ms == null ? '-' : `${fmtZ(ms)} / ${fmtTime(ms)} SHJ`);

// 125 -> "2h 05m" (negative allowed)
export const fmtDur = (min) => {
  if (min == null) return '-';
  const sign = min < 0 ? '-' : '';
  const a = Math.abs(Math.round(min));
  return `${sign}${Math.floor(a / 60)}h ${String(a % 60).padStart(2, '0')}m`;
};

// Live countdown text. Under 10 minutes it shows seconds, so it visibly ticks. Past times read "passed".
export const cdText = (target, now) => {
  if (target == null) return 'verify';
  const s = Math.floor((target - now) / 1000);
  const a = Math.abs(s);
  const h = Math.floor(a / 3600);
  const m = Math.floor((a % 3600) / 60);
  if (s < 0) return a < 60 ? 'just passed' : `passed ${h > 0 ? `${h} h ${String(m).padStart(2, '0')} min` : `${m} min`} ago`; // overdue: whole minutes, no second-by-second ticking
  const body =
    h > 0
      ? `${h} h ${String(m).padStart(2, '0')} min`
      : a >= 600
        ? `${m} min`
        : `${m} min ${String(a % 60).padStart(2, '0')} s`;
  return s < 0 ? `passed ${body} ago` : body;
};
// urgency tone from minutes left: exceeded (<15), risk (<45), legal otherwise; unknown = verify
export const cdTone = (target, now) => {
  if (target == null) return 'verify';
  const m = (target - now) / MIN;
  return m < 15 ? 'error' : m < 45 ? 'warning' : 'success';
};
