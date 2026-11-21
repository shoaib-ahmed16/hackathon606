import { useState } from 'react';
import toast from 'react-hot-toast';
import {
  Alert,
  Box,
  Button,
  IconButton,
  Paper,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TablePagination,
  TableRow,
  TextField,
  Tooltip,
} from '@mui/material';
import AddIcon from '@mui/icons-material/Add';
import EditIcon from '@mui/icons-material/Edit';
import DeleteIcon from '@mui/icons-material/Delete';
import { useAdd, useList, useRemove, useUpdate } from '@/features/posts/postsApi';
import PostFormDialog from '@/features/posts/PostFormDialog';
import { getErrorMessage } from '@/utils/getErrorMessage';
import { useDebounce } from '@/hooks/useDebounce';
import ConfirmDialog from '@/components/ConfirmDialog';
import EmptyState from '@/components/EmptyState';
import PageHeader from '@/components/PageHeader';
import Loader from '@/components/Loader';

// Full CRUD reference page: list + search + pagination, create / edit dialog, delete confirm.
// Copy this page + features/posts/* for a new resource.
export default function Posts() {
  const [page, setPage] = useState(0);
  const [limit, setLimit] = useState(10);
  const [search, setSearch] = useState('');
  const debouncedSearch = useDebounce(search);
  const [editing, setEditing] = useState(null); // null | 'new' | post
  const [deleting, setDeleting] = useState(null); // null | post

  // dummyjson: /posts/search?q=... for searching, /posts?limit&skip otherwise
  const { data, isLoading, isFetching, isError, error, refetch } = useList({
    limit,
    skip: page * limit,
    ...(debouncedSearch && { q: debouncedSearch }),
  });
  const [addPost, { isLoading: adding }] = useAdd();
  const [updatePost, { isLoading: updating }] = useUpdate();
  const [removePost, { isLoading: removing }] = useRemove();

  const run = async (promise, okMsg, done) => {
    try {
      await promise.unwrap();
      toast.success(okMsg);
      done();
    } catch (e) {
      toast.error(getErrorMessage(e));
    }
  };

  const onSave = (form) =>
    editing === 'new'
      ? run(addPost({ ...form, userId: 1 }), 'Post created', () => setEditing(null))
      : run(updatePost({ id: editing.id, ...form }), 'Post updated', () => setEditing(null));

  const onDelete = () => run(removePost(deleting.id), 'Post deleted', () => setDeleting(null));

  if (isLoading) return <Loader />;
  if (isError)
    return (
      <Alert severity="error" action={<Button onClick={refetch}>Retry</Button>}>
        {getErrorMessage(error)}
      </Alert>
    );

  return (
    <Stack spacing={2}>
      <PageHeader
        title="Posts"
        actions={
          <>
            <Box sx={{ width: 220 }}>
              <TextField
                placeholder="Search..."
                value={search}
                onChange={(e) => {
                  setSearch(e.target.value);
                  setPage(0);
                }}
              />
            </Box>
            <Button variant="contained" startIcon={<AddIcon />} onClick={() => setEditing('new')}>
              New post
            </Button>
          </>
        }
      />

      <Paper sx={{ opacity: isFetching ? 0.6 : 1, transition: 'opacity .2s' }}>
        <TableContainer>
          <Table>
            <TableHead>
              <TableRow>
                <TableCell width={70}>ID</TableCell>
                <TableCell>Title</TableCell>
                <TableCell width={110} align="right">
                  Actions
                </TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {data.items.map((p) => (
                <TableRow key={p.id} hover>
                  <TableCell>{p.id}</TableCell>
                  <TableCell>{p.title}</TableCell>
                  <TableCell align="right">
                    <Tooltip title="Edit">
                      <IconButton size="small" onClick={() => setEditing(p)}>
                        <EditIcon fontSize="small" />
                      </IconButton>
                    </Tooltip>
                    <Tooltip title="Delete">
                      <IconButton size="small" color="error" onClick={() => setDeleting(p)}>
                        <DeleteIcon fontSize="small" />
                      </IconButton>
                    </Tooltip>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
        {!data.items.length && <EmptyState title="No posts found" hint="Try another search" />}
        <TablePagination
          component="div"
          count={data.total}
          page={page}
          rowsPerPage={limit}
          rowsPerPageOptions={[5, 10, 25]}
          onPageChange={(_e, p) => setPage(p)}
          onRowsPerPageChange={(e) => {
            setLimit(+e.target.value);
            setPage(0);
          }}
        />
      </Paper>

      {editing && (
        <PostFormDialog
          key={editing === 'new' ? 'new' : editing.id}
          open
          post={editing === 'new' ? null : editing}
          loading={adding || updating}
          onSubmit={onSave}
          onClose={() => setEditing(null)}
        />
      )}
      <ConfirmDialog
        open={!!deleting}
        title="Delete post?"
        message={deleting?.title}
        loading={removing}
        onConfirm={onDelete}
        onClose={() => setDeleting(null)}
      />
    </Stack>
  );
}
