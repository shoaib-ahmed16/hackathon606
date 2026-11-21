import { useAppDispatch } from '@/app/hooks';
import { useLogoutAuditMutation } from '@/features/ops/opsApi';
import { logout } from './authSlice';

// Signing out is recorded in the audit trail first, then the session is cleared (even if the record fails).
export function useSignOut() {
  const dispatch = useAppDispatch();
  const [record] = useLogoutAuditMutation();
  return async () => {
    try {
      await record().unwrap();
    } catch {
      /* sign out regardless */
    }
    dispatch(logout());
  };
}
