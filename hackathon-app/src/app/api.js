import { createApi, fetchBaseQuery } from '@reduxjs/toolkit/query/react';
import { API_URL } from '@/config/env';
import { logout } from '@/features/auth/authSlice';

const baseQuery = fetchBaseQuery({
  baseUrl: API_URL,
  prepareHeaders: (headers, { getState }) => {
    const token = getState().auth.token;
    if (token) headers.set('Authorization', `Bearer ${token}`);
    return headers;
  },
});

// Auto-logout on 401 (expired or invalid token)
const baseQueryWithAuth = async (args, api, extra) => {
  const result = await baseQuery(args, api, extra);
  if (result.error?.status === 401 && api.endpoint !== 'login') api.dispatch(logout());
  return result;
};

/**
 * ONE api for the whole app. Feature files add endpoints with api.injectEndpoints().
 * Tag types are registered automatically by createCrudApi (see app/createCrudApi.js).
 */
export const api = createApi({
  reducerPath: 'api',
  baseQuery: baseQueryWithAuth,
  tagTypes: [],
  endpoints: () => ({}),
});
