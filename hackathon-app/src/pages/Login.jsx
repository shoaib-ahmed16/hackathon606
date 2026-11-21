import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { z } from 'zod';
import { Alert, Button, Stack, Typography } from '@mui/material';
import { useAppDispatch, useAppSelector } from '@/app/hooks';
import { selectIsAuthed, setCredentials } from '@/features/auth/authSlice';
import { useLoginMutation } from '@/features/auth/authApi';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { rules } from '@/utils/validators';
import AuthLayout from '@/components/layout/AuthLayout';
import PasswordField from '@/components/PasswordField';
import FormTextField from '@/components/form/FormTextField';
import { useZodForm } from '@/components/form/useZodForm';

const schema = z.object({
  username: rules.required('Username'),
  password: z.string().min(1, 'Password is required'),
});

export default function Login() {
  const dispatch = useAppDispatch();
  const navigate = useNavigate();
  const from = useLocation().state?.from?.pathname ?? '/';
  const authed = useAppSelector(selectIsAuthed);
  const [login, { error }] = useLoginMutation();
  const {
    control,
    handleSubmit,
    formState: { isSubmitting },
  } = useZodForm(schema, { username: '', password: '' });

  if (authed) return <Navigate to={from} replace />;

  const onSubmit = async (values) => {
    try {
      const session = await login(values).unwrap();
      dispatch(setCredentials(session));
      navigate(from, { replace: true });
    } catch {
      /* error shown via `error` below */
    }
  };

  return (
    <AuthLayout title="Welcome back" subtitle="Sign in to continue">
      <Stack component="form" onSubmit={handleSubmit(onSubmit)} noValidate spacing={2}>
        {error && <Alert severity="error">{getErrorMessage(error)}</Alert>}
        <FormTextField
          control={control}
          name="username"
          label="Username"
          autoFocus
          autoComplete="username"
        />
        <FormTextField
          control={control}
          name="password"
          label="Password"
          as={PasswordField}
          autoComplete="current-password"
        />
        <Button type="submit" variant="contained" size="large" disabled={isSubmitting}>
          {isSubmitting ? 'Signing in...' : 'Sign in'}
        </Button>
        <Typography variant="caption" sx={{ color: 'text.secondary', textAlign: 'center' }}>
          Demo users: occ.dm, dispatch.1, crew.ctl.1, recovery.1 (password: FogOps@2026)
        </Typography>
      </Stack>
    </AuthLayout>
  );
}
