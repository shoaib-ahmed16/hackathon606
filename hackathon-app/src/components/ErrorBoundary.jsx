import { Component } from 'react';
import { useLocation } from 'react-router-dom';
import SectionSkeleton from '@/components/SectionSkeleton';

// Catches a render error so one broken part never blanks the whole app. It never leaves an empty screen:
//  * a page file that cannot be fetched (the tab was opened before a new version was deployed) reloads the page once by itself;
//  * any other error retries quietly a few times, showing a loading placeholder (data that arrives a moment later usually fixes it);
//  * only if it keeps failing does the person see a message with Try again / Reload.
// `label` names the area (so one broken widget does not blank the whole screen); `resetKey` clears the error when the page changes.
const CHUNK = /dynamically imported module|Importing a module script failed|Loading chunk|Loading CSS chunk|error loading dynamically/i;
const RELOAD_KEY = 'fooChunkReload';
const RETRIES = 4;

function reloadOnce() {
  try {
    const last = Number(sessionStorage.getItem(RELOAD_KEY) || 0);
    if (Date.now() - last < 30000) return false;   // already reloaded a moment ago: do not loop
    sessionStorage.setItem(RELOAD_KEY, String(Date.now()));
  } catch {
    /* storage unavailable: fall through and reload anyway, once per mount */
  }
  window.location.reload();
  return true;
}

class Boundary extends Component {
  state = { error: null, tries: 0, reloading: false };
  timer = null;
  static getDerivedStateFromError(error) {
    return { error };
  }
  componentDidCatch(error, info) {
    // eslint-disable-next-line no-console
    console.error(`[${this.props.label ?? 'app'}] render failed:`, error, info?.componentStack);
    try {
      sessionStorage.setItem('lastRenderError', JSON.stringify({ at: new Date().toISOString(), label: this.props.label ?? 'app', message: String(error?.message ?? error), stack: String(error?.stack ?? '').slice(0, 1500) }));
    } catch { /* storage unavailable */ }
    if (CHUNK.test(String(error?.message ?? error)) && reloadOnce()) {
      this.setState({ reloading: true });
      return;
    }
    if (this.state.tries < RETRIES) this.timer = setTimeout(() => this.setState((s) => ({ error: null, tries: s.tries + 1 })), 900 + this.state.tries * 700);
  }
  componentDidUpdate(prev) {
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null, tries: 0 });
  }
  componentWillUnmount() {
    clearTimeout(this.timer);
  }
  render() {
    const { error, tries, reloading } = this.state;
    if (!error) return this.props.children;
    if (reloading || tries < RETRIES) return <SectionSkeleton compact label="Loading" />;
    return (
      <div className="crash" role="alert">
        <h3>This part of the screen could not be shown</h3>
        <p className="k">The rest of the app still works. Try again, or reload the page if it keeps happening.</p>
        <pre>{String(error?.message ?? error)}</pre>
        <button type="button" className="btn primary" onClick={() => this.setState({ error: null, tries: 0 })}>Try again</button>{' '}
        <button type="button" className="btn" onClick={() => window.location.reload()}>Reload page</button>
      </div>
    );
  }
}

export default function ErrorBoundary({ children, label }) {
  const { pathname } = useLocation();
  return <Boundary label={label} resetKey={pathname}>{children}</Boundary>;
}
