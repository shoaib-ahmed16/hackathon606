import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { useAppSelector } from '@/app/hooks';
import { selectIsAuthed } from '@/features/auth/authSlice';
import FogIntro from '@/components/FogIntro';

export default function ProtectedRoute() {
  const authed = useAppSelector(selectIsAuthed);
  const location = useLocation();
  return authed ? (
    <>
      <FogIntro />
      <Outlet />
    </>
  ) : <Navigate to="/login" replace state={{ from: location }} />;
}
