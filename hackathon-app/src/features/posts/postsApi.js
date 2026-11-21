import { createCrudApi } from '@/app/createCrudApi';

// Example resource. For a new one (users, products, orders...) copy this file: change name/path.
export const { useList, useGet, useAdd, useUpdate, useRemove } = createCrudApi({
  name: 'Post',
  path: '/posts',
  addPath: '/posts/add', // dummyjson uses /add; most APIs just use POST /posts (delete this line)
  listKey: 'posts', // dummyjson wraps lists as { posts: [...] }
});

export {
  useList as useGetPostsQuery,
  useGet as useGetPostQuery,
  useAdd as useAddPostMutation,
  useUpdate as useUpdatePostMutation,
  useRemove as useDeletePostMutation,
};
