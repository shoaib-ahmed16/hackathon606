export const MIN = 60000;
const dubai = { timeZone: 'Asia/Dubai' };
const tf = new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', ...dubai });
const df = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', ...dubai });
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
