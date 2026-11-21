import { lazy, Suspense } from 'react';
import { Route, Routes } from 'react-router-dom';
import ProtectedRoute from './ProtectedRoute';
import MainLayout from '@/components/layout/MainLayout';
import Loader from '@/components/Loader';

// Lazy-load pages -> add new pages here
const Dashboard = lazy(() => import('@/pages/Console'));
const Alerts = lazy(() => import('@/pages/Alerts'));
const FlightWatch = lazy(() => import('@/pages/FlightWatch'));
const Audit = lazy(() => import('@/pages/Audit'));
const ReportsAudit = lazy(() => import('@/pages/ReportsAudit'));
const Login = lazy(() => import('@/pages/Login'));
const Realtime = lazy(() => import('@/pages/Realtime'));
const Posts = lazy(() => import('@/pages/Posts'));
const NotFound = lazy(() => import('@/pages/NotFound'));

export default function AppRoutes() {
  return (
    <Suspense fallback={<Loader />}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route element={<ProtectedRoute />}>
          <Route element={<MainLayout />}>
            <Route index element={<Dashboard />} />
            <Route path="alerts" element={<Alerts />} />
            <Route path="flights" element={<FlightWatch />} />
            <Route path="audit" element={<Audit />} />
            <Route path="reports" element={<ReportsAudit />} />
            <Route path="posts" element={<Posts />} />
            <Route path="realtime" element={<Realtime />} />
          </Route>
        </Route>
        <Route path="*" element={<NotFound />} />
      </Routes>
    </Suspense>
  );
}
