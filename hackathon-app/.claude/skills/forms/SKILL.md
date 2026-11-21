---
name: forms
description: Build forms quickly with react-hook-form + zod (fields, validation, submit with RTK mutation, server errors, toasts, dialog forms). Use for any create/edit/settings/login-style form.
---

# Forms (react-hook-form + zod + MUI)

Reference forms: `pages/Signup.jsx` (full page form, cross-field rule), `pages/Login.jsx`, `features/posts/PostFormDialog.jsx` (create/edit dialog).

```jsx
import { z } from 'zod';
import { rules, passwordsMatch } from '@/utils/validators';
import FormTextField from '@/components/form/FormTextField';
import { useZodForm } from '@/components/form/useZodForm';

const schema = z.object({
  name: rules.required('Name'),
  email: rules.email,
  age: rules.positiveNumber, // z.coerce.number() -> works with text inputs
});

const {
  control,
  handleSubmit,
  reset,
  watch,
  formState: { isSubmitting },
} = useZodForm(schema, { name: '', email: '', age: '' });

const onSubmit = async (values) => {
  // only runs when the schema passes
  try {
    await save(values).unwrap();
    toast.success('Saved');
    reset();
  } catch (e) {
    toast.error(getErrorMessage(e));
  }
};

<Stack component="form" onSubmit={handleSubmit(onSubmit)} noValidate spacing={2}>
  <FormTextField control={control} name="name" label="Name" />
  <FormTextField control={control} name="email" label="Email" />
  <FormTextField control={control} name="password" label="Password" as={PasswordField} />
  <FormTextField control={control} name="role" label="Role" select>
    <MenuItem value="admin">Admin</MenuItem>
  </FormTextField>
  <Button type="submit" variant="contained" disabled={isSubmitting}>
    Save
  </Button>
</Stack>;
```

- **Rules**: `src/utils/validators.js` has `rules.required/email/username/password/phone/url/positiveNumber` and `passwordsMatch`. Add project-wide rules there. Zod docs: `z.string().min(2, 'msg')`, `z.enum([...])`, `z.boolean()`, `z.array(...)`, `.optional()`, `.refine(fn, { message, path })`, `z.coerce.number()` / `.date()`.
- **Edit forms**: pass existing values as `defaultValues`; render the dialog/form with `key={item.id}` so it resets, or call `reset(item)` when data arrives.
- **Server errors**: show `<Alert severity="error">{getErrorMessage(error)}</Alert>` from the mutation's `error`, or `setError('email', { message })` for a field error.
- **Other inputs**: Checkbox/Switch/Select/DatePicker -> `Controller` from react-hook-form directly (see `FormTextField.jsx`). Dynamic lists -> `useFieldArray`.
- Errors show after a field is touched, and all at once on submit (`noValidate` on the form so the browser doesn't interfere).
