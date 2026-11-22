import { api } from '@/app/api';
import { refreshed } from './opsSlice';

// Refresh every screen now: refetch everything tagged Ops and note the time, which re-arms the single auto-refresh timer
// (so a refresh by hand, after an action or from a live event is never followed a moment later by a timer refresh).
export const refreshAll = () => (dispatch) => {
  dispatch(api.util.invalidateTags(['Ops']));
  dispatch(refreshed(Date.now()));
};
