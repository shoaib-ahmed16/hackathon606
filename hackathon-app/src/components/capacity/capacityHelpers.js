// Labels and display rules for the Airport capacity screen. Unknown is shown as a dash, never as 0, and a figure that comes
// from history is shown with ">=" because a historical peak is a lower bound of what an airport handled, not its limit.
export const SOURCE = {
  STATUS_EVENT: ['Status entry', 'success'],
  CONFIGURED: ['Assumed', 'info'],
  HISTORY: ['From history', 'warning'],
  UNKNOWN: ['Unknown', 'default'],
};

export const OUTCOME = {
  CAPACITY_AVAILABLE: ['Capacity available', 'success'],
  CAPACITY_CONSTRAINED: ['Capacity constrained', 'warning'],
  CAPACITY_EXCEEDED: ['Capacity exceeded', 'error'],
  UNKNOWN_VERIFICATION_REQUIRED: ['Unknown / verification required', 'default'],
};

export const WRITERS = ['OCC', 'ADMIN'];

export const dash = (v) => (v == null ? '—' : v);
export const lowerBound = (v, source) => (v == null ? '—' : source === 'HISTORY' ? `≥ ${v}` : v);
export const ms = (iso) => (iso ? Date.parse(iso) : null);
export const hourLabel = (iso) => (iso ? String(new Date(iso).getUTCHours()).padStart(2, '0') : '');
export const scenarioParams = (scenarioId) => (scenarioId ? { scenario_id: scenarioId } : {});
