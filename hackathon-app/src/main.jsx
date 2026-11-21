import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { BrowserRouter } from 'react-router-dom';
import { Toaster } from 'react-hot-toast';
import '@fontsource-variable/inter'; // self-hosted font (change in theme/typography.js)
import { store } from '@/app/store';
import ThemeProvider from '@/theme/ThemeProvider';
import SocketProvider from '@/services/SocketProvider';
import ErrorBoundary from '@/components/ErrorBoundary';
import App from './App';

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <Provider store={store}>
      <ThemeProvider>
        <BrowserRouter>
          <SocketProvider>
            <ErrorBoundary>
              <App />
            </ErrorBoundary>
          </SocketProvider>
          <Toaster position="top-right" />
        </BrowserRouter>
      </ThemeProvider>
    </Provider>
  </StrictMode>,
);
