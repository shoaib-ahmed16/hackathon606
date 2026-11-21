import { lazy, Suspense } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import ProtectedRoute from './ProtectedRoute';
import ConsoleLayout from '@/console/ConsoleLayout';
import Loader from '@/components/Loader';

// Lazy-load pages -> add new pages here
const Board = lazy(() => import('@/console/pages/BoardPage'));
const Rules = lazy(() => import('@/console/pages/RulesPage'));
const Integrations = lazy(() => import('@/console/pages/IntegrationsPage'));
const Alerts = lazy(() => import('@/pages/Alerts'));
const Audit = lazy(() => import('@/pages/Audit'));
const ReportsAudit = lazy(() => import('@/pages/ReportsAudit'));
const DataExplorer = lazy(() => import('@/pages/DataExplorer'));
const Login = lazy(() => import('@/pages/Login'));
const NotFound = lazy(() => import('@/pages/NotFound'));

// The console shell (situation strip + lens bar) wraps every signed-in page. The old /flights table page is gone:
// the board IS the flights view (KPI cards, filters, lanes, flight panel).
export default function AppRoutes() {
  return (
    <Suspense fallback={<Loader />}>
      <Routes>
        <Route path="/login" element={<Login />} />
        <Route element={<ProtectedRoute />}>
          <Route path="data" element={<DataExplorer />} />
          <Route element={<ConsoleLayout />}>
            <Route index element={<Board />} />
            <Route path="rules" element={<Rules />} />
            <Route path="integrations" element={<Integrations />} />
            <Route path="audit" element={<Audit />} />
            <Route path="data-quality" element={<Alerts />} />
            <Route path="reports" element={<ReportsAudit />} />
            <Route path="flights" element={<Navigate to="/" replace />} />
            <Route path="alerts" element={<Navigate to="/data-quality" replace />} />
          </Route>
        </Route>
        <Route path="*" element={<NotFound />} />
      </Routes>
    </Suspense>
  );
}
