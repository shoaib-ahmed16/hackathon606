import { api } from './api';

/**
 * CRUD in one call. Generates list / get / add / update / delete endpoints with cache tags,
 * so lists refresh automatically after add / edit / delete.
 *
 *   export const posts = createCrudApi({ name: 'Post', path: '/posts', addPath: '/posts/add', listKey: 'posts' });
 *   export const { useList, useGet, useAdd, useUpdate, useRemove } = posts;
 *
 * Options
 *   name     unique, singular, PascalCase  (also the cache tag)
 *   path     collection URL                 e.g. '/posts'
 *   addPath  POST URL if different          (default: path)
 *   listKey  key holding the array in the list response (e.g. dummyjson -> 'posts'); omit if the API returns a plain array
 *
 * List response is normalised to { items, total }. Call it with query params: useList({ limit: 10, skip: 0, q: 'x' }).
 * If your backend differs (e.g. PATCH instead of PUT), tweak it here once and every resource follows.
 */
export const createCrudApi = ({ name, path, addPath = path, listKey }) => {
  const LIST = { type: name, id: 'LIST' };

  const injected = api.enhanceEndpoints({ addTagTypes: [name] }).injectEndpoints({
    endpoints: (build) => ({
      [`list${name}`]: build.query({
        query: (params) => ({ url: path, params }),
        transformResponse: (res) => {
          const items = listKey ? res[listKey] : res;
          return { items, total: res.total ?? items.length };
        },
        providesTags: (res) => [LIST, ...(res?.items ?? []).map(({ id }) => ({ type: name, id }))],
      }),
      [`get${name}`]: build.query({
        query: (id) => `${path}/${id}`,
        providesTags: (_r, _e, id) => [{ type: name, id }],
      }),
      [`add${name}`]: build.mutation({
        query: (body) => ({ url: addPath, method: 'POST', body }),
        invalidatesTags: [LIST],
      }),
      [`update${name}`]: build.mutation({
        query: ({ id, ...body }) => ({ url: `${path}/${id}`, method: 'PUT', body }),
        invalidatesTags: (_r, _e, { id }) => [{ type: name, id }, LIST],
      }),
      [`delete${name}`]: build.mutation({
        query: (id) => ({ url: `${path}/${id}`, method: 'DELETE' }),
        invalidatesTags: (_r, _e, id) => [{ type: name, id }, LIST],
      }),
    }),
  });

  const ep = injected.endpoints;
  return {
    useList: ep[`list${name}`].useQuery,
    useGet: ep[`get${name}`].useQuery,
    useAdd: ep[`add${name}`].useMutation,
    useUpdate: ep[`update${name}`].useMutation,
    useRemove: ep[`delete${name}`].useMutation,
  };
};
