import { api } from '@/app/api';
import { OPS_API_URL } from '@/config/env';

// Login against the FOO API:  POST /api/auth/login { username, password }
//   -> { token, user: { user_id, username, display_name, role_code } }
// Errors come back as { detail } (shown through getErrorMessage).
const toSession = ({ token, user }) => ({
  token,
  user: {
    id: user.user_id,
    username: user.username,
    name: user.display_name,
    role: user.role_code,
  },
});

export const authApi = api.injectEndpoints({
  endpoints: (build) => ({
    login: build.mutation({
      query: ({ username, password }) => ({
        url: `${OPS_API_URL}/api/auth/login`,
        method: 'POST',
        body: { username, password },
      }),
      transformResponse: toSession,
    }),
  }),
});

export const { useLoginMutation } = authApi;
