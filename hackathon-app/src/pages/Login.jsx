import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import { selectIsAuthed, setCredentials } from '@/features/auth/authSlice';
import { useLoginMutation } from '@/features/auth/authApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { LogoFull } from '@/components/Logo';
import { APP_TAGLINE } from '@/config/brand';

export default function Login() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const from = useLocation().state?.from?.pathname ?? '/';
  const authed = useAppSelector(selectIsAuthed);
  const [login, { error, isLoading }] = useLoginMutation();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [show, setShow] = useState(false);
  const [touched, setTouched] = useState(false);

  if (authed) return <Navigate to={from} replace />;

  const missing = !username.trim() || !password;

  const onSubmit = async (e) => {
    e.preventDefault();
    setTouched(true);
    if (missing) return;
    try {
      const session = await login({ username: username.trim(), password }).unwrap();
      dispatch(setCredentials(session));
      navigate(from, { replace: true });
    } catch {
      /* error shown via `error` below */
    }
  };

  return (
    <div className="login">
      <form className="login-card" onSubmit={onSubmit} noValidate>
        <div className="login-logo">
          <LogoFull height={150} />
          <div className="k" style={{ textAlign: 'center' }}>{APP_TAGLINE}</div>
        </div>
        <label className="field-l k" style={{ display: 'block' }}>
          Username
          <input
            className="field-in"
            name="username"
            autoFocus
            autoComplete="username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </label>
        <label className="field-l k" style={{ display: 'block' }}>
          Password
          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <input
              className="field-in"
              name="password"
              type={show ? 'text' : 'password'}
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
            <button
              type="button"
              className="btn sm ghost"
              style={{ marginTop: 6 }}
              aria-pressed={show}
              onClick={() => setShow((v) => !v)}
            >
              {show ? 'Hide' : 'Show'}
            </button>
          </div>
        </label>
        {touched && missing && <div className="err">Enter your username and password.</div>}
        {error && <div className="err">{getErrorMessage(error)}</div>}
        <button type="submit" className="btn primary" disabled={isLoading}>
          {isLoading ? 'Signing in...' : 'Sign in'}
        </button>
        <div className="k" style={{ textAlign: 'center', marginTop: 14 }}>
          Demo users: occ.dm, dispatch.1, crew.ctl.1, recovery.1 (password: FogOps@2026)
        </div>
      </form>
    </div>
  );
}
