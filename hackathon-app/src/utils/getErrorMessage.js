// Turns an RTK Query error into a readable string
export const getErrorMessage = (err) =>
  err?.data?.message ||
  (typeof err?.data?.detail === 'string' && err.data.detail) ||
  err?.error ||
  err?.message ||
  'Something went wrong';
