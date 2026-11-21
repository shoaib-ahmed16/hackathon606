import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';

// react-hook-form + zod in one line:
//   const { control, handleSubmit, reset, formState: { isSubmitting } } = useZodForm(schema, defaults);
// Errors show after the field is touched; all errors show on submit.
export function useZodForm(schema, defaultValues) {
  return useForm({ resolver: zodResolver(schema), defaultValues, mode: 'onTouched' });
}
