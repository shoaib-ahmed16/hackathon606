import { z } from 'zod';
import { Button, Dialog, DialogActions, DialogContent, DialogTitle, Stack } from '@mui/material';
import { rules } from '@/utils/validators';
import FormTextField from '@/components/form/FormTextField';
import { useZodForm } from '@/components/form/useZodForm';

const schema = z.object({
  title: rules.required('Title'),
  body: rules.required('Body'),
});

// Create + edit form in one dialog. Pass `post` to edit, omit to create.
// Parent renders it with a `key` so the form resets: <PostFormDialog key={post?.id ?? 'new'} ... />
export default function PostFormDialog({ open, post, loading, onSubmit, onClose }) {
  const { control, handleSubmit } = useZodForm(schema, {
    title: post?.title ?? '',
    body: post?.body ?? '',
  });

  return (
    <Dialog open={open} onClose={onClose} maxWidth="sm" fullWidth>
      <form onSubmit={handleSubmit(onSubmit)} noValidate>
        <DialogTitle>{post ? 'Edit post' : 'New post'}</DialogTitle>
        <DialogContent>
          <Stack spacing={2} sx={{ pt: 1 }}>
            <FormTextField control={control} name="title" label="Title" autoFocus />
            <FormTextField control={control} name="body" label="Body" multiline minRows={3} />
          </Stack>
        </DialogContent>
        <DialogActions>
          <Button color="inherit" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" variant="contained" disabled={loading}>
            {post ? 'Save' : 'Create'}
          </Button>
        </DialogActions>
      </form>
    </Dialog>
  );
}
