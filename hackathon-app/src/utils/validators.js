import { z } from 'zod';

// Reusable zod building blocks. Compose per form:
//   const schema = z.object({ email: rules.email, password: rules.password });
// Docs: https://zod.dev  (z.string().min(2,'msg'), z.coerce.number().positive(), z.enum([...]), .optional(), .refine(...))
export const rules = {
  required: (label = 'This field') => z.string().trim().min(1, `${label} is required`),
  email: z.string().trim().min(1, 'Email is required').pipe(z.email('Enter a valid email')),
  username: z
    .string()
    .trim()
    .min(3, 'At least 3 characters')
    .regex(/^[a-zA-Z0-9_.]+$/, 'Letters, numbers, _ and . only'),
  password: z.string().min(6, 'At least 6 characters'),
  phone: z
    .string()
    .trim()
    .regex(/^\+?[0-9\s-]{7,15}$/, 'Enter a valid phone number'),
  url: z.url('Enter a valid URL'),
  positiveNumber: z.coerce.number({ message: 'Enter a number' }).positive('Must be greater than 0'),
};

// Cross-field helper: schema.refine(...passwordsMatch)
export const passwordsMatch = [
  (v) => v.password === v.confirm,
  { message: 'Passwords do not match', path: ['confirm'] },
];
