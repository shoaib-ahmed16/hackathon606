import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { BrowserRouter } from 'react-router-dom';
import { Toaster } from 'react-hot-toast';
import '@fontsource-variable/inter'; // self-hosted font (change in theme/typography.js)
import { store } from '@/app/store';
import ThemeProvider from '@/theme/ThemeProvider';
import ErrorBoundary from '@/components/ErrorBoundary';
import ThemeSync from '@/console/ThemeSync';
import '@/console/console.css';
import App from './App';

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <Provider store={store}>
      <ThemeProvider>
        <BrowserRouter>
          <ThemeSync />
          <ErrorBoundary>
            <App />
          </ErrorBoundary>
          <Toaster
            position="bottom-center"
            toastOptions={{ style: { background: 'var(--surface-3)', color: 'var(--text)', border: '1px solid var(--line-2)', fontSize: 14 } }}
          />
        </BrowserRouter>
      </ThemeProvider>
    </Provider>
  </StrictMode>,
);
