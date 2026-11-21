import { Component } from 'react';
import { useLocation } from 'react-router-dom';

// Catches a render error. A poll can briefly hand a component data in a shape it did not expect; the next poll usually fixes it,
// so the first failures retry on their own. If it keeps failing the person sees what broke and can retry without losing their place.
// `label` names the area (so one broken widget does not blank the whole screen); `resetKey` clears the error when the page changes.
class Boundary extends Component {
  state = { error: null, tries: 0 };
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
    if (this.state.tries < 3) this.timer = setTimeout(() => this.setState((s) => ({ error: null, tries: s.tries + 1 })), 1500);
  }
  componentDidUpdate(prev) {
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null, tries: 0 });
  }
  componentWillUnmount() {
    clearTimeout(this.timer);
  }
  render() {
    const { error, tries } = this.state;
    if (!error) return this.props.children;
    if (tries < 3) return <div className="crash"><span className="k">Refreshing this part of the screen…</span></div>;
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
