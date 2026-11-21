import { Controller } from 'react-hook-form';
import { TextField } from '@mui/material';

// MUI TextField wired to react-hook-form (value, onChange, error + message).
//   <FormTextField control={control} name="email" label="Email" />
//   <FormTextField control={control} name="password" label="Password" as={PasswordField} />
//   <FormTextField control={control} name="role" label="Role" select><MenuItem value="a">A</MenuItem></FormTextField>
export default function FormTextField({ control, name, as: Field = TextField, ...props }) {
  return (
    <Controller
      control={control}
      name={name}
      render={({ field, fieldState }) => (
        <Field
          {...props}
          {...field}
          value={field.value ?? ''}
          error={!!fieldState.error}
          helperText={fieldState.error?.message ?? props.helperText ?? ''}
        />
      )}
    />
  );
}
